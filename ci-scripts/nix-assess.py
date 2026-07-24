#!/usr/bin/env python3
"""nix-assess — BP-02/BP-03 assessment-envelope producer (fail-closed join).

Joins this pipeline's three machine reports into ONE schema-versioned
assessment envelope (kasm-nix-assessment/v1) the remediator ingests:

    nix-scan-report.json      (scan-nix)     candidate identity + scanner/DB
    nix-build-report.json     (publish)      publication mappings
    sbom-attach-report.json   (sbom-publish) attestation results

Fail-closed per BP-03: a missing report, a scan row without a publication
mapping, a config-digest mismatch, a pushed image without a resolvable
manifest digest, or a published occurrence without a verified attestation
FAILS this job (exit 1) — after writing the truthful envelope, so the
failure is diagnosable. Vulnerability findings never fail this job; that is
the remediator's business.

Kinds produced:
    release    publishing pipelines (default branch / web / schedule / trigger)
    candidate  merge-request pipelines (no publication claims at all)

The schema contract is committed at ci-scripts/schemas/ and mirrored from
the kasm-nix-remediator repo (the consumer's strict parser is generated from
the same source). Structural validation here is self-contained (stdlib);
the remediator remains the authoritative gate.

Registry lookups (attestation existence for skipped_equivalent rows, manifest
fallback) go through the command named by $ASSESS_SKOPEO (default: skopeo)
so tests can stub it. Registry credentials via $REG_USER/$REG_PASS.

Usage: nix-assess.py --workdir DIR --out FILE
  DIR must hold nix-scan-report.json, grype/ and sboms/ (from scan-nix), and
  for release kinds nix-build-report.json (publish) + sbom-attach-report.json
  (sbom-publish). Job/pipeline identity from CI_* env.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_ID = "kasm-nix-assessment/v1"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SHA256_REF = re.compile(r"^sha256:[0-9a-f]{64}$")

errors: list[str] = []


def fail(msg: str) -> None:
    print(f"[nix-assess] FAIL: {msg}", file=sys.stderr)
    errors.append(msg)


def note(msg: str) -> None:
    print(f"[nix-assess] {msg}")


def norm_digest(value: str | None, what: str, profile: str) -> str | None:
    """Normalize podman (bare hex) / docker (sha256:hex) digests; None if absent."""
    if not value:
        return None
    v = value.strip().lower()
    if HEX64.match(v):
        v = f"sha256:{v}"
    if not SHA256_REF.match(v):
        fail(f"{profile}: {what} is not a sha256 digest: {value!r}")
        return None
    return v


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path, required: bool):
    if not path.is_file():
        if required:
            fail(f"required report missing: {path.name}")
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as e:
        fail(f"{path.name} is not valid JSON: {e}")
        return None


def pipeline_kind() -> str:
    src = os.environ.get("CI_PIPELINE_SOURCE", "")
    if src == "merge_request_event":
        return "merge_request"
    if src in ("schedule", "web", "trigger"):
        return src
    if os.environ.get("CI_COMMIT_BRANCH") and os.environ.get("CI_COMMIT_BRANCH") == os.environ.get(
        "CI_DEFAULT_BRANCH"
    ):
        return "default_branch"
    # push pipelines off the default branch don't publish; treat as candidate-ish web
    return "web"


def skopeo_digest(ref: str) -> str | None:
    """Resolve a manifest digest via skopeo inspect (auth from REG_USER/REG_PASS)."""
    cmd = [os.environ.get("ASSESS_SKOPEO", "skopeo"), "inspect", "--format", "{{.Digest}}"]
    user, pw = os.environ.get("REG_USER"), os.environ.get("REG_PASS")
    if user and pw:
        cmd += ["--creds", f"{user}:{pw}"]
    cmd.append(f"docker://{ref}")
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        note(f"skopeo unavailable for {ref}: {e}")
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


def attestation_digest_for(dest: str, manifest_digest: str) -> str | None:
    """cosign stores the attestation at <repo>:sha256-<hex>.att — resolve it."""
    repo = dest.rsplit(":", 1)[0]
    hexd = manifest_digest.split(":", 1)[1]
    return skopeo_digest(f"{repo}:sha256-{hexd}.att")


ACTION_MAP = {"pushed": "pushed", "skipped": "skipped_equivalent", "failed": "failed"}


def build_artifact(row: dict, pub: dict | None, att: dict | None, workdir: Path, kind: str) -> dict:
    profile = row["name"]
    art = row.get("artifact") or {}
    cand_cfg = norm_digest(art.get("config_digest"), "scan config_digest", profile)

    matches_rel = f"grype/{profile}.grype.json.gz"
    matches_path = workdir / matches_rel
    if not matches_path.is_file():
        fail(f"{profile}: raw grype artifact missing: {matches_rel}")
        matches = {"path": matches_rel, "sha256": "0" * 64}
    else:
        matches = {"path": matches_rel, "sha256": sha256_file(matches_path)}

    artifact: dict = {
        "profile": profile,
        "candidate": {"ref": art.get("ref") or f"candidate/unknown/{profile}", "config_digest": cand_cfg or "sha256:" + "0" * 64},
        "publication": None,
        "sbom": None,
        "matches_artifact": matches,
    }
    if not art.get("ref"):
        fail(f"{profile}: scan row has no candidate ref")
    if kind == "candidate":
        return artifact

    # ── release: publication join ────────────────────────────────────────────
    if pub is None:
        fail(f"{profile}: scanned but no publication mapping row exists (BP-03)")
        return artifact

    action_raw = pub.get("action") or ""
    basis = pub.get("equivalenceBasis") or ""
    action = ACTION_MAP.get(action_raw)
    if action is None or (action == "skipped_equivalent" and basis != "rootfs.diff_ids"):
        fail(
            f"{profile}: publish action {action_raw!r} basis {basis!r} is not a "
            f"recognized publication outcome (deliberately-unpublished profiles must "
            f"not appear in a release assessment)"
        )
        return artifact

    pub_cand_cfg = norm_digest(pub.get("candidateConfigDigest"), "publish candidateConfigDigest", profile)
    if pub_cand_cfg is None or cand_cfg is None or pub_cand_cfg != cand_cfg:
        fail(
            f"{profile}: config-digest join failed — scan {cand_cfg} vs publish {pub_cand_cfg} "
            f"(the scanned candidate is not the published candidate)"
        )

    intended = art.get("intended_ref")
    dest = pub.get("dest") or ""
    if not intended or intended != dest:
        fail(f"{profile}: intended_ref {intended!r} != publish dest {dest!r}")

    manifest = norm_digest(pub.get("manifestDigest"), "manifestDigest", profile)
    if manifest is None and action == "pushed":
        # docker builds can miss --digestfile; the digest is resolvable from the registry
        resolved = skopeo_digest(dest) if dest else None
        manifest = norm_digest(resolved, "registry-resolved manifestDigest", profile)
        if manifest is None:
            fail(f"{profile}: pushed but no manifest digest recorded or resolvable")
    if manifest is None and action == "skipped_equivalent":
        fail(f"{profile}: content-identical skip without the remote manifest digest")

    artifact["publication"] = {
        "intended_ref": intended or dest or "unknown",
        "action": action,
        "candidate_config_digest": pub_cand_cfg,
        "manifest_digest": manifest,
        "remote_config_digest": norm_digest(pub.get("remoteConfigDigest"), "remoteConfigDigest", profile),
        "equivalence_basis": basis or action_raw,
    }
    if action == "failed":
        fail(f"{profile}: publish action=failed — release assessment cannot accept this occurrence")
        return artifact

    # ── release: SBOM attestation join ───────────────────────────────────────
    sbom_rel = workdir / "sboms" / f"{profile}.cdx.json.gz"
    content_digest = f"sha256:{sha256_file(sbom_rel)}" if sbom_rel.is_file() else None
    if content_digest is None:
        fail(f"{profile}: CycloneDX SBOM artifact missing: sboms/{profile}.cdx.json.gz")

    att_digest = None
    result = "missing"
    if action == "pushed":
        if att is None:
            fail(f"{profile}: pushed but absent from sbom-attach-report (BP-03)")
        else:
            att_manifest = norm_digest(att.get("manifest_digest"), "attach manifest_digest", profile)
            att_digest = norm_digest(att.get("attestation_digest"), "attestation_digest", profile)
            if att.get("result") != "attested+signed":
                result = "failed"
                fail(f"{profile}: attestation result {att.get('result')!r} != attested+signed")
            elif att_manifest != manifest:
                result = "failed"
                fail(f"{profile}: attestation bound to {att_manifest}, publish pushed {manifest}")
            elif att_digest is None:
                result = "failed"
                fail(f"{profile}: attested but no attestation digest recorded")
            else:
                result = "verified"
    else:  # skipped_equivalent: the prior attestation must exist on the live manifest
        if manifest is not None:
            att_digest = norm_digest(
                attestation_digest_for(dest, manifest), "existing attestation digest", profile
            )
            if att_digest is not None:
                result = "verified"
            else:
                fail(
                    f"{profile}: content-identical skip but no attestation exists on the "
                    f"live manifest {manifest} (was it ever attested?)"
                )

    artifact["sbom"] = {
        "source_name": art.get("sbom_source_name") or intended or dest,
        "content_digest": content_digest or "sha256:" + "0" * 64,
        "attestation_digest": att_digest or "sha256:" + "0" * 64,
        "result": result,
    }
    return artifact


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    w = args.workdir

    kind = "candidate" if pipeline_kind() == "merge_request" else "release"
    note(f"assessment kind: {kind} (pipeline source {os.environ.get('CI_PIPELINE_SOURCE')!r})")

    scan = load_json(w / "nix-scan-report.json", required=True)
    build = load_json(w / "nix-build-report.json", required=(kind == "release"))
    attach = load_json(w / "sbom-attach-report.json", required=(kind == "release"))
    if scan is None:
        return 1

    commit = os.environ.get("CI_COMMIT_SHA", "")
    if not re.match(r"^[0-9a-f]{40}$", commit):
        fail(f"CI_COMMIT_SHA is not a 40-hex sha: {commit!r}")

    # cross-report source-commit agreement (BP-01's observable surface here)
    for name, doc, key in (
        ("nix-scan-report", scan, "commit"),
        ("nix-build-report", build, None),
        ("sbom-attach-report", attach, "source_commit"),
    ):
        if doc is None:
            continue
        val = doc.get(key) if key else (doc.get("run") or {}).get("gitSha")
        if val and commit and val != commit:
            fail(f"{name} was produced from commit {val}, this pipeline is {commit}")

    pub_rows = {r.get("profile"): r for r in (build or {}).get("images", [])}
    att_rows = {r.get("profile"): r for r in (attach or {}).get("images", [])}

    artifacts = []
    scanned = []
    for row in scan.get("images", []):
        name = row.get("name")
        if not name:
            fail("scan report contains a row without a name")
            continue
        scanned.append(name)
        artifacts.append(build_artifact(row, pub_rows.get(name), att_rows.get(name), w, kind))

    failed_scans = list(scan.get("failed") or [])
    not_built = list(scan.get("not_built") or [])
    requested = sorted(set(scanned) | set(failed_scans) | set(not_built))
    scanners = scan.get("scanners") or {}
    db_id = scanners.get("grype_db_checksum") or scanners.get("grype_db_built") or "unknown"

    envelope = {
        "schema": SCHEMA_ID,
        "assessment_kind": kind,
        "source": {
            "project": os.environ.get("CI_PROJECT_PATH", "unknown"),
            "pipeline_id": os.environ.get("CI_PIPELINE_ID", "0"),
            "commit": commit or "0" * 40,
            "assessment_job_id": os.environ.get("CI_JOB_ID", "0"),
            "pipeline_kind": pipeline_kind(),
            "scan_job_id": os.environ.get("SCAN_JOB_ID") or _job_id_from(scan) or None,
            "publish_job_id": ((build or {}).get("run") or {}).get("jobId") or None,
            "attestation_job_id": (attach or {}).get("job_id") or None,
        },
        "scanner": {
            "syft": scanners.get("syft") or "unknown",
            "grype": scanners.get("grype") or "unknown",
            "database_id": db_id,
            "database_built": scanners.get("grype_db_built") or "unknown",
        },
        "coverage": {
            "complete_for_requested_scope": not failed_scans and not not_built,
            "requested": requested,
            "scanned": sorted(scanned),
            "not_built": sorted(not_built),
            "failed": sorted(failed_scans),
        },
        "artifacts": artifacts,
    }

    if failed_scans:
        fail(f"scan report records failed scans: {failed_scans}")
    if not_built:
        note(f"coverage incomplete: requested-but-not-built {not_built}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(envelope, indent=2, sort_keys=True) + "\n")
    note(f"wrote {args.out} ({len(artifacts)} artifact(s), kind={kind})")

    if errors:
        print(f"[nix-assess] assurance join FAILED with {len(errors)} error(s); "
              f"the envelope above is truthful but this assessment is NOT trustworthy",
              file=sys.stderr)
        return 1
    note("assurance join clean")
    return 0


def _job_id_from(scan: dict) -> str | None:
    for row in scan.get("images", []):
        jid = (row.get("artifact") or {}).get("scan_job_id")
        if jid:
            return str(jid)
    return None


if __name__ == "__main__":
    raise SystemExit(main())

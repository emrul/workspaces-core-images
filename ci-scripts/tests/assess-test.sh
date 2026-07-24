#!/usr/bin/env bash
# assess-test.sh — BP-03 acceptance: "a committed negative fixture for each
# missing or mismatched artifact makes the join job fail."
#
# Runs ci-scripts/nix-assess.py against the committed base fixture
# (ci-scripts/tests/assess/base) and mutated negatives of it. The positive
# case must exit 0 and emit a structurally-valid kasm-nix-assessment/v1
# envelope; every negative must exit non-zero. Needs bash+python3 only
# (runs unchanged on the shell runner or inside $DIND_IMG).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSESS="${HERE}/../nix-assess.py"
BASE="${HERE}/assess/base"
STUB="${HERE}/assess/skopeo-stub"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export CI_COMMIT_SHA="ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12"
export CI_PROJECT_PATH="kasm-technologies/labs-sandbox/kasm-nix"
export CI_PIPELINE_ID="1234" CI_JOB_ID="5003"
export CI_PIPELINE_SOURCE="web"
export ASSESS_SKOPEO="${STUB}"

pass=0; failn=0
say() { printf '%s\n' "$*"; }

fresh() {  # new workdir from the base fixture
  rm -rf "${TMP}/w"; cp -R "${BASE}" "${TMP}/w"
}

run_assess() {  # $1 = workdir; echoes exit code
  local rc=0
  python3 "${ASSESS}" --workdir "$1" --out "$1/assessment.json" >"${TMP}/log" 2>&1 || rc=$?
  echo "${rc}"
}

expect() {  # $1=name $2=expected(zero|nonzero) $3=workdir
  local rc; rc="$(run_assess "$3")"
  if { [ "$2" = zero ] && [ "${rc}" = 0 ]; } || { [ "$2" = nonzero ] && [ "${rc}" != 0 ]; }; then
    say "PASS ${1}"; pass=$((pass+1))
  else
    say "FAIL ${1} (exit ${rc}, expected ${2})"; sed 's/^/    /' "${TMP}/log" | tail -12; failn=$((failn+1))
  fi
}

mutate() {  # $1=file-in-workdir $2=python statement over dict `d`
  python3 - "${TMP}/w/$1" "$2" <<'EOF'
import json, sys
path, stmt = sys.argv[1], sys.argv[2]
d = json.load(open(path))
exec(stmt)
json.dump(d, open(path, "w"), indent=2)
EOF
}

# ── positive: clean release join ─────────────────────────────────────────────
fresh; expect "release-clean" zero "${TMP}/w"
python3 - "${TMP}/w/assessment.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "kasm-nix-assessment/v1"
assert d["assessment_kind"] == "release"
assert d["coverage"]["complete_for_requested_scope"] is True
arts = {a["profile"]: a for a in d["artifacts"]}
assert set(arts) == {"chrome", "obsidian"}
c = arts["chrome"]
assert c["candidate"]["config_digest"] == "sha256:" + "11" * 32   # normalized from bare hex
assert c["publication"]["action"] == "pushed"
assert c["sbom"]["result"] == "verified"
o = arts["obsidian"]
assert o["publication"]["action"] == "skipped_equivalent"
assert o["publication"]["equivalence_basis"] == "rootfs.diff_ids"
assert o["sbom"]["result"] == "verified"                          # via stubbed .att lookup
assert all(len(a["matches_artifact"]["sha256"]) == 64 for a in d["artifacts"])
assert d["source"]["scan_job_id"] == "5001"
assert d["source"]["attestation_job_id"] == "5002"
assert d["source"]["publish_job_id"] == "5000"
print("envelope structure OK")
EOF
say "PASS release-envelope-structure"; pass=$((pass+1))

# ── positive: MR candidate (no publication inputs at all) ────────────────────
fresh
rm "${TMP}/w/nix-build-report.json" "${TMP}/w/sbom-attach-report.json"
CI_PIPELINE_SOURCE="merge_request_event" expect "candidate-mr" zero "${TMP}/w"
python3 - "${TMP}/w/assessment.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["assessment_kind"] == "candidate"
assert d["source"]["pipeline_kind"] == "merge_request"
assert all(a["publication"] is None and a["sbom"] is None for a in d["artifacts"])
print("candidate envelope OK")
EOF
say "PASS candidate-envelope-structure"; pass=$((pass+1))

# ── negatives: each missing/mismatched artifact fails the join ───────────────
fresh; rm "${TMP}/w/nix-build-report.json"
expect "neg-missing-build-report" nonzero "${TMP}/w"

fresh; rm "${TMP}/w/sbom-attach-report.json"
expect "neg-missing-attach-report" nonzero "${TMP}/w"

fresh; mutate nix-build-report.json 'd["images"][0]["candidateConfigDigest"] = "99"*32'
expect "neg-config-digest-mismatch" nonzero "${TMP}/w"

fresh; mutate nix-build-report.json 'd["images"] = [d["images"][1]]'   # chrome scanned, no mapping
expect "neg-scan-row-without-mapping" nonzero "${TMP}/w"

fresh; mutate nix-build-report.json 'd["images"][0]["dest"] = "registry.example.test/kasm-nix/other:nix"'
expect "neg-intended-ref-mismatch" nonzero "${TMP}/w"

fresh; mutate nix-build-report.json 'd["images"][0].update(action="failed", manifestDigest="", equivalenceBasis="")'
expect "neg-publish-failed" nonzero "${TMP}/w"

fresh; mutate nix-build-report.json 'd["images"][1]["manifestDigest"] = ""'
expect "neg-skip-without-remote-manifest" nonzero "${TMP}/w"

fresh; mutate sbom-attach-report.json 'd["images"] = []'      # pushed but never attested
expect "neg-pushed-not-attested" nonzero "${TMP}/w"

fresh; mutate sbom-attach-report.json 'd["images"][0].update(result="attest-failed", attestation_digest="")'
expect "neg-attestation-failed" nonzero "${TMP}/w"

fresh; mutate sbom-attach-report.json 'd["images"][0]["manifest_digest"] = "88"*32'
expect "neg-attestation-wrong-manifest" nonzero "${TMP}/w"

fresh; mutate nix-scan-report.json 'd["commit"] = "ff"*20'
expect "neg-cross-report-commit-mismatch" nonzero "${TMP}/w"

fresh; rm "${TMP}/w/grype/chrome.grype.json.gz"
expect "neg-missing-grype-artifact" nonzero "${TMP}/w"

fresh; rm "${TMP}/w/sboms/chrome.cdx.json.gz"
expect "neg-missing-sbom-artifact" nonzero "${TMP}/w"

fresh; mutate nix-scan-report.json 'd["failed"] = ["zoom"]'
expect "neg-failed-scan-recorded" nonzero "${TMP}/w"

fresh  # attestation absent on the live registry for the content-identical skip
ASSESS_STUB_EMPTY=1 expect "neg-skip-attestation-absent-on-registry" nonzero "${TMP}/w"

say ""
say "assess-test: ${pass} passed, ${failn} failed"
[ "${failn}" -eq 0 ]

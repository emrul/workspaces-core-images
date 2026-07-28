#!/usr/bin/env python3
"""nix-seccomp-audit.py — does the registry actually serve every workspace the
seccomp profile its image requires?

Why this exists: on 2026-07-28 two engineers got a broken TraceLabs desktop
(xfce4-panel aborting on every icon) while it worked for the maintainer. The
requirement — "this workspace needs the bwrap profile, not the chrome one" —
existed in three disconnected places: a comment in onlyoffice/launch, the
registry's hand-maintained workspace.json, and nobody's checklist. Nothing
compared them, so a workspace could silently be served the wrong profile.

The requirement is now declared once, in bin/nix-profiles.toml, and stamped onto
each image as dev.kasm.seccomp.profile. This audit closes the loop: it compares
the declaration against what the registry actually serves.

The two profiles are distinguished by capability, not by name — both carry the
same `_patch` string, so only the syscall set tells them apart:

    bwrap  : mount + pivot_root allowed UNCONDITIONALLY (no capability gate)
    chrome : unshare allowed, mount/pivot_root NOT

A workspace that needs bwrap but is served chrome is the dangerous case: bwrap
gets far enough to create the user namespace and is then denied at the mount
stage, which glycin does not recognise as "sandbox unavailable", so it never
falls back and GTK aborts on the fallback icon.

    ./nix-seccomp-audit.py --registry https://kasm-nix-registry.emrul.dev/1.1/list.json

Exit 0 = every declaration satisfied. Exit 1 = drift (or a workspace missing).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REQUIRED_UNCONDITIONAL = ("mount", "pivot_root")


def declared_profiles(toml_path: Path) -> dict[str, str]:
    """profile -> required seccomp, read from nix-profiles.toml.

    Deliberately regex rather than a TOML parser: this must run on any python3
    in CI, and tomllib is 3.11+ (the shell runner here is 3.10)."""
    text = toml_path.read_text()
    out: dict[str, str] = {}
    for m in re.finditer(r"^\[profiles\.([A-Za-z0-9_-]+)\]((?:(?!^\[).)*)", text, re.M | re.S):
        name, body = m.group(1), m.group(2)
        sec = re.search(r'^seccomp\s*=\s*"([a-z]+)"', body, re.M)
        kasm = re.search(r'^kasm_name\s*=\s*"([^"]+)"', body, re.M)
        out[kasm.group(1) if kasm else name] = sec.group(1) if sec else "chrome"
    return out


def served_profiles(url: str) -> dict[str, str]:
    """kasm image name -> the profile the registry actually serves."""
    with urllib.request.urlopen(url, timeout=60) as r:
        doc = json.load(r)
    workspaces = doc.get("workspaces") or doc.get("list") or []
    out: dict[str, str] = {}
    for w in workspaces:
        # The docker image is not a top-level field in this registry format: it
        # lives under compatibility[].image (per supported Kasm version).
        image = ""
        for c in (w.get("compatibility") or []):
            if c.get("image"):
                image = c["image"]
                break
        if not image:
            image = w.get("image") or w.get("name") or ""
        key = image.rsplit("/", 1)[-1].split(":", 1)[0]
        if not key:
            continue
        rc = w.get("run_config") or {}
        raw = next((s.split("seccomp=", 1)[1]
                    for s in (rc.get("security_opt") or []) if "seccomp=" in s), None)
        if raw is None:
            out[key] = "none"
            continue
        try:
            prof = json.loads(raw)
        except json.JSONDecodeError:
            out[key] = "unparseable"
            continue
        allowed: set[str] = set()
        for blk in prof.get("syscalls", []):
            if blk.get("action") != "SCMP_ACT_ALLOW" or blk.get("includes"):
                continue  # `includes` = gated on a capability/arch, not unconditional
            allowed |= set(blk.get("names", []))
        out[key] = "bwrap" if all(s in allowed for s in REQUIRED_UNCONDITIONAL) else "chrome"
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profiles", default=str(Path(__file__).resolve().parent.parent / "bin" / "nix-profiles.toml"))
    ap.add_argument("--registry", required=True)
    ap.add_argument("--warn-missing", action="store_true",
                    help="treat a declared workspace absent from the registry as a warning")
    args = ap.parse_args(argv)

    want = declared_profiles(Path(args.profiles))
    try:
        have = served_profiles(args.registry)
    except Exception as e:  # network/registry problems must not read as "all clear"
        print(f"FAIL: could not read the registry: {e}", file=sys.stderr)
        return 1

    drift, missing = [], []
    for name, need in sorted(want.items()):
        got = have.get(name)
        if got is None:
            missing.append(name)
        elif need == "bwrap" and got != "bwrap":
            drift.append((name, need, got))

    for name, need, got in drift:
        print(f"DRIFT  {name}: requires {need}, registry serves {got}")
    for name in missing:
        print(f"{'WARN ' if args.warn_missing else 'DRIFT'}  {name}: declared but not in the registry")

    ok = len(want) - len(drift) - len(missing)
    print(f"\n{ok}/{len(want)} declarations satisfied "
          f"({sum(1 for v in want.values() if v == 'bwrap')} require bwrap)")
    if drift or (missing and not args.warn_missing):
        print("\nA workspace that requires bwrap but is served chrome will create a "
              "user namespace and then be denied at the mount stage — which glycin "
              "does not detect, so the desktop aborts instead of degrading.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

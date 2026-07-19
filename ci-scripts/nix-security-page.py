#!/usr/bin/env python3
"""nix-security-page.py — merge a scan report into the live security.json.

Called by the security-page CI job after every successful scan-nix on the
default branch. Unlike the registry repo's gen_security.py (full-catalog
regeneration for manual deploys), this UPSERTS: change-gated pipelines scan
only the apps that rebuilt, so their rows are merged into the currently
served file instead of replacing it — the twice-daily chrome pipeline
refreshes chrome's row without touching the other 40.

Usage: nix-security-page.py <nix-scan-report.json> <out: security.json>
Env:   LIVE_URL  currently served file (default the /1.1/ deployment)

Exit 0 with a SKIP message (and no output file) when publishing would make
the served data worse: failed scans in the report, no rows, or the live
file being unavailable while this report covers only a slice of the
catalog. The CI job treats "no output file" as nothing-to-publish.
"""
import json
import sys
import time
import urllib.request

LIVE_URL = "https://kasm-nix-registry.emrul.dev/1.1/security.json"
FRESH_MIN_IMAGES = 20  # full-catalog threshold for seeding without a live file


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    report_path, out_path = sys.argv[1], sys.argv[2]
    import os
    live_url = os.environ.get("LIVE_URL", LIVE_URL)

    report = json.loads(open(report_path).read())
    if report.get("failed"):
        print(f"SKIP: report has failed scans: {report['failed']}")
        return 0
    rows = report.get("images", [])
    if not rows:
        print("SKIP: report has no image rows")
        return 0

    live = None
    try:
        with urllib.request.urlopen(live_url, timeout=30) as r:
            live = json.loads(r.read())
    except Exception as e:  # noqa: BLE001 — any fetch failure handled the same
        print(f"live fetch failed ({e})", file=sys.stderr)
    if live is None and len(rows) < FRESH_MIN_IMAGES:
        print(f"SKIP: no live file and report covers only {len(rows)} images "
              f"(<{FRESH_MIN_IMAGES}) — refusing to shrink the served table")
        return 0

    today = time.strftime("%Y-%m-%d", time.gmtime())
    merged = {i["name"]: i for i in (live or {}).get("images", [])}
    for i in rows:
        merged[i["name"]] = {
            "name": i["name"],
            "packages": i["packages"],
            "cves": i["cves"],
            "updated": today,
        }
    out = {
        "scanned_at": today,
        "scanners": report.get("scanners", {}),
        "vex": report.get("vex", {}),
        "commit": report.get("commit", ""),
        "images": sorted(merged.values(), key=lambda i: i["name"]),
    }
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print(f"wrote {out_path}: {len(rows)} row(s) updated, "
          f"{len(out['images'])} total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

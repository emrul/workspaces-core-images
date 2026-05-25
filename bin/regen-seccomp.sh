#!/usr/bin/env bash
# regen-seccomp.sh — regenerate src/common/seccomp/chrome.json from a
# pinned Docker (moby/moby) upstream seccomp default profile.
#
# The output is the upstream profile with three rule deletions and
# one rule addition, capturing the patch needed to permit unprivileged
# user-namespace sandboxes (Chrome, Electron, bwrap, glycin) without
# weakening any other CAP_SYS_ADMIN gates.
#
# Always re-run this when bumping MOBY_TAG so the baseline stays
# auditable. The committed chrome.json carries `_baseline` and
# `_patch` provenance fields so reviewers can diff against the exact
# upstream version we forked from.
#
# Usage:
#   bin/regen-seccomp.sh                       # use pinned MOBY_TAG
#   MOBY_TAG=v25.0.7 bin/regen-seccomp.sh      # bump baseline

set -euo pipefail

# ───── Pinned baseline ─────────────────────────────────────────────────
MOBY_TAG="${MOBY_TAG:-v25.0.6}"
BASELINE_URL="https://raw.githubusercontent.com/moby/moby/${MOBY_TAG}/profiles/seccomp/default.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_PATH="${REPO_ROOT}/src/common/seccomp/chrome.json"

# ───── Preflight ───────────────────────────────────────────────────────
command -v jq   >/dev/null || { echo "jq is required"   >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

# ───── Fetch baseline ──────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "→ fetching moby ${MOBY_TAG} default seccomp profile" >&2
curl -fsSL "${BASELINE_URL}" -o "${TMP}/baseline.json"

# Sanity-check the baseline still has the rules we expect to patch.
# If upstream restructures the clone rule, fail loudly rather than
# silently producing a no-op patch.
RESTRICTIVE_CLONE_COUNT=$(jq '
  [.syscalls[] | select(
    (.names == ["clone"])
    and ((.args // []) | any(.value == 2114060288))
  )] | length
' "${TMP}/baseline.json")
CLONE3_ERRNO_COUNT=$(jq '
  [.syscalls[] | select(
    (.names == ["clone3"]) and (.action == "SCMP_ACT_ERRNO")
  )] | length
' "${TMP}/baseline.json")

if [[ "${RESTRICTIVE_CLONE_COUNT}" -lt 1 || "${CLONE3_ERRNO_COUNT}" -lt 1 ]]; then
  cat >&2 <<EOF
ERROR: baseline ${MOBY_TAG} no longer has the expected restrictive
rules (found clone=${RESTRICTIVE_CLONE_COUNT}, clone3_errno=${CLONE3_ERRNO_COUNT}).
Upstream may have restructured the profile. Re-inspect and update
this script's patch filter before regenerating.
EOF
  exit 2
fi

# ───── Apply patch ─────────────────────────────────────────────────────
echo "→ patching: drop ${RESTRICTIVE_CLONE_COUNT} restrictive clone rule(s)" >&2
echo "→ patching: drop ${CLONE3_ERRNO_COUNT} clone3 ENOSYS rule(s)"          >&2
echo "→ patching: add 1 permissive rule for clone/clone3/unshare/setns"      >&2

jq --arg moby "${MOBY_TAG}" '
  {
    _baseline: ("moby/moby \($moby) profiles/seccomp/default.json"),
    _patch: "kasm-chrome: drop unprivileged clone/clone3 restrictions; allow clone/clone3/unshare/setns unconditionally. Regenerate with bin/regen-seccomp.sh.",
    _regen: "MOBY_TAG=\($moby) bin/regen-seccomp.sh"
  } + .
  | .syscalls |= map(
      select(
        ((.names == ["clone"]) and ((.args // []) | any(.value == 2114060288))) | not
      )
    )
  | .syscalls |= map(
      select(
        ((.names == ["clone3"]) and (.action == "SCMP_ACT_ERRNO")) | not
      )
    )
  | .syscalls += [{
      names: ["clone", "clone3", "unshare", "setns"],
      action: "SCMP_ACT_ALLOW",
      comment: "Kasm: allow user-namespace sandboxing (Chrome, Electron, bwrap, glycin) without CAP_SYS_ADMIN. Replaces Docker default rules that gated these on CAP_SYS_ADMIN."
    }]
' "${TMP}/baseline.json" > "${OUT_PATH}"

# ───── Verify result ───────────────────────────────────────────────────
jq empty "${OUT_PATH}"

DEFAULT_ACTION=$(jq -r '.defaultAction' "${OUT_PATH}")
if [[ "${DEFAULT_ACTION}" != "SCMP_ACT_ERRNO" ]]; then
  echo "ERROR: defaultAction changed to ${DEFAULT_ACTION} (expected SCMP_ACT_ERRNO)" >&2
  exit 3
fi

POST_RESTRICTIVE=$(jq '
  [.syscalls[] | select(
    (.names == ["clone"])
    and ((.args // []) | any(.value == 2114060288))
  )] | length
' "${OUT_PATH}")
POST_CLONE3_ERRNO=$(jq '
  [.syscalls[] | select(
    (.names == ["clone3"]) and (.action == "SCMP_ACT_ERRNO")
  )] | length
' "${OUT_PATH}")

if [[ "${POST_RESTRICTIVE}" -ne 0 || "${POST_CLONE3_ERRNO}" -ne 0 ]]; then
  echo "ERROR: patch did not fully remove restrictive rules" >&2
  exit 4
fi

echo "✓ wrote ${OUT_PATH}" >&2
echo "  baseline:  moby/moby ${MOBY_TAG}" >&2
echo "  audit:     make seccomp-audit" >&2

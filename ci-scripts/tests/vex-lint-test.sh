#!/usr/bin/env bash
# vex-lint-test.sh — regression tests for ci-scripts/nix-vex-lint.sh, the
# gate that turns OpenVEX statements into grype suppression rules. This code
# controls what the scanner HIDES, so every rejection case is a committed
# fixture (ci-scripts/tests/vex/), not a claim in a commit message.
#
# Run locally (repo root or anywhere): bash ci-scripts/tests/vex-lint-test.sh
# CI: the vex-lint job runs it on changes to the lint script, the fixtures,
# or the live VEX file.
set -euo pipefail

HERE="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LINT="${HERE}/../nix-vex-lint.sh"
FIX="${HERE}/vex"
LIVE="${HERE}/../../security/vex/kasm-nix.openvex.json"

pass=0; failcnt=0
expect_reject() {  # $1=fixture $2=grep pattern for the failure reason
  local out
  if out="$(bash "${LINT}" "${FIX}/$1" 2>&1)"; then
    echo "FAIL: $1 was ACCEPTED (must be rejected)"; failcnt=$((failcnt+1))
  elif ! grep -q "$2" <<<"${out}"; then
    echo "FAIL: $1 rejected for the wrong reason: ${out}"; failcnt=$((failcnt+1))
  else
    pass=$((pass+1))
  fi
}
expect_rule() {  # $1=file $2=exact rule fragment expected in output [$3=--scope args]
  local out
  if ! out="$(bash "${LINT}" ${3:-} "$1" 2>&1)"; then
    echo "FAIL: $(basename "$1") was REJECTED: ${out}"; failcnt=$((failcnt+1))
  elif ! grep -qF "$2" <<<"${out}"; then
    echo "FAIL: $(basename "$1") missing expected rule '$2'; got: ${out}"; failcnt=$((failcnt+1))
  else
    pass=$((pass+1))
  fi
}
expect_no_rule() {  # $1=file $2=fragment that must NOT appear [$3=--scope args]
  local out
  if ! out="$(bash "${LINT}" ${3:-} "$1" 2>&1)"; then
    echo "FAIL: $(basename "$1") was REJECTED: ${out}"; failcnt=$((failcnt+1))
  elif grep -qF "$2" <<<"${out}"; then
    echo "FAIL: $(basename "$1") emitted '$2' but must not; got: ${out}"; failcnt=$((failcnt+1))
  else
    pass=$((pass+1))
  fi
}

expect_reject invalid-no-doc-version.json        "document fields"
expect_reject invalid-no-vuln-name.json          "vulnerability.name"
expect_reject invalid-bad-justification.json     "justification"
expect_reject invalid-empty-subcomponents.json   "subcomponent"
expect_reject invalid-false-positive-status.json "non-OpenVEX status"
expect_reject invalid-narrow-scope.json          "unrecognised product scope"

# Qualifiers/subpath must be stripped from the emitted version; namespaced
# purl keeps the full module path as the grype package name.
expect_rule "${FIX}/valid-qualified-purl.json" "name: golang.org/x/crypto"
expect_rule "${FIX}/valid-qualified-purl.json" "version: v0.50.0"

# ── profile scope ─────────────────────────────────────────────────────────────
# Non-reachability is a per-image property: perl 5.42.0 is the SAME store path
# everywhere it ships, so a statement assured for tracelabs must not suppress it
# in a profile whose perl consumer was never examined.

# Rejections: an unrecognised scope key, and a scope naming a profile that does
# not exist (which would suppress nothing while reading as though it does).
expect_reject invalid-bad-scope-key.json "unrecognised product scope"
PROFILES_TOML="${HERE}/../../bin/nix-profiles.toml" \
  expect_reject invalid-unknown-profile.json "not a profile in"

# A profile-scoped statement suppresses ONLY under its own scope.
expect_no_rule "${FIX}/valid-profile-scope.json" "vulnerability: CVE-2026-13221"
expect_rule    "${FIX}/valid-profile-scope.json" "vulnerability: CVE-2026-13221" "--scope tracelabs"
expect_no_rule "${FIX}/valid-profile-scope.json" "vulnerability: CVE-2026-13221" "--scope inkscape"

# Catalog-wide statements apply under every scope; profile-scoped ones do not
# leak across scopes.
expect_rule    "${FIX}/valid-mixed-scope.json" "vulnerability: CVE-1111-1111"
expect_rule    "${FIX}/valid-mixed-scope.json" "vulnerability: CVE-1111-1111" "--scope inkscape"
expect_no_rule "${FIX}/valid-mixed-scope.json" "vulnerability: CVE-2222-2222" "--scope inkscape"
expect_rule    "${FIX}/valid-mixed-scope.json" "vulnerability: CVE-2222-2222" "--scope tracelabs"


# The LIVE statement file must always lint (a broken live file fails every
# scan job — catch it here first).
expect_rule "${LIVE}" "vulnerability: CVE-"

echo "vex-lint-test: ${pass} passed, ${failcnt} failed"
exit "$(( failcnt > 0 ))"

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
expect_rule() {  # $1=file $2=exact rule fragment expected in output
  local out
  if ! out="$(bash "${LINT}" "$1" 2>&1)"; then
    echo "FAIL: $(basename "$1") was REJECTED: ${out}"; failcnt=$((failcnt+1))
  elif ! grep -qF "$2" <<<"${out}"; then
    echo "FAIL: $(basename "$1") missing expected rule '$2'; got: ${out}"; failcnt=$((failcnt+1))
  else
    pass=$((pass+1))
  fi
}

expect_reject invalid-no-doc-version.json        "document fields"
expect_reject invalid-no-vuln-name.json          "vulnerability.name"
expect_reject invalid-bad-justification.json     "justification"
expect_reject invalid-empty-subcomponents.json   "subcomponent"
expect_reject invalid-false-positive-status.json "non-OpenVEX status"
expect_reject invalid-narrow-scope.json          "not catalog-scoped"

# Qualifiers/subpath must be stripped from the emitted version; namespaced
# purl keeps the full module path as the grype package name.
expect_rule "${FIX}/valid-qualified-purl.json" "name: golang.org/x/crypto"
expect_rule "${FIX}/valid-qualified-purl.json" "version: v0.50.0"

# The LIVE statement file must always lint (a broken live file fails every
# scan job — catch it here first).
expect_rule "${LIVE}" "vulnerability: CVE-"

echo "vex-lint-test: ${pass} passed, ${failcnt} failed"
exit "$(( failcnt > 0 ))"

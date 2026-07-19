#!/usr/bin/env bash
# nix-vex-lint.sh — validate the OpenVEX statement file and emit the grype
# ignore rules derived from it (stdout). Single source of truth for the
# checks: called by nix-scan-l3.sh before every scan, and exercised against
# committed invalid fixtures by ci-scripts/tests/vex-lint-test.sh.
#
# Checks (fail-loud, exit 1 with a reason on stderr):
#   - document fields: @context, @id, author, timestamp, numeric version
#   - statements[] present; every statement has vulnerability.name
#   - status ∈ the OpenVEX vocabulary (false_positive is NOT a status)
#   - not_affected statements: justification-or-impact_statement, with any
#     justification restricted to the OpenVEX five-value vocabulary;
#     non-empty products, each with non-empty subcomponents whose purls
#     carry an exact version
#   - product scope: grype ignore rules are catalog-wide by mechanism, so
#     every product @id must equal ${VEX_CATALOG_PRODUCT} — narrower scopes
#     are rejected rather than silently over-applied
#
# Emitted rules pin vulnerability + package name + EXACT version (purl
# qualifiers/subpath stripped) — a name-only rule would keep suppressing
# every future version after the statement's basis stops applying.
#
# This is a GATE, not an OpenVEX validator of record — authoring tooling
# (the remediator's draft_vex adapter) validates with a real OpenVEX
# implementation before statements land here.
set -euo pipefail

VEX_FILE="${1:?usage: nix-vex-lint.sh <openvex.json>}"
VEX_CATALOG_PRODUCT="${VEX_CATALOG_PRODUCT:-https://kasm-nix-registry.emrul.dev/catalog}"

die() { echo "[nix-vex-lint] FAIL: $*" >&2; exit 1; }

[ -f "${VEX_FILE}" ] || die "no such file: ${VEX_FILE}"
jq -e '.statements | type == "array"' "${VEX_FILE}" >/dev/null 2>&1 \
  || die "not valid OpenVEX (no statements array)"
jq -e '."@context" and ."@id" and .author and .timestamp and (.version | type == "number")' "${VEX_FILE}" >/dev/null \
  || die "missing required document fields (@context/@id/author/timestamp/version)"
jq -e '[.statements[] | (.vulnerability.name // "") | length > 0] | all' "${VEX_FILE}" >/dev/null \
  || die "statement(s) missing vulnerability.name"

bad_status="$(jq -r '[.statements[].status]
  | map(select(. != "not_affected" and . != "affected" and . != "fixed" and . != "under_investigation"))
  | join(" ")' "${VEX_FILE}")"
[ -z "${bad_status}" ] || die "non-OpenVEX status(es): ${bad_status}"

bad_just="$(jq -r '[.statements[]
  | select(.status=="not_affected") | .justification // empty
  | select(. != "component_not_present" and . != "vulnerable_code_not_present"
       and . != "vulnerable_code_not_in_execute_path"
       and . != "vulnerable_code_cannot_be_controlled_by_adversary"
       and . != "inline_mitigations_already_exist")] | join(" ")' "${VEX_FILE}")"
[ -z "${bad_just}" ] || die "justification(s) outside the OpenVEX vocabulary: ${bad_just}"

bad_shape="$(jq -r '.statements[]
  | select(.status=="not_affected")
  | select(
      ((.justification // .impact_statement // "") == "")
      or ((.products // []) | length == 0)
      or ([.products[] | (.subcomponents // []) | length] | min // 0) == 0
      or ([.products[].subcomponents[]."@id"
           | test("^pkg:[^/]+/[^@]+@.+$") | not] | any)
    )
  | .vulnerability.name' "${VEX_FILE}")"
[ -z "${bad_shape}" ] || die "not_affected statement(s) missing justification/products/versioned subcomponent purls: ${bad_shape}"

narrow="$(jq -r --arg cat "${VEX_CATALOG_PRODUCT}" '.statements[]
  | select(.status=="not_affected")
  | select([.products[]."@id"] | all(. == $cat) | not)
  | .vulnerability.name' "${VEX_FILE}")"
[ -z "${narrow}" ] || die "statement(s) not catalog-scoped (grype ignore rules cannot express narrower products): ${narrow}"

echo "ignore:"
jq -r '.statements[]
       | select(.status=="not_affected")
       | .vulnerability.name as $v
       | .products[].subcomponents[]."@id"
       | capture("^pkg:[^/]+/(?<n>[^@]+)@(?<ver>[^?#]+)")
       | "  - vulnerability: \($v)\n    package:\n      name: \(.n)\n      version: \(.ver)"' "${VEX_FILE}"

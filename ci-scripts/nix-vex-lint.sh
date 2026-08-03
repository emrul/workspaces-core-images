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
#   - product scope: every product @id must be either ${VEX_CATALOG_PRODUCT}
#     (catalog-wide) or ${VEX_CATALOG_PRODUCT}#profile=<name> (one profile).
#     Anything else is rejected rather than silently over-applied.
#   - profile-scoped ids must name a profile that EXISTS in nix-profiles.toml,
#     because a typo would otherwise be a silent no-op — a statement that
#     suppresses nothing while reading as though it does
#
# Emitted rules pin vulnerability + package name + EXACT version (purl
# qualifiers/subpath stripped) — a name-only rule would keep suppressing
# every future version after the statement's basis stops applying.
#
# ── Why profile scope exists ──────────────────────────────────────────────────
# A grype ignore rule cannot express "only in image X": name+version is all it
# matches on. So scope is enforced by WHICH RULES ARE EMITTED, not by the rule
# body — the caller passes --scope <profile> per scan and gets the catalog-wide
# statements plus that profile's. Without --scope, ONLY catalog-wide statements
# are emitted, so a caller that forgets it under-suppresses (a visible finding)
# rather than over-suppressing (a hidden one).
#
# This matters because non-reachability is a per-image property. perl 5.42.0 is
# the SAME store path in every profile that ships it, so store-path scoping
# cannot separate consumers: kasmvnc and xdg-utils (assured non-reachable) share
# it with hspell's multispell reached via inkscape -> enchant (not assured). The
# profile is the only axis on which that distinction is expressible.
#
# This is a GATE, not an OpenVEX validator of record — authoring tooling
# (the remediator's draft_vex adapter) validates with a real OpenVEX
# implementation before statements land here.
set -euo pipefail

SCOPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="${2:?--scope needs a profile name}"; shift 2 ;;
    --scope=*) SCOPE="${1#--scope=}"; shift ;;
    *) break ;;
  esac
done

VEX_FILE="${1:?usage: nix-vex-lint.sh [--scope <profile>] <openvex.json>}"
VEX_CATALOG_PRODUCT="${VEX_CATALOG_PRODUCT:-https://kasm-nix-registry.emrul.dev/catalog}"
PROFILES_TOML="${PROFILES_TOML:-}"

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

bad_scope="$(jq -r --arg cat "${VEX_CATALOG_PRODUCT}" '.statements[]
  | select(.status=="not_affected")
  | select([.products[]."@id"]
           | all(. == $cat or startswith($cat + "#profile=")) | not)
  | .vulnerability.name' "${VEX_FILE}")"
[ -z "${bad_scope}" ] || die "statement(s) with an unrecognised product scope — want ${VEX_CATALOG_PRODUCT} or ${VEX_CATALOG_PRODUCT}#profile=<name>: ${bad_scope}"

# Profile names: grammar, then existence. An id naming a profile that does not
# exist suppresses nothing while reading as though it does, which is the one
# failure mode a reviewer cannot see by reading the statement.
scoped_profiles="$(jq -r --arg cat "${VEX_CATALOG_PRODUCT}" '.statements[]
  | select(.status=="not_affected") | .products[]."@id"
  | select(startswith($cat + "#profile="))
  | sub("^.*#profile="; "")' "${VEX_FILE}" | sort -u)"

for p in ${scoped_profiles}; do
  printf '%s' "${p}" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' \
    || die "profile scope '${p}' is not a valid profile name"
done

if [ -n "${scoped_profiles}" ] && [ -n "${PROFILES_TOML}" ] && [ -f "${PROFILES_TOML}" ]; then
  for p in ${scoped_profiles}; do
    grep -Eq "^\[profiles\.${p}\]" "${PROFILES_TOML}" \
      || die "profile scope '${p}' is not a profile in ${PROFILES_TOML} (a typo here suppresses nothing but reads as though it does)"
  done
fi

if [ -n "${SCOPE}" ]; then
  printf '%s' "${SCOPE}" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' \
    || die "--scope '${SCOPE}' is not a valid profile name"
fi

# Emission. Catalog-wide statements always; profile-scoped only when the caller
# names that profile. No --scope means catalog-wide only — under-suppressing on
# a forgotten flag leaves a finding visible, which is the safe direction.
echo "ignore:"
jq -r --arg cat "${VEX_CATALOG_PRODUCT}" --arg scope "${SCOPE}" '.statements[]
       | select(.status=="not_affected")
       | .vulnerability.name as $v
       | [ .products[]
           | select(."@id" == $cat
                    or ($scope != "" and ."@id" == ($cat + "#profile=" + $scope))) ] as $ps
       | select(($ps | length) > 0)
       | $ps[].subcomponents[]."@id"
       | capture("^pkg:[^/]+/(?<n>[^@]+)@(?<ver>[^?#]+)")
       | "  - vulnerability: \($v)\n    package:\n      name: \(.n)\n      version: \(.ver)"' "${VEX_FILE}"

#!/usr/bin/env bash
# nix-verify-base.sh — report which OS base each PUBLISHED workspace image is built
# on, straight from the registry.
#
# curl + python3 only. No skopeo (none of our hosts has it), no crane, and no image
# pulls: it reads the manifest and the config blob, so verifying the whole catalogue
# costs seconds and a few hundred KB rather than tens of gigabytes.
#
# The labels come from ci-scripts/nix-base-build.sh (stamped on the distro base) and
# are re-stamped per app by bin/nix-crane-assemble:
#   org.opencontainers.image.base.name    the upstream source image
#   org.opencontainers.image.base.digest  its digest
#   dev.kasm.base.flavor                  rapidfort-curated | upstream
#
# Images published BEFORE labelling show "-" — that is the expected reading for a
# stale image, not a bug, and it is exactly what tells you a rebuild has not landed.
#
# Usage:
#   bash ci-scripts/nix-verify-base.sh                       # every :nix repo
#   bash ci-scripts/nix-verify-base.sh chrome vscode
#   EXPECT_FLAVOR=rapidfort-curated bash ci-scripts/nix-verify-base.sh   # CI gate
#
# Auth (any one):
#   GITLAB_TOKEN=<PAT with read_registry>      (oauth2)
#   CI_JOB_TOKEN                               (in CI, automatic)
#   REG_USER + REG_PASS                        (deploy token pair)
set -uo pipefail

REG_HOST="${REG_HOST:-registry.gitlab.com}"
NS_PATH="${NS_PATH:-kasm-technologies/labs-sandbox/kasm-nix}"
TAG="${KASM_TAG:-nix}"
EXPECT="${EXPECT_FLAVOR:-}"
AUTH_REALM="${AUTH_REALM:-https://gitlab.com/jwt/auth}"

if [ -n "${GITLAB_TOKEN:-}" ]; then      ru="oauth2";              rp="${GITLAB_TOKEN}"
elif [ -n "${CI_JOB_TOKEN:-}" ]; then    ru="gitlab-ci-token";     rp="${CI_JOB_TOKEN}"
elif [ -n "${REG_USER:-}" ]; then        ru="${REG_USER}";         rp="${REG_PASS:-}"
else echo "nix-verify-base.sh: no credentials (set GITLAB_TOKEN, or REG_USER/REG_PASS)" >&2; exit 2
fi

# One pull-scoped token per repository (GitLab scopes registry tokens per repo).
reg_token() {
  curl -sS --max-time 30 -u "${ru}:${rp}" \
    "${AUTH_REALM}?service=container_registry&scope=repository:${NS_PATH}/$1:pull" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")'
}

ACCEPT=(-H 'Accept: application/vnd.oci.image.index.v1+json'
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
        -H 'Accept: application/vnd.oci.image.manifest.v1+json'
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json')

# repo -> the labels on its amd64 config blob
labels_of() {
  local repo="$1" tok mani cfg_digest
  tok="$(reg_token "${repo}")"; [ -n "${tok}" ] || { echo "AUTHFAIL"; return; }

  mani="$(curl -sS --max-time 30 -H "Authorization: Bearer ${tok}" "${ACCEPT[@]}" \
    "https://${REG_HOST}/v2/${NS_PATH}/${repo}/manifests/${TAG}" 2>/dev/null)"
  [ -n "${mani}" ] || { echo "NOTAG"; return; }

  # Registry errors must be reported as such. Reading NAME_UNKNOWN as "the image is
  # odd" wastes time — and the name is the usual culprit here, because several
  # profiles publish under a different kasm_name (vscode -> vs-code, onlyoffice ->
  # only-office, libreoffice -> libre-office, torbrowser -> tor-browser).
  local regerr
  regerr="$(printf '%s' "${mani}" | python3 -c 'import sys,json
try: m=json.load(sys.stdin)
except Exception: sys.exit()
e=(m.get("errors") or [{}])[0]
if e.get("code"): print(e["code"])')"
  if [ -n "${regerr}" ]; then echo "REGERR:${regerr}"; return; fi

  # An index needs a second hop to the image manifest. Prefer linux/amd64, but fall
  # back to the first child: crane writes single-arch indexes with NO platform field
  # at all (the fat store is one), and requiring amd64 there finds nothing and reads
  # as "manifest has no config".
  local child
  child="$(printf '%s' "${mani}" | python3 -c 'import sys,json
try: m=json.load(sys.stdin)
except Exception: sys.exit()
ms=m.get("manifests") or []
if ms:
    for d in ms:
        p=d.get("platform") or {}
        if p.get("architecture")=="amd64" and p.get("os")=="linux":
            print(d["digest"]); break
    else:
        print(ms[0]["digest"])')"
  if [ -n "${child}" ]; then
    mani="$(curl -sS --max-time 30 -H "Authorization: Bearer ${tok}" "${ACCEPT[@]}" \
      "https://${REG_HOST}/v2/${NS_PATH}/${repo}/manifests/${child}" 2>/dev/null)"
  fi

  cfg_digest="$(printf '%s' "${mani}" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("config") or {}).get("digest",""))
except Exception: print("")')"
  [ -n "${cfg_digest}" ] || { echo "NOCONFIG"; return; }

  curl -sSL --max-time 30 -H "Authorization: Bearer ${tok}" \
    "https://${REG_HOST}/v2/${NS_PATH}/${repo}/blobs/${cfg_digest}" 2>/dev/null \
    | python3 -c 'import sys,json
try: l=(json.load(sys.stdin).get("config") or {}).get("Labels") or {}
except Exception: l={}
print(l.get("dev.kasm.base.flavor","-"),
      l.get("org.opencontainers.image.base.name","-"),
      (l.get("org.opencontainers.image.base.digest","-") or "-")[:19],
      l.get("dev.kasm.nix.built-at","-"))'
}

apps=("$@")
if [ "${#apps[@]}" -eq 0 ]; then
  command -v glab >/dev/null 2>&1 || { echo "pass image names, or install glab to enumerate them" >&2; exit 2; }
  proj="${CI_PROJECT_ID:-kasm-technologies%2Flabs-sandbox%2Fkasm-nix}"
  while read -r r; do [ -n "$r" ] && apps+=("$r"); done < <(
    glab api "projects/${proj}/registry/repositories?per_page=100" 2>/dev/null \
      | python3 -c 'import sys,json
try:
    for r in json.load(sys.stdin): print(r["path"].split("/")[-1])
except Exception: pass' | sort)
  [ "${#apps[@]}" -gt 0 ] || { echo "could not enumerate the registry — pass names explicitly" >&2; exit 2; }
fi

printf '%-24s %-18s %-44s %-21s %s\n' IMAGE FLAVOR BASE BASE_DIGEST BUILT
bad=0; unlabelled=0; checked=0
for a in "${apps[@]}"; do
  out="$(labels_of "${a}")"
  case "${out}" in
    AUTHFAIL) printf '%-24s %s\n' "${a}" "(registry auth failed)"; continue ;;
    NOTAG)    printf '%-24s %s\n' "${a}" "(no :${TAG} tag)"; continue ;;
    NOCONFIG) printf '%-24s %s\n' "${a}" "(manifest has no config)"; continue ;;
    REGERR:NAME_UNKNOWN)     printf '%-24s %s\n' "${a}" "(no such repository — check the kasm_name mapping)"; continue ;;
    REGERR:MANIFEST_UNKNOWN) printf '%-24s %s\n' "${a}" "(repository exists, no :${TAG} tag)"; continue ;;
    REGERR:*) printf '%-24s %s\n' "${a}" "(registry error: ${out#REGERR:})"; continue ;;
  esac
  read -r flavor base digest built <<<"${out}"
  checked=$((checked+1))
  printf '%-24s %-18s %-44s %-21s %s\n' "${a}" "${flavor}" "${base}" "${digest}" "${built}"
  [ "${flavor}" = "-" ] && unlabelled=$((unlabelled+1))
  [ -n "${EXPECT}" ] && [ "${flavor}" != "${EXPECT}" ] && bad=$((bad+1))
done

echo
echo "checked ${checked} image(s); ${unlabelled} carry no base label (published before labelling, or a resolute variant)"
if [ -n "${EXPECT}" ]; then
  [ "${bad}" -gt 0 ] && { echo "FAIL: ${bad} image(s) do not report flavor '${EXPECT}'" >&2; exit 1; }
  echo "OK: every checked image reports flavor '${EXPECT}'"
fi

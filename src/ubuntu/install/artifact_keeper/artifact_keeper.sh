#!/usr/bin/env bash
# artifact_keeper.sh — point this build's distro package sources at an Artifact
# Keeper pull-through cache, then put them back before the image is squashed.
#
#   apply   back up each source file to <file>.ak-orig, then rewrite upstream -> AK
#   revert  restore every <file>.ak-orig found, then delete the backups
#
# Opt-in: with AK_URL empty, `apply` is a no-op and the build is byte-identical
# to one where this script does not exist.
#
# `revert` is deliberately NOT gated on AK_URL. Every core dockerfile ends with
#
#     FROM scratch
#     COPY --from=base_layer / /
#
# so a rewritten /etc/apt/sources.list.d/* would be squashed into the published
# image and point kasmweb/core-* at internal dev infra. cleanup.sh does not
# restore package sources. revert must therefore run unconditionally, so that a
# half-configured build (AK_URL set for `apply`, lost by the time we reach the
# end) still self-heals.
#
# Scope is phase 1: ubuntu (incl. resolute, which builds with DISTRO=ubuntu),
# alpine, fedora. Any other $DISTRO falls through as a no-op by design — see
# design/artifact-keeper-flag-design.md §0. Adding a family is one case branch.
set -euo pipefail
IFS=$'\n\t'

ACTION="${1:-}"
AK_URL="${AK_URL:-}"
AK_URL="${AK_URL%/}"   # tolerate a trailing slash from the CI variable
DISTRO="${DISTRO:-}"

# Timestamped and prefixed so these lines are greppable in a CI job log.
log() { printf '%s [artifact_keeper] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

# AK_TEST_ROOT prefixes every path so the rewrite tables can be exercised
# against fixture files outside a container (see artifact_keeper_test.sh). Empty
# in every real build, which is the only configuration that ships.
R="${AK_TEST_ROOT:-}"

# Directories that may hold a rewritten source file. revert sweeps all of them
# regardless of $DISTRO; zypp is listed for the deferred opensuse family so the
# sweep stays correct when that lands.
SOURCE_DIRS=("${R}/etc/apt" "${R}/etc/yum.repos.d" "${R}/etc/apk" "${R}/etc/zypp")

# ---------------------------------------------------------------------------
# apply helpers
# ---------------------------------------------------------------------------

# back_up <file> — copy to <file>.ak-orig unless a backup already exists.
# Idempotent: a second apply must not overwrite the pristine copy with an
# already-rewritten one.
back_up() {
  local f="$1"
  [ -f "${f}" ] || return 0
  if [ -f "${f}.ak-orig" ]; then
    log "backup already present, not re-taking: ${f}.ak-orig"
  else
    cp -p -- "${f}" "${f}.ak-orig"
  fi
}

# rewrite <file> <sed-expr>... — back up, then apply each expression in place.
#
# Deliberately not `sed -i`: GNU takes a bare -i, BSD/macOS reads the next
# argument as a backup suffix, and being runnable on a dev machine is what makes
# artifact_keeper_test.sh possible. Writing back through `cat >` keeps the
# original inode, mode and owner, which matters for files under /etc.
rewrite() {
  local f="$1"; shift
  [ -f "${f}" ] || return 0
  back_up "${f}"
  local args=()
  local e
  for e in "$@"; do args+=(-e "${e}"); done
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064 — expand $tmp now, not at trap time
  trap "rm -f '${tmp}'" RETURN
  # -E (ERE) so `https?` works on both GNU and BSD sed; GNU-only `\?` in a BRE
  # silently matches nothing rather than erroring, which is the worst failure mode
  # here — the build would succeed while caching nothing.
  sed -E "${args[@]}" -- "${f}" >"${tmp}"
  cat -- "${tmp}" >"${f}"
  log "rewrote ${f}"
}

# Matches http:// or https:// so a source pinned to either scheme is caught.
# ERE syntax — see the sed -E note in rewrite().
S='https?://'

apply_ubuntu() {
  local expr=(
    "s|${S}archive\.ubuntu\.com/ubuntu|${AK_URL}/debian/ubuntu-archive|g"
    "s|${S}security\.ubuntu\.com/ubuntu|${AK_URL}/debian/ubuntu-security|g"
    "s|${S}ports\.ubuntu\.com/ubuntu-ports|${AK_URL}/debian/ubuntu-ports|g"
  )
  local f
  # deb822 (.sources) is the noble+ default; .list still exists on jammy and in
  # third-party drop-ins. Both carry the URL as plain text, so one sed covers them.
  for f in "${R}"/etc/apt/sources.list \
           "${R}"/etc/apt/sources.list.d/*.sources \
           "${R}"/etc/apt/sources.list.d/*.list; do
    rewrite "${f}" "${expr[@]}"
  done
}

apply_alpine() {
  # /etc/apk/repositories is one URL per line, version path included
  # (v3.22/main), so a host-and-root swap preserves the rest verbatim.
  rewrite "${R}/etc/apk/repositories" \
    "s|${S}dl-cdn\.alpinelinux\.org/alpine|${AK_URL}/alpine/alpine|g"
}

# apply_fedora <version>
#
# dnf prefers metalink= over baseurl= and will silently bypass a rewrite that
# only adds a baseurl, so metalink (and any mirrorlist) must be commented out.
# That makes this the one family where a wrong URL hard-fails instead of
# falling back — the two path shapes below are verified against the instance:
#   os       <ak>/rpm/fedora-<ver>-os/$basearch/os/
#   updates  <ak>/rpm/fedora-<ver>-updates/$basearch/    (no trailing /os/)
apply_fedora() {
  local ver="$1"
  local f

  for f in "${R}/etc/yum.repos.d/fedora.repo" "${R}/etc/yum.repos.d/fedora-updates.repo"; do
    [ -f "${f}" ] || { log "absent, skipping: ${f}"; continue; }
    local suffix path
    case "${f}" in
      *updates*) suffix="updates"; path="\$basearch/" ;;
      *)         suffix="os";      path="\$basearch/os/" ;;
    esac
    rewrite "${f}" \
      "s|^metalink=|#ak-disabled-metalink=|" \
      "s|^mirrorlist=|#ak-disabled-mirrorlist=|" \
      "s|^#?baseurl=.*|baseurl=${AK_URL}/rpm/fedora-${ver}-${suffix}/${path}|"
  done
}

do_apply() {
  if [ -z "${AK_URL}" ]; then
    log "AK_URL empty — passthrough disabled, leaving package sources untouched"
    return 0
  fi
  [ -n "${DISTRO}" ] || die "DISTRO is unset; cannot choose a rewrite table"
  log "applying passthrough for DISTRO=${DISTRO} via ${AK_URL}"

  case "${DISTRO}" in
    ubuntu)    apply_ubuntu ;;
    alpine)    apply_alpine ;;
    fedora42)  apply_fedora 42 ;;
    fedora43)  apply_fedora 43 ;;
    *)
      # Deliberate no-op: dockerfile-kasm-core is shared with the deferred
      # debian/kali/parrot matrix rows, which must build exactly as before.
      log "DISTRO=${DISTRO} is not in phase 1 — no rewrite table, nothing to do"
      return 0
      ;;
  esac
  log "apply complete"
}

do_revert() {
  local restored=0 d f orig
  for d in "${SOURCE_DIRS[@]}"; do
    [ -d "${d}" ] || continue
    # -print0/read -d '' so a path with whitespace cannot split. No `-exec` so
    # the count stays accurate.
    while IFS= read -r -d '' orig; do
      f="${orig%.ak-orig}"
      mv -f -- "${orig}" "${f}"
      log "restored ${f}"
      restored=$((restored + 1))
    done < <(find "${d}" -type f -name '*.ak-orig' -print0 2>/dev/null)
  done

  if [ "${restored}" -eq 0 ]; then
    log "no .ak-orig backups found — nothing to restore (expected when AK is off)"
  else
    log "revert complete: ${restored} file(s) restored"
  fi

  # Belt and braces: the leak guard in CI greps the image for the AK hostname,
  # but failing here is cheaper than failing there, and far cheaper than
  # shipping it.
  if [ -n "${AK_URL}" ]; then
    local host="${AK_URL#*://}"; host="${host%%/*}"
    if grep -rqs -- "${host}" "${SOURCE_DIRS[@]}" 2>/dev/null; then
      die "AK hostname ${host} still present in package sources after revert"
    fi
    log "verified: no reference to ${host} remains in package sources"
  fi
}

case "${ACTION}" in
  apply)  do_apply ;;
  revert) do_revert ;;
  *) echo "usage: ${0##*/} apply|revert" >&2; exit 64 ;;
esac

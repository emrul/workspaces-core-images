#!/usr/bin/env bash
# host-run.sh — drop-in replacement for dind-run.sh that runs the SAME command
# DIRECTLY on the host instead of inside a privileged podman-in-podman container.
#
# Why this exists: the DinD harness was built for the forge box, which had
# containerd + nerdctl and no host podman, so podman had to come from a
# container. The OCI runner has docker on the host, and every build script is
# engine-agnostic (CONTAINER_CLI), so the nesting buys nothing there and costs:
#   * a privileged container per job;
#   * `sudo nerdctl run` root children the runner cannot kill — one orphan from a
#     cancelled 2026-07-15 pipeline was still running 27 days later;
#   * images landing in podman's store, invisible to docker, and therefore
#     invisible to a co-located Kasm (which is what motivated the change);
#   * the client-cleanup hang that dind-run.sh's detach/wait dance works around.
#
# It takes dind-run.sh's ARGUMENT SHAPE deliberately, so a job changes one word
# and reverting is the same one word:
#
#   usage: host-run.sh <name> <"nerdctl run"-shaped args...> <image> <cmd...>
#
# Translation:
#   -d / --privileged / --rm      dropped (no container to run)
#   --name X                      dropped
#   -e VAR=value                  exported for the command
#   -e VAR                        already inherited; no-op
#   -v HOST:/work[:ro]            becomes KASM_REPO=HOST — the scripts resolve
#                                 their own paths from it (see nix-base-src.sh)
#   -v ...anything else           dropped: host paths need no mounting
#   <image>                       dropped (the arg after the run flags)
#   /work/... inside the command   rewritten to $KASM_REPO/...
#
# Cancel safety is still THIS script's job. GitLab does not reliably run
# after_script on cancel, and the build starts containers of its own (the crane
# staging registry, the nix builder). Without a trap those outlive the job
# exactly as the DinD container used to.
set -uo pipefail

name="${1:?usage: host-run.sh <name> <run args...> <image> <cmd...>}"; shift

env_pairs=()
repo=""

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--privileged|--rm|-i|-t|-it) shift ;;
    --name) shift 2 ;;
    -e)
      case "$2" in
        *=*) env_pairs+=("$2") ;;   # explicit value
        *)   ;;                      # inherit-from-environment: nothing to do
      esac
      shift 2 ;;
    -v|--volume)
      # HOST:CONTAINER[:opts] — only the /work mount carries meaning for us
      _m="$2"; _rest="${_m#*:}"; _c="${_rest%%:*}"; _h="${_m%%:*}"
      [ "${_c}" = "/work" ] && repo="${_h}"
      shift 2 ;;
    -*) shift ;;                     # any other run flag: irrelevant on a host
    *) break ;;                      # positional: the image
  esac
done

# The image argument (e.g. quay.io/podman/stable) has no meaning here.
[ $# -gt 0 ] && shift

[ $# -gt 0 ] || { echo "[host-run] no command given" >&2; exit 2; }

: "${repo:=${CI_PROJECT_DIR:-$PWD}}"

# Rewrite the container-side repo path to the host checkout.
cmd=()
for a in "$@"; do
  case "$a" in
    /work/*) cmd+=("${repo}/${a#/work/}") ;;
    /work)   cmd+=("${repo}") ;;
    *)       cmd+=("$a") ;;
  esac
done

CONTAINER_CLI="${CONTAINER_CLI:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"

# Containers the build starts itself. Named explicitly rather than pattern-matched
# so this can never remove a container belonging to another tenant on the host —
# the remediator's model server lives here too.
OWNED_CONTAINERS="nix-crane-registry"

child=""
cleanup() {
  if [ -n "${child}" ]; then
    # kill the whole process group: the scripts fork nix/crane/curl children
    kill -TERM "-${child}" 2>/dev/null || kill -TERM "${child}" 2>/dev/null || true
    sleep 2
    kill -KILL "-${child}" 2>/dev/null || true
  fi
  for c in ${OWNED_CONTAINERS}; do
    "${CONTAINER_CLI}" rm -f "${c}" >/dev/null 2>&1 || true
  done
}
trap 'cleanup; exit 143' INT TERM
trap cleanup EXIT

# ── preflight: can this user actually reach the engine's store? ──────────────
# build-nix-store-volume resolves the nix staging volume with
# `<cli> volume inspect --format '{{.Mountpoint}}'` and then reads that path from
# the HOST filesystem. Docker creates its data-root 0700/0710 root:root, so an
# unprivileged runner cannot traverse to it — and the symptom downstream is
# "staged nothing", which points nowhere near the cause. A docker upgrade or
# reinstall that resets those permissions reintroduces it silently, so check here
# rather than let a build fail obscurely 40 minutes later.
preflight_store_access() {
  local root vols me
  me="$(id -un)"
  root="$("${CONTAINER_CLI}" info --format '{{.DockerRootDir}}' 2>/dev/null \
          || "${CONTAINER_CLI}" info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
  [ -n "${root}" ] && [ -d "${root}" ] || return 0   # cannot resolve: not our call to fail
  vols="${root}/volumes"

  # root needs no permission; nothing to check.
  [ "$(id -u)" -eq 0 ] && return 0
  [ -x "${root}" ] && { [ ! -d "${vols}" ] || [ -x "${vols}" ]; } && return 0

  cat >&2 <<EOF
[host-run] FATAL: ${me} cannot traverse the container engine's store.

  what           : ${root} $( [ -d "${vols}" ] && echo "and ${root}/volumes" )
  current mode   : $(stat -c '%A %U:%G' "${root}" 2>/dev/null || echo unknown)$( [ -d "${vols}" ] && printf ' / %s' "$(stat -c '%A %U:%G' "${vols}" 2>/dev/null)" )
  running as     : ${me} $(id -nG "${me}" 2>/dev/null | tr ' ' ',' | sed 's/^/(groups: /;s/$/)/')

  Why this matters: the build resolves the nix staging volume through
  '${CONTAINER_CLI} volume inspect --format {{.Mountpoint}}' and then READS that
  path directly. Without traversal the build reports "staged nothing" and rebuilds
  from scratch — or fails in a way that looks like a nix problem, not a
  permissions one.

  Most likely cause: a docker upgrade/reinstall reset the data-root permissions.

  Fix now (one command, safe, no restart):
      sudo chmod 0711 ${root} ${root}/volumes

  Fix durably (kasm-nix-infra, so a rebuilt host keeps it):
      sudo bash scripts/provision-runner.sh            # converges it (see §5a2)
      sudo bash scripts/provision-runner.sh --verify    # asserts it, exits non-zero

  0711 is traversal only: a process that knows the path can walk to it, and no
  local user can enumerate the store. Do NOT use 0755 — that adds nothing the
  build needs.

  To bypass this shim entirely and go back to podman-in-podman, set the CI
  variable NIX_RUNNER_SHIM=dind-run.sh (the podman store is still intact).
EOF
  return 1
}
preflight_store_access || exit 1

echo "[host-run] ${name}: running on the host (${CONTAINER_CLI}, repo ${repo})"
printf '[host-run]   %s\n' "${cmd[*]}"

# setsid puts the command in its own process group so the trap can signal the
# whole tree (the scripts fork nix/crane/curl children). Optional: absent on
# macOS, where this only ever runs for a dry test — the trap then falls back to
# signalling the direct child.
SETSID=""
command -v setsid >/dev/null 2>&1 && SETSID=setsid
if [ "${#env_pairs[@]}" -gt 0 ]; then
  ${SETSID} env KASM_REPO="${repo}" "${env_pairs[@]}" "${cmd[@]}" &
else
  ${SETSID} env KASM_REPO="${repo}" "${cmd[@]}" &
fi
child=$!
wait "${child}"
rc=$?

# Match dind-run.sh: a garbled/absent status is a failure, never a success.
[ -n "${rc}" ] || rc=1
exit "${rc}"

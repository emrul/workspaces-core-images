#!/bin/sh
# bwrap dispatcher — installed as /usr/bin/bwrap, with the real bubblewrap moved
# to /usr/bin/bwrap.real.
#
# WHY THIS EXISTS
# On Ubuntu 25.10+ (Resolute) gdk-pixbuf decodes images via glycin, which runs
# its loaders inside `bwrap --unshare-all`. glycin picks that sandbox by probing
# whether it can create a user namespace; once it commits, ANY later bwrap
# failure is fatal — there is no fallback. GTK then turns the failed icon load
# into a fatal assertion (`Bail out!`), which kills xfce4-panel. The result is a
# desktop showing icon labels with no icons, no panel and no theming, while
# applications keep working (xfdesktop/xfwm4/Xvnc survive).
#
# bwrap fails that way in several environments we do not control:
#   * seccomp permits unshare but not the mount family      → EPERM "make / slave"
#   * AppArmor docker-default denies bwrap's mounts          → EACCES "make / slave"
#   * host has kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu 23.10+
#     default, and the CIS-hardened Kasm host image): the userns creator is
#     transitioned into a restricted profile, so it lacks CAP_NET_ADMIN inside
#     the namespace it just made → "loopback: Failed RTM_NEWADDR"
# The last one cannot be fixed by any container-side security_opt.
#
# Upstream's answer (KASM-8257, src/ubuntu/install/xfce/bwrap_wrapper.sh) is to
# strip bwrap's flags and exec the target directly, so the loader runs
# unsandboxed instead of dying. That is correct FOR GLYCIN, but it must not apply
# to everything: the Nix images run buildFHSEnv apps (onlyoffice, steam) through
# nix-bwrap-run, which needs a REAL bwrap (`--overlay-src`) to give them a real
# /nix/store under their FHS root. Passing those through would silently strip the
# app's FHS mount namespace and break it.
#
# So this dispatcher decides per invocation:
#   * target under /usr/libexec/glycin-loaders/  → passthrough (strip flags, exec)
#   * anything else                              → exec the real bubblewrap
#
# TRADE-OFF: glycin image decoding then runs unsandboxed. That is already the
# posture on any host where userns creation is denied (glycin's own fallback), so
# it is not a new exposure there — but on a permissive host it does give up a
# sandbox that would have worked. Untrusted image decode is a real attack
# surface; upstream accepted the same trade. Everything that is NOT a glycin
# loader keeps its full sandbox, which is the part this dispatcher adds.
#
# See design/glycin-desktop-whiteout.md.
set -e

REAL=/usr/bin/bwrap.real
GLYCIN_MARKER=/usr/libexec/glycin-loaders/

# Decide first, without consuming "$@": is any argument a glycin loader path?
# Checking every argument (not just the trailing command) is deliberate — the
# target's position depends on how many bind/setenv triples precede it.
for arg in "$@"; do
    case "${arg}" in
        "${GLYCIN_MARKER}"*)
            # ── passthrough: strip bwrap's own flags, exec the target ──────────
            while [ $# -gt 0 ]; do
                case "$1" in
                    # 0-arg flags
                    --help|--version) shift ;;
                    --unshare-user|--unshare-user-try|--unshare-ipc) shift ;;
                    --unshare-pid|--unshare-net|--unshare-uts) shift ;;
                    --unshare-cgroup|--unshare-cgroup-try|--unshare-all) shift ;;
                    --share-net|--disable-userns|--assert-userns-disabled) shift ;;
                    --clearenv|--new-session|--die-with-parent|--as-pid-1) shift ;;
                    # 1-arg flags
                    --args|--argv0|--userns|--userns2|--pidns) shift 2 ;;
                    --uid|--gid|--hostname|--chdir|--unsetenv) shift 2 ;;
                    --lock-file|--sync-fd|--perms|--size) shift 2 ;;
                    --remount-ro|--proc|--dev|--tmpfs|--mqueue|--dir) shift 2 ;;
                    --seccomp|--add-seccomp-fd|--exec-label|--file-label) shift 2 ;;
                    --block-fd|--userns-block-fd|--info-fd|--json-status-fd) shift 2 ;;
                    --cap-add|--cap-drop|--level-prefix) shift 2 ;;
                    # 2-arg flags
                    --setenv|--bind|--bind-try|--dev-bind|--dev-bind-try) shift 3 ;;
                    --ro-bind|--ro-bind-try|--file|--bind-data|--ro-bind-data) shift 3 ;;
                    --symlink|--chmod) shift 3 ;;
                    # 3-arg flags
                    --overlay|--tmp-overlay|--ro-overlay) shift 4 ;;
                    # end-of-options marker
                    --) shift; break ;;
                    # first unrecognized arg is the target command
                    *) break ;;
                esac
            done
            [ $# -gt 0 ] || {
                echo "bwrap(dispatch): glycin passthrough found no target command" >&2
                exit 2
            }
            exec "$@"
            ;;
    esac
done

# ── everything else: the real bubblewrap, unmodified ──────────────────────────
# Fail loudly rather than silently downgrading a real sandbox to a passthrough.
# A missing bwrap.real means the image was built wrong, and an FHS app quietly
# losing its mount namespace is exactly the failure this dispatcher exists to
# avoid.
[ -x "${REAL}" ] || {
    echo "bwrap(dispatch): ${REAL} missing or not executable — refusing to run" \
         "'$*' unsandboxed. Rebuild the image (install_xfce_ui.sh moves the real" \
         "bubblewrap to ${REAL})." >&2
    exit 127
}
exec "${REAL}" "$@"

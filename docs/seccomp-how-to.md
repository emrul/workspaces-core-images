# Custom seccomp profile for nested sandboxes

`src/common/seccomp/chrome.json` is a tuned copy of Docker's default
seccomp profile that permits **unprivileged user-namespace creation**.
It exists so that processes inside a Kasm container can run their own
sandboxes — Chrome / Chromium / Edge, Electron apps, `bubblewrap`
(glycin image loaders, Flatpak runtimes), and any other tool that
calls `clone(CLONE_NEWUSER)` or `unshare(CLONE_NEWUSER)`.

Without this profile (or `--security-opt seccomp=unconfined`, or
sysbox, or a privileged container) those tools fail and must be run
with their sandbox disabled — `chrome --no-sandbox`, `glycin` falling
back to in-process loaders, etc. The net security is **worse** than
running with a tuned profile, because you keep ~99% of the default
syscall filter *and* recover the nested sandbox.

## What this profile changes vs Docker default

Diffed against `moby/moby v25.0.6 profiles/seccomp/default.json`:

- **Drops** the rule that allows `clone()` only when its flags arg does
  not contain any `CLONE_NEW*` bit (`MASKED_EQ 0x7E020000`), for both
  x86-family and s390 calling conventions.
- **Drops** the rule that returns `ENOSYS` from `clone3()` for callers
  without `CAP_SYS_ADMIN`.
- **Adds** an unconditional allow rule for `clone`, `clone3`, `unshare`,
  `setns`.

Everything else — `mount`, `umount`, `bpf`, `perf_event_open`,
`setdomainname`, etc. — remains gated on `CAP_SYS_ADMIN` exactly as in
the Docker default. Default action is still `SCMP_ACT_ERRNO`, so any
syscall not explicitly allowed returns `EPERM`.

## Host prerequisite: unprivileged user namespaces

The host kernel must permit unprivileged user-namespace creation.
Check:

```sh
sysctl kernel.unprivileged_userns_clone   # Debian/Ubuntu, must be 1
sysctl user.max_user_namespaces           # must be > 0 (default 15000+)
```

- Ubuntu ≥ 23.10 / Debian ≥ 12 / kernel ≥ 6.1 mainline: enabled by default.
- Ubuntu 22.04 / Debian 11: `kernel.unprivileged_userns_clone=1` may
  need to be set explicitly. AppArmor's `userns_create` restriction
  (Ubuntu 24.04+) is independent of the seccomp story — see "AppArmor
  on Ubuntu 24.04+" below.

If a host can't enable this, the profile is harmless but ineffective:
Chrome still needs `--no-sandbox`.

## AppArmor on Ubuntu 24.04+

Ubuntu 23.10 introduced a separate AppArmor restriction
(`kernel.apparmor_restrict_unprivileged_userns=1`) that blocks
unprivileged userns creation even when the seccomp filter would allow
it. Two options:

1. Disable the restriction host-wide:
   `sysctl kernel.apparmor_restrict_unprivileged_userns=0`
2. Run the container with an AppArmor profile that grants
   `userns,` — pass `--security-opt apparmor=unconfined` or ship a
   custom profile. `unconfined` is fine here because seccomp is doing
   the heavy lifting.

This applies equally to Docker, Podman, and Kubernetes (via crio /
containerd) on affected hosts.

## Using the profile

### Docker

Copy the profile to the host (anywhere Docker can read it), then:

```sh
docker run \
  --security-opt seccomp=/etc/docker/seccomp/chrome.json \
  --security-opt apparmor=unconfined \           # only on Ubuntu 24.04+
  -p 6901:6901 -e VNC_PW=password \
  kasmweb/core-ubuntu-noble:1.17.0
```

`docker-compose.yaml`:

```yaml
services:
  workspace:
    image: kasmweb/core-ubuntu-noble:1.17.0
    security_opt:
      - seccomp=/etc/docker/seccomp/chrome.json
      - apparmor=unconfined           # Ubuntu 24.04+ host only
```

### Podman

Podman uses an identical default profile shape (shared via
`containers/common`). The custom-profile flag is the same:

```sh
podman run \
  --security-opt seccomp=/etc/containers/seccomp/chrome.json \
  -p 6901:6901 -e VNC_PW=password \
  kasmweb/core-ubuntu-noble:1.17.0
```

**Rootless Podman caveat.** Rootless containers already run inside a
user namespace, so a nested Chrome sandbox needs `max_user_namespaces`
high enough for the *nested* userns and the host kernel must permit
nested userns creation (default on for modern kernels). The seccomp
profile is still required — the filter applies regardless of rootless
vs rootful.

**Podman default profile location** (for diffing / refreshing):
`/usr/share/containers/seccomp.json`.

### Kubernetes

Since Kubernetes 1.19 the right mechanism is `seccompProfile` with
`type: Localhost`. The profile must exist on every node at
`<kubelet-root>/seccomp/<name>` (default
`/var/lib/kubelet/seccomp/chrome.json`):

```yaml
apiVersion: v1
kind: Pod
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: chrome.json
  containers:
    - name: workspace
      image: kasmweb/core-ubuntu-noble:1.17.0
```

Distribute the file via DaemonSet, node provisioning (Ignition /
cloud-init / Ansible), or a CSI/hostPath sidecar. The container
runtime (containerd / cri-o) reads the file from the node filesystem
when the kubelet hands it the pod spec.

For Kasm-on-k8s deployments, the Kasm Helm chart's pod spec template
is where this `seccompProfile` block belongs; coordinate with the
team that owns the chart.

### Kasm workspace config

Kasm's admin UI exposes a "Docker Run Config" field per workspace
image. Set it to:

```json
{
  "security_opt": [
    "seccomp=/etc/docker/seccomp/chrome.json"
  ]
}
```

Add `"apparmor=unconfined"` to the array on Ubuntu 24.04+ hosts.
Downstream `workspaces-images` (the Chrome / Edge / Brave single-app
images) should then drop their `--no-sandbox` launch arg — handle that
in the workspaces-images repo, not here.

## Verifying it works

Inside a running container:

```sh
# 1. unshare(CLONE_NEWUSER) should succeed
unshare -U /bin/true && echo "userns ok"

# 2. Chrome's namespace sandbox should engage
google-chrome --headless --disable-gpu --dump-dom https://example.com 2>&1 \
  | grep -i sandbox
# expect: "Sandbox: namespace_sandbox" or no sandbox warnings.
# If you see "namespace sandbox failed: EPERM" the profile isn't applied.

# 3. Container-init trace, if enabled, will show kasm-setup proceeding
#    without retries on namespace operations.
```

On the host, confirm Docker picked up the profile:

```sh
docker inspect <container> --format '{{ .HostConfig.SecurityOpt }}'
# expect:  [seccomp=/etc/docker/seccomp/chrome.json]
```

## Refreshing from upstream

Docker periodically adds rules for new syscalls (recent additions:
`landlock_*`, `process_madvise`, `futex_waitv`, `cachestat`,
`map_shadow_stack`). When you bump the baseline:

```sh
# 1. Fetch current Docker default
curl -sL https://raw.githubusercontent.com/moby/moby/<tag>/profiles/seccomp/default.json \
  > /tmp/docker-default-seccomp.json

# 2. Re-apply the patch
jq '
  .syscalls |= map(
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
      "names": ["clone", "clone3", "unshare", "setns"],
      "action": "SCMP_ACT_ALLOW",
      "comment": "Kasm: allow user-namespace sandboxing (Chrome, Electron, bwrap, glycin) without CAP_SYS_ADMIN. Replaces Docker default rules that gated these on CAP_SYS_ADMIN."
    }]
' /tmp/docker-default-seccomp.json > src/common/seccomp/chrome.json
```

Diff the result against the previous version and review any new
syscall families Docker has added.

## Alternatives (when this profile isn't an option)

- **sysbox** — install `sysbox-runc` on the host, run the container
  with `--runtime=sysbox-runc`. Nested userns + most CAP_SYS_ADMIN
  operations become safe by construction. Kasm core images ship sysbox
  support via `src/ubuntu/install/sysbox/install_systemd.sh`. Higher
  operational cost than a static seccomp file but the strongest answer
  for nested-container workloads.
- **`--security-opt seccomp=unconfined`** — works, but disables the
  *entire* seccomp filter. Net security worse than this tuned profile.
  Use only for local debugging.
- **`--cap-add SYS_ADMIN` or `--privileged`** — effectively no
  container isolation. Do not use in production for browser workloads.

# Nix catalog build harness (Portal box)

Builds and publishes the Nix per-app catalog on the Portal dev box
(`ssh ubuntu@51.195.190.65`), which runs **containerd + nerdctl** (no
podman/docker engine). Since `bin/build-nix-store-volume` targets podman, we run
it inside a **privileged podman-in-podman** container (`quay.io/podman/stable`).
The DinD podman's store is bind-mounted to host `/srv/nix-build/containers`, so
the Nix store cache **and** the built images persist across runs.

See `design/nix-package-process.md` §§ Component 1 / 3b for the design, and the
`nix-portal-dind-build` project memory for host specifics.

## Scripts

| Script | Runs on | Does |
|---|---|---|
| `dind-launch.sh [PROFILES] [PUSH]` | host | starts the build as a detached privileged DinD container |
| `dind-build.sh` | in DinD | loads `nix-ubuntu` base, runs `build-nix-store-volume --emit-app-images`, writes `STATUS`/`build.log` |
| `dind-check.sh [--watch [secs]]` | host | external progress/verification — reads `STATUS` + queries the live overlay store (exit 0=success, 2=running, 1=failed) |
| `dind-push.sh` | in DinD | `podman login` (token on **stdin**) + push fat store & runnable `nix-<app>` → `forge.emrul.dev/beta/<name>:nix` |
| `dind-drain.sh` | in DinD | recovery: load+finish+push pre-built `app-*.tar`, deleting each as it goes (only needed for the legacy tar flow) |

Heavy state on the host: `/srv/nix-build/containers` (persistent podman store +
cache) and `/srv/nix-build/output` (logs, `STATUS`).

## Prerequisites

- `nix-ubuntu:dev` available to the DinD podman. Reuse from the LAN box:
  ```sh
  ssh emrul@192.168.1.140 'docker save localhost/nix-ubuntu:dev | gzip -1' \
    | ssh ubuntu@51.195.190.65 'gunzip -c | sudo tee /srv/nix-build/output/nix-ubuntu.tar >/dev/null'
  ```
  `dind-build.sh` loads it on first run.
- Repo synced to `~/dev/kasm/gitlab/workspaces-core-images` (mutagen `wci-portal`).

## Build

```sh
# one app (smoke)
ssh ubuntu@51.195.190.65 'cd ~/dev/kasm/gitlab/workspaces-core-images && runs/nix-portal/dind-launch.sh chrome'
# full catalog (all profiles in bin/nix-profiles.toml)
ssh ubuntu@51.195.190.65 'cd ~/dev/kasm/gitlab/workspaces-core-images && runs/nix-portal/dind-launch.sh'

# watch from outside (verifies real images in the store, not just logs)
ssh ubuntu@51.195.190.65 'cd ~/dev/kasm/gitlab/workspaces-core-images && runs/nix-portal/dind-check.sh --watch'
```

## Publish

Token lives at `…/portal_infra/.env` (`PACKAGE_PUSH_TOKEN`). Pipe it on stdin so
it never lands in argv/logs:

```sh
TOKEN=$(sed -n 's/^PACKAGE_PUSH_TOKEN=//p' …/portal_infra/.env | tr -d '"'\'' \r')
printf '%s' "$TOKEN" | ssh ubuntu@51.195.190.65 \
  'sudo nerdctl run -i --rm --privileged \
     -v /srv/nix-build/containers:/var/lib/containers \
     -v ~/dev/kasm/gitlab/workspaces-core-images:/work:ro \
     quay.io/podman/stable bash /work/runs/nix-portal/dind-push.sh'
```

Result: `forge.emrul.dev/beta/nix-store-amd64:nix` (fat store) +
`forge.emrul.dev/beta/nix-<app>:nix` (one per wired GUI app).

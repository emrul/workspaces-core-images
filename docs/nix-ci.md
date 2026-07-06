# GitLab CI: building & publishing the Kasm Nix app catalog

`.gitlab-ci.yml` builds the deduped Nix store + one image per GUI app and
publishes each under Kasm's naming convention. It runs on a self-hosted runner
and drives the proven **nix-portal podman-in-podman** harness, so all heavy work
happens inside `quay.io/podman/stable` against a persistent podman store.

> The previous core-distro pipeline is preserved at
> `ci-scripts/gitlab-ci-core.yml` (not run by this project).

## Pipeline

| Stage | Job | Does |
|---|---|---|
| `prepare` | `prepare` | `ci-scripts/nix-changed-profiles.sh` computes `NIX_PROFILES` from the commit diff (change-gating) and exports it as a dotenv artifact. |
| `base` | `base` | **manual / `allow_failure`** — `runs/nix-portal/dind-base.sh` builds core-minimal + nix-ubuntu into the store. Play it when the base dockerfiles / core tree change; normal runs reuse the warm base. |
| `build` | `build` | `runs/nix-portal/dind-build.sh` → `build-nix-store-volume --emit-app-images` → fat store + one `localhost/nix-<profile>:dev` per GUI app (per-app builds parallelised, `BUILD_PARALLEL`). |
| `publish` | `publish` | inside the store: `podman login` the registry, then `ci-scripts/nix-publish.sh` tags each to its kasm name and pushes to `$REGISTRY_NS` (scoped to `NIX_PROFILES`). |

CLI/library profiles (`node`, `python`, `terraform`, …) have no
`custom_startup.sh`, so `--emit-app-images` never produces an image for them —
they're automatically excluded from publish.

### Change-gating (`prepare` → `NIX_PROFILES`)

`prepare` diffs the commit and emits a dotenv `NIX_PROFILES` that `build` and
`publish` inherit:

- **`""`** — whole catalog. A shared/base file changed
  (`build-nix-store-volume`, `nix-profiles.toml`, the base dockerfiles,
  `src/common/**`, `src/ubuntu/install/nix/{scripts,units}/**`,
  `runs/nix-portal/**`), or it's a schedule, or the diff can't be determined.
- **`"onlyoffice vscode"`** — only those apps changed
  (`src/ubuntu/install/nix/<app>/**`), so only they build + publish.
- **`"__none__"`** — nothing image-relevant changed (docs / CI only); `build`
  and `publish` no-op.

A manual/trigger `NIX_PROFILES` variable overrides the computed value (higher
precedence than dotenv).

### Parallel per-app builds

`build-nix-store-volume` builds the per-app images with `BUILD_PARALLEL`
concurrency (default `4` in CI): the first app is built serially to warm the
shared base/store layers, then the rest fan out. `BUILD_PARALLEL=1` restores
serial builds.

### Cancel safety

Every DinD job names its container `nixci-<job>-<pipeline>` and a `default:
after_script` force-removes it. Without this, a cancelled/timed-out job leaves
the root-owned `sudo nerdctl` build orphaned (the runner can't kill a root child
of the `gitlab-runner` user), and it keeps building + holds the podman store
lock, blocking the next pipeline.

## Runner (this is the caching strategy)

A dedicated **self-hosted runner on the forge box** (`ssh ubuntu@51.195.190.65`),
already registered as **"Nix builder"** (tag `nix-builder`, shell executor).
Forge is containerd + nerdctl with **no host docker/podman engine**, so the
pipeline launches the build inside a privileged `quay.io/podman/stable`
container (same as `runs/nix-portal/`). Caching = the **persistent podman store**
bind-mounted from `/srv/nix-build/containers` (~200 GB warm): Nix dedup +
`cache.nixos.org` + podman layer cache mean a no-change rerun fetches almost
nothing. Build logs/STATUS land in `/srv/nix-build/output`.

Runner setup (already done; recorded for reproducibility):

```sh
# on the forge host
sudo curl -fsSL -o /usr/local/bin/gitlab-runner \
  https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64
sudo chmod +x /usr/local/bin/gitlab-runner
sudo gitlab-runner install --user=gitlab-runner --working-directory=/home/gitlab-runner
sudo gitlab-runner start
# passwordless sudo for the DinD launcher:
echo 'gitlab-runner ALL=(root) NOPASSWD: /usr/local/bin/nerdctl, /usr/bin/nerdctl' \
  | sudo tee /etc/sudoers.d/gitlab-runner-nerdctl && sudo chmod 0440 /etc/sudoers.d/gitlab-runner-nerdctl
# register (token from Project → Settings → CI/CD → Runners; tag it nix-builder):
sudo gitlab-runner register --non-interactive --url https://gitlab.com \
  --token <PROJECT_RUNNER_TOKEN> --executor shell --description "forge nix-builder (DinD)"
```

Single builder assumed — `build` and `publish` share the local store, so the
built images are available to publish without a registry round-trip.

### GitLab caching primitives (complementary)

`cache:` (S3/MinIO-backed) and BuildKit `--cache-to/--cache-from type=registry`
are available if you ever add ephemeral runners, but aren't needed here — the
persistent store covers it. `cache.nixos.org` is automatic; stand up your own
(attic/S3) to cache custom derivations across fresh hosts.

## Registry & naming

Published image = `<REGISTRY_NS>/<kasm_name>:<KASM_TAG>`.

- `REGISTRY_NS` — defaults to `$CI_REGISTRY_IMAGE` (this project's GitLab
  Container Registry, `registry.gitlab.com/kasm-technologies/labs-sandbox/kasm-nix`).
  Migrate to Docker Hub later by setting the CI/CD variable
  **`REGISTRY_NS=docker.io/kasmweb`** (+ a registry login) — no code change.
- `KASM_TAG` — `nix`.
- `kasm_name` — the profile's `kasm_name` in `bin/nix-profiles.toml` when it
  differs, else the profile name. Overrides to match Kasm's Docker Hub:
  `vscode→vs-code`, `onlyoffice→only-office`, `libreoffice→libre-office`,
  `torbrowser→tor-browser`.

## Running it

- **Automatic**: push to the default branch (`kasm-nix`) → `build` then `publish`.
- **Subset**: set CI/CD variable `NIX_PROFILES="onlyoffice vscode"` (space list).
- **Manual base refresh**: play the `base` job (or run a `web` pipeline) after
  changing the base dockerfiles / core install tree.
- **Local publish dry-run** of the mapping:
  ```sh
  REGISTRY_NS=registry.example/kasm-nix DRY_RUN=1 DOCKER=podman bash ci-scripts/nix-publish.sh
  ```

## Notes

- FHS/bubblewrap apps (OnlyOffice, Steam) need the `bwrap.json` seccomp profile
  at **run** time, not build — see `docs/seccomp-how-to.md`.
- Add an app: `[profiles.<name>]` (+ `kasm_name` if it differs) and
  `src/ubuntu/install/nix/<name>/{launch,custom_startup.sh}`; the pipeline picks
  it up automatically.

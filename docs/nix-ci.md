# GitLab CI: building & publishing the Kasm Nix app catalog

`.gitlab-ci.yml` builds the deduped Nix store and one image per GUI app, then
publishes each under Kasm's naming convention. This doc covers the pipeline,
the runner it needs, the caching model, and the registry/naming scheme.

> The previous core-distro pipeline is preserved at
> `ci-scripts/gitlab-ci-core.yml` (not run by this project).

## Pipeline

| Stage | Job | Does |
|---|---|---|
| `base` | `build-base` | `docker build` core-minimal (`dockerfile-kasm-core-minimal`) then `nix-ubuntu` (`dockerfile-nix-ubuntu`). |
| `apps` | `build-apps` | `bin/build-nix-store-volume --emit-app-images` → one `localhost/nix-<profile>:dev` per GUI app (shared base/store layers deduped). |
| `publish` | `publish` | `ci-scripts/nix-publish.sh` tags each to its kasm name and pushes to `$REGISTRY_NS`. |

CLI/library profiles (`node`, `python`, `terraform`, `claude-code`, …) have no
`custom_startup.sh`, so `--emit-app-images` never produces an image for them —
they're automatically excluded from publish.

## Runner (this is the caching strategy)

The heavy Nix build is only fast because state persists between runs, so use a
**dedicated self-hosted runner on a persistent host**, not ephemeral shared
runners.

Requirements:
- Tag **`nix-builder`** (matches `default.tags` in `.gitlab-ci.yml`).
- `docker` (or `podman`) on `PATH`; a **shell executor** is simplest (the Nix
  build already runs its heavy work inside a `nixos/nix` container).
- A **persistent host** so two things stay warm across runs:
  - the Nix store staging volume `nix-build-stage-<arch>` (Nix dedup → most
    reruns fetch nothing from `cache.nixos.org`), and
  - the local Docker layer cache (core/nix-ubuntu base builds become instant).
- **One** builder is assumed — `base` images and the store volume are reused
  locally by `apps`/`publish`. With multiple builders you'd need to push the
  base + store-images to the registry and pull them per job.

Register it against the project (Settings → CI/CD → Runners → New project runner
→ copy the token):

```sh
gitlab-runner register \
  --non-interactive \
  --url https://gitlab.com/ \
  --token <PROJECT_RUNNER_TOKEN> \
  --executor shell \
  --description "nix-builder (persistent, docker on PATH)"
# then add the `nix-builder` tag to it in the runner settings.
```

The forge build host (`ssh ubuntu@51.195.190.65`, `/srv/nix-build`) already has
exactly this shape and is the natural candidate.

### GitLab caching primitives (complementary)

- **`cache:`** — keyed/path-based, backed by S3/MinIO for cross-runner sharing.
  Not used here (the persistent volume covers the big cache), but available for
  smaller artifacts.
- **BuildKit registry cache** — add `--cache-to/--cache-from type=registry,ref=…`
  to the base builds if you ever move to ephemeral runners.
- **`cache.nixos.org`** — upstream Nix binary cache, automatic. Stand up your
  own (attic/S3) if you want your custom derivations cached across fresh hosts.

## Registry & naming

Published image = `<REGISTRY_NS>/<kasm_name>:<KASM_TAG>`.

- `REGISTRY_NS` — defaults to `$CI_REGISTRY_IMAGE` (this project's GitLab
  Container Registry, e.g. `registry.gitlab.com/kasm-technologies/labs-sandbox/kasm-nix`).
  Migrate to Docker Hub later by setting **`REGISTRY_NS=docker.io/kasmweb`** (a
  CI/CD variable) — no code change — plus a `docker login` for that registry.
- `KASM_TAG` — `nix`.
- `kasm_name` — the profile's `kasm_name` field in `bin/nix-profiles.toml` when
  it differs from the profile name, else the profile name. Current overrides
  (to match Kasm's Docker Hub): `vscode→vs-code`, `onlyoffice→only-office`,
  `libreoffice→libre-office`, `torbrowser→tor-browser`.

## Running it

- **Automatic**: push to the default branch → full build + publish.
- **Subset**: set CI/CD variable `NIX_PROFILES="onlyoffice vscode"` (space list)
  to build/publish only those.
- **Manual**: run a pipeline from the UI/API (`web` source) on any branch — it
  publishes too (handy for feature-branch cuts).
- **Local dry-run** of just the publish mapping:
  ```sh
  REGISTRY_NS=registry.example/kasm-nix DRY_RUN=1 bash ci-scripts/nix-publish.sh
  ```

## Notes

- FHS/bubblewrap apps (OnlyOffice, Steam) need the `bwrap.json` seccomp profile
  at **run** time, not build — see `docs/seccomp-how-to.md`.
- To add an app: add a `[profiles.<name>]` block (+ `kasm_name` if it differs)
  and `src/ubuntu/install/nix/<name>/{launch,custom_startup.sh}`; the pipeline
  picks it up automatically.

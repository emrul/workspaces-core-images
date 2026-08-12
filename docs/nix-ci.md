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
| `prepare` | `base-check` | Decides which distro bases need rebuilding → `NIX_BASES_REBUILD` (dotenv): union of base inputs changed in the diff (`NIX_BASES_AFFECTED`) and upstream source-image digest staleness (`ci-scripts/nix-base-check.sh`, run in DIND on publishing pipelines). |
| `base` | `base` | Auto — rebuilds the stale/affected distro bases (`ci-scripts/nix-base-build.sh`), core + `nix-<distro>` for each, **parallel across distros** (`BUILD_PARALLEL`), stamping each with its source-image digest. Skips fast when all bases are fresh. Force with the `BASE_DISTROS` variable. |
| `build` | `build` | `runs/nix-portal/dind-build.sh` → `build-nix-store-volume --emit-app-images` → fat store + one `localhost/nix-<profile>:dev` per GUI app (per-app builds parallelised, `BUILD_PARALLEL`). |
| `publish` | `publish` | inside the store: `podman login` the registry, then `ci-scripts/nix-publish.sh` tags each to its kasm name and pushes to `$REGISTRY_NS` (scoped to `NIX_PROFILES`). |
| `scan` | `security-page` | Upserts this run's scan rows into `security.json` (`ci-scripts/nix-security-page.py`, merging against what the registry currently serves) and publishes it as an **artifact** — it no longer writes any docroot. |
| `scan` | `refresh-registry` | Triggers the `kasm-nix-registry` pipeline (job-token auth, `strategy: depend`, `allow_failure`) passing `SECURITY_JOB_ID`, so the Pages site is rebuilt around the new `security.json`. Pages deployments are immutable — republishing is the only way to update the security page. |

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

## Hardened base (RapidFort)

The single-app catalogue is built on RapidFort's **curated** Noble image rather than
`docker.io/library/ubuntu:24.04`:

```
quay.io/rfcurated/rfubu:24.04-rfcurated
  → dockerfile-kasm-core-minimal   → localhost/kasm-core-ubuntu-noble-minimal:dev
  → dockerfile-nix-ubuntu          → localhost/nix-ubuntu:dev   ← every single-app image
```

Switching one variable switches the whole catalogue, because every per-app image is
assembled `FROM localhost/nix-ubuntu:dev`. `ci-scripts/nix-base-src.sh` owns the
distro → source-image mapping (shared by `nix-base-build.sh` and
`nix-base-check.sh`, which each used to carry their own copy).

| variable | meaning |
|---|---|
| `NIX_BASE_SRC_UBUNTU` | the ubuntu source image. Set to `ubuntu:24.04` to revert. |
| `RF_REGISTRY` | registry the token is minted for (`quay.io`) |
| `RF_ROOT_URL` | RapidFort platform URL — **protected** CI variable |
| `RF_ACCESS_ID` / `RF_SECRET_ACCESS_KEY` | RapidFort **platform** credentials — **masked + protected** CI variables |
| `RF_CLI_VERSION` | version of the credential helper in our package registry |

Only `ubuntu` moves. `fedora`, `alpine` and `resolute` (which the TraceLabs desktop
builds on) stay on their stock upstream images.

### Why the auth is not a plain `podman login`

RapidFort issues **no static registry credential**. `RF_ACCESS_ID` /
`RF_SECRET_ACCESS_KEY` are *platform* credentials — quay rejects them directly
(`{"code":"UNAUTHORIZED","message":"Invalid Username or Password"}`, verified). What
actually authenticates is a quay **robot token** that RapidFort's Docker credential
helper mints on demand:

```
platform creds ──▶ docker-credential-rfcurated get ──▶ {rfcurated+<org>, <token>}
                                                        expires_in: 3600
```

One hour — so the working credential cannot be a CI variable either. It has to be
minted per job:

1. `ci-scripts/rf-fetch-credhelper.sh` (on the runner) downloads the helper from
   this project's **generic package registry** with `CI_JOB_TOKEN`, into
   `$CI_PROJECT_DIR/.rf/` — which the base job already mounts into DIND at
   `/work/.rf/`. The binary is ~10 MB of vendor code and is deliberately **not**
   committed; publish a new version with `ci-scripts/rf-publish-credhelper.sh` and
   bump `RF_CLI_VERSION`.
2. `ci-scripts/rf-credhelper-login.sh` (inside DIND) runs the helper's `get`, then
   pipes the returned token into `podman login` on stdin. We call `get` ourselves
   rather than registering a `credHelpers` entry, so the exchange happens once, at a
   known point, with our own error messages.

The auth file is `REGISTRY_AUTH_FILE=/tmp/kasm-nix-auth.json` and the helper's
`~/.rapidfort/credentials` is written mode `600` — both **inside the ephemeral DIND
container**, never in the persistent store (`/var/lib/containers`) and never in a
layer.

⚠️ **The helper refuses to run when both `docker` and `podman` are on `PATH`**
("ERROR: Both Docker and Podman are available in PATH"). The builder is podman-only
so this never fires in CI, but it does on a mixed developer box — hence the explicit
pre-flight check, because otherwise it surfaces as a generic "could not mint a
token" and sends you auditing your credentials.

**Checking credentials by hand** — `ci-scripts/rf-auth-check.sh` asks the registry
directly with curl (no podman, no RF CLI) and separates "credentials rejected" from
"no such repo" from "no such tag". Note it needs a *registry* credential, so feed it
the helper's output rather than the platform creds:

```bash
creds=$(echo quay.io | ~/rapidfort/docker-credential-rfcurated get)
RF_USERNAME=$(jq -r .Username <<<"$creds") RF_PASSWORD=$(jq -r .Secret <<<"$creds") \
  bash ci-scripts/rf-auth-check.sh
```

### Verifying what a published image is built on

Every image records its OS base, using the **standard OCI base annotations** so
generic tooling understands them, plus one convenience label for at-a-glance checks:

| label | value |
|---|---|
| `org.opencontainers.image.base.name` | e.g. `quay.io/rfcurated/rfubu:24.04-rfcurated` |
| `org.opencontainers.image.base.digest` | that image's digest |
| `dev.kasm.base.flavor` | `rapidfort-curated` or `upstream` |

`ci-scripts/nix-base-build.sh` stamps them on each distro base;
`bin/nix-crane-assemble` re-stamps them on every per-app image. The re-stamp is
deliberate rather than relying on `crane append` carrying the base config forward —
a provenance label that exists only by inheritance is one that can go missing without
anyone noticing, and these are the labels used to prove the catalogue is hardened.

⚠️ Do not confuse `dev.kasm.nix.base-rev` with these: that one is the **nixpkgs**
rev, a completely different axis.

Read them back off the registry with no pulls (curl + python3 only — none of our
hosts has skopeo):

```bash
GITLAB_TOKEN=<read_registry PAT> bash ci-scripts/nix-verify-base.sh
# or gate a pipeline on it:
EXPECT_FLAVOR=rapidfort-curated bash ci-scripts/nix-verify-base.sh
```

`-` in the FLAVOR column means that image predates labelling — i.e. the rebuild has
not reached it yet. Resolute images correctly report their own base (`ubuntu:26.04`),
not the RapidFort one.

### Rolling the switch out

Changing the source image makes the ubuntu base stale, and `base` is **manual** — so
the order matters, and it is the same trap as any base change (see the TRAP note
under Change-gating):

1. play **`base`** — rebuilds core-minimal + nix-ubuntu from the RF image
2. play **`publish-base`**
3. re-run **`build`** — per-app images layer onto the new base. Without step 1 they
   silently layer onto the *stale* warm `localhost/nix-ubuntu:dev`.
4. **`publish`**

### Two things to watch

- **i386.** `dockerfile-kasm-core-minimal` installs VirtualGL, which does
  `dpkg --add-architecture i386` and pulls ~10 `:i386` libraries
  (`src/ubuntu/install/virtualgl/install_virtualgl.sh`). RF's apt mirror is a pinned
  RapidFort snapshot, and i386 multiarch was noted as absent during the evaluation.
  The `chrome-rf-poc` chain built cleanly through this step, so the libraries
  resolve — but if a base build fails on the RF image, this is the first place to
  look. Steam/Wine, which need a real i386 userspace at runtime, are the apps most
  at risk.
- **The CVE numbers will look better than the remediation warrants.** RF replaces
  ~37 core libraries with `rf-*` forks built from newer upstream. Real patching, but
  the renamed packages also fall outside the Ubuntu CVE feed, so scanners stop
  matching them: the evaluation measured Trivy 34→0 and grype 106→3, mostly a
  detection artifact rather than 106 fixed bugs. Report the drop with that caveat
  attached — see `design/cve-scanning.md`.

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
- **Base rebuilds are automatic**: `base-check` → `base` rebuild a distro base
  when its inputs change (`src/common`, `src/<distro>`, the base dockerfiles) or
  its upstream source image (`ubuntu:24.04`, `fedora:42`, `alpine:3.21`) moves;
  `publish-base` then auto-publishes the rebuilt ones. Force a specific set with
  the `BASE_DISTROS="ubuntu fedora alpine"` variable on a `web` pipeline.
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

# Artifact Keeper as a pull-through cache — feasibility review

**Scope:** the two build pipelines in `images/` (`workspaces-core-images`, fork
branch `feat/container-init`):

1. **Base build** — `dockerfile-kasm-core*` (8 variants) → `kasmweb/core-<distro>`,
   driven by `ci-scripts/template-vars.yaml` + `ci-scripts/build.sh`.
2. **Nix store build** — `bin/build-nix-store-volume` → one partitioned `/nix`
   store image plus `--emit-app-images` per-app images, via `bin/nix-crane-assemble`.

**Artifact Keeper capability baseline** (from `artifactkeeper.com/docs`, Aug 2026):
37 native formats; remote (pull-through) repos documented as supported for *all*
formats, `upstream_url` per remote, 24h default TTL with ETag revalidation,
SHA-256 validation. **No Nix binary-cache format.** Generic format is documented
as a hosted/upload format — proxying an arbitrary HTTP upstream is *not*
documented either way and needs confirming with the vendor.

---

## Summary verdict

| | Base build | Nix store build |
|---|---|---|
| Share of external bytes coverable | **~85–90%** | **~5%** |
| Blocker | none — config + reference rewrites | `cache.nixos.org` has no AK format |

The base build is a good fit. The Nix build is not: the overwhelming majority of
its download volume is Nix substitution from `cache.nixos.org`, which Artifact
Keeper has no format for.

---

## 1. Base build

### 1a. Goes through Artifact Keeper cleanly

| Dependency | Where | AK format |
|---|---|---|
| Distro base images — `ubuntu:24.04`, `ubuntu:26.04`, `debian:bookworm-slim`, `fedora:*`, `alpine:3.*`, `oraclelinux:8`, `opensuse/leap:16.0`, `centos:centos7` | `ci-scripts/template-vars.yaml` (`base_image:`) | Docker/OCI remote |
| Builder images — `alpine:3`, `golang:1.25-alpine` | hardcoded `FROM` at the top of all 8 dockerfiles | Docker/OCI remote |
| Distro package repos — apt (`archive.ubuntu.com`, `deb.debian.org`), dnf, apk (`dl-cdn.alpinelinux.org`), zypper | inherited from the base image's own sources config; touched only for parrot in `src/ubuntu/install/package_rules/package_rules.sh:26` | Debian/APT, RPM/YUM, Alpine/APK remotes |
| EPEL | `install_kde.sh`, `install_openbox.sh`, `install_xfce_ui.sh` | RPM/YUM remote |
| RPMFusion (free/el, free/fedora) | `src/ubuntu/install/audio/install_audio.sh:10-31` | RPM/YUM remote |
| Oracle Linux repos (`yum.oracle.com`) | `src/ubuntu/install/rhel/install_rhel.sh:14-35` | RPM/YUM remote |
| Packman (`ftp.gwdg.de`) | `install_audio.sh:38`, `install_recorder.sh:11` | RPM/YUM remote |
| openSUSE OBS (`download.opensuse.org` — M17N:fonts, Printing) | `install_custom_fonts.sh:37`, `install_printer.sh:11` | RPM/YUM remote |
| Salt Project (`repo.saltproject.io`) | `src/ubuntu/install/extra/remnux.sh:9-13` | Debian/APT remote |
| Trivy vuln DBs — `public.ecr.aws/aquasecurity/trivy-db:2`, `trivy-java-db:1` | `ci-scripts/scan:12` | Docker/OCI remote (they are OCI artifacts) |

**Non-issue:** the `kasmgo_builder` stage runs `go build`, but
`src/common/kasm-go/go.mod` has no `require` block — stdlib only, no vendor dir
needed, no `proxy.golang.org` traffic. No Go remote required today; worth adding
`GOPROXY` pointing at AK pre-emptively if that module ever grows a dependency.

### 1b. Needs a mirror-and-rewrite, not a pull-through

These are raw HTTPS file fetches. AK's Generic format is documented as an
upload/hosted format; nothing in the docs says a Generic remote can proxy an
arbitrary upstream path. **Confirm with the vendor** — if Generic-remote exists
these become a URL rewrite; if not, they need publishing into AK and the source
URLs changed.

| Dependency | Where | Notes |
|---|---|---|
| `kasmweb-build-artifacts.s3.amazonaws.com` — ~50 references: KasmVNC (`.deb`/`.rpm`/`.apk` per distro/arch), profile-sync, audio_input, websocket_relay, webcam, gamepad, recorder, printer_service, smartcard_bridge, desktop apps, `cups-pdf` rpm | `src/*/install/*/install_*.sh` | **These are real packages.** Better landing zone than Generic: AK **Debian/RPM/Alpine *local* (hosted)** repos, which gives per-package metadata and scanning rather than opaque blobs. Highest-value item in the whole review — it is Kasm's own supply chain and currently has zero mediation. |
| `github.com/emrul/container-init` releases (`container-init`, `systemd1-shim`) | `ADD` at line 13–14 of every core dockerfile | Uses Dockerfile `ADD`, which can't carry auth headers — either keep AK anonymous-readable for this repo or convert to `RUN curl` with a CI-injected token |
| `github.com/VirtualGL/virtualgl` releases (3.1.3, 4 artifacts) | `src/ubuntu/install/virtualgl/install_virtualgl.sh:3,5,37,57` | |
| `kasm-ci.s3.amazonaws.com/kasm.svg` | `src/ubuntu/install/emblems/install_emblems.sh:11` | |
| Trivy binary tarball (`$S3_BUCKET`, GitHub-releases fallback) | `ci-scripts/download-trivy`, `ci-scripts/nix-scan-base.sh:60-72` | |
| `tools.kali.org/kali-metapackages` | `src/ubuntu/install/extra/kali.sh:9` | |

### 1c. Cannot go through Artifact Keeper

| Dependency | Where | Why |
|---|---|---|
| `git clone https://github.com/REMnux/salt-states.git` | `src/ubuntu/install/extra/remnux.sh:17` | AK has Git LFS, not a git remote. Options: vendor the tree, or replace with a tarball fetch through Generic. |

---

## 2. Nix store build

### 2a. Goes through Artifact Keeper

| Dependency | Where | AK format |
|---|---|---|
| `docker.io/nixos/nix:2.28.4` (the builder container; also seeds the warm staging volume) | `bin/build-nix-store-volume:29` (`--nix-image` / `NIX_IMAGE_DEFAULT`), `bin/nix-bake-closure:38` (`NIX_IMAGE`), `dockerfile-nix-app:34` | Docker/OCI remote — already overridable via flag/env, so this is a one-variable change |
| Core image consumed as `BASE_IMAGE` by `dockerfile-nix-ubuntu*` | build arg | internal registry, already mediated |

That is essentially the whole list. Everything below is the actual volume.

### 2b. Cannot go through Artifact Keeper

| Dependency | Where | Why |
|---|---|---|
| **`cache.nixos.org` substitution** — the bulk of the build's bytes across 54 profiles in `bin/nix-profiles.toml` | implicit default substituter inside the `nixos/nix` container; the build sets only `download-buffer-size` (`build-nix-store-volume:276`) | **AK has no Nix binary-cache format.** The protocol is small and GET-only (`/nix-cache-info`, `/<hash>.narinfo`, `/nar/*.nar.xz`) — a plausible candidate for AK's WASM custom-format plugin system, but that is unbuilt today. |
| Flake inputs — `github:NixOS/nixpkgs/nixos-26.05` (floating, resolved per build), plus `nix2container`, `flake-utils`, and the three overlay flakes | `bin/nix-profiles.toml:28`, `nix/flake.nix:20-24`, `bin/nix-*-overlay/flake.nix` | Nix fetches these as GitHub codeload tarballs through its own fetcher; no AK format intercepts that path |
| Fixed-output derivation sources in `bin/nix-kasm-overlay/pkgs/` — Chrome deb (`dl.google.com`), Maltego zip (`downloads.maltego.com`), the Kasm S3 artifacts re-packaged for Nix, and `fetchFromGitHub` for spiderfoot / sublist3r / phoneinfoga / metagoofil | `pkgs/*/package.nix` | Rewriting these URLs to AK *is* technically safe — an FOD hash is content-addressed, so the hash in `pin.json` stays valid — but it depends on Generic-remote existing, and it decouples the overlay from upstream reproducibility |

### 2c. What to do about Nix instead

Artifact Keeper is the wrong tool for this half. Three options, in the order I'd
rank them:

1. **Run a real Nix binary cache next to AK** — `harmonia`, `attic`, or plain
   `nix copy` to an S3/MinIO bucket, with `extra-substituters` pointed at it and
   `cache.nixos.org` kept as fallback. Standard, well-trodden, gets both the
   bandwidth saving and a record of exactly which store paths entered a build.
2. **Ask the vendor about a Nix WASM plugin.** The protocol is trivial enough
   that this is a fair ask, and it would keep one system. Do not plan around it
   until they commit.
3. **Generic-remote passthrough as an interim** — *if* AK supports a Generic
   remote with path passthrough, `substituters = https://<ak>/<repo>/` works,
   because narinfo signatures pass through unmodified and still validate against
   `cache.nixos.org`'s public key. Unconfirmed; test before proposing.

**Worth telling the devops team:** the traceability goal is already partly met on
the Nix side by construction. Every build resolves the floating nixpkgs ref to a
concrete commit up front and stamps it onto the image as an OCI label
(`build-nix-store-volume` § ref pinning → `nix-crane-assemble`), and the
assessment envelope pins source commit + scan/publish job IDs + `model_stack_id`.
That is a stronger provenance record than a proxy access log. The gap a cache
would close is *availability and byte-level custody*, not traceability.

---

## 3. Integration cost and risks

**Reference rewrites required for the Docker/OCI remote.** AK's Docker proxy is
addressed as `<ak-host>/<repo-name>/<image>:<tag>` — a namespace prefix, not a
transparent mirror. That means editing:

- `ci-scripts/template-vars.yaml` — every `base_image:` entry
- 8 dockerfiles — the hardcoded `FROM alpine:3` and `FROM golang:1.25-alpine`
  builder stages (currently not `ARG`-driven; make them `ARG` so the prefix is a
  CI variable rather than a source change)
- `bin/build-nix-store-volume:29`, `bin/nix-bake-closure:38`, `dockerfile-nix-app:34`
- `ci-scripts/scan:12` — the hardcoded `--db-repository public.ecr.aws/...`

Alternative worth testing first: a **containerd `hosts.toml` mirror** on the
runner (`infra/scripts/provision-runner.sh`), which would leave every image
reference untouched. This depends on AK serving a plain `/v2/` API under a
per-upstream host entry with `override_path`; not documented, needs a spike.

**Other risks:**

- **New CI single point of failure.** The OCI runner is egress-only
  (`infra/terraform/oci/network.tf`). Routing all pulls through one AK instance
  makes it a hard dependency for every build. Ask what its HA story is, and keep
  upstream as a virtual-repo fallback where the format allows.
- **TTL is not offline.** 24h default revalidation means upstream is still
  contacted; this is not an air-gap solution and shouldn't be sold as one.
- **Credentials.** AK creds become CI variables in two repos. The `ADD <url>`
  fetches in the dockerfiles can't send auth headers — either those repos stay
  anonymous-readable or the lines convert to `RUN curl`.
- **Rolling tags.** `alpine:3` and `epel-release-latest-*` are floating; a
  pull-through cache with a 24h TTL changes *when* you pick up a new upstream,
  which can turn a reproducible failure into an intermittent one. Pin these while
  you're editing the references anyway.

## 4. Suggested sequencing

1. **Confirm with the vendor:** (a) does a Generic *remote* exist with arbitrary
   upstream + path passthrough; (b) does the Docker remote serve a plain `/v2/`
   suitable for a containerd host mirror; (c) any appetite for a Nix binary-cache
   plugin.
2. **Phase 1 — highest value, lowest risk:** publish the Kasm S3 artifacts
   (KasmVNC and the component binaries) into AK *hosted* Debian/RPM/Alpine repos
   and repoint `src/*/install/*/install_*.sh`. This is Kasm's own supply chain and
   the part with the weakest current provenance.
3. **Phase 2:** Docker/OCI remotes for base + builder images and the trivy DBs.
4. **Phase 3:** APT/YUM/APK remotes for the distro and third-party repos.
5. **Nix:** track separately — stand up a binary cache, don't wait on AK.

---

## 5. Test instance survey — `artifact.huan.oci.dev.remotebrowser.net`

Inspected 2026-08-09, anonymously — no credentials needed to read. `/health`,
`/api/v1/repositories`, `/api/v1/formats` are all open, every repo is
`allow_anonymous_access: true`, and the Docker registry issues an anonymous
bearer token. Writes (creating repos) will need credentials.

`{"status":"healthy","version":"1.6.0","demo_mode":false}` — database, storage,
security_scanner and opensearch all healthy.

### URL layout (confirmed by fetch)

`https://<host>/<format>/<repo-key>/<upstream-path-verbatim>` — the upstream path
is passed through unchanged, which makes every rewrite a pure prefix swap:

- apt: `https://<host>/debian/ubuntu-archive` → `dists/noble/Release` ✅ 200, correct content
- rpm: `https://<host>/rpm/oraclelinux-9-baseos/x86_64/repodata/repomd.xml` ✅ 200
- apk: `https://<host>/alpine/alpine/v3.21/main/x86_64/APKINDEX.tar.gz` ✅ 200

Docker/OCI is different — it is a **standard registry at the root**:
`/v2/` with `WWW-Authenticate: Bearer realm=".../v2/token", service="artifact-keeper"`,
anonymous token issued on request. Image refs are `<host>/<repo-key>/<image>:<tag>`.
This is promising for a containerd `hosts.toml` mirror, but untested (no OCI
remote exists yet to test against).

### What exists — 46 repos, ~30 GB cached

All OS package repos, all `remote`, all anonymous:

| Family | Repos present |
|---|---|
| debian | `ubuntu-archive`, `ubuntu-ports`, `ubuntu-security`, `debian-archive`, `debian-security`, `kali-rolling`, `parrot-7` |
| rpm | almalinux 8/9, rocky 8/9, oraclelinux 8/9 (incl. their EPEL + codeready + distro-builder), fedora 42/43 (os + updates), opensuse-leap-16 (oss + non-oss) |
| alpine | `alpine` (whole CDN root) |
| local (empty test) | `eric-docker-test`, `eric-helm-test`, `eric-vs-code-test` |
| other | `ubuntu-staging` (a third repo_type: `staging`) |

Suite coverage verified through the proxy: ubuntu `noble` / `noble-updates` /
`noble-security` / `resolute` ✅; debian `bookworm` / `trixie` / `bullseye` ✅;
alpine `v3.21` / `v3.22` / `v3.23` ✅. That covers every distro our
`template-vars.yaml` matrix builds except centos7 (EOL, vault-only).

### What's missing — devops needs to create these

Blocking full coverage of the base build:

| Needed | For | Format |
|---|---|---|
| **OCI remote → `registry-1.docker.io`** | every `FROM` in the matrix + `alpine:3` / `golang:1.25-alpine` builders + `nixos/nix` | oci |
| **OCI remote → `public.ecr.aws`** | trivy DB / java-DB (`ci-scripts/scan:12`) | oci |
| EPEL remote → `dl.fedoraproject.org/pub/epel` | `install_kde.sh`, `install_openbox.sh`, `install_xfce_ui.sh` (Oracle's bundled EPEL doesn't cover the Fedora path we use) | rpm |
| RPMFusion → `download1.rpmfusion.org` + `mirrors.rpmfusion.org` | `install_audio.sh:10-31` | rpm |
| Packman → `ftp.gwdg.de/pub/linux/misc/packman/suse` | `install_audio.sh:38`, `install_recorder.sh:11` | rpm |
| openSUSE OBS `M17N:fonts` and `Printing` | `install_custom_fonts.sh:37`, `install_printer.sh:11` | rpm |
| Salt Project → `repo.saltproject.io` | `extra/remnux.sh` | debian |
| Generic remote(s) → `kasmweb-build-artifacts.s3.amazonaws.com`, `github.com/emrul/container-init`, VirtualGL releases | the ~50 raw fetches in §1b | generic |

### Format availability — resolved, with a caveat

`/api/v1/formats` reports 13 core handlers, all enabled: **cargo, conan, debian,
generic, go, helm, maven, npm, nuget, oci, pypi, rpm, rubygems**.

- **`generic` is enabled** — so the §1b raw fetches have a home. Whether a
  generic repo accepts `repo_type: "remote"` with an arbitrary `upstream_url`
  still needs one write test; it cannot be determined read-only.
- **Caveat:** working `alpine` and `vscode` repos exist on this instance but
  neither format appears in that list of 13, so the endpoint is not the
  authoritative enabled-set. Don't treat a format's absence there as proof it's
  unavailable — test it.
- **Still no Nix.** Confirmed against the live instance, not just the docs. §2c
  stands unchanged.

### Revised coverage against *what is deployed today*

| | coverable now | after the table above is created |
|---|---|---|
| Base build | ~55% (distro repos only) | ~90% |
| Nix store build | ~0% | ~5% (builder container only) |

---

*Verification note: Artifact Keeper's Generic-remote behaviour and its
suitability as a containerd `hosts.toml` mirror remain unconfirmed — both need a
write-capable account on the instance to test.*

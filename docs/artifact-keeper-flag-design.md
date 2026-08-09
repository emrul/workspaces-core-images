# Artifact Keeper passthrough — opt-in flag design

Companion to `artifact-keeper-review.md` (analysis + instance survey). This is
the work order: exact flag surface, file-by-file change list, and the
provisioning AK needs before each phase can land.

**Status:** design only, no code written. Target instance
`https://artifact.huan.oci.dev.remotebrowser.net` is dev infra, so the default
must remain "off" and the off-path must be byte-identical to today's build.

---

## 1. Flag surface

Three variables, all empty-by-default. Empty ⇒ every code path below is a no-op.

| Variable | Scope | Effect when set |
|---|---|---|
| `AK_URL` | base build (docker build arg) | rewrite distro package sources to AK. e.g. `https://artifact.huan.oci.dev.remotebrowser.net` |
| `AK_REGISTRY` | base + nix build (CI variable / build arg) | prefix for OCI pulls. e.g. `artifact.huan.oci.dev.remotebrowser.net/dockerhub` |
| `AK_GENERIC` | base build (docker build arg) | base URL for the raw-file fetches in §5. Separate from `AK_URL` because it needs a different repo and may not be supported at all (untested) |

Rationale for three rather than one: the three back onto different AK repo types
with independent readiness. Distro repos exist today; the OCI remote does not
exist yet; generic-remote support is unconfirmed. One combined flag would force
all three to land together.

**Design rule:** no script may *require* AK. Every rewrite is
`if [ -n "${AK_URL:-}" ]; then … fi`, and CI sets the variable only on an opt-in
branch or a manual pipeline run.

---

## 2. The constraint that shapes everything: rewrites must not ship

Every core dockerfile ends with:

```
FROM scratch
COPY --from=base_layer / /
```

(`dockerfile-kasm-core:262-263`, and the equivalent in all 8 others.)

The whole filesystem is squashed into the published image. A rewritten
`/etc/apt/sources.list.d/*` or `/etc/yum.repos.d/*` therefore **ships to
customers**, pointing `kasmweb/core-*` at internal dev infra. `cleanup.sh` does
not restore package sources — it only runs `zypper clean --all` / cache purges.

So the rewrite is necessarily **apply → build → revert**:

- `artifact_keeper.sh apply` — back up each source file to `<file>.ak-orig`, rewrite
- `artifact_keeper.sh revert` — restore from `.ak-orig`, delete the backups

`revert` must run in its own `RUN` immediately before the cleanup step in every
dockerfile, and must be unconditional (not gated on `AK_URL`) so that a
half-configured build still self-heals.

**Non-negotiable companion:** a CI guard that greps the final image for the AK
hostname and fails the build on a hit. Without it this design has a quiet path to
leaking internal infrastructure into public images. Add it to `ci-scripts/test.sh`
or as a standalone job — it is cheap (`docker run --rm <img> grep -r` over
`/etc/apt`, `/etc/yum.repos.d`, `/etc/zypp/repos.d`, `/etc/apk/repositories`).

---

## 3. New file: `src/ubuntu/install/artifact_keeper/artifact_keeper.sh`

Lives in the shared `src/ubuntu/install/` tree like `package_rules` (which all
distros already reuse — every dockerfile copies `./src/ubuntu/install/package_rules`
regardless of family).

Takes `apply` | `revert`, dispatches on `$DISTRO` exactly as `package_rules.sh`
does. Per-family rewrite:

| Family | Files | Rewrite |
|---|---|---|
| ubuntu | `/etc/apt/sources.list`, `/etc/apt/sources.list.d/*.sources` (deb822 on noble+) | `archive.ubuntu.com/ubuntu` → `$AK_URL/debian/ubuntu-archive`; `security.ubuntu.com/ubuntu` → `$AK_URL/debian/ubuntu-security`; `ports.ubuntu.com/ubuntu-ports` → `$AK_URL/debian/ubuntu-ports` |
| debian / kasmos | same | `deb.debian.org/debian` → `$AK_URL/debian/debian-archive`; `security.debian.org/…` → `$AK_URL/debian/debian-security` |
| kali | same | `http.kali.org/kali` → `$AK_URL/debian/kali-rolling` |
| parrot | `/etc/apt/sources.list.d/parrot.list` | `deb.parrot.sh/parrot` → `$AK_URL/debian/parrot-7` (**note:** replaces the existing MIT-mirror substitution at `package_rules.sh:26` — the two must not both fire) |
| alpine | `/etc/apk/repositories` | `dl-cdn.alpinelinux.org/alpine` → `$AK_URL/alpine/alpine` |
| fedora | `/etc/yum.repos.d/fedora*.repo` | metalink → baseurl `$AK_URL/rpm/fedora-<ver>-os` and `-updates`. **Must disable `metalink=`** — dnf prefers it and will bypass the rewrite |
| oracle | `/etc/yum.repos.d/oracle-linux-ol*.repo` | `yum.oracle.com/repo/OracleLinux/OL<n>/…` → `$AK_URL/rpm/oraclelinux-<n>-<component>` |
| rocky / alma / rhel9 | `/etc/yum.repos.d/*.repo` | mirrorlist → baseurl `$AK_URL/rpm/{rocky,almalinux}-<n>-<component>`; same metalink caveat |
| opensuse | `/etc/zypp/repos.d/*.repo` | `download.opensuse.org/distribution/leap/16.0/repo/{oss,non-oss}` → `$AK_URL/rpm/opensuse-leap-16-{oss,nonoss}` |

The upstream→AK mapping is a data table in the script, not scattered `sed`s, so
that adding a repo is a one-line change and the table can be diffed against the
instance's `/api/v1/repositories` output.

**URL layout is a pure prefix swap** — verified by fetch against the instance:
`https://<host>/<format>/<repo-key>/<upstream-path-verbatim>`. No path
translation needed.

---

## 4. Per-dockerfile change list

The insertion point is **the first stage that touches the package manager** — not
uniformly the `package_rules` line. Two files break the pattern.

| Dockerfile | `apply` goes before | Notes |
|---|---|---|
| `dockerfile-kasm-core` | `:68` (package_rules COPY) | base_layer `:35`, ARG DISTRO `:40` |
| `dockerfile-kasm-core-minimal` | `:75` | base_layer `:42` |
| `dockerfile-kasm-core-ubuntu-resolute` | `:74` | base_layer `:35` |
| `dockerfile-kasm-core-kasmos` | `:64` | base_layer `:34` |
| `dockerfile-kasm-core-fedora` | `:38` | in `install_tools` stage `:34`; inherited by base_layer `:51` |
| `dockerfile-kasm-core-oracle` | `:38` | in `install_tools` `:34`; base_layer `:51` |
| `dockerfile-kasm-core-centos` | `:39` | in `install_tools` `:35`; base_layer `:52`. CentOS 7 is EOL and **has no AK repo** — leave it unflagged |
| **`dockerfile-kasm-core-alpine`** | **`:45`**, not `:74` | `install_tools.sh` runs `apk add` at `:45`, *before* package_rules at `:74`. Rewriting at the package_rules line would miss every `apk` call in the tools stage |
| **`dockerfile-kasm-core-suse`** | **`:47`** | **has no `package_rules` step at all** — its first package operation is `install_tools.sh` at `:47` |

For the five files whose `base_layer` is `FROM install_tools`, a single `apply` in
the `install_tools` stage carries through. For the four where `base_layer` is
`FROM $BASE_IMAGE` directly, `apply` must be in `base_layer`.

`revert` goes in every one of the nine, in its own `RUN` immediately before the
`cleanup.sh` line (`dockerfile-kasm-core:259` and equivalents).

Each file also gains `ARG AK_URL=""` / `ARG AK_GENERIC=""` in the stage(s) that
use them — remember an `ARG` is scoped per stage and must be redeclared.

### Image references (`AK_REGISTRY`)

| Location | Today | Change |
|---|---|---|
| `ci-scripts/template-vars.yaml` | `base_image:` per matrix row | prefix at render time in `template-gitlab.py`, not by editing 20+ rows |
| all 9 dockerfiles `:10` | `FROM --platform=$BUILDPLATFORM alpine:3 AS containerinit_fetch` | promote to `ARG CI_ALPINE_IMAGE=alpine:3` — currently hardcoded |
| all 9 dockerfiles `:22-30` | `FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS kasmgo_builder` | promote to `ARG CI_GOLANG_IMAGE=golang:1.25-alpine` |
| `ci-scripts/scan:12` | `--db-repository public.ecr.aws/aquasecurity/trivy-db:2` (hardcoded) | make the two DB repos overridable env vars |
| `bin/build-nix-store-volume:29` | `NIX_IMAGE_DEFAULT="docker.io/nixos/nix:2.28.4"` | **already overridable** via `--nix-image`; nothing to change, just wire the flag in CI |
| `bin/nix-bake-closure:38` | `NIX_IMAGE="${NIX_IMAGE:-docker.io/nixos/nix:latest}"` | already env-overridable |
| `dockerfile-nix-app:34` | `ARG NIX_IMAGE="docker.io/nixos/nix:2.28.4"` | already an ARG |

The Nix side is nearly free — the three entry points are already parameterised.

### CI plumbing

`ci-scripts/build.sh` already takes `EXTRA_BUILD_ARGS` as positional `$7`
(word-split deliberately, `:12`). The flag rides in there — **no signature
change**. `gitlab-ci.template` gains the conditional that populates it from a CI
variable.

---

## 5. Raw-file fetches (`AK_GENERIC`) — lowest confidence

The ~50 fetches from `kasmweb-build-artifacts.s3.amazonaws.com`, plus
`github.com/emrul/container-init` releases, VirtualGL releases, `kasm-ci.s3…/kasm.svg`
and the trivy tarball. Two open problems:

1. **Unconfirmed capability.** `generic` is an enabled format on the instance,
   but whether a generic repo accepts `repo_type: "remote"` with an arbitrary
   `upstream_url` cannot be determined read-only. One write test settles it.
2. **`ADD` can't authenticate.** `container-init` is fetched with Dockerfile
   `ADD` (`:13-14` in all 9). If the AK generic repo needs credentials, those
   lines must become `RUN curl` with a CI-injected header.

If generic-remote turns out not to exist, the fallback is better anyway for the
Kasm artifacts specifically: they are real `.deb`/`.rpm`/`.apk` files, so publish
them into AK **hosted** Debian/RPM/Alpine repos and get package metadata and
scanning instead of opaque blobs. That is a mirroring job, not a flag.

---

## 6. Provisioning required, by phase

Nothing below is blocked on code; all of it is AK-side work devops can start now.

**Phase 1 — distro repos.** Fully backed by what's deployed. No provisioning
needed for ubuntu / debian / kali / parrot / alpine / oracle / rocky / alma /
opensuse-base / fedora-base.

**Phase 2 — needs new remotes:**

| Repo to create | Upstream | Format |
|---|---|---|
| dockerhub | `https://registry-1.docker.io` | oci |
| ecr-public | `https://public.ecr.aws` | oci |
| epel-8 / epel-9 | `https://dl.fedoraproject.org/pub/epel/` | rpm |
| rpmfusion-free-el / -fedora | `https://download1.rpmfusion.org/free/el/`, `https://mirrors.rpmfusion.org/free/fedora/` | rpm |
| packman-leap | `https://ftp.gwdg.de/pub/linux/misc/packman/suse/` | rpm |
| obs-m17n-fonts | `https://download.opensuse.org/repositories/M17N:/fonts/16.0/` | rpm |
| obs-printing | `https://download.opensuse.org/repositories/Printing/16.0/` | rpm |
| saltproject | `https://repo.saltproject.io` | debian |

**Phase 3 — needs a capability answer first:** generic remote(s), per §5.

**Never:** `cache.nixos.org` and Nix flake inputs (no AK format — see review §2c),
and the `git clone` of REMnux salt-states (`extra/remnux.sh:17`).

---

## 7. Test plan

1. **Off-path regression.** Build one image per family with no flags set; confirm
   the dockerfile digest chain is unchanged from `develop`. This is the gate that
   makes the flag safe to merge.
2. **On-path, ubuntu first.** `AK_URL` only, `dockerfile-kasm-core`. Confirm
   `apt-get update` pulls from AK (check AK's `storage_used_bytes` moves) and the
   image is functionally identical.
3. **Leak guard.** Grep the resulting image for the AK hostname — must be zero
   hits across `/etc/apt`, `/etc/yum.repos.d`, `/etc/zypp/repos.d`,
   `/etc/apk/repositories`. Wire this as a permanent CI job, not a one-off.
4. **Alpine and suse specifically** — the two files whose insertion point differs.
   A rewrite that silently lands after the first `apk add` / `zypper` call looks
   like a pass but caches nothing; verify by AK-side byte counters, not by build
   success.
5. **`AK_REGISTRY` on the nix builder** — the cheapest on-path test of the OCI
   remote once it exists, since `--nix-image` needs no code change.

## 8. Open questions for the vendor / devops

1. Does a `generic` repo support `repo_type: "remote"` with an arbitrary upstream?
2. Does `/v2/` work as a containerd `hosts.toml` mirror? If yes, §4's image-reference
   rewrites collapse into one runner-side config change in
   `infra/scripts/provision-runner.sh` and most of that table disappears.
3. `/api/v1/formats` lists 13 formats but working `alpine` and `vscode` repos
   exist outside that list — what is that endpoint actually reporting?
4. What is the HA / uptime expectation for this instance? Once builds route
   through it, it is a CI dependency; the review flags it as a new SPOF.

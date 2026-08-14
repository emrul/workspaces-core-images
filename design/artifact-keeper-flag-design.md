# Artifact Keeper passthrough — opt-in flag design

Companion to `artifact-keeper-review.md` (analysis + instance survey). This is
the work order: exact flag surface, file-by-file change list, and the
provisioning AK needs before each phase can land.

**Status:** design only, no code written. Target instance
`https://artifact.huan.oci.dev.remotebrowser.net` is dev infra, so the default
must remain "off" and the off-path must be byte-identical to today's build.

---

## 0. Scope — Ubuntu, Alpine and Fedora

**Phase 1 covers only the families we ship Nix bases for.** Everything
else below is retained as analysis but is explicitly **deferred** — do not
implement it.

| | Families | Core dockerfiles |
|---|---|---|
| **Phase 1** | ubuntu (incl. resolute), alpine, fedora | `dockerfile-kasm-core`, `-minimal`, `-ubuntu-resolute`, `-alpine`, `-fedora` |
| **Deferred** | debian, kasmos, kali, parrot, oracle, centos, rocky, alma, rhel9, opensuse | `-kasmos`, `-oracle`, `-centos`, `-suse` |

All three families are backed and verified end-to-end against the live instance
(§6), so phase 1 ships them together. Alpine is the only irregular insertion
point in the set (§4) — that is a per-file care point, not a reason to sequence
it separately.

Rationale: AK only earns its keep underneath something we build and ship on a
cadence. The Nix bases are `dockerfile-nix-ubuntu`, `-nix-ubuntu-resolute`,
`-nix-alpine` and `-nix-fedora`, whose `BASE_IMAGE` defaults point at
`kasm-core-ubuntu-noble`, `kasm-core-ubuntu-resolute`, `kasm-core-alpine` and
`kasm-core-fedora` respectively. Those four chains are the whole target.
`-minimal` is in scope because the CI row for `nix-ubuntu` actually builds from
`core-ubuntu-noble-minimal:nix` (`template-vars.yaml:387`), not from the full
core image.

**How the scoping is enforced — and why it costs almost nothing.**
`dockerfile-kasm-core` is shared by the ubuntu, debian and kali matrix rows
(`template-vars.yaml:47`, `64`, `98`, `114`, `131`, `148`), so per-dockerfile
gating would be wrong. Instead the `artifact_keeper.sh` mapping table (§3)
simply carries **no entry** for a deferred `$DISTRO`: `apply` is a no-op there,
and `revert` finds no `.ak-orig` files to restore. Adding a family later is one
table row, not a dockerfile change.

Two simplifications fall out of the narrowing, both worth banking:

- **The parrot conflict disappears.** §3 flagged that a parrot rewrite collides
  with the existing MIT-mirror substitution at `package_rules.sh:26`. Deferring
  parrot means nothing has to touch `package_rules.sh` at all.
- **Alpine becomes the only irregular insertion point.** §4 called out alpine
  and suse as the two files breaking the pattern; with suse deferred, alpine is
  the sole exception.

---

## 1. Flag surface

Three variables, all empty-by-default. Empty ⇒ every code path below is a no-op.

| Variable | Scope | Effect when set |
|---|---|---|
| `AK_URL` | base build (docker build arg) | rewrite distro package sources to AK. e.g. `https://artifact.huan.oci.dev.remotebrowser.net` |
| `AK_REGISTRY` | base + nix build (CI variable / build arg) | prefix for OCI pulls. e.g. `artifact.huan.oci.dev.remotebrowser.net/dockerhub` |
| `AK_GENERIC` | base build (docker build arg) | base URL for the raw-file fetches in §5. **Must be the full API route** — `https://<host>/api/v1/repositories/<key>/download` — not a `$AK_URL`-style prefix; see §5 |

Rationale for three rather than one: the three back onto different AK repo types
with independent readiness, and as of 2026-08-14 all three exist — distro repos
(pre-existing), `dockerhub` / `ecr-public` (created, §6), and generic remotes
(confirmed working, §8 Q1). Keeping them separate still matters for a reason that
only emerged on testing: `AK_URL` is a pure prefix swap while `AK_GENERIC` needs a
completely different URL shape, so they cannot share a rewrite helper. One
combined flag would also force all three to land together.

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

**Build the table with these three families only.** The deferred rows are kept
below for whoever picks up phase 2; they must not appear in the shipped table.

| Family | Files | Rewrite |
|---|---|---|
| ubuntu (incl. resolute) | `/etc/apt/sources.list`, `/etc/apt/sources.list.d/*.sources` (deb822 on noble+) | `archive.ubuntu.com/ubuntu` → `$AK_URL/debian/ubuntu-archive`; `security.ubuntu.com/ubuntu` → `$AK_URL/debian/ubuntu-security`; `ports.ubuntu.com/ubuntu-ports` → `$AK_URL/debian/ubuntu-ports` |
| alpine | `/etc/apk/repositories` | `dl-cdn.alpinelinux.org/alpine` → `$AK_URL/alpine/alpine` — verified working end-to-end, see §6 |
| fedora | `/etc/yum.repos.d/fedora*.repo` | metalink → baseurl `$AK_URL/rpm/fedora-<ver>-os` and `-updates`. **Must disable `metalink=`** — dnf prefers it and will bypass the rewrite |

<details>
<summary><b>Deferred — do not implement</b></summary>

| Family | Files | Rewrite |
|---|---|---|
| debian / kasmos | same as ubuntu | `deb.debian.org/debian` → `$AK_URL/debian/debian-archive`; `security.debian.org/…` → `$AK_URL/debian/debian-security` |
| kali | same | `http.kali.org/kali` → `$AK_URL/debian/kali-rolling` |
| parrot | `/etc/apt/sources.list.d/parrot.list` | `deb.parrot.sh/parrot` → `$AK_URL/debian/parrot-7` (**note:** collides with the existing MIT-mirror substitution at `package_rules.sh:26` — the two must not both fire) |
| oracle | `/etc/yum.repos.d/oracle-linux-ol*.repo` | `yum.oracle.com/repo/OracleLinux/OL<n>/…` → `$AK_URL/rpm/oraclelinux-<n>-<component>` |
| rocky / alma / rhel9 | `/etc/yum.repos.d/*.repo` | mirrorlist → baseurl `$AK_URL/rpm/{rocky,almalinux}-<n>-<component>`; same metalink caveat |
| opensuse | `/etc/zypp/repos.d/*.repo` | `download.opensuse.org/distribution/leap/16.0/repo/{oss,non-oss}` → `$AK_URL/rpm/opensuse-leap-16-{oss,nonoss}` |

</details>

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

**Five of the nine are in scope.** `-kasmos`, `-oracle`, `-centos` and `-suse`
are untouched in phase 1 — do not add `ARG`s or `RUN` lines to them.

| Dockerfile | `apply` goes before | Notes |
|---|---|---|
| `dockerfile-kasm-core` | `:68` (package_rules COPY) | base_layer `:35`, ARG DISTRO `:40`. Shared with the debian/kali rows — those no-op via the §3 table, see §0 |
| `dockerfile-kasm-core-minimal` | `:75` | base_layer `:42`. The base the `nix-ubuntu` CI row actually builds on |
| `dockerfile-kasm-core-ubuntu-resolute` | `:74` | base_layer `:35` |
| `dockerfile-kasm-core-fedora` | `:38` | in `install_tools` stage `:34`; inherited by base_layer `:51` |
| **`dockerfile-kasm-core-alpine`** | **`:45`**, not `:74` | `install_tools.sh` runs `apk add` at `:45`, *before* package_rules at `:74`. Rewriting at the package_rules line would miss every `apk` call in the tools stage. **The only irregular insertion point in scope** |

<details>
<summary><b>Deferred — do not implement</b></summary>

| Dockerfile | `apply` would go before | Notes |
|---|---|---|
| `dockerfile-kasm-core-kasmos` | `:64` | base_layer `:34` |
| `dockerfile-kasm-core-oracle` | `:38` | in `install_tools` `:34`; base_layer `:51` |
| `dockerfile-kasm-core-centos` | `:39` | in `install_tools` `:35`; base_layer `:52`. CentOS 7 is EOL and **has no AK repo** — leave it unflagged permanently |
| `dockerfile-kasm-core-suse` | `:47` | **has no `package_rules` step at all** — its first package operation is `install_tools.sh` at `:47` |

</details>

Of the five in scope, `-fedora` and `-alpine` have `base_layer` as
`FROM install_tools`, so a single `apply` in the `install_tools` stage carries
through. The three ubuntu-family files take `base_layer` `FROM $BASE_IMAGE`
directly, so `apply` must go in `base_layer`.

`revert` goes in each of those five, in its own `RUN` immediately before the
`cleanup.sh` line (`dockerfile-kasm-core:259` and equivalents). It stays
unconditional (not gated on `AK_URL`) so a half-configured build self-heals.

Each file also gains `ARG AK_URL=""` / `ARG AK_GENERIC=""` in the stage(s) that
use them — remember an `ARG` is scoped per stage and must be redeclared.

### Image references (`AK_REGISTRY`)

| Location | Today | Change |
|---|---|---|
| `ci-scripts/template-vars.yaml` | `base_image:` per matrix row | prefix at render time in `template-gitlab.py`, not by editing 20+ rows |
| the 5 in-scope dockerfiles `:10` | `FROM --platform=$BUILDPLATFORM alpine:3 AS containerinit_fetch` | promote to `ARG CI_ALPINE_IMAGE=alpine:3` — currently hardcoded. Present in all 9; phase 1 changes only the five |
| the 5 in-scope dockerfiles `:22-30` | `FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS kasmgo_builder` | promote to `ARG CI_GOLANG_IMAGE=golang:1.25-alpine`. Same — all 9 have it, only five change |
| `ci-scripts/scan:12` | `--db-repository public.ecr.aws/aquasecurity/trivy-db:2` (hardcoded) | make the two DB repos overridable env vars |
| `bin/build-nix-store-volume:29` | `NIX_IMAGE_DEFAULT="docker.io/nixos/nix:2.28.4"` | **already overridable** via `--nix-image`; nothing to change, just wire the flag in CI |
| `bin/nix-bake-closure:38` | `NIX_IMAGE="${NIX_IMAGE:-docker.io/nixos/nix:latest}"` | already env-overridable |
| `dockerfile-nix-app:34` | `ARG NIX_IMAGE="docker.io/nixos/nix:2.28.4"` | already an ARG |

The Nix side is nearly free — the three entry points are already parameterised.

### CI plumbing

`ci-scripts/build.sh` already takes `EXTRA_BUILD_ARGS` as positional `$7`
(`:12`, expanded unquoted at `:19` with an explicit `shellcheck disable=SC2086`
because the word-splitting is deliberate). The flag rides in there — **no
signature change to `build.sh`**.

**One correction to the obvious approach.** `$7` is currently supplied as
`"{{ IMAGE.extraBuildArgs | default('') }}"` (`gitlab-ci.template:66` and `:99`),
which is a *Jinja render-time* value read from `template-vars.yaml`. A CI
variable is a *job-runtime* env var, so it cannot populate `extraBuildArgs`. Do
not try to thread it through the YAML. Append at runtime instead:

```jinja
- bash ci-scripts/build.sh … "{{ IMAGE.dockerfile }}" "{{ IMAGE.extraBuildArgs | default('') }} ${AK_BUILD_ARGS}"
```

with `AK_BUILD_ARGS` assembled once in the existing `before_script` in
`ci-scripts/gitlab-ci-core.yml:25`:

```sh
export AK_BUILD_ARGS=""
[ -n "${AK_URL:-}" ]     && AK_BUILD_ARGS="--build-arg AK_URL=${AK_URL}"
[ -n "${AK_GENERIC:-}" ] && AK_BUILD_ARGS="${AK_BUILD_ARGS} --build-arg AK_GENERIC=${AK_GENERIC}"
```

Unset ⇒ `AK_BUILD_ARGS` is empty ⇒ `$7` gains only a trailing space, which the
word-split discards. The off-path stays byte-identical, which is what test-plan
step 1 gates on.

`AK_REGISTRY` is the exception: it rewrites `IMAGE.base`, which really is
render-time, so it belongs in `template-gitlab.py` as a prefix applied while
generating the child pipeline. That still reads the CI variable fine — the
template is re-rendered every pipeline — but it means flipping `AK_REGISTRY`
changes the *generated config*, not just a build arg.

---

## 5. Raw-file fetches (`AK_GENERIC`) — capability now confirmed

The ~50 fetches from `kasmweb-build-artifacts.s3.amazonaws.com`, plus
`github.com/emrul/container-init` releases, VirtualGL releases, `kasm-ci.s3…/kasm.svg`
and the trivy tarball.

**Both original blockers are cleared** (tested 2026-08-14, §8 Q1):

1. ~~Unconfirmed capability.~~ A `generic` + `repo_type: "remote"` repo with an
   arbitrary `upstream_url` works and returns bytes sha256-identical to upstream.
2. ~~`ADD` can't authenticate.~~ The download route serves **anonymously** when
   the repo has `allow_anonymous_access: true`, so the `ADD` lines at `:13-14`
   can stay as they are. No `RUN curl` conversion needed.

**The one real complication is the URL shape.** Unlike the distro formats, a
generic repo is *not* reachable at `/generic/<key>/<path>` — that 404s. The
working route is:

```
$AK_URL/api/v1/repositories/<key>/download/<upstream-path-verbatim>
```

So `AK_GENERIC` must be set to the whole
`https://<host>/api/v1/repositories/<key>/download` base, and it cannot share the
prefix-swap helper used for `AK_URL`. This is the concrete reason §1 keeps the
two variables separate — the split turned out to be justified for a different
reason than originally guessed.

Deciding between remote-proxy and hosted-mirror is now a genuine choice rather
than a fallback. Proxying works today and needs no publishing pipeline; but the
Kasm artifacts are real `.deb`/`.rpm`/`.apk` files, so publishing them into AK
**hosted** Debian/RPM/Alpine repos would get package metadata and scanning
instead of opaque blobs. The `staging` repo type noted in §8 may be the intended
mechanism. Proxy first, revisit hosted when the mirroring job is worth building.

---

## 6. Provisioning required, by phase

Nothing below is blocked on code; all of it is AK-side work devops can start now.

**Phase 1 — distro repos. Nothing to provision: all three families are backed
and verified end-to-end** against the live instance on 2026-08-14. Each row
below was fetched through AK, not merely observed in the repo list:

| Family | Repos | Proof |
|---|---|---|
| ubuntu | `ubuntu-archive`, `ubuntu-security`, `ubuntu-ports` (`debian`/`remote`) | `GET /debian/ubuntu-archive/dists/noble/Release` → 200, 254968 B |
| fedora | `fedora-42-os`, `-42-updates`, `fedora-43-os`, `-43-updates` (`rpm`/`remote`) | `GET /rpm/fedora-43-os/x86_64/os/repodata/repomd.xml` → 200, 5966 B |
| alpine | `alpine` (`alpine`/`remote` → `dl-cdn.alpinelinux.org/alpine/`) | `GET /alpine/alpine/v3.22/main/x86_64/APKINDEX.tar.gz` → 200, 500344 B — **sha256-identical to upstream**; `7zip-24.09-r0.apk` likewise (915773 B) |

§3's `$AK_URL/alpine/alpine` mapping is correct exactly as written.

> **Trap that cost us a wrong conclusion — read this before enumerating repos.**
> `GET /api/v1/repositories` is **permission-filtered, and silently so**. The
> `svc-nix-build` service account sees 49 repos; an admin session sees 53. The
> four it hides are precisely those whose format is not one of the 13 that
> `/api/v1/formats` reports: `alpine`, plus `eric-vs-code-test` (`vscode`),
> `eric-tf-test` (`terraform`) and `eric-ansible-test` (`ansible`).
>
> A non-admin enumeration therefore shows **no alpine repo**, which reads as
> "alpine is unsupported" — a conclusion this document briefly recorded and
> which was wrong. The repo has existed since 2026-07-20. A direct
> `GET /api/v1/repositories/alpine` returns 200 even for the service account;
> only the *listing* drops it. Enumerate with an admin credential, or query keys
> directly. Review §5's note that working `alpine` and `vscode` repos exist
> outside the format list was right all along.

**Phase 2 — created and verified 2026-08-14** (see §8 Q1/Q3 for the format
caveat):

| Repo | Upstream | Format | Proof |
|---|---|---|---|
| `dockerhub` | `https://registry-1.docker.io` | `docker` | `GET /v2/dockerhub/library/alpine/manifests/3` → 200, real OCI image index |
| `ecr-public` | `https://public.ecr.aws` | `docker` | `GET /v2/ecr-public/aquasecurity/trivy-db/manifests/2` → 200 |
| `rpmfusion-free-fedora` | `https://mirrors.rpmfusion.org/free/fedora/` | `rpm` | `GET /rpm/rpmfusion-free-fedora/rpmfusion-free-release-42.noarch.rpm` → 200, 11571 B |

**Phase 2 — the narrowed remote list.** Only three of the original eight rows
survive the scope cut:

| Repo to create | Upstream | Format | Needed for |
|---|---|---|---|
| dockerhub | `https://registry-1.docker.io` | oci | every `FROM` in the five in-scope files, plus the `alpine:3` / `golang:1.25-alpine` builders and `nixos/nix` |
| ecr-public | `https://public.ecr.aws` | oci | trivy DB / java-DB (`ci-scripts/scan:12`) — CI-wide, not distro-specific |
| rpmfusion-free-fedora | `https://mirrors.rpmfusion.org/free/fedora/` | rpm | `install_audio.sh:27,31` (fedora 42/43) |

**Dropped by the scope cut, not merely deferred:** `epel-8` / `epel-9` and
`rpmfusion-free-el`. Every EPEL fetch in the tree is an EL8/EL9 path
(`install_kde.sh:66,75,84,94`, `install_xfce_ui.sh:97,110,121,140`,
`install_kasm_vnc.sh:7,10` via `oracle-epel-release-*`), and
`download1.rpmfusion.org/free/el/` likewise (`install_audio.sh:10-23`). Fedora
itself uses neither. The review's phrasing suggested EPEL was on a Fedora path;
it is not.

**Also deferred with their families:** `packman-leap`, `obs-m17n-fonts`,
`obs-printing` (all opensuse) and `saltproject` (remnux, debian).

**Phase 3 — needs a capability answer first:** generic remote(s), per §5. The
scope cut barely touches this: the raw fetches are mostly distro-agnostic and
the `container-init` `ADD` is in all nine dockerfiles regardless.

**Never:** `cache.nixos.org` and Nix flake inputs (no AK format — see review §2c),
and the `git clone` of REMnux salt-states (`extra/remnux.sh:17`).

---

## 7. Test plan

1. **Off-path regression.** Build with no flags set and confirm the dockerfile
   digest chain is unchanged from `develop`. Cover the five in-scope files
   **plus at least one deferred file** (`-suse` is the strongest choice, having
   no `package_rules` step) to prove the untouched families really are
   untouched. This is the gate that makes the flag safe to merge.
2. **Deferred-distro no-op.** With `AK_URL` **set**, build a debian or kali row
   off `dockerfile-kasm-core`. The §0 table-miss path must leave sources
   unmodified and AK's byte counters flat. This is the test that the shared
   dockerfile didn't quietly widen the scope.
3. **On-path, ubuntu first.** `AK_URL` only, `dockerfile-kasm-core`. Confirm
   `apt-get update` pulls from AK (check AK's `storage_used_bytes` moves) and the
   image is functionally identical.
4. **Leak guard.** Grep the resulting image for the AK hostname — must be zero
   hits across `/etc/apt`, `/etc/yum.repos.d`, `/etc/apk/repositories` (keep
   `/etc/zypp/repos.d` in the grep even though suse is deferred; it costs
   nothing and it will be right when suse lands). Wire this as a permanent CI
   job, not a one-off. If AK ever requires auth, extend it to the credential
   value too — see the credentials note in review §3.
5. **Alpine specifically** — now the only irregular insertion point in scope. A
   rewrite that silently lands after the first `apk add` looks like a pass but
   caches nothing; verify by AK-side byte counters, not by build success.
6. **Fedora metalink** — confirm `metalink=` is actually disabled and dnf is
   hitting the baseurl. Same failure mode as alpine: a build that succeeds while
   caching nothing.
7. **`AK_REGISTRY` on the nix builder** — the cheapest on-path test of the OCI
   remote once it exists, since `--nix-image` needs no code change.

## 8. Open questions for the vendor / devops

Probed against the live instance 2026-08-14. Q1–Q3 are now settled.

1. **Does a `generic` repo support `repo_type: "remote"` with an arbitrary
   upstream? — YES, confirmed by fetch.** A generic remote pointed at
   `kasmweb-build-artifacts.s3.amazonaws.com` returned
   `calculator_2.0.3-1_amd64.deb` **sha256-identical to upstream** (92400 B).
   Two findings that change §5:
   - **It serves anonymously.** No `Authorization` header, 200. So the
     Dockerfile `ADD` problem (`:13-14`, all 9 files) is **not** a blocker as
     long as the repo carries `allow_anonymous_access: true` — those lines do
     **not** need converting to `RUN curl`.
   - **But the download path is an API route, not a clean prefix:**
     `/api/v1/repositories/<key>/download/<upstream-path>`. `/generic/<key>/…`
     404s to the SPA. So §3's "pure prefix swap" holds for the *distro* formats
     (`/debian/<key>/…`, `/rpm/<key>/…`, `/alpine/<key>/…`) but **not** for
     generic. `AK_GENERIC` must therefore be the full
     `…/api/v1/repositories/<key>/download` base, and it cannot share a rewrite
     helper with `AK_URL`. Note also `.../files/...` 404s and
     `.../artifacts/...` returns `NOT_FOUND` — only `download` works.
2. **Does `/v2/` work as a containerd `hosts.toml` mirror? — NO. Settled with a
   real `dockerhub` remote in place.** AK requires the repo key *inside* the
   `/v2/` path: `/v2/dockerhub/library/alpine/manifests/3` → 200 (real OCI
   index), while every form containerd can actually emit 404s:

   | Path | Result |
   |---|---|
   | `/v2/library/alpine/manifests/3` (`server = "https://ak"`) | 404 |
   | `/dockerhub/v2/library/alpine/manifests/3` (`server = "https://ak/dockerhub"`) | 404 |
   | `/oci/dockerhub/v2/library/alpine/manifests/3` | 404 |

   containerd appends `/v2/<image>/…` to the mirror host and has nowhere to put
   a repo key. **So §4's image-reference rewrite table stands and is required** —
   it does not collapse into a `provision-runner.sh` change. Revisit only if AK
   adds a default- or virtual-repo concept.
3. **`/api/v1/formats` — ANSWERED, and it is doubly misleading.** It reports 13
   handlers, all `handler_type: "Core"` with `plugin_id: null` — i.e. the
   *core-handler* set, not the enabled set. Plugin formats (`alpine`, `vscode`,
   `terraform`, `ansible`) work fine but never appear. Compounding it, the repo
   *listing* hides plugin-format repos from non-admin callers (see the §6 trap).
   Practical rules:
   - **Use `format: "docker"` for OCI remotes, not `"oci"`.** Sending `"oci"` —
     which *is* in the reported list — yields a repo silently stored as
     `generic`. Sending `"docker"` stores `docker`. Both still proxy via `/v2/`,
     but the mistyped repo will not get OCI-aware handling.
   - A genuinely unknown format is rejected properly (`400 Invalid format`), so
     the `oci`→`generic` behaviour is specific, not a general silent-coercion.
4. What is the HA / uptime expectation for this instance? Once builds route
   through it, it is a CI dependency; the review flags it as a new SPOF. **Still
   unanswered — needs a human, not an API call.**

### Instance facts worth banking (verified 2026-08-14)

- **Repo count depends on who asks:** 53 as admin, 49 as `svc-nix-build`. Review
  §5's "46 repos" was a non-admin count taken before the phase-2 additions.
- **`svc-nix-build` cannot create repositories.** `POST /api/v1/repositories`
  → `403 FORBIDDEN`; the account reports `is_admin: false` with an empty
  `/api/v1/permissions`. An identical body succeeds as admin, so this is a
  permissions boundary, not a malformed request. Provisioning needs the admin
  login; the build path does not.
- **`PATCH` on `upstream_url` returns 200 but does not persist.** A PATCH
  repointing `rpmfusion-free-fedora` echoed a 200 while
  `GET /api/v1/repositories/rpmfusion-free-fedora` still reported the original
  upstream. Mechanism undiagnosed — treat repo edits as unreliable and prefer
  delete-and-recreate until someone confirms which fields are mutable.
- **Transient upstream 502s happen; do not read them as capability limits.** One
  fetch failed with `502 … "error sending request"` and three identical retries
  then returned 200. An earlier draft of this doc concluded from that single 502
  that AK cannot follow upstream redirects — **that conclusion was wrong** and
  has been removed. `mirrors.rpmfusion.org` 302-redirects to a mirror and AK
  handles it. Retry before diagnosing.
- **`staging` is a third `repo_type`** beyond `local`/`remote` (`ubuntu-staging`),
  undocumented in either doc and possibly relevant to §5's mirror-and-publish
  fallback.
- **EPEL is EL-only, confirmed instance-side.** The only EPEL repos are
  `oraclelinux-8-epel` / `oraclelinux-9-epel`, i.e. Oracle's bundled EPEL. No
  Fedora EPEL exists, matching the §6 finding that every EPEL path in the tree
  is EL8/EL9.
- **`fedora-42-*` points at `archives.fedoraproject.org`** (the archive host)
  while `fedora-43-*` uses `dl.fedoraproject.org`. Fedora 42 is already archived
  upstream; expect it to behave differently from 43 under cache revalidation.
- **The `/v2/` bearer flow is a placeholder.** `GET /v2/token` returns the
  literal string `"anonymous"` as both `token` and `access_token`
  (`expires_in: 900`). Do not treat `/v2/` as access-controlled on this instance.
- **No OpenAPI/Swagger spec** is served (`/openapi.json`, `/api/v1/openapi.json`,
  `/swagger.json`, `/api/v1/docs` all 404). The repo-create body has to be
  modelled from a `GET` on an existing repo. Accepted create fields: `key`,
  `name`, `format`, `repo_type`, `upstream_url`, `description`, `is_public`,
  `allow_anonymous_access`.
- **Repo listing is paginated** at 20/page behind an `{items, pagination}`
  envelope — a naive `GET /api/v1/repositories` silently shows only the first 20.
- **Admin login:** `POST /api/v1/auth/login` with `{username, password}` returns
  `access_token` / `refresh_token` and a `must_change_password` flag.

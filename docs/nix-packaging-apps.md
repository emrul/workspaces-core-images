# Packaging apps as Nix packages

How to take an app we install today via a downloaded `.deb`/`.rpm`/`.apk`
(the pattern in `src/<distro>/install/<feature>/install_<feature>.sh`) and
turn it into a Nix package that the `nix-ubuntu` image can activate from the
mounted `/nix` store.

The companion `design/nix-package-process.md` covers *how the store image is
built and layered*. This doc covers the layer below that: **how an individual
app becomes a derivation in the first place.**

## Why bother — the per-distro `if` ladder disappears

`src/ubuntu/install/kasm_vnc/install_kasm_vnc.sh` is ~200 lines, most of it a
`if [[ "${DISTRO}" == ... ]]` ladder selecting a different prebuilt artifact
per distro+arch and a different package manager (`apt`/`dnf`/`apk`/`zypper`)
to pull the matching system libraries. That complexity exists because a
`.deb` is dynamically linked against *that distro's* glibc, libjpeg, perl,
etc., so you need one artifact per distro and you lean on the host package
manager for dependencies.

Nix removes the reason for all of it. A derivation declares its dependencies
explicitly; they come from the pinned Nix store, not the host. The same build
output runs identically on Ubuntu, Fedora, or Alpine. **One derivation
replaces every branch of the ladder.**

## Decision: is the app already in nixpkgs?

```
Is there a nixpkgs#<name> for it?
├── YES → just add it to bin/nix-profiles.toml. No derivation needed.
│         e.g. chromium, vscode, obsidian — see the existing profiles.
└── NO  → write a derivation. Two options:
          A. You only have a prebuilt binary artifact (our S3 .deb/.rpm)
             → repackage it (autoPatchelfHook). Pragmatic. ~70 lines.
          B. You can build it from source
             → stdenv.mkDerivation from source. Purest. More work.
```

Most off-the-shelf desktop apps are already in nixpkgs — that path needs no
derivation at all, you just list `nixpkgs#foo` in `bin/nix-profiles.toml`.
The interesting case is our **own / vendor binaries** that will never be in
nixpkgs: KasmVNC, the various `kasm_*` component binaries, customer blobs.
Those need Option A or B.

---

## Option A — repackage a prebuilt `.deb` (recommended for our artifacts)

We already have build pipelines emitting `.deb`/`.rpm`/`.apk` to S3. Don't
throw that away — wrap one artifact in a derivation that:

1. fetches the artifact (`fetchurl`, pinned by hash),
2. extracts it (`dpkg-deb -x`),
3. rewrites every ELF binary's interpreter + RPATH to point at Nix-store
   libraries (`autoPatchelfHook`),
4. wraps any script entrypoints so their interpreter, libraries, and runtime
   PATH helpers resolve from the store (`makeWrapper`).

This is the standard nixpkgs idiom for vendor binaries (Slack, Discord,
Zoom, pre-built VS Code all do it).

### Worked example — KasmVNC

A complete, **built-and-verified** example lives at
[`nix/pkgs/kasmvnc/default.nix`](../nix/pkgs/kasmvnc/default.nix). It is the
direct Nix analogue of `install_kasm_vnc.sh`. The high-level shape:

```nix
{ lib, stdenv, fetchurl, dpkg, autoPatchelfHook, makeWrapper
, libxcrypt-legacy, freetype, mesa, libGL, pixman, libpng, openssl, zlib
, libunwind, systemdLibs, xorg
, perl, xkeyboard_config, xkbcomp, xauth, procps, hostname }:

stdenv.mkDerivation {
  pname = "kasmvncserver";
  version = "1.5.0";

  # Reuse the EXACT artifact our KasmVNC pipeline already publishes.
  src = fetchurl {
    url  = "https://kasmweb-build-artifacts.s3.amazonaws.com/.../kasmvncserver_noble_1.5.0_arm64.deb";
    hash = "sha256-yRmc9HUyCL+2n9AWqXgCQr6/xDNwzDjJfWHpCjx4PgQ=";
  };

  nativeBuildInputs = [ dpkg autoPatchelfHook makeWrapper ];

  # Every library the apt/dnf/apk lines used to install — declared once,
  # distro-independent. autoPatchelfHook patches each ELF against these.
  buildInputs = [ stdenv.cc.cc.lib libxcrypt-legacy freetype mesa libGL
    pixman libpng openssl zlib libunwind systemdLibs
    xorg.libX11 xorg.libXau xorg.libXcursor /* ... */ ];

  unpackPhase  = "dpkg-deb -x \"$src\" .";
  installPhase = '' ... cp -a usr/. "$out/"; wrapProgram ... '';
}
```

### The five gotchas this example actually hit

Each of these is a real failure I worked through building it — they are the
things you will hit repackaging any non-trivial `.deb`:

1. **Map `Depends:` → `buildInputs`.** Run `dpkg-deb -e <deb> && cat
   DEBIAN/control | grep Depends` (or `tar xf control.tar.* -O ./control`).
   Each `libfoo` Debian package maps to a nixpkgs attribute. autoPatchelfHook
   prints exactly which sonames are still unresolved, so it's an iterate-to-
   green loop, not guesswork.

2. **Old sonames need `-legacy` variants.** Ubuntu's `libcrypt1` is
   `libcrypt.so.1`; nixpkgs' default `libxcrypt` ships `libcrypt.so.2`. You
   need `libxcrypt-legacy`. Watch for this with any `.so.<low-number>`.

3. **Script shebangs are literal, not PATH-resolved.** The `.deb`'s perl
   scripts carry `#!/usr/bin/perl`. That only works if the base image happens
   to ship perl. Rewrite it to the Nix interpreter (`substituteInPlace ...
   --replace "#!/usr/bin/perl" "#!${perlEnv}/bin/perl"`) so the package is
   self-contained.

4. **Interpreter modules need their *transitive* closure.** For perl, use
   `perl.withPackages (p: [ ... ])`, **not** `makePerlPath`. The former builds
   an `@INC` that includes the modules *and their dependencies*
   (`List::MoreUtils` silently needs `Exporter::Tiny`); the latter only lists
   what you name and fails at runtime. Same principle for Python
   (`python3.withPackages`), Ruby, etc.

5. **Maintainer scripts do real work — replicate it.** The KasmVNC `.deb`'s
   `postinst` creates generic-named symlinks via `update-alternatives`
   (`Xkasmvnc`→`Xvnc`, `kasmvncpasswd`→`vncpasswd`). The perl server invokes
   the generic names, so the derivation recreates those symlinks in
   `installPhase`. Always read `postinst`/`prerm` — Nix runs none of them.

### Build & verify it yourself

No `nix` on macOS? Build inside the `nixos/nix` container (the same one
`bin/build-nix-store-volume` uses):

```bash
cd workspaces-core-images
podman run --rm -v "$PWD/nix/pkgs/kasmvnc:/work:ro" docker.io/nixos/nix:2.28.4 sh -c '
  out=$(nix build --impure --no-link --print-out-paths \
    --extra-experimental-features "nix-command flakes" \
    --expr "(builtins.getFlake \"github:NixOS/nixpkgs/nixos-25.05\").legacyPackages.aarch64-linux.callPackage /work/default.nix {}")
  "$out/bin/Xkasmvnc" -version          # ELF: interpreter + libs from /nix/store
  "$out/bin/kasmvncserver" --help       # perl entrypoint: modules + PATH resolve
'
```

Verified output (arm64): `Xvnc KasmVNC 1.5.0...` and the full `kasmvncserver`
usage banner — every dependency resolved from the store, zero host packages.

### Trade-offs

- ✅ Reuses the artifact pipeline we already trust; ~70 lines; fast (no
  compile, just extract + patchelf).
- ✅ One derivation, all distros, both arches (`x86_64` + `aarch64` keyed off
  `stdenv.hostPlatform.system`).
- ⚠️ `sourceProvenance = binaryNativeCode` — it's a binary blob, not built
  from source. Provenance/audit is only as good as the upstream artifact.
- ⚠️ You inherit upstream's build assumptions; you patch around them
  (the five gotchas) rather than controlling them.

---

## Option B — build from source (purest, most effort)

If the source is buildable, the cleanest Nix package builds it directly. No
prebuilt blob, fully reproducible, cross-compiles naturally, upstreamable to
nixpkgs.

```nix
{ stdenv, fetchFromGitHub, cmake, pkg-config, /* real buildInputs */ }:

stdenv.mkDerivation {
  pname = "kasmvnc";
  version = "1.5.0";
  src = fetchFromGitHub {
    owner = "kasmtech"; repo = "KasmVNC";
    rev = "v1.5.0"; hash = lib.fakeHash;   # fill from build error
  };
  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [ /* xorg libs, libjpeg-turbo, openssl, ... */ ];
  # standard cmake configure/build/install
}
```

### Trade-offs

- ✅ No binary blob; reproducible; `sourceProvenance` is real source.
- ✅ arm64 (and any platform) for free — no waiting on an upstream arm64
  artifact (note `onlyoffice` in `bin/nix-profiles.toml` is amd64-only today
  precisely because we depend on its prebuilt binary).
- ✅ Eligible to upstream into nixpkgs, after which it's just `nixpkgs#kasmvnc`
  and this whole file goes away.
- ⚠️ You reproduce the entire upstream build in Nix terms — its dependencies,
  build flags, patches. For a CMake/autotools C project that's tractable; for
  something with a bespoke build system it's real work.
- ⚠️ Build time + cache cost: every bump recompiles unless cached.

**Recommendation:** start with **Option A** for our existing artifacts
(KasmVNC and the `kasm_*` components). Move an app to Option B only when
binary provenance, arm64 support, or upstreaming to nixpkgs justifies the
effort.

---

## Wiring a custom package into the store-image flow

The entries in `bin/nix-profiles.toml` are flake references — today all
`nixpkgs#foo`. A custom derivation just needs to be a flake output you can
reference the same way.

1. **Expose it from a flake.** Add the package to a flake's `packages`
   output (a small `nix/flake.nix` that does
   `packages.<system>.kasmvnc = pkgs.callPackage ./pkgs/kasmvnc { }`).

2. **Reference it in `nix-profiles.toml`** like any other package:

   ```toml
   [profiles.kasmvnc]
   pkgs = ["path:./nix#kasmvnc"]          # local flake during dev
   # or "git+https://github.com/emrul/...#kasmvnc"  once committed
   ```

   `bin/build-nix-store-volume`'s `nix profile install` handles a local/git
   flake ref exactly like a `nixpkgs#` ref. It lands in
   `/nix/var/nix/profiles/kasmvnc/` and the existing `nix-activate` flow wires
   it into PATH + the XFCE menu.

3. **Pin the same nixpkgs as `[base]`.** A custom derivation should resolve
   `glibc`/`openssl`/`xorg.*` against the *same* pinned nixpkgs as the
   `[base]` layer (see `design/nix-package-process.md` → "Update cadence").
   Otherwise its delta layer carries near-duplicate base libs and bloats the
   store image.

---

## Choosing the base image for a Nix app image

`dockerfile-nix-ubuntu` takes a `BASE_IMAGE` build arg (default:
`localhost/kasm-core-ubuntu-noble:dev`). For single-app Nix images — browsers,
Electron apps, anything whose runtime comes entirely from `/nix/store` — use
`core-ubuntu-noble-minimal` instead of the standard core:

```bash
docker build \
  -f dockerfile-nix-ubuntu \
  --build-arg BASE_IMAGE=kasmweb/core-ubuntu-noble-minimal:dev \
  -t kasmweb/nix-ubuntu-chrome:dev .
```

**Why this is safe for Nix apps.** The minimal image strips system-level LLVM
(`libLLVM.so`, ~137 MiB) and WebKit (`libwebkit2gtk`, ~121 MiB). These are
only used by system-installed software that needs software rendering or an
embedded browser engine. A Nix app's closure is fully self-contained — `nix
build` resolves every dependency (Mesa, LLVM, GTK, etc.) to paths inside
`/nix/store`, so the system copies are never consulted. Chrome, Chromium, and
all QtWebEngine apps have been verified to work correctly from the minimal base.

**Why it matters.** Beyond the ~400 MiB size saving on the base layer, the
minimal image removes tools (`openssh-client`, compilers, `wget`,
`add-apt-repository`) that expand the attack surface of a long-lived browser
container. See `design/core-minimal.md` for the full list of removals.

**When to keep the standard core.** If a Nix app's activation script or
wrapper needs to fall back to system-installed tools (unusual), or you are
building a general-purpose desktop image rather than a single-app image, use
the standard `core-ubuntu-noble`. The minimal image is specifically for
browser/app containers where the Nix store is the sole software source.

---

## Dev / feature-branch builds

Day to day we don't test against released artifacts — we test against
feature-branch `.deb`s our pipelines push to S3 with a name that encodes the
branch and commit, e.g.:

```
kasmweb-build-artifacts.s3.amazonaws.com/kasmvnc/
  a4b74a836b7745209e6d5506fa2723603ed8b930/
  kasmvncserver_noble_1.4.1_feature_touch-device-support_a4b74a_amd64.deb
  └ commit (full) ┘          └ ver ┘└─── branch ───┘└short┘└arch┘
```

This is the exact `${VER}_${BRANCH}_${COMMIT6}` scheme `install_kasm_vnc.sh`
already builds (release artifacts drop the branch+commit suffix and are named
just `<version>`). The derivation reproduces that logic, so you select a
feature-branch build with data, not by editing code.

### Two contexts — pick the right one

- **KasmVNC and other core-image components** are baked into the core image
  *today* (via `install_kasm_vnc.sh`), not mounted from `/nix`. To test a
  feature-branch build of those in the **current** images, edit the script's
  `KASMVNC_VER` / `BRANCH` / `COMMIT_ID` and rebuild the core image
  (`bash runs/lean-noble-build.sh`). The `git rerere` note in `CLAUDE.md`
  about the recurring `COMMIT_ID` bump conflict is exactly this workflow.
- **Apps delivered via the Nix store** (the `nix-profiles.toml` set, and
  KasmVNC *if/when* it moves there) use the derivation override below. The
  rest of this section is that path.

### Step 1 — override the source

The `kasmvnc` derivation takes a `source` argument (defaulting to the pinned
release). Override it with the feature-branch coordinates:

```nix
pkgs.callPackage ./nix/pkgs/kasmvnc {
  source = {
    version = "1.4.1";
    commit  = "a4b74a836b7745209e6d5506fa2723603ed8b930";
    branch  = "feature_touch-device-support";   # "release" for a release build
    hashes  = {
      amd64 = "sha256-XT6TsZvuN+CintgSy/3MnBhC8W1PqXS4b+LzpD+6Ygw=";
      arm64 = "sha256-b/s9XONiYqq6lXU2xFnZuaMXpuJf9BcCfrsbmGY/sIY=";
    };
  };
}
```

(If the package is exposed from a flake, `.override { source = { ... }; }`
does the same thing.)

### Step 2 — get the hash (don't guess it)

You usually don't know the artifact hash up front. Set the relevant arch to a
fake hash, build, and copy the real one from the error:

```nix
hashes = { amd64 = lib.fakeHash; arm64 = lib.fakeHash; };
```

```
error: hash mismatch in fixed-output derivation
  '...kasmvncserver_noble_1.4.1_feature_touch-device-support_a4b74a_arm64.deb.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-b/s9XONiYqq6lXU2xFnZuaMXpuJf9BcCfrsbmGY/sIY=
```

Paste the `got:` value back in. (The filename in the error is also a free
sanity check that the branch/commit/arch resolved to a real artifact.)

### Step 3 — build just the package (fast inner loop)

No `nix` on macOS? Build inside the same `nixos/nix` container
`bin/build-nix-store-volume` uses. This is the actual command used to verify
the feature-branch build above (arm64):

```bash
cd workspaces-core-images
podman run --rm -v "$PWD/nix/pkgs/kasmvnc:/work:ro" docker.io/nixos/nix:2.28.4 sh -c '
  out=$(nix build --impure --no-link --print-out-paths \
    --extra-experimental-features "nix-command flakes" \
    --expr "(builtins.getFlake \"github:NixOS/nixpkgs/nixos-25.05\").legacyPackages.aarch64-linux.callPackage /work/default.nix {
      source = {
        version = \"1.4.1\";
        commit  = \"a4b74a836b7745209e6d5506fa2723603ed8b930\";
        branch  = \"feature_touch-device-support\";
        hashes  = { amd64 = \"sha256-XT6TsZvuN+CintgSy/3MnBhC8W1PqXS4b+LzpD+6Ygw=\";
                    arm64 = \"sha256-b/s9XONiYqq6lXU2xFnZuaMXpuJf9BcCfrsbmGY/sIY=\"; }; };
    }")
  "$out/bin/Xkasmvnc" -version    # verified: reports commit a4b74a836b...
'
```

With `nix` installed locally and the package wired into `nix/flake.nix`, this
collapses to:

```bash
nix build .#kasmvnc --override-input ...   # or use .override in the flake
```

Building only the package (seconds, no image rebuild) is the tight loop for
checking a feature artifact patches and runs before you spend time on a full
image.

### Step 4 — fold it into a test image

Two ways, depending on how much you need:

1. **Quick single-app OCI image (fastest).** The PoC flake (`nix/flake.nix`)
   already builds runnable per-app images with `nix2container`. Add `kasmvnc`
   (with your `source` override) as one of its `apps`/`profiles` and build its
   `*-run` target — you get a bootable image carrying just the feature build,
   no full store rebuild. Good for "does this one artifact work in a desktop".

2. **Full store image (closest to production).** Point the profile at your
   overridden package and rebuild the store volume:

   ```toml
   # bin/nix-profiles.toml — temporary dev override
   [profiles.kasmvnc]
   pkgs = ["path:./nix#kasmvnc"]    # flake output carrying the source override
   ```

   ```bash
   ./bin/build-nix-store-volume --profile kasmvnc \
       --tag localhost/kasm-nix-store-arm64:touch-test
   ```

   Then run `nix-ubuntu` with that store mounted (see
   `design/nix-package-process.md` §Verification step 5). `--profile kasmvnc`
   builds only that one profile's layer, so iteration stays cheap.

### Why this beats the `.deb` install loop

Same artifact, but: no per-distro branching, the hash pins exactly which
build you tested (no "which `.deb` is in this layer?" ambiguity), and
`--profile <name>` rebuilds only the changed layer instead of a full image.
The override lives in your build invocation, so a dev test never touches the
committed release pins.

## Quick reference — Debian dep → nixpkgs attribute

From mapping KasmVNC's `Depends:`. Most `libfoo-N` packages map to the
obvious nixpkgs name; the non-obvious ones:

| Debian `Depends:`        | nixpkgs attribute        | note |
|--------------------------|--------------------------|------|
| `libc6`, `libgcc-s1`, `libstdc++6` | `stdenv.cc.cc.lib` | provided by stdenv |
| `libcrypt1`              | `libxcrypt-legacy`       | old `.so.1` soname |
| `libgbm1`               | `mesa`                   | libgbm lives in mesa |
| `libgl1`                | `libGL`                  | libglvnd |
| `libsystemd0`           | `systemdLibs`            | lib-only output |
| `libx11-6`, `libxext6`, … | `xorg.libX11`, `xorg.libXext`, … | `xorg.*` namespace |
| `libxshmfence1`         | `xorg.libxshmfence`      | lowercase in `xorg.*` |
| `perl:any`              | `perl.withPackages`      | + transitive module closure |
| `libdatetime-perl`      | `perlPackages.DateTime`  | strip `lib`/`-perl`, CamelCase |
| `xauth`, `procps`, `x11-xkb-utils` | `xauth`, `procps`, `xkbcomp` | runtime PATH, not patchelf |

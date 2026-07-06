# core-ubuntu-noble-minimal — design notes

Security-hardened, lighter variant of `dockerfile-kasm-core` intended as a
base for application images (primarily Nix-based browser images like Chrome
and Chromium) where the goal is reduced attack surface rather than maximum
feature coverage.

## What it is

`dockerfile-kasm-core-minimal` (`kasmweb/core-ubuntu-noble-minimal`) is a
direct derivative of `dockerfile-kasm-core` with four differences:

| Change | Saving | Rationale |
|---|---|---|
| All Kasm feature binaries kept | — | Webcam, gamepad, printer, recorder, smartcard, squid all included; downstream images can disable at build time |
| `INCLUDE_PERL=0` | ~70 MiB | Perl runtime not needed at runtime; kasm-xvnc bypasses the VNC perl wrapper |
| Sysbox/systemd step removed | ~30 MiB + attack surface | Installs real systemd, dbus, iptables, kmod — not needed when container-init is PID 1 |
| `KASM_LANG_PROFILE=en` | ~470 MiB | Drops all gettext `.mo` translation catalogs; **keeps all fonts including CJK** so browsers render any language |
| Security hardening step | ~260 MiB + attack surface | See below |

## Security hardening step

`src/ubuntu/install/security_hardening/install_security_hardening.sh` runs
after VirtualGL and before the cleanup step. It purges (best-effort,
`--force-depends` so Kasm packages are not uninstalled):

| Package(s) | Why removed |
|---|---|
| `openssh-client` | Prevents using the container as an SSH jump-host or for outbound credential-bearing SSH connections |
| `wget` | Build-time only (all install scripts have already run); blocks a common payload-download vector at runtime |
| `software-properties-common`, `python3-software-properties` | Blocks `add-apt-repository` — prevents adding unauthorised APT sources at runtime |
| Compiler toolchain (`gcc`, `g++`, `cpp`, `binutils`, `make`, `build-essential`, `*-dev` headers) | Blocks on-the-fly exploit / SUID-helper compilation |
| `llvm-*`, `libllvm*` | 137 MiB system LLVM pulled in by `mesa-utils` for llvmpipe software rendering. Unused when downstream Nix apps (Chrome, Chromium, etc.) carry their own Mesa+LLVM in `/nix/store`. XFWM4 loses OpenGL compositing but falls back to XRender automatically. |
| `libwebkit2gtk-4.*`, `libjavascriptcoregtk-4.*` | 121 MiB WebKit engine dragged in as a stray XFCE/GTK dependency; has no role in a browser-base image where the real browser is a Nix package. |

## `KASM_LANG_PROFILE=en` — what it actually does

The `en` profile in `src/ubuntu/install/cleanup/cleanup.sh`:

- **Drops** all of `/usr/share/locale-langpack` (~350 MiB of gettext `.mo`
  files translating system utility UI strings — `acl`, `adduser`,
  `alsa-utils`, etc. — into every language). English is the runtime default
  regardless; these files are never consulted in a browser image.
- **Drops** non-English entries from `/usr/share/locale` and rebuilds the
  glibc locale archive to `en_*` only (~117 MiB → ~5 MiB).
- **Keeps all fonts**, including `fonts-noto-cjk` (~92 MiB). Fonts are what
  browsers use to render multilingual text; removing them would cause CJK
  pages to show tofu. The language packs have no bearing on rendering.
- **Drops** ibus CJK input method dictionaries (not needed when system locale
  is English).

`latin` profile is unchanged: it filters locale-langpack to Latin/Cyrillic
scripts and also drops CJK fonts (suitable for European-language-only images
that don't need CJK rendering).

## CVE scanning

The repo uses Trivy. On the remote build host (`emrul@192.168.1.140`), Trivy
is available as a Docker image. Quick scan of a locally-built image:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $HOME/.trivycache:/root/.cache \
  aquasec/trivy image \
  --scanners vuln \
  --severity HIGH,CRITICAL \
  --no-progress \
  --ignore-status will_not_fix,fix_deferred \
  kasmweb/core-ubuntu-noble-minimal:dev
```

The CI pipeline runs the same scan via `ci-scripts/scan` with the additional
Rego allow-list at `ci-scripts/vulnerability-filter.rego` (suppresses known
false positives and `will_not_fix` noise).

### Go stdlib CVEs — June 2026

First scan of the minimal image found all HIGH/CRITICAL findings in `stdlib
v1.24.4` — the Go standard library baked into `kasm-upload-server` and
`kasm-xvnc` by the `kasmgo_builder` stage. No OS package vulnerabilities.

Root cause: `golang:1.24-alpine` in the builder was pinned to 1.24.4 at
image build time. Several CVEs (CVE-2025-68121 CRITICAL, CVE-2025-61726 HIGH,
and a run of 2026-dated DoS findings) have fixes only in Go 1.25.x.

Fix: bumped all 8 dockerfiles (`dockerfile-kasm-core*`) from
`golang:1.24-alpine` to `golang:1.25-alpine`. Rebuilding regenerates the
embedded stdlib in both Go binaries, clearing all findings.

**Ongoing maintenance**: when Trivy reports `stdlib` findings, the fix is
always to bump the `golang:` tag in the builder stage, not to patch OS
packages. Check `go.dev/dl/` for the latest stable release.

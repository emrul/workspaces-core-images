# nix/ — Nix app images PoC (nix2container)

Spike implementation for the [`design/nix`](../design/nix/) bundle. Builds the
5-app demo set (chrome, chromium, vs-code, firefox, audacity) as OCI images with
[nix2container](https://github.com/nlewo/nix2container) to demonstrate
content-addressed, cross-image layer sharing.

Requires Nix with flakes (see
[`../design/nix/docs/demo-environment-setup.md`](../design/nix/docs/demo-environment-setup.md)).

## Status

Both flavours work (verified on the x86_64 test host — see
[`../design/nix/docs/handover.md`](../design/nix/docs/handover.md)):

- **Dedup-proof** (`.#<app>`, `.#fat`): per-app + fat images with no base.
  Measured **pull fat → any app = 0 bytes** (explicit shared base + per-app
  layers; see [`../design/nix/docs/investigation-findings.md`](../design/nix/docs/investigation-findings.md) §1b).
- **Runnable** (`.#<app>-run`, `.#fat-run`): `fromImage = nix-ubuntu` (core +
  activation) via `pullImageFromManifest` against a local registry, with a
  generated `/nix/var/nix/profiles` tree. Boots a KasmVNC desktop; Chrome/VS
  Code/Firefox launch from the menu + Desktop, sandboxed via the seccomp
  profile. Run with `runs/nix-demo.sh` (needs `--security-opt seccomp=…` and the
  userns sysctl — see [`../design/nix/docs/demo-environment-setup.md`](../design/nix/docs/demo-environment-setup.md) §7).

## Build

```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh   # if not in a login shell
cd nix

# Build closures (substitutes from cache.nixos.org where possible):
nix build .#chrome .#chromium .#vscode .#firefox .#audacity .#fat -L

# Load into the local Docker daemon:
nix run .#chrome.copyToDockerDaemon
nix run .#chromium.copyToDockerDaemon

# Or export a self-contained archive (airgapped path):
nix run .#chrome.copyTo -- oci-archive:./nix-chrome.tar:nix-chrome:spike
```

## Prove the dedup

```bash
# After loading chrome + chromium into Docker:
docker inspect --format '{{json .RootFS.Layers}}' nix-chrome:spike   | tr ',' '\n' | sort > /tmp/chrome.layers
docker inspect --format '{{json .RootFS.Layers}}' nix-chromium:spike | tr ',' '\n' | sort > /tmp/chromium.layers
echo "shared layers:"; comm -12 /tmp/chrome.layers /tmp/chromium.layers | wc -l
echo "chromium-only layers:"; comm -23 /tmp/chromium.layers /tmp/chrome.layers | wc -l
```

A large shared count + small chromium-only count = the headline result: after
pulling one Chromium-family image, the next is almost free.

# Demo / Build Environment Setup

How to stand up a host that can build the Nix per-app + fat images. Reproducible
by any teammate. These are the exact steps used on the shared x86_64 test box.

> TL;DR: a Linux x86_64 host with **Docker ≥ 28** and **Nix (flakes on)**. Put
> the Nix store and Docker data on your biggest disk. No podman/skopeo/buildah
> needed on the host — nix2container brings its own skopeo via the flake.

## 1. Host requirements

| Need | Why | Minimum |
|---|---|---|
| Linux **x86_64** (Ubuntu 24.04 used here) | Nix builds per-system; native arch avoids 10×+ qemu | — |
| **Docker ≥ 28** (`docker --version`) | `--mount type=image` (fat-image runtime mount) landed in 28.0 | 28.0 |
| Disk | Nix store (5 GUI apps ≈ 5–10 GiB) + Docker images | ~30 GiB free, on a big drive |
| RAM / CPU | Chromium-class closures build/pull fast | 8 GiB / 4 cores+ |
| `git`, `rsync` | fetch/sync the repo | any |

Check Docker can mount images (Docker 28+):

```bash
docker --version            # >= 28.0
docker info | grep -i "docker root dir"
```

## 2. Put heavy data on your big disk (space-constrained hosts)

Two things grow large: the **Docker data-root** and the **Nix store**. If your
root filesystem is small, move both to a larger mount (here `/mnt/data`).

### 2a. Docker data-root → big disk

```bash
sudo mkdir -p /mnt/data/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{ "data-root": "/mnt/data/docker" }
JSON
sudo systemctl restart docker
docker info | grep -i "docker root dir"   # => /mnt/data/docker
```

(On the shared box this was already configured.)

## 3. Install Nix (Determinate installer — flakes enabled by default)

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
  | sh -s -- install --no-confirm
```

This installs a multi-user daemon and writes `/etc/nix/nix.conf` with
`extra-experimental-features = nix-command flakes`. Open a new shell, or source
the profile in the current one:

```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix --version          # Determinate Nix 3.x (Nix 2.3x)
nix flake --help >/dev/null && echo "flakes enabled"
```

> Non-login shells (e.g. `ssh host 'cmd'`) may not auto-source the profile.
> Prefix Nix commands with the `source` line above, or run via a login shell.

Upstream alternative (if you don't want Determinate):
`sh <(curl -L https://nixos.org/nix/install) --daemon`, then add
`experimental-features = nix-command flakes` to `/etc/nix/nix.conf` and
`sudo systemctl restart nix-daemon`.

## 4. Relocate the Nix store to the big disk (do it right after install)

The Determinate installer puts `/nix` on the root filesystem. Move it to the big
disk **while it is still small (~200 MiB)**, using a **bind mount** (not a
symlink — store paths hard-code `/nix/store`, and Nix recommends a real mount at
`/nix`). fstab makes it survive reboot.

```bash
sudo systemctl stop nix-daemon.service nix-daemon.socket \
                    determinate-nixd.service determinate-nixd.socket
sudo mv /nix /mnt/data/nix
sudo mkdir -p /nix
grep -q "/mnt/data/nix /nix" /etc/fstab \
  || echo "/mnt/data/nix /nix none bind 0 0" | sudo tee -a /etc/fstab
sudo mount --bind /mnt/data/nix /nix
sudo systemctl start determinate-nixd.socket nix-daemon.socket nix-daemon.service

# verify: /nix should be on the big device
mount | grep ' /nix '
df -h /nix | tail -1
nix store info >/dev/null && echo "store OK"
```

If your root disk has ample space, skip this section — `/nix` on root is fine.

## 5. Get the repo onto the host

From a clone of `workspaces-core-images` (branch `feat/nix`):

```bash
# from your workstation
rsync -az --exclude '.git' \
  /path/to/workspaces-core-images/ \
  <user>@<host>:~/workspaces-core-images/
```

Or `git clone` the fork directly on the host if it has credentials.

## 6. Build the prerequisite core image

The Nix images layer `FROM` this fork's `container-init` core (the upstream
Dockerhub core is the bash-supervisor flavour and is **not** compatible — it
has no `/etc/container-init.d/`). Build it once:

```bash
cd ~/workspaces-core-images
docker build -f dockerfile-kasm-core \
  --build-arg BASE_IMAGE=ubuntu:24.04 \
  --build-arg DISTRO=ubuntu \
  --build-arg BG_IMG=bg_kasm.png \
  -t localhost/kasm-core-ubuntu-noble:dev .
```

~5–15 min (pulls + installs the whole desktop stack). Re-run only on upstream
sync.

## 7. Chrome sandbox prerequisite (run with the seccomp profile)

The runnable images launch Chromium/Chrome **with** their namespace sandbox (no
`--no-sandbox`). That needs the tuned seccomp profile at run time and
unprivileged user namespaces enabled on the host:

```bash
# Host (once): allow unprivileged userns (Ubuntu 23.10+ AppArmor restriction)
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-nix-app-userns.conf

# Run flags (in runs/nix-demo.sh):
docker run … \
  --security-opt seccomp=$PWD/src/common/seccomp/chrome.json \
  --security-opt apparmor=unconfined \
  …
```

See [`../../docs/seccomp-how-to.md`](../../docs/seccomp-how-to.md). Without these,
Chrome can't sandbox and will fail (the profile is harmless but ineffective if
the host blocks userns).

## 8. Ready

You now have: Docker (images on the big disk), Nix with flakes (store on the big
disk), the repo, the core image, and the Chrome sandbox prerequisites. Build +
run with `bash runs/nix-demo.sh` (see [`build-pipeline.md`](build-pipeline.md)
for the design).

## Teardown / reset

```bash
# remove built images
docker image prune -af
# uninstall Determinate Nix (also unwinds the /nix bind mount it knows about;
# if you added the fstab line manually, remove it)
/nix/nix-installer uninstall
sudo sed -i '\#/mnt/data/nix /nix#d' /etc/fstab
```

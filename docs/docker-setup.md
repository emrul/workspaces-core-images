# Docker host setup for the Nix image catalog

Hosts that pull the Nix workspace images (`nix-<app>:<tag>`) or the fat store
(`nix-store:<tag>`) must run **Docker Engine ≥ 28 with the containerd image
store (snapshotter) enabled.** This is a hard requirement, not a nicety — the
layer-dedup that the catalog is built around only works on a content-addressed
image store.

## Why

The build (`bin/build-nix-store-volume` + `bin/nix-crane-assemble`) hand-assembles
every image so that the fat store and each per-app image share **byte-identical
`/store` layers** (see `design/nix-delivery-model.md`). The intended payoff: a
host that already has the fat store — or any other app — pulls a new app for
≈0 store bytes; only its thin OS base + a few-KB wiring/symlink layer transfer.

That payoff depends on how the client decides a layer is "already present":

| Image store | Reuse keyed on | Result for our layers |
|---|---|---|
| classic **`overlay2`** graph driver (old Docker default) | **chainID** (a layer *plus all its parents*) | The fat store is `FROM scratch`; per-app images are on the OS base, so identical store blobs sit on different chains → **re-downloaded**. Dedup does **not** materialize. |
| **containerd** content store (snapshotter) | **content digest** (chain-independent) | Identical blobs are recognized across images → **"already exists"**, no re-download. Dedup works as designed. |

This was verified directly: with the fat store's `de8b47…` (a 618 MB app store
layer) already present, pulling another image reports it as **`already exists`**
under the containerd store, but **re-downloads** it under `overlay2`
(see `design/nix-dedup-gap.md`).

Content-addressed storage is the norm on modern runtimes: Kubernetes dropped the
Docker shim in v1.24 and runs **containerd** (or CRI-O) directly, both
content-addressed. Enabling Docker's containerd store just aligns a Docker host
with that standard — it is not a workaround.

## Requirement: Docker ≥ 28

We support **Docker Engine 28.0 or newer only.** Rationale:

- The containerd image store is stable and well-exercised by 28.x (it shipped as
  experimental in 24, matured through 25–27).
- 28+ pairs cleanly with current `nvidia-container-toolkit` for the GPU workspaces.
- It lets us assume one image-store model across all hosts instead of supporting
  both `overlay2` and containerd behaviors.

Check: `docker version --format '{{.Server.Version}}'` → must be ≥ 28.

## Configuration

Enable the containerd snapshotter in `/etc/docker/daemon.json`. **Merge** this
with any existing config — do not drop the `runtimes` block on GPU hosts:

```json
{
  "features": { "containerd-snapshotter": true },
  "runtimes": {
    "nvidia": { "path": "nvidia-container-runtime", "args": [] }
  }
}
```

Then restart the daemon:

```bash
sudo systemctl restart docker
```

### One-time migration cost

The containerd store is **separate** from the old `overlay2` store, so images
pulled before the switch become invisible and must be **re-pulled** (including
Kasm's own images). Plan a maintenance window: switching restarts Docker and
drops running containers/sessions. Old `overlay2` data can be reclaimed later
(`/var/lib/docker/overlay2` / `docker system prune` after confirming the new
store is healthy).

### GPU hosts

The snapshotter is orthogonal to the NVIDIA runtime — keep the `runtimes` block
above. After switching, re-run a GPU smoke test (e.g. `runs/nix-chrome-gpu.sh`
or `runs/nix-blender-gpu.sh`) to confirm `--runtime=nvidia` + `--device
/dev/dri/*` still work under the containerd store.

## Verification

1. **Store is active:**
   ```bash
   docker info --format '{{.DriverStatus}}'
   ```
   Should report the containerd snapshotter (e.g. `Storage Driver: overlayfs`
   with `driver-type: io.containerd.snapshotter.v1`), **not** `overlay2`.

2. **Dedup works** — on a host that already has the fat store:
   ```bash
   docker pull <registry>/nix-store:<tag>      # once
   docker pull <registry>/<app>:<tag>          # then any app
   ```
   The app's **store layers must report `Already exists`**; only the OS base (if
   absent) and the small wiring/symlink layer should download. If big store
   layers re-download, the snapshotter is not active (still on `overlay2`).

## Notes

- **Kasm hosts** use Docker directly (not k8s), so they default to `overlay2` and
  must be switched explicitly per this doc.
- **Registry storage** dedups by digest regardless of the client store, so
  pushes/registry footprint already benefit; this doc is purely about **client
  pull cost**.
- If a host cannot enable the snapshotter, the alternative is the **image-mount
  model** (thin `nix-<distro>` base + `--mount type=image` the fat store at
  `/nix` + launch-form app selection) — no per-app image pull at all. See
  `design/nix-delivery-model.md` §5.

# Assessment: Should the Kasm Base Image Get Thinner via Nix?

Addresses the stated question: *should the Kasm core image be extracted to be
thinner, with some default components (KasmVNC and co.) delivered as Nix
packages bound at runtime?*

Status: **assessment only** (Open Question 2 — whether to *implement* is a
separate decision). Recommendation below, with the trade-offs that drive it.

## What's in the core image today

The core image (`dockerfile-kasm-core`, this fork) bundles, via apt/yum/apk:
the desktop (XFCE/IceWM), **KasmVNC**, profile-sync, upload server, audio
in/out, gamepad, webcam, printer, recorder, squid, smartcard, optional
NVIDIA/VirtualGL, plus the `container-init` PID-1 supervisor and its units.
Most of these are Kasm-built component binaries pulled in at build time (see
repo `CLAUDE.md` "What's inside a core image").

## The idea

Move some of these components out of the apt-built image and deliver them as
**Nix packages**, bound at runtime from the same mounted/shared store the apps
use. The core image becomes a thin OS + container-init shell; KasmVNC etc. come
from `/nix`.

## Could it work? (feasibility)

| Component | In nixpkgs? | Nix-packageable? | Notes |
|---|---|---|---|
| XFCE / IceWM | yes | yes | desktop envs are well-supported |
| **KasmVNC** | no (Kasm-built) | **custom derivation** | builds from the `KasmVNC` repo; non-trivial (Xvnc fork, web assets) |
| profile-sync, upload/printer/recorder/audio/webcam/gamepad/squid/smartcard | no (Kasm-built) | custom derivations | each is a Kasm component binary; packaging = writing derivations + keeping them in step with their source repos |
| container-init | no (Kasm-built, Go) | yes (Go is easy in Nix) | but it's PID 1 / the entrypoint — least suitable to move off-image |

So it's *feasible* but the Kasm-built components would each need a maintained
custom derivation tracking its upstream repo — a non-trivial, ongoing cost.

## Benefits

- **Thinner base** that updates independently of its components: patch KasmVNC
  by re-emitting one Nix layer, no full core rebuild.
- **Unified update story**: components and apps share the same store, cache,
  and cadence machinery.
- **Layer sharing** between core components and app closures (shared glibc/X11
  etc. already in `[base]`).
- **Reproducibility/SBOM** for the whole stack, not just apps.

## Costs / risks

- **Maintenance multiplied.** Every Kasm-built binary needs a Nix derivation
  kept in lockstep with its source repo — work the apt path doesn't require
  today. This is the dominant cost and it never goes away.
- **Bootstrapping / chicken-and-egg.** If KasmVNC is in `/nix` and `/nix` is a
  runtime mount, the desktop can't start until the volume is present. The image
  is no longer self-sufficient — bad for the simple `docker run core` case and
  for the per-app images (which would now *all* depend on a store mount).
- **PID 1 must stay baked.** container-init is the entrypoint; it can't come
  from a runtime-mounted store. So the "thin shell" still contains the
  supervisor + units + the OS.
- **Two packaging systems** in the core image (apt for OS bits + Nix for
  components) — more moving parts, more to debug.
- **Regression surface.** KasmVNC is the heart of the product; moving it onto a
  newly-written derivation risks subtle headless/X behavior changes.

## Recommendation

**Do not move KasmVNC or the core Kasm components into Nix in this effort.**
Keep the core image apt-built and self-sufficient. Reasons:

1. The per-app images are strongest when **self-contained** (`docker run
   kasmweb/chrome` with no store mount). Making the *base* depend on a Nix mount
   undermines that and the verified-publisher UX.
2. The maintenance cost of custom derivations for every Kasm-built binary is
   high and permanent, for a benefit (independent component patching) that the
   existing per-component install-script + CI already largely provides.
3. The big win Nix offers Kasm — shipping *third-party apps* with dedup and fast
   CVE cadence — is fully captured by the app pipeline without touching the base.

### A narrow, lower-risk variant worth keeping on the table

If component-patch agility becomes a real pain point, package **only**
non-PID-1, non-KasmVNC components (e.g. recorder, squid) as Nix and bind them
*optionally*, while keeping KasmVNC + container-init baked and the image
self-sufficient by default. Treat as a separate future spike, not part of this
PoC.

### What this PoC *should* do instead

- Keep the base as-is; layer Nix **apps** on top (`fromImage = core`).
- Ensure the `[base]` Nix closure (glibc, X11, gtk, nss…) is well-chosen so app
  deltas stay thin — that's where the layer-efficiency win actually lives.
- Revisit base-thinning only after the app pipeline is in production and we have
  real data on whether component-patch cadence is a bottleneck.

### Next step (deferred, not closed)

We will **scope what KasmVNC-as-Nix actually involves** before ruling it in or
out — a time-boxed investigation: can KasmVNC's Xvnc fork + web assets be
expressed as a derivation, what does it cost to keep in step with the KasmVNC
repo, and does an *optional* bind (image still self-sufficient by default)
sidestep the bootstrapping problem above. This is a separate spike from the app
pipeline (REQUIREMENTS "Open / Deferred" #3), not part of this PoC.

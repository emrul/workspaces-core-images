# Chrome at scale — memory optimization for the single-app image

## Context

The Nix single-app Chrome image (`src/ubuntu/install/nix/chrome/`) runs one
`google-chrome-stable` per workspace container, rendered to KasmVNC. On a fleet
of ephemeral agents, per-session Chrome memory is a direct multiplier on how many
workspaces a node can host. This note inventories what we launch today and the
levers available to trim Chrome's footprint.

This is orthogonal to `design/nix-workspace-as-code.md` — it's about tuning the
app itself, not composing stores.

## What we launch today

`src/ubuntu/install/nix/scripts/nix-launch` (chromium-family argv) sets only
**functional** flags, no memory tuning:

- GPU path (`nix-gpu-run --available`): `--password-store=basic --no-sandbox
  --ignore-gpu-blocklist --use-angle=vulkan --ozone-platform=x11
  --disable-dev-shm-usage --no-first-run --disable-search-engine-choice-screen`
- Software path: `--password-store=basic --disable-gpu --disable-dev-shm-usage
  --no-first-run --disable-search-engine-choice-screen`
- `chrome/launch` adds `--start-maximized`.
- `chrome/post-build.sh` writes one managed policy:
  `/etc/opt/chrome/policies/managed/kasm-flags.json` =
  `{"CommandLineFlagSecurityWarningsEnabled": false}` (cosmetic — hides the
  `--no-sandbox` infobar).

`--disable-dev-shm-usage` is already present, which shifts Chrome's shared memory
off `/dev/shm` (tmpfs / RAM-backed) onto `/tmp` (container writable layer / disk)
— so one memory→disk shift is already in effect.

## Root cause worth fixing first

Chrome sizes its memory heuristics — renderer-process count, cache budgets, tab-
discard thresholds — off the RAM it can **see**. In a container that is usually
the **host's** total RAM, not the workspace's cgroup memory limit. So Chrome plans
as if it were on a large desktop and overshoots: even if the container is capped
at, say, 2 GB, Chrome may budget for the host's 32 GB. That mismatch is where most
of the waste originates, and it is why explicit capping matters more in this
context than on a normal desktop. Newer Chrome may honor cgroup v2 memory pressure
signals, but do not rely on it — cap explicitly.

## Levers (ranked, highest-leverage first)

| Lever | Type | Effect | Tradeoff |
|-------|------|--------|----------|
| `--enable-low-end-device-mode` | flag | **Top pick.** One switch that enables Chrome's whole low-memory profile (smaller caches, aggressive tab discarding, fewer processes). Directly counters the host-RAM overshoot | Slightly less snappy; minor UI trims |
| `--renderer-process-limit=N` **or** `--process-per-site` | flag | Caps process sprawl. `--process-per-site` collapses all same-site tabs/frames into one renderer (default is process-per-site-*instance*, which spawns more); `--renderer-process-limit` is a hard ceiling you can tie to the container's memory allocation | A site's renderer crash takes its tabs; marginally less isolation |
| **Memory Saver** mode | policy | Discards idle background tabs → large win for multi-tab users | Discarded tabs reload on focus (latency). **Policy name changed across Chrome versions** (`HighEfficiencyModeEnabled` → `MemorySaverModeSavings`) — verify against the pinned `google-chrome` version via `chrome://policy`; do not assume the name/semantics |
| `--disable-background-networking`, `--disable-component-update` | flag | An ephemeral session does not need background component / field-trial / safe-browsing update fetches — steady RAM + CPU + network saving | Components stay stale within the session (fine for throwaway sessions) |
| `NetworkPredictionOptions: 2` | policy | Disables speculative prerender/prefetch, which spins up extra renderers that hold pages in RAM | Slightly slower navigation |
| `BackgroundModeEnabled: false` | policy | Prevents Chrome staying resident in the background | Minimal — Chrome is the only app here anyway |
| Disable **site isolation** (`--disable-site-isolation-trials` / `SitePerProcess: false`) | flag/policy | **Largest raw saving** — no longer one process per cross-site frame | **Security tradeoff:** removes a Spectre / cross-site defense. Only acceptable if the threat model permits arbitrary-web browsing without it. **Not a default** |

**Avoid** `--js-flags="--max-old-space-size=…"`: capping V8 old-space per renderer
risks OOM crashes on heavy pages. It is a Node lever, not a browser lever.

## Where to place each (override-ability)

Split by whether a customer should be able to override it (see the override-point
design in `design/nix-workspace-as-code.md` § Pre-seeding configuration):

- **Baked flags** — process-model tuning that is a platform decision:
  `--enable-low-end-device-mode`, `--renderer-process-limit` / `--process-per-site`,
  `--disable-background-networking`, `--disable-component-update`. Put in
  `nix-launch` / `chrome/launch`.
- **Policy-expressible** — the customer-overridable surface: Memory Saver,
  `NetworkPredictionOptions`, `BackgroundModeEnabled`, and (if ever used) site
  isolation. Put in the managed-policy JSON (`chrome/post-build.sh`, or better, a
  desktop/base-level policy seed per the recommendation in
  `nix-workspace-as-code.md`). A customer who wants, e.g., tabs *not* discarded
  drops a counter-policy.

## Measured results (2026-07, .140)

Measured with the committed harness `runs/chrome-density/` — a faithful rewrite of
the `perf-report.html` method (ramp 1→8, N=3 median, `docker run` direct with
`seccomp=chrome.json` + `apparmor=unconfined`, software render, no GPU). The
headline metric is **anon** (private working set = the packing floor; file/page
cache is reclaimable and shared, so it does not bound packing). Arms are injected
purely via `APP_ARGS` — no image or code change. Two workloads:

- **Scenario 1 — near-idle** (one fixed local page/session). Anchors arm A to the
  report (baseline anon ≈ 290 MiB/session ≈ the report's 319; the density delta is
  just the lighter blank page).
- **Scenario 2 — heavy** (8 distinct-hostname tabs/session → 8 distinct *sites* →
  8 renderers; each tab retains a fixed 32 MiB heap + 3000-node DOM).

### Scenario 1 (near-idle)

| metric | baseline | trio | Δ |
|--------|---------:|-----:|--:|
| anon / session | 289.6 MiB | 279.8 MiB | **−3.4%** |
| sessions / 100 GB (anon) | 354 | 366 | **+3%** |

Monotonic (trio < baseline at every step), so real but small. At idle the trio ≈
`--enable-low-end-device-mode` alone; the other two levers are inert with one tab.

### Scenario 2 (heavy) — 4 arms

| arm | anon/sess | sessions/100 GB | vs baseline |
|-----|----------:|----------------:|------------:|
| baseline | 647.6 MiB | 158 | — |
| trio (`low-end` + `--renderer-process-limit=3`) | 639.4 | 160 | +1% |
| `noiso` (site isolation off only) | 638.8 | 160 | +1% |
| `trio_noiso` (isolation off **and** limit=3) | 603.9 | 170 | **+7%** |

Renderer counts (8 sites): baseline **9**, trio **8**, noiso **8**, trio_noiso **3**.

### What the data says

1. **`--renderer-process-limit` is inert while site isolation is on.** Site-per-
   process forces one renderer per site regardless of the cap; trio stayed at 8
   renderers. The cap only bites once isolation is disabled (trio_noiso → 3).
2. **Disabling site isolation *alone* saves ~nothing** (noiso: still 8 renderers,
   +1%). It only helps paired with a low process limit.
3. **Even the full corner-cut buys ~7%** (heavy). Because page *content* (JS heaps,
   DOM) stays resident no matter how few processes host it — consolidation reclaims
   per-process *overhead*, not content. The saving would be larger for a
   many-*light*-tabs workload (overhead dominates) and near-zero for few-heavy-tabs.
4. **`--enable-low-end-device-mode` does NOT silently disable site isolation** on
   this Chrome/Linux (trio kept 8 renderers) — it is genuinely security-neutral,
   resolving the earlier caveat.

## Recommended default (revised by the data)

- **Ship `--enable-low-end-device-mode`.** Free, security-neutral, ~3–4% idle / ~1%
  heavy. Put it in `nix-launch` / `chrome/launch`.
- **Drop `--renderer-process-limit` from the default.** It is inert under site
  isolation (the safe posture); keeping it implies a benefit that does not exist
  unless you also disable isolation.
- **Memory Saver stays an opt-in policy** — its benefit is idle-tab discarding over
  time, which this steady-state benchmark cannot capture; assert from design, not
  from these numbers.
- **Do NOT disable site isolation as a default.** +7% heavy is not worth the
  Spectre / cross-site exposure (see `nix-workspace-as-code.md` for the full
  security reasoning). Reserve it for kiosk/single-site workspaces only.

**The strategic conclusion:** in-browser flags top out at single-digit %, because
the bottleneck is **anon**, which the flags cannot compress or share. The big
density wins live elsewhere: the nix design already shares `/nix/store` *file*
pages across co-located sessions (+50% vs stock), and **compressed memory (zswap)**
attacks the *anon* floor — the complementary half. See
`design/workspace-density-zswap.md` (the next investigation).

## Open follow-ups

1. Wire `--enable-low-end-device-mode` into `chrome/launch` (single flag; measured
   +3–4% idle, security-neutral).
2. Apply the same tuning to the fat-store desktop `chromium` profile, not only the
   single-app image (the desktop path gets no Chrome wiring today — same gap as the
   managed policies in `nix-workspace-as-code.md`).
3. **zswap** — the real anon-floor lever; tracked separately in
   `design/workspace-density-zswap.md`.
</content>

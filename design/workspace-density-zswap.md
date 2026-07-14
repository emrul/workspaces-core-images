# Workspace density via compressed memory (zswap)

## Context

Chrome-at-scale (`design/chrome-at-scale.md`) established that in-browser flags top
out at single-digit % density gains, because the bottleneck is **anon** — the
private, per-session working set — which flags can neither share nor compress. The
nix design already attacks the *other* half (shared `/nix/store` **file** pages
cached once across co-located sessions → +50% vs stock). Compressed memory attacks
the **anon** half. This note is that investigation.

## Why zswap, not zram

The obvious "compressed memory" candidates are zram and zswap. Per Chris Down's
analysis (*zswap vs zram: when to use what*, 2026-03) and our constraints:

- **zram is the special-case / "exotic" one** — a fixed-size compressed RAM block
  device with **no automatic tiering**. Its failure modes are disqualifying for a
  customer fleet: LRU inversion (cold init data locks fast RAM while hot pages
  spill to disk), **no graceful degradation** (OOM kills or multi-minute
  brownouts under pressure — cf. Cloudflare), and manual writeback config. Kernel
  maintainers are moving away from it.
- **zswap is the production default** — a compressed cache *in front of ordinary
  disk swap*, integrated into the kernel reclaim path: automatic cold→disk
  tiering, **graceful degradation** (perf cliff, not hangs), per-cgroup
  accounting/writeback (kernel ≥6.8), rejects incompressible pages. Meta/Instagram
  run it at scale.

**The decisive point for *this* system:** zram *strangles the page cache* — by
refusing to swap anon to disk it forces file-cache eviction, which would directly
undermine the shared `/nix/store` file-page caching that gives nix its +50%. zswap
lets the kernel choose anon-vs-file eviction by recency, so it **preserves the
file-sharing win and adds anon compression** — the two compose. Customer fleets
run on disk-backed servers, so zswap's disk requirement is a non-issue.

**Decision: zswap.** It is the low-ops, graceful, file-cache-compatible choice.

## Host setup (.140)

Already favourable — no new infra:

- Kernel **6.17** (newest zswap; per-cgroup `memory.zswap.current`).
- Existing **16 G disk swap** at `/mnt/data/Kasm.swap` (zswap backing already present).
- cgroup v2, PSI available (`/proc/pressure/memory`, per-cgroup `memory.pressure`).
- zswap was `enabled=N`, `compressor=lzo`. We enable it with **zstd** (ratio over
  speed): `echo zstd > /sys/module/zswap/parameters/compressor; echo 1 > .../enabled`.
  `zpool=zsmalloc`, `max_pool_percent=20` (≈25 G compressed pool on this host).

Reversible: `echo 0 > /sys/module/zswap/parameters/enabled`.

## Method

`runs/chrome-density/zswap-probe.sh`: enable zswap, launch a **memory-limited**
heavy Chrome fleet (`--memory=M` below the natural working set, so the kernel
reclaims cold anon into the compressed pool), then measure:

- **Compression ratio** = `stored_pages*4096 / pool_total_size` (global), cross-
  checked per-cgroup via `memory.swap.current / memory.zswap.current`.
- **Per-session real RAM** = `memory.current` (compressed pool is charged to it, so
  this is *true* real RAM under the cap) split into resident anon / compressed /
  disk-written-back.
- **Usability** = each container's OWN `memory.pressure` full avg10 (host-wide PSI
  stays ~0 while the host has spare RAM — the per-cgroup pressure is the signal).

Heavy workload = 8 distinct-site tabs/session (each retains a 32 MiB heap + 3000
DOM nodes), same as `chrome-at-scale.md` scenario 2.

## Results

### Cap sweep (4 heavy sessions/cap, idle-after-load)

Per-container `--memory` cap vs real RAM, the RAM/compressed/disk split, and each
container's OWN cgroup pressure (`memory.pressure` full avg10):

| cap | real RAM/sess (`memory.current`) | resident anon | zswap pool | disk swap | pool ratio | disk written-back | cgPSI full10 | → sess/100 GB |
|----:|--------------------------------:|--------------:|-----------:|----------:|-----------:|------------------:|-------------:|--------------:|
| 800m | 724 MiB | 570 | 14 | 80 | (5.3, tiny) | ~0.5 MiB | 0.15% | 141 |
| 600m¹ | 520 | ~200 | ~220 | ~480 | ~1.7–2.2 | ~0.5 MiB | — | 197 |
| 500m | 488 | 130 | 230 | 575 | 1.06 | ~930 MiB | 0.24% | 210 |
| 400m | 392 | 120 | 125 | 598 | 1.14 | ~2.5 GiB | 0.26% | 261 |
| 300m | 290 | 116 | 75 | 608 | 1.36 | ~4.4 GiB | 0.30% | 353 |

¹ from the earlier N=6 probe. Baseline (uncapped heavy) = 139–158 sess/100 GB.

### What the sweep actually shows

1. **Real RAM/session ≈ the cap** (`memory.current` tracks it, because the
   compressed pool is charged against the cap). So density ≈ `100 GB / cap` — down
   to **300m → ~353 sess/100 GB, ~2.3–2.5× baseline** — *provided the session
   stays usable at that cap*.
2. **The usability knee never appeared** — cgPSI stayed **0.15–0.30%** all the way
   to 300m. But that is an artefact of the workload: after the 40 s load the tabs
   go **idle**, so their cold anon swaps out and is **never faulted back** → no
   stall. This is the *idle/background-session* case, and it packs beautifully.
3. **The win is mostly disk-tiering of idle cold anon, NOT compression.** At tight
   caps the pool ratio collapses to ~1.0–1.4:1 and disk write-back explodes
   (**~4.4 GiB** at 300m across 4 sessions). Chrome anon compresses poorly under
   load; zswap is a thin compressed cache in front of what is really plain
   disk-swap of untouched memory. zswap's value here is graceful tiering + cutting
   *some* disk I/O, not a big compression multiplier.

## Tradeoffs (honest)

- **The density win is real but conditional on sessions being idle.** cgPSI stayed
  low only because the benchmark tabs stop touching memory after load. **Active**
  sessions (scrolling, JS, interaction) would refault that cold anon → pressure and
  latency spikes. The 300m figure is an *idle-fleet* ceiling, not a universal one.
- **Compression is a minor contributor; disk-tiering does the work.** So the real
  cost is **disk I/O** (SSD wear, and a refault storm if many idle sessions wake at
  once), not CPU compression. ~4.4 GiB written for 4 sessions at 300m is a lot.
- **Chrome anon compresses poorly (~1–2:1 under load).** zswap's compression alone
  would give far less than the cap-based packing; the packing comes from tiering
  cold pages out of RAM entirely.
- **Per-container caps are mandatory.** With spare host RAM nothing reclaims; the
  density is a *packing* strategy (tight `--memory` caps + over-commit), gated by
  the active-session fraction.

## Recommendation

zswap (zstd) + per-container `--memory` caps is a **strong density lever for
idle-heavy fleets** — where most sessions sit unused most of the time, cold anon
tiers out and you pack ~2–2.5× more sessions per host at negligible stall. It is a
**host + orchestration** change (enable zswap on the agent, set workspace memory
caps), not an image change, so it fits a customer fleet without touching the
Chrome/nix build. Keep zswap (graceful, preserves the file-cache win) over zram.

But it is **not the free 2× the raw numbers suggest**: the win is disk-tiering of
idle memory, so it lives or dies on (a) the active/idle mix and (b) disk I/O
headroom. The gating experiment is **active sessions at a tight cap** — that finds
the real knee. Until that's measured, treat ~2× as an *idle-fleet* upper bound, not
a shipping number.

## Next steps

1. **Active-session sweep** — drive periodic interaction (scroll/JS touching the
   retained heap) at each cap; find the cap where cgPSI crosses ~5–10%. THIS is the
   real knee and the honest density number.
2. **Disk I/O budget** — measure write-back MiB/s and SSD wear at the target
   packing ratio; size the swap file on `/mnt/data` accordingly.
3. **CPU cost** — compression + refault CPU at the target ratio (lower priority now
   that disk-tiering, not compression, is shown to dominate).
4. Validate the **file-cache win is preserved** under zswap (the reason we chose it
   over zram): confirm `/nix/store` pages still cache once across co-located
   sessions while anon tiers out.
5. `lz4` vs `zstd` — likely marginal given compression isn't the main lever.

## Next steps

1. Cap sweep → usability knee (min viable `--memory`), then density at that cap.
2. **CPU/latency cost** at the target packing ratio (the real question, not "does
   it save RAM").
3. Compare `lz4` (faster, lower ratio) vs `zstd` for the CPU/ratio trade on this
   workload.
4. Validate the **file-cache win is preserved** under zswap (anon compresses,
   `/nix/store` file pages still shared) — the core reason we chose zswap over zram.
5. Repeat on a **near-idle** fleet (higher cold-anon fraction → likely a better ratio).

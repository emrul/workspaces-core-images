# Adopting VNC-574 (upstream startup-latency work) on container-init images

Status: branch `perf/vnc-574-adoption`, measured 2026-09-17. Context: the
KasmVNC lead reviewed our container-init / perl-bypass work and landed a
lighter-weight set of startup optimisations for stock images in
workspaces-core-images !420 plus KasmVNC branch
`feature/VNC-574_runtime_startup_latency`. This records what we took from it,
what we did not, and a like-for-like measurement.

## What upstream did vs. what we already had

| Upstream (VNC-574) | container-init images | Adopted here? |
|---|---|---|
| perl `vncserver`: lazy-load `DateTime*`; skip `vncserver -kill` when no pid file | perl is not on the boot path at all (`kasm-xvnc`, `design/kasm-xvnc-perl-bypass.md`) | n/a |
| Xvnc: `dlopen()` FFmpeg by soname before the recursive `/usr/lib` walk; defer libavformat | nothing — this is inside Xvnc | **yes**, via the KasmVNC pin |
| Unpack the outer StaticX layer of the Python helpers at image build | upload server is Go; other helpers unchanged | **yes**, Go port |
| Hide `nm-applet` / `xiccd` autostart | `cleanup.sh` already deletes these and ~20 more | n/a (superset) |
| Defer optional helpers until the XFCE desktop+panel are mapped (Python gate, 15 s cap) | socket activation: unused helpers never start | **no** — see below |

Not adopted, deliberately: the deferred-helper gate. It requires a DOCK
window, so it always runs to its 15 s timeout on images that remove
`xfce4-panel` (43 of 80 workspaces-images dockerfiles), and it adds a runtime
Python dependency. Socket activation covers the same ground without either.

## The KasmVNC updates in detail

The pin moves from `a4b74a83` (1.4.1, `feature_touch-device-support`, a
temporary test pin; before that the 1.5.0 release `17265fac`) to `4fa5e59a`
(1.5.1, `feature/VNC-574_runtime_startup_latency`). That branch is KasmVNC
`master` at `e793d58a` plus two commits:

**`4fa5e59a` — Defer FFmpeg demuxing libraries until first use**
(`common/rfb/ffmpeg.{cxx,h}`). This is the one that matters to us, because
it is inside `Xvnc` and therefore inside the ~250 ms floor that
`design/kasm-xvnc-perl-bypass.md` wrote off as "unreachable without modifying
Xvnc".

- Before: the `FFmpeg` singleton constructor loaded four libraries
  (libavformat, libavutil, libswscale, libavcodec), and for *each* one ran a
  `std::filesystem::recursive_directory_iterator` over `/usr/lib` (then
  `/usr/lib64`) comparing every filename to the soname, `dlopen()`ing the
  first match. Four full recursive walks of `/usr/lib` on every Xvnc start —
  cheap on a warm dentry cache, expensive on a cold one or a large image.
- After: `dlopen("libavutil.so.N", RTLD_LAZY)` by soname first, letting the
  dynamic loader use `ld.so.cache`; the directory walk survives only as a
  compatibility fallback. libavformat (and its dependency closure) is no
  longer loaded at startup at all: it is only needed for file-backed
  benchmark input, so it moves behind `ensureFormat()` / `std::call_once` on
  the five demux entry points. `avcodec_find_decoder` and
  `avcodec_parameters_to_context` are now resolved from libavcodec, where
  they actually live, rather than via libavformat's handle.
- No CLI, config or protocol change.

**`53e05a7d` — Load Perl timezone modules only when needed**
(`unix/vncserver`). Drops top-level `use DateTime; use DateTime::TimeZone;`
in favour of `require` inside the two timezone-option callbacks. Saves perl
module load time on every `vncserver` invocation. **No effect on
container-init images**: `kasm-xvnc` execs Xvnc directly and the minimal
images remove perl altogether (`INCLUDE_PERL=0`). It only helps the bash
fallback path and anyone running the standalone CLI.

Also picked up by moving to a 1.5.1 master-based build: upstream's VNC-546
artifact renaming (`kasmvncserver_<distro>_<codename>_…`; the old
codename-only names 403), which is why the installer had to come across as a
whole rather than as a two-line pin change.

Compatibility check for the perl bypass: `git diff 17265fac..4fa5e59a --
unix/vncserver unix/kasmvnc_defaults.yaml` is only the six-line lazy-load
change above. The argv the wrapper would generate is therefore identical to
1.5.0's, and `buildXvncArgs` needs no re-capture for this bump.

## Changes on this branch

- `install_kasm_vnc.sh`: upstream's version (VNC-546 artifact naming with
  legacy fallback; pin `4fa5e59a`, 1.5.1) plus our baked-TLS-cert block.
  `unix/vncserver` argv construction and `kasmvnc_defaults.yaml` are unchanged
  between 1.5.0 and this build, so `kasm-xvnc`'s baked argv needs no
  re-capture. **This replaces the temporary `feature_touch-device-support`
  pin; touch support is not in this build.** Re-pin once VNC-574 merges to
  KasmVNC master.
- `src/common/kasm-go/cmd/kasm-unpack-staticx`: Go port of upstream's
  `unpack_staticx.py`. Same CLI name, layout (`/opt/kasm-unpacked/<name>/`)
  and wrapper text, and the four installer hooks are upstream's lines
  verbatim, so the eventual `kasm/develop` merge should be conflict-free.
  Verified **byte-identical** output against the Python original on all four
  real helpers. Build-time only; `cleanup.sh` removes it.
  - Applies to gamepad, printer, smartcard, audio-input. Not upload (ours is
    Go). Webcam (115 MB) and recorder are also StaticX and are untouched by
    upstream too — candidates for later.
  - StaticX archives are xz with a **BCJ-x86 + LZMA2** filter chain. Decoders
    limited to bare LZMA2 (e.g. `ulikunitz/xz`) pass synthetic tests and fail
    on every real helper; we vendor `xi2/xz` and pin the chain with a fixture.
    arm64 helpers were not available to test: an unsupported filter fails the
    image build loudly rather than shipping a broken helper.

## Measurement

Upstream's methodology: fresh container per trial, `--cpus 2 --memory 4g`,
warm page cache, 20 trials, median time from container start to "XFCE
desktop and panel mapped + X responsive" (same predicate as upstream's
`wait_for_desktop.py`). We add time-to-first-listen (KasmVNC websocket port).
Variants interleaved round-robin; 2 discarded warm-ups each. Host: linbox
(20 cores, 125 GiB, background load avg ~5) — faster than upstream's OCI VM,
so compare ratios, not absolutes. Harness + raw data:
`design/data/vnc-574-bench/`.

| Variant | Listen, median s | Desktop, median s [min–max] |
|---|---|---|
| stock `core-ubuntu-noble:develop` | 1.584 | 12.249 [10.24–13.26] |
| stock + VNC-574 (`-private:feature_VNC-574…`) | 1.078 | 4.009 [3.66–4.55] |
| ours, full core @ `kasm-nix` HEAD | 0.467 | 4.299 [3.90–5.62] |
| **ours, full core @ this branch** | **0.452** | **2.804 [2.52–3.40]** |
| ours, published minimal `kasm-core-ubuntu:nix` (pre-change) | 0.444 | 4.490 [3.98–4.80] |

Reading it:

- Upstream's claim reproduces: stock improves 67 % here (they reported 57.6 %
  on slower hardware).
- Before this branch, container-init was ~2.3x faster to first listen but
  **no faster to desktop** than fixed stock (4.30 vs 4.01 s). Our earlier
  conclusion that helper launch "does not block" was true for listen time
  only; we had never measured desktop time under a CPU limit.
- The reason: `printer` and `smartcard` are not socket-activated in our unit
  set — Xvnc owns `/tmp/printer` and `/tmp/smartcard` (`-UnixRelay`), so the
  helpers are relay *clients* and start eagerly. Each was decompressing a
  ~20 MB xz bundle on a 2-CPU budget during XFCE startup (helper start
  1.30 s → 0.55 s once unpacked).
- With the unpack + KasmVNC bump: 2.80 s, 35 % better than our baseline and
  30 % better than stock + VNC-574, while keeping the listen-time lead.
  Attribution between the two changes was not isolated; listen time barely
  moved (0.467 → 0.452), which suggests the desktop gain is mostly the unpack
  and the FFmpeg fix is small on this host (warm cache, fast disk — it should
  matter more cold).

## Follow-ups

- Printer/smartcard still extract their inner PyInstaller archive at boot.
  Starting them lazily (e.g. on first relay connection) would remove the last
  eager Python from the desktop path.
- Unpack webcam and recorder.
- Cold-cache runs (needs `drop_caches` on the bench host) and an arm64 build.
- Rebuild the published minimal/nix images from this branch and re-measure.

# Known issues

Tracked, understood problems in the Nix workspace images that are NOT yet fixed
in the shipped images — with the diagnosis and the intended fix, so we don't
re-investigate them from scratch. Each entry: symptom → root cause (evidence) →
why it's not fixed yet → the fix. Mostly surfaced by the app-assurance testbench
(`kasm-nix-testbench`).

---

## 1. Steam: ~55 s blank screen on first launch (client self-download)

**Symptom.** Launching the Steam workspace shows a blank desktop for ~100 s
before the sign-in window appears. It reads as "broken" and will generate
support tickets. Every *fresh* session hits it, not just the first ever (see
"why not persistence").

**Root cause — it is NOT slow CEF; it's Steam downloading its own client.**
Timeline captured on `.140` (fresh profile, sign-in window at +71 s):

| Phase | Duration | Note |
|-------|----------|------|
| Download client (482 MB) | 34 s | from `client-update.steamstatic.com` |
| Extract package | 21 s | LZMA `.vz` archives |
| Restart + steamwebhelper → window | ~16 s | CEF itself ≈ 6 s |

nixpkgs' `steam` ships only the **bootstrap** (`steam.sh` + `steam-run` FHS),
not the ~482 MB client payload (`ubuntu12_32/steam`, `steamui`, `tenfoot`,
`resources`). On a fresh profile Steam reports `installed version 0`, then pulls
and extracts the whole client before it can draw anything. steamwebhelper (CEF)
itself starts in ~6 s once the client is present — as fast as our Chrome / VS
Code images. So the fix is to remove the download, not to speed up CEF.

**Why persistence is not the answer (for shipping).** A persistent profile
(`persistent_profile_path`) would make the download a one-time cost per user,
but profile persistence is a per-deployment / per-customer choice — we can't
enable it as a default in the shipped image or registry entry. It also wouldn't
help brand-new users or ephemeral sessions.

**The fix (#2): bake the current client into the image at build — the Chrome
pattern.** We already do exactly this for Chrome and Discord (fetch the current
artifact at build, pin it by hash, refresh on a schedule). Steam is the same
model, just with more parts:

- Chrome = one `.deb`, fetched by URL, `version`+`src` overridden from `pin.json`.
- Steam client = a **VDF manifest** at
  `https://client-update.steamstatic.com/steam_client_ubuntu12` listing a
  `version` plus ~8-10 packages, each with a compressed `zipvz` download and a
  `sha2vz` hash. It is fully machine-readable and pinnable — no need to *run*
  Steam at build (my earlier "Steam won't bootstrap in the nix build" worry was
  aimed at the wrong approach: we fetch+stage the packages, we don't execute
  Steam).

  Sketch:
  1. Discoverer (in `bin/nix-kasm-update`): fetch the manifest, read `version`
     and each package's `zipvz` + `sha2vz`; write `pkgs/steam-client/pin.json`.
  2. Overlay pkg: `fetchurl` each `.vz` (pinned by `sha2vz`), stage them into
     the layout Steam's bootstrap expects — `~/.local/share/Steam/package/` plus
     a written `steam_client_ubuntu12.installed` manifest — so on first launch
     Steam verifies (hashes match) and skips the download. Pre-extracting the
     `.vz` (removing the ~21 s extract too) is a further option.
  3. Seed that tree into `$HOME/kasm-default-profile` in the steam finish build.
  4. Manifest cadence `twice-daily` (same schedule as chrome/discord) so the
     baked client stays current and Steam only ever fetches a tiny delta.

  Result: first launch drops from ~103 s to ~15-20 s (CEF + a delta check).

**Tradeoffs / open questions.**
- ~500 MB image bloat for the baked client (per the steam image only).
- Must rebuild on a frequent cadence or the baked client goes stale and Steam
  re-downloads the delta (small, but grows with staleness).
- The `.vz` format is Valve's LZMA container; staging vs pre-extracting needs a
  small unpacker (`vzd`/`lzma`) — confirm the exact on-disk layout Steam's
  verify accepts before committing to pre-extract.

**Interim mitigation (shipped separately).** A lightweight "Steam is starting…"
splash (`src/ubuntu/install/nix/steam/launch`, zenity pulse that auto-closes
when Steam's window appears) so the blank period reads as progress, not a hang.
It does not make Steam faster — it only removes the "looks broken" perception
until #2 lands.

**Evidence / how to reproduce.** Run the steam image with
`--security-opt apparmor=unconfined --security-opt seccomp=<bwrap profile>
--gpus all`, then read `~/.local/share/Steam/logs/console-linux.txt` — the
`Downloading Update` → `Extracting package` → `Update complete, launching…`
sequence is the ~55 s. (testbench catch, 2026-07-17.)

# Trace Labs OSINT — a Nix-pipeline workspace image

Status: **draft for review, rev 1**. Owner: emrul. Requested 2026-07-19.

## 1. Goal

Deliver a Trace Labs OSINT desktop as a single Kasm workspace image, built
on our Nix pipeline rather than the upstream imperative installer. Trace
Labs is the OSINT CTF org (search-party CTF, missing-persons); their
distributable is a full VM, historically Kali-based. Kasm's previous port
(`kasmtech/workspaces-images` `src/ubuntu/install/tracelabs`) tracked the
Kali era. Trace Labs has since rebased onto **Debian 13** with a *focused
OSINT toolset* — `scripts/tlosint-tools.sh` in `tracelabs/tlosint-vm` — and
dropped the Kali kitchen-sink. We follow the new, focused set.

The upstream `tlosint-tools.sh` is ~980 lines of `apt` + `pipx` +
`go install` + `rustup`/`cargo`, wrapped in self-heal loops
(`apt_self_heal`, `ensure_shodan_available`, `ensure_rust_cargo_available`),
four-shell PATH persistence, and a runtime "OSINT Updater" that re-runs the
whole thing. That machinery exists *because the imperative install is
flaky*. Moving to a Nix profile pins the whole toolset to one nixpkgs
revision, puts every tool on PATH by construction, updates atomically on a
ref bump, and rides the update/eval-gate/testbench cadence we already run.
The "unpick and keep up to date" cost is a one-time packaging investment
that then disappears into existing machinery.

## 2. Scope decisions (settled with the requester 2026-07-19)

- **Drop Docker + docker-compose + Owlculus.** Nested Docker inside a Kasm
  workspace is a non-starter by default, and Owlculus is a web-app stack,
  not a desktop tool. Document it as an optional external add-on; not in v1.
- **Follow the new Debian-13 focused OSINT set, not the Kali arsenal.** The
  old port's `kali-tools-top10`, autopsy, hydra, fern-wifi, ophcrack, etc.
  are pentest tooling Trace Labs itself moved away from. Excluding them
  gives a much smaller closure.
- **Standalone image, NOT in the fat store.** The fat store is one shared
  partitioned `/nix` that every fat-store desktop mounts and picks a single
  app from via the launch form. Trace Labs is the opposite shape — a whole
  desktop of tools present together — and folding its closure into the
  shared store would bloat every other fat-store desktop. It is its own
  image: a nix-ubuntu core base (full XFCE + KasmVNC already) + a
  `tracelabs` Nix profile + desktop wiring, published under its own name.
  Base variant discussed in §4.5.
- **Package the 4 nixpkgs-missing tools properly in the overlay** (not a
  thin imperative fallback layer). A temporary imperative layer reintroduces
  exactly the flakiness we are escaping. GPLv3 is acceptable and we will
  publish our build/package scripts, so custom derivations are unencumbered.

## 3. Tool inventory → delivery mechanism

Verified against our pinned `nixos-26.05` (and a few `nixos-unstable` for
fast-movers) on the .140 Nix host, 2026-07-19.

**In nixpkgs — ship via the `tracelabs` profile (the bulk):**
`sherlock`, `sn0int`, `theharvester`, `recon-ng`, `maltego`,
`translate-shell` (`trans`), `exiftool`, `steghide`, `stegseek`, `tor`,
`tor-browser` (replaces `torbrowser-launcher`), `brave`, `firefox-esr`,
`chromium`, `python3Packages.shodan`. Plus adjacent OSINT tooling the VM
installs piecemeal or not at all, all present in nixpkgs and worth
including: `maigret`, `holehe`, `socialscan`, `photon`, `dnsrecon`,
`dnstwist`, `subfinder`, `amass`, `mat2`, `outguess`, `zsteg`, `whatweb`,
`wafw00f`, `nmap`, `ffuf`, `gobuster`.

**Not in nixpkgs — package in `bin/nix-kasm-overlay` (§5):**
`spiderfoot`, `phoneinfoga`, `sublist3r`, `metagoofil`. Three Python apps
+ one Go binary. `stegosuite` is also absent but upstream already treats it
as optional — skip unless asked.

**Keep as wiring files, no Nix needed (§6):** Firefox hardening
`policies.json` + OSINT bookmarks; the Brave managed-policy that
force-installs the Forensic-OSINT screenshot extension
(`jojaomahhndmeienhjihojidkddkahcn`); desktop icons; the participant-guide
PDF shortcut.

**Cut / obviated by Nix:** the OSINT-Updater desktop launcher (update =
rebuild on a newer ref), all `ensure_*`/`apt_self_heal`/PATH-persistence
machinery, rustup/GOPATH/pipx bootstrapping, `torbrowser-launcher`, Docker,
Owlculus.

## 4. Build architecture

### 4.1 A profile in the same store build

`tracelabs` becomes a section in `bin/nix-profiles.toml`, built into the
same partitioned store as every other profile. It differs from existing
profiles in two ways: it is a *multi-tool desktop* (many `pkgs`, not one
launchable app), and it is **excluded from the fat store** (§4.3).

### 4.2 Layer reuse with the apps we already ship (answering requester Q3)

Decompose "reuse existing app image layers":

1. **No rebuild of shared apps** — unconditional today. Store paths are
   content-addressed; the staging volume is warm. A `tracelabs` profile
   including `firefox`/`chromium`/`tor-browser`/`brave` realizes them *from
   cache*. No extra build time.
2. **No extra maintenance** — unconditional. `tracelabs` pins the same
   ref/overlay, so those apps are the *same derivations* as their
   standalone profiles; one ref bump moves both.
3. **Byte-identical layer sharing on the registry** — needs a deliberate
   step. The partitioner (`bin/build-nix-store-volume` §§6–7) only
   deduplicates paths that live in `[base]` or a declared `[layers.*]`
   entry; everything else is copied into each profile's *delta*. Today
   `firefox`'s unique closure sits entirely in `profile-firefox`, so a
   naive `tracelabs` would **duplicate** it into `profile-tracelabs`. Fix:
   promote the heavy overlapping closures into declared `[layers.*]`
   entries — the browsers (each ~400 MB), and a JVM layer for `maltego`.
   Then the standalone app image and the tracelabs image both subtract that
   layer from their deltas and reference the *same blob by digest*. This is
   exactly what `[layers.electron]`/`[layers.qt6]` already do; the
   `[promote] threshold_percent` analyzer flags candidates automatically.

   Scope the promotion to heavy closures only. The 15+ small tools
   (`sherlock`, `holehe`, `dnstwist`, the Python CLIs) are a few MB each —
   duplicating them into the delta is cheaper than the layer-count and
   coordination overhead of declaring a layer per tool.

### 4.3 Fat-store exclusion

The fat-store assembly (`bin/nix-crane-assemble`, the `fat_args` glob over
`profile-*`) currently includes every profile's delta. Add an exclude for
`profile-tracelabs` so the fat-store mountable image does not carry Trace
Labs' unique closure. The promoted shared browser/JVM layers remain in the
fat store — those apps are fat-store apps independently — so only the
`tracelabs` delta (the 4 overlay tools + the OSINT metapackage bundle +
wiring) is withheld. Mechanically: a `fat_exclude` list (default
`tracelabs`) filtered out of the `profile-*` loop; keep it data-driven so
future desktop-style profiles can opt out the same way.

### 4.4 Standalone image assembly

The `tracelabs` per-app image is assembled by the existing per-app path:
base + shared `[layers.*]` it uses + `profile-tracelabs` delta + a wiring
layer + ENV. No new assembler mode is required beyond the fat-store exclude
and the `[layers.*]` promotions. Published under its own name (proposed
`tracelabs-osint`), tagged like the rest of the catalog.

### 4.5 Base variant — independent of Trace Labs' Debian 13

Trace Labs' upstream VM is Debian 13 **because their installer is
`apt`/`pipx`/`go`/`cargo`** — their tools bind to the host libc and Debian's
package set, so their distro choice is a consequence of the install method.
Our tools come from nixpkgs: each carries its own closure (its own glibc,
its own deps) and links against nothing from the host OS. A nixpkgs
`sherlock`/`spiderfoot`/`tor-browser` behaves identically on Noble,
Resolute, Alpine or Fedora. **There is no compatibility reason to match
Debian 13** — we never touch Debian's packages. The base is chosen on our
own merits.

Recommendation: **Resolute** (Ubuntu 26.04, the multi-store variant where
even the Kasm services — KasmVNC, profile-sync, audio-input, recorder,
webcam, gamepad — are Nix stores unioned at boot by `nix-compose`;
`dockerfile-nix-ubuntu-resolute`). For a fully-Nix OSINT image it is the
most consistent choice — services and tools are one Nix-delivered surface —
and 26.04 sits next to our `nixos-26.05` pin (closer glibc). The only reason
to fall back to **Noble** (24.04, Kasm services from distro packages) is
maturity: Resolute is the newer path and less battle-tested. Decision left
open (§11) pending the requester's confidence in Resolute; the profile and
overlay work is identical either way, so this does not block phase 1.

## 5. The four overlay derivations

Home: `bin/nix-kasm-overlay/pkgs/<tool>/package.nix`, wired in `overlay.nix`
(same pattern as the existing `profile_sync`/`kasmvnc` packages), so they
inherit the overlay's `--override-input` nixpkgs pin and the eval-gate.

- **`sublist3r`** — Python (`buildPythonApplication`, pinned upstream rev,
  deps in nixpkgs: `requests`, `dnspython`, `argparse`).
- **`metagoofil`** — Python; small, `googlesearch`/`requests` deps.
- **`spiderfoot`** — Python, the heaviest. Upstream pins `lxml>=4.9,<5`;
  the VM script hacks that cap out at build time for Python 3.13. In Nix we
  take `lxml` from nixpkgs and relax the constraint in the derivation (no
  runtime pip). Ships a `spiderfoot`/`sf.py` launcher; the web UI binds
  `127.0.0.1:5001` (matches the Firefox bookmark).
- **`phoneinfoga`** — Go (`buildGoModule`, vendored modhash). The only
  non-Python of the four.

Each gets a smoke test in the profile (the tool answers `--help`/`version`),
validated by kasm-nix-testbench (§8).

## 6. Desktop wiring

Distro-agnostic files baked into the image's wiring layer (not Nix):

- **Firefox** enterprise `policies.json` — telemetry off, strict tracking
  protection, resistFingerprinting, sanitize-on-shutdown, geo/mic/camera
  blocked, and the OSINT bookmarks toolbar (Shodan, Censys, crt.sh,
  urlscan, VirusTotal, Wayback, HIBP, GreyNoise, OSINT Framework, Trace
  Labs CTF, local SpiderFoot). Lifted from the upstream script.
- **Brave** managed policy force-installing the Forensic-OSINT full-page
  screenshot extension. Brave itself comes from the `brave` layer.
- **Desktop**: OSINT tool icons, wallpaper, the Trace Labs
  participant-guide PDF shortcut. Sourced from `tlosint-vm`'s
  `kali-config/.../includes.chroot` equivalents (Debian 13 branch).

No in-container updater, no `pkexec` desktop entry — updates come from the
pipeline.

## 7. Registry integration

New entry in `kasm-nix-registry`, flagged as a **full desktop** rather than
a single-app launch (no `/tmp/launch_selections.json` app pick). Needs:

- **seccomp `run_config`** — TraceLabs bundles multiple Chromium-family
  browsers (chromium, brave) whose sandbox needs the clone/unshare syscall
  set. The per-app seccomp profile must be the *union* of the browser
  requirements, not the default-desktop profile. (See the
  container-init/Chrome sandbox notes — bwrap/seccomp is a known launch
  gotcha for Nix Chromium apps.)
- **GPU** — browsers benefit from `nix-gpu-run`; the standalone image
  carries the `[gpu]` layer like other browser apps, degrading to software
  rendering when no GPU is allocated.
- Pull creds / unsigned-registry conventions as per the existing registry.

## 8. Update & assurance model

Replaces the imperative "OSINT Updater":

- **Update** = bump the profile's ref in `nix-profiles.toml` (or let the
  twice-daily updater move the overlay/fast-cadence pins), rebuild. The
  eval-gate keeps a broken tool from shipping.
- **Validation** = kasm-nix-testbench launches the workspace, exercises each
  tool (the §5 smoke checks + browser launch + policy application), and
  screenshot-baselines the desktop. This is the analogue of the upstream
  script's built-in `validator()` — but external, reproducible, and gating.
- **CVE posture** — the image is scanned by the existing `scan-nix` L3 path
  and appears on the security page like any other catalog image; the OSINT
  tools' closures are in the SBOM.

## 9. Licensing / publishing

GPLv3 is acceptable to the requester and we will publish the build/package
scripts. The overlay derivations (§5) and this profile definition are
publishable; nothing here embeds secrets or proprietary bits. Trace Labs
branding assets (participant guide, icons) ship under their existing terms —
confirm redistribution is within Trace Labs' license before publishing the
image publicly (their VM is openly distributed, so this is expected to be
fine; flag for a quick check).

## 10. Phasing

- **Phase 1** — the four overlay derivations + the `tracelabs` profile with
  the *nixpkgs-available* tools only; standalone image; fat-store exclude;
  basic desktop wiring. Validate every tool launches. No layer promotion
  yet (accept per-image duplication of the browser closures).
- **Phase 2** — promote the heavy shared closures to `[layers.*]` (§4.2.3)
  and confirm byte-identical dedup with the standalone browser images on the
  registry (skopeo digest compare, same method as the fat↔app dedup check).
- **Phase 3** — registry entry + seccomp/GPU run_config + testbench
  baselines; publish.

## 11. Open questions

- Base variant: **Resolute** recommended (§4.5) — confirm, or fall back to
  Noble if Resolute isn't yet trusted for a shipped image.
- Image/profile name: `tracelabs-osint` proposed. Confirm.
- Which nixpkgs ref for the fast-moving browsers in this profile — follow
  the catalog's `nixos-unstable` browser pins, or pin TraceLabs' browsers
  to `nixos-26.05` for stability? (OSINT work values reproducibility;
  leaning 26.05 with the self-hosted Chrome overlay excluded.)
- Do we want the adjacent-tool superset (§3, maigret/holehe/amass/…) in v1,
  or match the upstream script's exact list first and grow later?
- Trace Labs branding redistribution check (§9).

# Trace Labs OSINT — a Nix-pipeline workspace image

Status: **draft for review, rev 2**. Owner: emrul. Requested 2026-07-19.

Rev 2 closes an external review (2026-07-19, 8 findings, all verified
against the code/nixpkgs/upstream): corrects the product definition (the
VM does not run the optional tools script), fixes change-gating
(reverse-dependency selection), replaces the fat-store store-delta exclude
with a declarative `fat_store=false` applied at every construction point,
specifies the full-desktop startup/wiring contract, drops Maltego (unfree
binary) and declares amd64-only for v1 (tor-browser is x86_64/i686), and
corrects the layer-dedup claims (same-ref requirement; 80% heuristic won't
flag a 2-profile browser; "no rebuild" is warm-cache-conditional).

## 1. Goal

Deliver a Trace Labs OSINT desktop as a single Kasm workspace image, built
on our Nix pipeline rather than the upstream imperative installer. Trace
Labs is the OSINT CTF org (search-party CTF, missing-persons); their
distributable is a full VM, historically Kali-based, now rebased onto
**Debian 13**.

Moving to a Nix profile pins the whole toolset to one nixpkgs revision, puts
every tool on PATH by construction, updates atomically on a ref bump, and
rides the update/eval-gate/testbench cadence we already run. The upstream
tools script is ~980 lines of `apt`/`pipx`/`go`/`cargo` wrapped in self-heal
loops that exist *because the imperative install is flaky*; Nix removes the
need for all of it.

## 2. Product definition (v1 scope) — settled rev 2

**A review finding corrected a conflation in rev 1.** Two different upstream
artifacts exist, and they are NOT the same tool set:

- `scripts/tlosint-tools.sh` — an **optional** "customize your own system
  with our tools" utility. Upstream's README explicitly states it is *not*
  executed during the VM build. It is Trace Labs' blessed toolset list.
- `tlosint.yaml` — the actual **VM build recipe**. It installs Obsidian (via
  `scripts/tl/install-obsidian.sh`), a desktop environment, and the
  `overlays/tl-overlays` tree (Trace Labs vault, templates, guides,
  wallpaper, desktop config, branding), plus a `$packages` list. It does not
  reference the tools script.

**v1 = "containerized equivalent of the current Trace Labs VM experience"**,
defined as:

1. The exact `tlosint-tools.sh` inventory (Trace Labs' blessed toolset), at
   a **recorded upstream commit**.
2. The VM's high-value desktop assets: the **TL Vault / Obsidian workflow**
   (a defining part of the current VM), wallpaper, OSINT links, and the
   Firefox/Brave policies.

**Out of v1 core** (into a separately-approved *extension list*, not
shipped until asked): `theharvester`, `recon-ng`, `maltego`, and the
adjacent-tool superset (`maigret`, `holehe`, `amass`, …) — none are in the
tools script. Maltego is additionally blocked on licensing (§8).

**Deliverable: a manifest** (`design/tracelabs-manifest.tsv` or similar)
with a row per tool: `upstream-source | v1-included? | mechanism | excluded-reason`,
pinned to the matched upstream commit. This is the single source of truth
for what the image claims to be, and what the validator (§9) checks.

The tools-script inventory, mapped to delivery mechanism, verified against
`nixos-26.05` on the .140 host 2026-07-19:

- **From nixpkgs (the `tracelabs` profile):** `sherlock`, `sn0int`,
  `translate-shell` (`trans`), `exiftool`, `steghide`, `stegseek`, `tor`
  (CLI; not auto-started — §7.4), `tor-browser` (replaces
  `torbrowser-launcher`), `brave`, `firefox-esr`, `chromium`,
  `python3Packages.shodan`.
- **Overlay derivations (§5):** `spiderfoot`, `phoneinfoga`, `sublist3r`,
  `metagoofil`. `stegosuite` is absent from nixpkgs and upstream already
  treats it as optional — skip unless asked.
- **Obsidian:** already a catalog profile (`[profiles.obsidian]`) — reuse.
- **Wiring, not Nix (§7):** Firefox policy + OSINT bookmarks, Brave managed
  policy + forced extension (§9 caveat), TL Vault seed, wallpaper, icons.
- **Cut / obviated:** the OSINT-Updater launcher (update = rebuild),
  `ensure_*`/`apt_self_heal`/PATH machinery, rustup/GOPATH/pipx bootstrap,
  `torbrowser-launcher`, Docker, Owlculus (nested Docker is a non-starter in
  Kasm), the Kali arsenal from the old port.

## 3. Build architecture

### 3.1 A profile in the same store build, excluded from the fat store

`tracelabs` is a section in `bin/nix-profiles.toml`, built into the same
partitioned store as every other profile (so its overlapping closures can
share layers — §3.3), but it is a *multi-tool desktop*, not a single-app
launch, and it is **excluded from the fat store** because folding a whole
OSINT desktop into the shared store would bloat every other fat-store
desktop.

### 3.2 Fat-store exclusion — declarative, applied everywhere (rev 2 fix)

Rev 1 proposed skipping `profile-tracelabs` in the crane store-delta glob.
**A review finding showed that is incomplete**: the metadata layer and
`_meta.json` are generated from *every* selected profile
(`bin/build-nix-store-volume` `copy_meta_profile` loop ~808), so the fat
store would still advertise a `tracelabs` profile whose closure is absent;
and all named `[layers.*]` are placed in the fat store unconditionally
(`bin/nix-crane-assemble:125`), so promoting a Maltego JVM layer would bloat
fat even though no fat-store profile uses it.

Replace with a declarative profile property:

```toml
[profiles.tracelabs]
fat_store = false
```

Applied at **every** fat-store construction point:

- fat-store **store deltas** (`nix-crane-assemble` `profile-*` glob);
- fat-store **metadata + `_meta.json`** (`copy_meta_profile` loop and the
  `.profiles` jq in `build-nix-store-volume`) — omit `fat_store=false`
  profiles;
- fat-store **labels / provenance**;
- **shared layers in the fat store** — include a `[layers.*]` only when an
  *fat-store-included* profile uses it (so a browser layer stays, a
  TraceLabs-only JVM layer does not);
- **scan / report scope** — the fat-store SBOM must not list TraceLabs paths.

**Invariant test (must land with the feature):** `tracelabs` is absent from
fat-store store files, metadata, `_meta.json`, and the fat-store SBOM; the
standalone `tracelabs-osint` image contains its closure and activates it.

### 3.3 Layer reuse with existing app images — corrected (rev 2)

Decompose the requester's "reuse existing app image layers":

1. **No rebuild of shared apps** — true **only on a warm store/cache**
   (rev 1 overstated this as unconditional). Store paths are
   content-addressed; when the staging volume already holds the app's
   closure, a `tracelabs` profile including it realizes it from cache. A cold
   store rebuilds it once like any other path.
2. **No extra maintenance** — true **iff the refs match** (see §3.4).
3. **Byte-identical registry layer sharing** — needs two things, per a
   review finding:
   - **Promotion to a declared `[layers.*]`.** The partitioner only dedups
     paths in `[base]` or a `[layers.*]`; otherwise a shared path is *copied*
     into each profile's delta. So the heavy overlapping closures (the
     browsers) must be promoted to declared layers. The `[promote]`
     auto-analyzer will **not** surface these: a browser used by its
     standalone profile + TraceLabs is in ~2 of ~48 profiles (~4%), far below
     the 80% threshold. Promotion is a deliberate manual decision.
   - **Identical resolved nixpkgs rev.** A layer dedups only if both the
     layer and both consuming profiles resolve to the *same* store paths,
     i.e. the same nixpkgs commit. **This is the contradiction rev 1
     missed:** the standalone browsers pin `nixos-unstable`
     (`[profiles.firefox]`, `[profiles.brave]`, `[profiles.chromium]` all
     `ref = nixos-unstable`); pinning TraceLabs' browsers to `26.05` for
     stability would give them different store paths and share **nothing**.

   **Resolution:** if registry dedup is the goal, TraceLabs' browser layers
   must use the **same refs as the standalone browser profiles** (unstable).
   The choice is explicit: align refs and dedup, or pin `26.05` and carry
   own copies. Recommend aligning (dedup is the point of Q3). Do **not**
   promote a Maltego JVM layer — Maltego is dropped (§8), and fat-store layer
   selection (§3.2) must be fixed first regardless.

### 3.4 Change-gating — reverse-dependency selection (rev 2 fix)

**A review finding showed rev 1's update model is broken against the current
tooling:**

- `ci-scripts/nix-changed-profiles.sh` maps an overlay change by
  **directory name** (`pkgs/<x>/*` → app `<x>`) and hardcodes the
  overlay-consuming app list as `chrome vivaldi`. A change under
  `pkgs/spiderfoot/` would select a (non-existent) `spiderfoot` profile, and
  never `tracelabs` — so the profile would not reliably rebuild/publish/scan.
- `bin/nix-kasm-update` only implements `chrome-version-api`;
  `github-releases:*` and `nix-update` deliberately `fail "not implemented
  yet"` (`:177`).

Required before implementation:

- **Reverse-dependency selection** derived from `nix-profiles.toml`: build a
  map from each `kasm-overlay#<attr>` to every profile whose `pkgs`
  reference it, so a change to `pkgs/phoneinfoga/` selects **every**
  consuming profile (here, `tracelabs`). Replace the hardcoded `chrome
  vivaldi` arm with this derived set.
- **A defined cadence + owner per custom package** (§5) — these are
  Python/Go apps with no version API; realistically a manual pin bump on a
  documented schedule, or implement `github-releases` discovery honestly.
  Do not claim automated discovery that isn't implemented.
- **A test** proving a `phoneinfoga` pin change selects and rebuilds
  `tracelabs` (not a `phoneinfoga` profile).

### 3.5 Standalone image assembly + base variant

Assembled by the existing per-app path (base + shared `[layers.*]` +
`profile-tracelabs` delta + wiring + ENV), gated on the §7 startup contract.
Published as `tracelabs-osint`.

**Base is independent of Trace Labs' Debian 13.** Their VM is Debian because
their installer is apt/pipx/go/cargo; our tools come from nixpkgs with their
own closures, so the host base is our free choice. **Recommend Resolute**
(Ubuntu 26.04 multi-store, Kasm services also from Nix). But note (rev 2, a
review finding): Nix removes libc/package-manager coupling, **not** all host
coupling — apps still depend on the host kernel, user namespaces, seccomp,
D-Bus, GPU devices, certificates, `/etc` integration and desktop services,
so they will *not* necessarily behave identically across Noble/Resolute/
Alpine/Fedora. Justify Resolute via an **early TraceLabs runtime spike**
(does the full desktop + browsers + tor-browser actually launch on Resolute
under the real seccomp profile), not glibc proximity — which is irrelevant
when the closures are isolated. `amd64-only` for v1 (§8).

## 4. The four overlay derivations

Home: `bin/nix-kasm-overlay/pkgs/<tool>/package.nix`, wired in `overlay.nix`,
inheriting the overlay's nixpkgs pin and the eval-gate. Each gets an owner
and a documented update cadence (§3.4) and a smoke test (§9).

- **`sublist3r`** — Python (`buildPythonApplication`; deps `requests`,
  `dnspython` in nixpkgs).
- **`metagoofil`** — Python; `googlesearch`/`requests`.
- **`spiderfoot`** — Python, heaviest; take `lxml` from nixpkgs and relax the
  upstream `<5` cap in the derivation (no runtime pip). Web UI binds
  `127.0.0.1:5001`.
- **`phoneinfoga`** — Go (`buildGoModule`, vendored modhash).

## 5. — (folded into §2/§4)

## 6. — (folded into §7)

## 7. Full-desktop startup & wiring contract (rev 2 — was missing)

**A review finding: the assembler skips a standalone image entirely if
`src/ubuntu/install/nix/tracelabs/custom_startup.sh` is absent
(`nix-crane-assemble:200`), and every existing `custom_startup.sh` is a
single-application respawn loop** — wrong for a desktop of tools. The wiring
layer accepts only `custom_startup.sh`, an optional `launch`, and the output
of `post-build.sh` (`:102`). So we must define:

### 7.1 custom_startup.sh — full-desktop, no auto-launch
Not a respawn loop. Starts nothing on connect (the user opens tools from the
XFCE menu / desktop entries). Honours `DISABLE_CUSTOM_STARTUP` and the
`kasm_exec` contract for `docker exec` opens, but has no single `START_COMMAND`.

### 7.2 post-build.sh — installs the desktop experience
Firefox `policies.json` + OSINT bookmarks; Brave managed policy (+ forced
extension, §9); wallpaper; desktop entries + icons for every tool; the TL
Vault seed payload staged into the default-profile skel.

### 7.3 TL Vault seeding — new users only, never clobber a returning profile
The vault seeds via the Kasm default-profile mechanism
(`$HOME/kasm-default-profile`), which is copied into a **new** user home and
left untouched for a returning (profile-synced) home. Explicit requirement:
a returning investigator's edited vault must survive; the seed must not
overwrite it. Validated in §9.

### 7.4 Service posture
- **SpiderFoot** — user-launched via desktop entry (starts the web UI on
  `127.0.0.1:5001`), *not* a supervised container-init service. State under
  the user home so it persists.
- **Tor** — no system `tor` daemon auto-started; `tor-browser` bundles and
  manages its own tor. The `tor` CLI is available for tooling but idle by
  default. If any tool needs the daemon, it gets writable state under the
  user home, not `/var/lib/tor`.

## 8. Licensing & architecture (rev 2 — corrected)

- **Drop Maltego from v1.** nixpkgs marks it `unfree = true` /
  `binaryNativeCode` (verified). Rev 1's "nothing here embeds proprietary
  bits" was **false** with Maltego included, and there is no source to
  satisfy a redistribution obligation. Revisit only with explicit licensing
  + first-run approval.
- **amd64-only for v1.** `tor-browser`'s nixpkgs platforms are
  `x86_64-linux`/`i686-linux` only (verified) — an arm64 build fails to eval
  it. Declare `platforms = ["amd64"]`; arm64 needs `tor-browser`
  optionalized by architecture.
- **Component-level redistribution/notice review required** — GPLv3 on the
  Trace Labs *repo* does not settle terms for every bundled browser, binary
  tool, the forced browser extension, or the TL documents/vault. Publishing
  our derivations is also not automatically the complete
  corresponding-source obligation for GPL packages. Do this review before
  publishing the image publicly (browsers, the extension, and TL branding
  assets specifically).

## 9. Validation contract (rev 2 — expanded)

`--help` checks catch packaging failures but not container-specific ones.
kasm-nix-testbench acceptance matrix:

- Every GUI app opens through its generated desktop entry.
- Firefox **and** Brave policies are actually loaded by the *Nix-packaged*
  browsers (about:policies / brave://policy).
- Tor Browser connects successfully under the **real Kasm seccomp profile**.
- SpiderFoot starts, answers on loopback, writes state to a persistent path.
- Shodan works with no baked API key and documents user `shodan init`.
- `nmap` has expected capabilities without extra container privileges.
- TL Vault survives profile persistence and is seeded **only** for new users
  (§7.3).
- A **no-GPU** launch succeeds (software rendering).
- **Failure of the `tracelabs` profile blocks its publication** (eval-gate /
  the future skipped-security gate).

**Forced Brave extension** (`jojaomahhndmeienhjihojidkddkahcn`) is downloaded
and auto-updated at runtime, so it is **not in the image SBOM** and is an
external code-update channel. Explicitly: accept-and-document, self-host/pin,
or drop. Recommend documenting it in the security posture; consider dropping
for v1 if the external-update channel is unacceptable.

## 10. Update & assurance model

Update = bump the profile/overlay refs, rebuild; eval-gate blocks a broken
tool; testbench (§9) gates publication. CVE posture via the existing
`scan-nix` L3 path + security page. Custom packages (§4) each have an owner
and a documented manual-bump cadence until `github-releases` discovery is
implemented (§3.4).

## 11. Phasing

- **Phase 0 (spike, gates the rest):** an early Resolute runtime spike —
  build a minimal `tracelabs` profile (a couple of tools + one browser +
  tor-browser), assemble the standalone image, and confirm the full XFCE
  desktop + browsers + tor-browser launch under the real seccomp profile and
  with no GPU. Validates §3.5's base assumption before committing.
- **Phase 1:** the four overlay derivations (§4) with owners + tests; the
  `tracelabs` profile at the recorded upstream commit (§2 inventory);
  reverse-dependency change-gating (§3.4) with the phoneinfoga test;
  `fat_store=false` (§3.2) with the invariant test; the startup/wiring
  contract (§7) incl. TL Vault seeding.
- **Phase 2:** browser-layer promotion with ref alignment (§3.3) + registry
  dedup confirmation (skopeo digest compare).
- **Phase 3:** registry entry + seccomp/GPU run_config + full §9 testbench
  baselines; component licensing review (§8); publish.

## 12. Settled choices (rev 2)

- Resolute base, validated by the Phase-0 spike.
- Image name `tracelabs-osint`.
- v1 = exact tools-script inventory + TL Vault/Obsidian workflow; adjacent
  tools + theHarvester/recon-ng in a later extension list.
- amd64-only unless tor-browser is made architecture-conditional.
- `fat_store = false` as declarative profile metadata, applied at every
  fat-store construction point.
- Same browser refs as the standalone profiles where layer reuse is desired.
- No Maltego until licensing + first-run are explicitly approved.

## 13. Open questions

- Forced Brave extension: document-and-accept vs self-host vs drop for v1?
- Browser ref: confirm aligning TraceLabs browsers to the standalone
  `nixos-unstable` pins (for dedup) is acceptable, vs `26.05` stability with
  no dedup.
- Extension list contents/priority (theHarvester, recon-ng, maigret, …).
- TL branding/vault redistribution terms (§8).

# Trace Labs OSINT — a Nix-pipeline workspace image

Status: **draft for review, rev 5 — approved for the Phase-0 spike**. Owner:
emrul. Requested 2026-07-19.

Rev 4 (external review round 3): reviewer approves starting Phase 0 once the
spike explicitly selects its required profiles. Absorbed: per-profile
`app_base` is **mandatory in the same catalog/resolution pass** for
production (a separate invocation could float `nixos-unstable` to a
different commit and lose dedup — separate invocation is Phase-0-only); the
fat-store `db.sqlite` is an allowed **registration superset** (metadata
absence is defined narrowly — store/profiles/_meta.json/SBOM, not the DB);
the **three dependency-graph sets** (`requestedRoots` / `buildProfiles` /
`assembleApps`); composite provenance is **additive** (keep root
store-path/rev labels, add `profile-set-digest`); a concrete
**candidate→test→promote** sequence; and doc fixes (drop nmap, drop the
eval-gate wording, §5 subheadings, launcher scope, concrete layer-digest
compare).

Rev 5 (review round 4 + owner steer): **Maltego included as a TraceLabs-only
`pkgs` entry** (`nixpkgs#maltego`), *not* a standalone catalog profile or a
fat-store app — Maltego has never shipped via this repo's Nix packaging (the
`kasmweb/maltego` stock image is apt-based and unrelated) and stays that way.
Corrected: `allowUnfree` is already global (`build-nix-store-volume:251`, no
per-profile work); nixpkgs marks Maltego `binaryBytecode` and ships the
**ZIP** (Kasm ships the DEB — a different artifact to clear); redistribution
turns on the EULA/partnership, not the provenance tag. Maltego added to
Phase-0 validation (JVM / first-run login / `$HOME` persistence differ from
the browsers).

Rev 3 (review round 2) established the **composition model** — TraceLabs is a
thin unique profile + wiring that declares the existing app profiles through
`requires`, so their existing delta blobs are referenced unchanged by the
standalone apps, the fat store, and the TraceLabs image (three-way reuse).
Rev 2 closed review round 1 (product definition, change-gating,
`fat_store=false`, startup contract, dropped Maltego, amd64-only).

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

**Deliberately included beyond the tools script:** **Maltego** (owner
decision 2026-07-19). It is *not* in `tlosint-tools.sh`, but Kasm partners
with Maltego and already ships `kasmweb/maltego`, so the unfree/redistribution
concern that blocked it in earlier revs is settled by that partnership (§6).
Recorded in the manifest as an intentional addition, not a tools-script tool.

**Out of v1 core** (into a separately-approved *extension list*, not
shipped until asked): `theharvester`, `recon-ng`, and the adjacent-tool
superset (`maigret`, `holehe`, `amass`, …) — none are in the tools script.

**Deliverable: a manifest** (`design/tracelabs-manifest.tsv` or similar)
with a row per tool: `upstream-source | v1-included? | mechanism | excluded-reason`,
pinned to the matched upstream commit. This is the single source of truth
for what the image claims to be, and what the validator (§7) checks.

The tools-script inventory, mapped to delivery mechanism, verified against
`nixos-26.05` on the .140 host 2026-07-19:

- **Existing catalog profiles, composed via `requires` (§3.3):**
  `chromium`, `firefox` (catalog `nixpkgs#firefox`, deviation from upstream
  `firefox-esr` recorded — §3.3), `brave`, `torbrowser`, `obsidian`. These
  are *not* listed in TraceLabs' `pkgs`; their existing delta blobs are
  referenced, giving the three-way dedup that is the whole point.
- **`nixpkgs#maltego` in TraceLabs' own `pkgs`** (owner steer 2026-07-19 —
  *not* a standalone catalog profile, *not* in the fat store). Kasm's
  existing `kasmweb/maltego` is an apt-based **stock** image, unrelated to
  this repo's Nix packaging, and Maltego has never shipped via Nix here — it
  stays that way. So Maltego is just another TraceLabs-unique tool: it lives
  in `profile-tracelabs`'s delta (already `fat_store=false`), launched from
  the desktop like SpiderFoot. No dedup applies (there is no other Nix
  Maltego to share with) and none is claimed. `allowUnfree` is already global
  (§6), so this is literally one `pkgs` entry.
- **TraceLabs `pkgs` — from nixpkgs, unique to this profile:** `sherlock`,
  `sn0int`, `translate-shell` (`trans`), `exiftool`, `steghide`, `stegseek`,
  `tor` (CLI; not auto-started — §5.4), `python3Packages.shodan`.
- **Overlay derivations (§4), also TraceLabs `pkgs`:** `spiderfoot`,
  `phoneinfoga`, `sublist3r`, `metagoofil`. `stegosuite` is absent from
  nixpkgs and upstream treats it as optional — skip unless asked.
- **Wiring, not Nix (§5):** Firefox policy + OSINT bookmarks, Brave managed
  policy + forced extension (§7 caveat), TL Vault seed, wallpaper, icons.
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
(`bin/nix-crane-assemble:125`). (Rev 2 raised a Maltego JVM layer as the
worked example here; moot now — Maltego is a TraceLabs-only `pkgs` entry in
the excluded delta, §2/§6, not a promoted layer, so it never enters the fat
store. The unconditional-`[layers.*]` point still stands for any *future*
desktop-only shared layer.)

Replace with a declarative profile property:

```toml
[profiles.tracelabs]
fat_store = false
```

Applied at **every** fat-store construction point:

- fat-store **store deltas** (`nix-crane-assemble` `profile-*` glob) — omit
  `profile-tracelabs`. Note: the required browser/obsidian deltas stay
  (they are fat-store apps in their own right); only TraceLabs' *unique*
  delta is withheld;
- fat-store **metadata + `_meta.json`** (`copy_meta_profile` loop and the
  `.profiles` jq in `build-nix-store-volume`) — omit `fat_store=false`
  profiles;
- fat-store **labels / provenance**;
- **scan / report scope** — the fat-store SBOM must not list TraceLabs'
  unique paths.

**Completeness identity — separate `apps` from `fatApps` (rev 3).** The
publisher's fat-store completeness guard compares **every** `[profiles.*]`
in the TOML against `labels.json` (`ci-scripts/nix-publish.sh:358`); an
intentionally-absent `tracelabs` would make it classify *every* fat build as
partial and refuse to publish. Split the concepts:

- `apps` — all standalone profiles built, **including** TraceLabs (stays in
  global build/provenance reports).
- `fatApps` — only profiles with `fat_store != false`.

The completeness guard compares against `fatApps`. `build-nix-store-volume`
emits both sets so the publisher can tell them apart.

**The `db.sqlite` exception (rev 4).** TraceLabs' paths must stay *realized*
in the staging store (its standalone image needs them), and the fat store
copies the whole staging `db.sqlite` into its meta layer
(`bin/build-nix-store-volume:787`). So the fat store's Nix DB **will**
register TraceLabs paths even though their store files and profile symlink
are excluded. We accept this as a **registration superset** rather than
building a filtered DB (much cheaper, and it is exactly why the scanner
already deletes `nix/var/nix/db` before syft — the phantom-path fix). "Absent
from metadata" is therefore defined narrowly.

**Invariant test (must land with the feature):** `tracelabs` is absent from
the fat store's `/store` files, `/var/nix/profiles` symlinks, `_meta.json`,
and the fat-store SBOM, and does **not** trip the completeness guard;
`db.sqlite` may register TraceLabs paths (not asserted absent there); the
standalone `tracelabs-osint` image contains its closure and activates it.

### 3.3 Composition via `requires` — the dedup model (rev 3, central)

The requester's goal, precisely: someone who already pulled `chromium` /
`firefox` / the fat store must **not** re-pull those bytes for TraceLabs —
the layers must be *referenced*, not duplicated. Rev 2's "promote the
browsers to `[layers.*]`" was the wrong mechanism. The assembler already
provides the right one: a profile's `requires` list is emitted as **discrete
`COPY profile-<r>/store /store` layers** (`bin/build-nix-store-volume:1062`),
byte-identical to the standalone app image's delta and the fat store's — so
they dedupe by blob digest across all three manifests. The configuration is:

```toml
[profiles.tracelabs]
kasm_name = "tracelabs-osint"
fat_store = false
platforms = ["amd64"]
app_base  = "resolute"            # §3.5
pkgs = [ # TraceLabs-only: the 4 overlay derivations + CLI tools not shared
         # with any other profile (sherlock, sn0int, exiftool, steghide, …)
         # + maltego (unfree; TraceLabs-only, not a standalone/fat profile — §6)
         "nixpkgs#maltego",
]
requires = [ "obsidian", "chromium", "firefox", "brave", "torbrowser" ]
```

Three-way blob reuse this produces, per shared profile (e.g. firefox):
`firefox:nix` references `profile-firefox`; `nix-store:nix` (fat) contains
`profile-firefox`; `tracelabs-osint:nix` references *that same*
`profile-firefox` blob. A client with any of the three already has the blob.

Two consequences:

- **Ref alignment is automatic, not a separate decision.** `requires`
  references the *actual existing profiles*, so TraceLabs' Firefox is
  literally the catalog `firefox` profile at its `nixos-unstable` pin — same
  store paths, same blob, guaranteed dedup. There is no separate TraceLabs
  browser pin to keep aligned (rev 2's contradiction dissolves).
- **The base may differ without breaking store-layer reuse.** The
  `profile-firefox/store` COPY layer is independent of the `FROM` base
  image; TraceLabs on Resolute and standalone Firefox on Noble share the
  identical profile-store blob — only the base-OS layers differ (§3.5).

**No `[layers.*]` promotion, no Phase-2 promotion.** The existing profile
deltas *are* the compositional units. Phase 2 becomes: **verify exact
layer-digest reuse** — `skopeo inspect --raw` each of `tracelabs-osint:nix`,
`firefox:nix`, and `nix-store:nix`, and assert the `profile-firefox`
`.layers[].digest` value is identical across all three manifests (compare the
specific layer blob digests, **not** the overall image/manifest digest).

**Product choice — Firefox ESR vs catalog Firefox.** Upstream requests
`firefox-esr`; the catalog profile is `nixpkgs#firefox`
(`[profiles.firefox]`). Reusing the catalog profile is what gives dedup with
existing Firefox users; a separate ESR profile would share nothing. **Reuse
catalog `firefox`** and record the intentional deviation in the manifest
(§2); the hardening policies (§5.2) apply to either build, so we keep the
hardened-Firefox experience without a distinct blob.

### 3.4 `requires` dependency propagation (rev 3, refined rev 4)

`requires` works at *assembly* but only among profiles that were already
selected and built (`expand_requires` restricts to built profiles,
`bin/build-nix-store-volume:957`), and it does not propagate updates upward.

**Three distinct graph sets (rev 4)** — naively expanding `selected.txt` to
the forward closure would make a scoped TraceLabs build treat Firefox,
Chromium and Obsidian as *independently requested outputs* (assembling,
scanning and reporting each as a changed app). Keep them separate:

- **`requestedRoots`** — what the user / change detector actually asked for.
- **`buildProfiles`** — the forward `requires` closure needed to *build and
  compose* those roots (browsers/obsidian for TraceLabs). Built, but not
  reported as independently-changed apps.
- **`assembleApps`** — changed roots **plus** reverse-dependents needing
  restacking.

The intended behaviours fall out of this:

- **PhoneInfoga change** → build/reassemble TraceLabs; reuse unchanged
  browser blobs.
- **Firefox change** → rebuild Firefox and reassemble **both** Firefox and
  TraceLabs (Firefox is a requested root *and* a reverse-dependency source).
- **TraceLabs wiring change** → reassemble TraceLabs only.

The five mechanisms that implement this:

1. **Expand `requires` at selection into `buildProfiles`**, before profile
   building — a build with `requestedRoots={tracelabs}` must also *build*
   `firefox`/`chromium`/`obsidian`/… (today a scoped build omits them and
   assembly warns + drops the layer, `:298`) — without adding them to
   `requestedRoots`.
2. **Reverse-dependents into `assembleApps`** — a Firefox change must
   reassemble TraceLabs. Extends the overlay reverse-map (below) to
   profile-level `requires`: `firefox → tracelabs`, not just
   `phoneinfoga → tracelabs`.
3. **Eval-gate key must fold in `requires`** — `gate_input_key` hashes only
   the profile's own `pkgs` + rev + overlay sources
   (`bin/build-nix-store-volume:419`); a new Firefox rev would leave
   TraceLabs's key unchanged and skip reassembly. Include the transitive
   required-profile inputs/store-paths in the key.
4. **Scan the union of root + required closures** — vulnix scans only the
   named profile's closure (`ci-scripts/nix-scan-l3.sh:410`), so advisory
   results for TraceLabs would omit the browsers. (Syft/Grype scan the actual
   image, so the SBOM/CVE view stays complete; only the vulnix advisory is
   incomplete.) Scan `tracelabs ∪ requires`.
5. **Composite provenance — additive, not replacing (rev 4).** Existing
   consumers expect `dev.kasm.nix.store-path` / `dev.kasm.nix.rev` to
   describe the **root** profile — keep them. **Add**
   `dev.kasm.nix.profile-set-digest=<sha256>` (over the sorted
   `profile=store-path` set: TraceLabs + each required profile), and put the
   corresponding sorted `{profile: store-path}` map in the build report, so
   the scanner/remediator can reconstruct the composed closure without losing
   root-profile compatibility.

**Overlay change-gating (carried from rev 2, still required):**
`ci-scripts/nix-changed-profiles.sh` maps an overlay change by directory
name and hardcodes the overlay-consuming set as `chrome vivaldi`; a
`pkgs/phoneinfoga/` change must select `tracelabs` via a reverse map derived
from `nix-profiles.toml`. And `bin/nix-kasm-update` only implements
`chrome-version-api` (`github-releases:*`/`nix-update` `fail`), so the 4
custom packages (§4) get an owner + documented **manual** bump cadence, not
a claimed-but-absent auto-discovery.

**Test (must land):** change Firefox and prove — (1) Firefox rebuilds,
(2) TraceLabs reassembles, (3) TraceLabs carries the new `profile-firefox`
layer digest, (4) the *same* digest appears in `firefox:nix` and
`nix-store:nix`, (5) a `phoneinfoga` pin change selects+rebuilds `tracelabs`.

### 3.5 Per-profile base selection — mandatory for production (rev 4)

The assembler has one global app base (`APP_BASE_IMAGE=localhost/nix-ubuntu:dev`,
`bin/build-nix-store-volume:37`), tagged to a single global staging ref
(`base_ref=${REG_LOCAL}/nixbase:${APP_TAG}`, `bin/nix-crane-assemble:239`),
overridable only per whole run. It cannot assemble Noble apps and a Resolute
TraceLabs in one catalog run.

**Production must use per-profile `app_base` within the same catalog build
and resolution pass** — this is settled, *not* an open choice (rev 4). The
tempting "separate production invocation" is **rejected**: a second
invocation resolves floating `nixos-unstable` at a possibly-different commit
from the catalog build, giving TraceLabs a different Firefox closure and
losing the three-way dedup that is the entire point. One build, one
resolution.

```toml
[profiles.tracelabs]
app_base = "resolute"
```

Implementation:

- a **per-base staging ref** (e.g. `nixbase-resolute:${APP_TAG}`) instead of
  the single global `nixbase:${APP_TAG}` (`nix-crane-assemble:239`);
- **base name + config digest in image provenance**;
- reassembly propagation from a **Resolute** base rebuild to **Resolute
  profiles only** (today `NIX_BASE_REBUILT` tracks only the Noble/Ubuntu app
  base);
- validation that Noble Firefox and Resolute TraceLabs share the identical
  `profile-firefox` store-layer digest (§3.4 test).

**Phase-0 exception:** a separate invocation is acceptable *for the spike
only*, **provided the required profiles are explicitly selected and pinned to
the same resolved revisions** as the catalog build (§9 Phase 0).

**Base is independent of Trace Labs' Debian 13** (their Debian is a
consequence of their apt/pipx installer; our tools carry their own closures).
But Nix removes only libc/package-manager coupling — apps still depend on the
host kernel, user namespaces, seccomp, D-Bus, GPU, certs, `/etc`, desktop
services — so Resolute is justified by the **Phase-0 runtime spike** (does the
full desktop + browsers + tor-browser launch under the real seccomp
profile?), not glibc proximity. `amd64-only` for v1 (§6).

## 4. The four overlay derivations

Home: `bin/nix-kasm-overlay/pkgs/<tool>/package.nix`, wired in `overlay.nix`,
inheriting the overlay's nixpkgs pin and the eval-gate. Each gets an owner
and a documented update cadence (§3.4) and a smoke test (§7).

- **`sublist3r`** — Python (`buildPythonApplication`; deps `requests`,
  `dnspython` in nixpkgs).
- **`metagoofil`** — Python; `googlesearch`/`requests`.
- **`spiderfoot`** — Python, heaviest; take `lxml` from nixpkgs and relax the
  upstream `<5` cap in the derivation (no runtime pip). Web UI binds
  `127.0.0.1:5001`.
- **`phoneinfoga`** — Go (`buildGoModule`, vendored modhash).

## 5. Full-desktop startup & wiring contract (rev 2 — was missing)

**A review finding: the assembler skips a standalone image entirely if
`src/ubuntu/install/nix/tracelabs/custom_startup.sh` is absent
(`nix-crane-assemble:200`), and every existing `custom_startup.sh` is a
single-application respawn loop** — wrong for a desktop of tools. The wiring
layer accepts only `custom_startup.sh`, an optional `launch`, and the output
of `post-build.sh` (`:102`). So we must define:

### 5.1 custom_startup.sh — full-desktop, no auto-launch
Not a respawn loop. Starts nothing on connect (the user opens tools from the
XFCE menu / desktop entries). Honours `DISABLE_CUSTOM_STARTUP` and the
`kasm_exec` contract for `docker exec` opens, but has no single `START_COMMAND`.

**Panel gotcha (found + fixed in the Phase-0 spike, 2026-07-20).**
`nix-activate`'s `apply_single_app_desktop()` swaps XFCE to the **no-panel**
"single application" layout whenever *exactly one profile is active* — it
counts active profiles, and TraceLabs ships as **one** active profile (its
`requires` are composed into the image, not counted active). So a multi-tool
desktop is misread as single-app and `xfce4-panel` is dropped → blank screen
(WM + xfdesktop run, but no panel/menu).

The documented toggle `NIX_SINGLE_APP_DESKTOP=0` only works if it is set
**before** `nix-activate` runs (`Before=window-manager.service`). In practice
that's unreliable: Kasm's `run_config.environment` did not inject it into the
container (it wasn't present on relaunch), and a post-boot `export` is too
late. **Actual fix: `custom_startup.sh` ensures `xfce4-panel` is running**
(it runs after the WM via `custom-startup.service`, is idempotent via
`pgrep`, and `xfce4-panel` launches fine — proven in the spike). The
`run_config.environment` toggle is kept as harmless belt-and-suspenders.
Phase-1 improvement: have `nix-activate` treat a profile that declares itself
a desktop (`requires` + a marker, or `fat_store=false` desktop profiles) as
multi-app automatically, and bake `NIX_SINGLE_APP_DESKTOP=0` into the image
ENV for such profiles so the session config is right from boot (menu/panel
started by the session, not a post-hoc launch).

**Open sub-issue: desktop/panel icons don't render** (`glycin-image-rs`
image loader fails under bwrap — the known nix+glycin/LD_LIBRARY_PATH trap).
Folders/menu entries work; only the icon glyphs are missing. Cosmetic, to
fix after the panel is confirmed usable.

### 5.2 post-build.sh — installs the desktop experience
Firefox `policies.json` + OSINT bookmarks; Brave managed policy (+ forced
extension, §7); wallpaper; the TL Vault seed payload staged into the
default-profile skel; and desktop entries + icons **only for TraceLabs-unique
CLI/web tools** (SpiderFoot, the overlay tools). The required GUI profiles
(chromium/firefox/brave/torbrowser/obsidian) already contribute their own
generated desktop entries via their profile layers — do not duplicate them.

### 5.3 TL Vault seeding — new users only, never clobber a returning profile
The vault seeds via the Kasm default-profile mechanism. Correct path (rev 3,
`src/common/kasm-go/scripts/kasm-setup:73`): the seed lives at
**`/home/kasm-default-profile`** (not `$HOME/kasm-default-profile`), so
`post-build.sh` stages the vault under
`$DESTDIR/home/kasm-default-profile/Desktop/TL-Vault`. First-use is detected
by the target user **lacking `.bashrc`**: `kasm-setup` copies the
default-profile into `$HOME` only when `[ ! -f "$KASM_OS_HOME/.bashrc" ]`, so
a returning (profile-synced) home is left untouched. The §7 persistence test
must exercise that exact mechanism (seed on first launch; edit; relaunch with
a populated home; confirm the edit survives and the seed does not overwrite).

### 5.4 Service posture
- **SpiderFoot** — user-launched via desktop entry (starts the web UI on
  `127.0.0.1:5001`), *not* a supervised container-init service. State under
  the user home so it persists.
- **Tor** — no system `tor` daemon auto-started; `tor-browser` bundles and
  manages its own tor. The `tor` CLI is available for tooling but idle by
  default. If any tool needs the daemon, it gets writable state under the
  user home, not `/var/lib/tor`.

## 6. Licensing & architecture (rev 4 — Maltego included)

- **Maltego — included as a TraceLabs-only `pkgs` entry (owner decision,
  rev 4/5).** nixpkgs 26.05 marks it `unfree = true`, `sourceProvenance =
  binaryBytecode` (verified — it's a JVM app), and ships **Maltego's Linux
  ZIP** (`Maltego.v4.11.1.linux.zip`), whereas Kasm's stock installer
  consumes the DEB — a *different artifact*. `allowUnfree` needs no new work:
  the builder already exports `NIXPKGS_ALLOW_UNFREE=1`
  (`bin/build-nix-store-volume:251`), so the profile just lists
  `nixpkgs#maltego`.
  **Redistribution basis is the licence/EULA + the Kasm–Maltego
  partnership**, *not* the source-provenance tag (provenance describes how
  it's built, it does not determine corresponding-source obligations).
  Caveats to close before publish: (a) confirm the partnership/EULA covers
  redistributing **the nixpkgs ZIP artifact specifically** (Kasm ships the
  DEB today, so this is a genuinely different artifact to clear); (b) Maltego
  CE requires an **account login on first run** — validated in §7, and it
  must not block a fresh desktop from starting. This design records the
  *basis*; it does not itself adjudicate the EULA.
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

## 7. Validation contract (rev 2 — expanded)

`--help` checks catch packaging failures but not container-specific ones.
kasm-nix-testbench acceptance matrix:

- Every GUI app opens through its generated desktop entry.
- Firefox **and** Brave policies are actually loaded by the *Nix-packaged*
  browsers (about:policies / brave://policy).
- Tor Browser connects successfully under the **real Kasm seccomp profile**.
- SpiderFoot starts, answers on loopback, writes state to a persistent path.
- Shodan works with no baked API key and documents user `shodan init`.
- TL Vault survives profile persistence and is seeded **only** for new users
  (§5.3).
- Maltego completes its first-run startup/licensing flow (account login) and
  the desktop still starts cleanly for a user who skips it.
- A **no-GPU** launch succeeds (software rendering).
- **Failure of the `tracelabs` profile is a hard publication failure** (§8) —
  it must not silently skip while the pipeline goes green.

(`nmap` is not in the v1 inventory — it lives in the §2 extension list, so it
is not a v1 acceptance check.)

**Forced Brave extension** (`jojaomahhndmeienhjihojidkddkahcn`) is downloaded
and auto-updated at runtime, so it is **not in the image SBOM** and is an
external code-update channel. Explicitly: accept-and-document, self-host/pin,
or drop. Recommend documenting it in the security posture; consider dropping
for v1 if the external-update channel is unacceptable.

## 8. Publication gating — corrected (rev 3)

Rev 2 said "testbench gates publication / eval-gate blocks broken tools."
Neither is true today (review finding, verified):

- A failed profile **install** is recorded and *skipped*, not a build
  failure (`nix-publish` records `skipped`; the build proceeds).
- `testbench` runs **after** publish, `needs:[publish]`,
  `allow_failure: true`, fire-and-forget (`.gitlab-ci.yml:590`) — it cannot
  gate the tag it runs after.

For a public TraceLabs release, the concrete order (rev 4) — the existing
SBOM/signing jobs consume the *production* publish mapping and testbench runs
*after* production publish today, so this gate must be inserted, not assumed:

```
build → scan → push CANDIDATE digest (candidate tag)
      → synchronous testbench against the candidate
      → promote the SAME manifest digest to :nix   (copy/tag, no rebuild)
      → attach/sign SBOM + final image on the promoted digest
```

- **A requested-but-failed `tracelabs` profile is a HARD publication
  failure** — not skipped (behaviour change in `nix-publish` for
  `fat_store=false` desktop profiles: a desktop that failed to build must not
  silently vanish while the pipeline goes green).
- **Testbench failure OR infrastructure failure fails closed** for TraceLabs
  (no promotion) — unlike the report-only catalog testbench.
- **Promotion copies/tags the *tested* manifest digest** — it never rebuilds
  (a rebuild could resolve differently and ship an untested artifact).
- The final publication report **maps the tested candidate digest → the
  production manifest**.
- **Other catalog images keep their current flow** — this synchronous gate is
  initially TraceLabs-specific, so we don't perturb the 40-odd single-app
  images while proving it out.

Update model: bump the profile/overlay refs, rebuild. CVE posture via the
existing `scan-nix` L3 path (scanning the composed image — the union per
§3.4.4) + security page. Custom packages (§4) each have an owner + a
documented manual-bump cadence until `github-releases` discovery is
implemented.

## 9. Phasing

- **Phase 0 (spike, gates the rest):** an early Resolute runtime spike —
  a minimal `tracelabs` profile (a couple of unique tools) that
  `requires = ["firefox","torbrowser"]`. Because forward `requires` expansion
  isn't implemented until Phase 1, **invoke the spike with all roots
  explicit** — `--profile tracelabs --profile firefox --profile torbrowser` —
  all pinned to the *same resolved revisions* as the catalog build (so the
  dedup check is meaningful). A separate `--app-base-image
  nix-ubuntu-resolute` invocation is acceptable **for the spike only** (§3.5).
  Confirm: (a) the full XFCE desktop + composed browsers + tor-browser launch
  under the real seccomp profile with no GPU, and (b) the `profile-firefox`
  layer blob digest in the spike image **equals** the standalone `firefox:nix`
  layer digest (proves composition dedup before we build anything else).
  **Include `nixpkgs#maltego` in the spike `pkgs`** and check it too — the JVM
  launch, amd64-only story, CE first-run account login, and `$HOME`
  persistence differ meaningfully from the browsers and should be proven
  before Phase 1 (also measure its closure's contribution to the standalone
  image size).
- **Phase 1:** the four overlay derivations (§4) with owners + tests; the
  full `tracelabs` profile with `requires` at the recorded upstream commit
  (§2 inventory); `requires` dependency propagation (§3.4: selection,
  reverse-dependents, eval-gate key, scan union, composite provenance) with
  the Firefox-change test; `fat_store=false` + `fatApps`/`apps` split (§3.2)
  with the invariant test; the startup/wiring contract (§5) incl. correct TL
  Vault seeding.
- **Phase 2:** per-profile `app_base` in the **same catalog/resolution pass**
  (§3.5, mandatory for production — the Phase-0 separate invocation does not
  ship); confirm exact `profile-firefox` layer-blob-digest reuse across
  `tracelabs-osint:nix`, `firefox:nix`, and `nix-store:nix` (`skopeo inspect
  --raw`, compare `.layers[].digest`). **No browser-layer promotion** —
  composition already achieves the dedup.
- **Phase 3:** registry entry + seccomp/GPU run_config + full §7 testbench
  baselines with real publication gating (§8: hard-fail on failed tracelabs
  profile, candidate→test→promote); component licensing review (§6); publish.

## 10. Settled choices (rev 4)

- **Composition via `requires`, not layer promotion** — TraceLabs is a thin
  unique profile + wiring; `requires = [obsidian, chromium, firefox, brave,
  torbrowser]` references the existing profile delta blobs unchanged.
- **Per-profile `app_base = "resolute"` in the same catalog/resolution pass
  is mandatory for production** (a separate invocation risks a different
  `nixos-unstable` commit and loses dedup); separate invocation is
  Phase-0-only. Base differs from the catalog's Noble without breaking
  store-layer reuse.
- Image name `tracelabs-osint`.
- v1 = exact tools-script inventory + TL Vault/Obsidian workflow; adjacent
  tools + theHarvester/recon-ng in a later extension list.
- amd64-only unless tor-browser is made architecture-conditional.
- `fat_store = false` declarative metadata + `fatApps`/`apps` split, applied
  at every fat-store construction point; `db.sqlite` is an allowed
  registration superset (absence asserted for store/profiles/_meta.json/SBOM,
  not the DB).
- Three graph sets — `requestedRoots` / `buildProfiles` / `assembleApps` —
  so required profiles aren't reported as independently-changed apps.
- Composite provenance is additive: keep root `store-path`/`rev`, add
  `dev.kasm.nix.profile-set-digest` + the sorted profile→store-path map.
- Reuse the catalog `firefox` profile (deviation from upstream `firefox-esr`
  recorded in the manifest) — a separate ESR profile would share nothing.
- Real publication gating: hard-fail on a failed `tracelabs` profile;
  `build → scan → candidate → synchronous testbench → promote digest →
  attach/sign`, fail-closed, TraceLabs-specific initially.
- **Maltego included as a TraceLabs-only `pkgs` entry** — `nixpkgs#maltego`
  in `profile-tracelabs`; **not** a standalone Nix app, **not** in the fat
  store (owner steer: Maltego has never shipped via this repo's Nix packaging
  and stays that way). `allowUnfree` already global — one `pkgs` line, no new
  schema. Redistribution basis = EULA + Kasm–Maltego partnership; confirm the
  nixpkgs **ZIP** artifact (not Kasm's DEB) is covered, and CE first-run login
  before publish.

## 11. Open questions

- Forced Brave extension: document-and-accept vs self-host vs drop for v1?
- Extension list contents/priority (theHarvester, recon-ng, maigret, …).
- TL branding/vault redistribution terms (§6).

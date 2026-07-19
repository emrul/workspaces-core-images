# Trace Labs OSINT — a Nix-pipeline workspace image

Status: **draft for review, rev 3**. Owner: emrul. Requested 2026-07-19.

Rev 3 (external review round 2, 8 findings, all verified against the code):
the central correction is the **composition model** — TraceLabs is a thin
unique profile plus wiring that declares the existing app profiles through
`requires`, so their *existing* delta blobs are referenced unchanged by the
standalone apps, the fat store, and the TraceLabs image (three-way blob
reuse). This replaces rev 2's browser-promotion idea entirely. Rev 3 also
specifies `requires` dependency propagation (selection, reverse-dependents,
eval-gate key, scan union, composite provenance), per-profile base selection
(Resolute for TraceLabs while the catalog stays Noble), a corrected
fat-store completeness identity (`fatApps` vs `apps`), and real publication
gating (candidate→test→promote, not the post-publish allow_failure
testbench).

Rev 2 closed review round 1 (product definition, change-gating, declarative
`fat_store=false`, full-desktop startup contract, dropped Maltego, amd64-only).

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
tools script. Maltego is additionally blocked on licensing (§6).

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
(`bin/nix-crane-assemble:125`), so promoting a Maltego JVM layer would bloat
fat even though no fat-store profile uses it.

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

**Invariant test (must land with the feature):** `tracelabs` is absent from
fat-store store files, metadata, `_meta.json`, and the fat-store SBOM, and
does **not** trip the completeness guard; the standalone `tracelabs-osint`
image contains its closure and activates it.

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
layer-digest reuse** across `tracelabs-osint:nix`, `firefox:nix`, and
`nix-store:nix` (skopeo digest compare).

**Product choice — Firefox ESR vs catalog Firefox.** Upstream requests
`firefox-esr`; the catalog profile is `nixpkgs#firefox`
(`[profiles.firefox]`). Reusing the catalog profile is what gives dedup with
existing Firefox users; a separate ESR profile would share nothing. **Reuse
catalog `firefox`** and record the intentional deviation in the manifest
(§2); the hardening policies (§5.2) apply to either build, so we keep the
hardened-Firefox experience without a distinct blob.

### 3.4 `requires` dependency propagation (rev 3)

`requires` works at *assembly* but only among profiles that were already
selected and built (`expand_requires` restricts to built profiles,
`bin/build-nix-store-volume:957`), and it does not propagate updates upward.
Five gaps must close before this composes reliably:

1. **Expand `requires` at selection**, before profile building — a build
   selecting `tracelabs` must also select `firefox`/`chromium`/`obsidian`/…
   (today a scoped build omits them and assembly warns + drops the layer,
   `:298`).
2. **Reverse-dependents on change** — a Firefox change must reassemble
   TraceLabs. This extends rev 2's overlay reverse-map (the overlay reverse-map above, kept below)
   to profile-level `requires`: `firefox → tracelabs`, not just
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
5. **Composite provenance** — stamp TraceLabs with a digest over sorted
   `profile=store-path` entries (its own + each required profile), not its
   own profile store-path alone, so provenance reflects what actually
   composes the image.

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

### 3.5 Per-profile base selection (rev 3)

The assembler has one global app base (`APP_BASE_IMAGE=localhost/nix-ubuntu:dev`,
`bin/build-nix-store-volume:37`), overridable only per whole run
(`--app-base-image`). It cannot assemble ordinary apps on Noble and
TraceLabs on Resolute in one catalog run. Options:

- **Per-profile `app_base = "resolute"`** (clean long-term) — assembly and
  change-gating map it to `localhost/nix-ubuntu-resolute:dev`, and a Resolute
  base rebuild must propagate into TraceLabs reassembly (today
  `NIX_BASE_REBUILT` only tracks the Noble/Ubuntu app base).
- Build TraceLabs in a **separate invocation/job** with
  `--app-base-image localhost/nix-ubuntu-resolute:dev`.
- **Noble for v1**, defer Resolute.

Recommend per-profile base selection as the target; for the Phase-0 spike a
separate invocation is enough to prove it out. **Base is independent of
Trace Labs' Debian 13** (their Debian is a consequence of their apt/pipx
installer; our tools carry their own closures). But Nix removes only
libc/package-manager coupling — apps still depend on host kernel, user
namespaces, seccomp, D-Bus, GPU, certs, `/etc`, desktop services — so
Resolute must be justified by the **Phase-0 runtime spike** (does the full
desktop + browsers + tor-browser launch under the real seccomp profile),
not glibc proximity. `amd64-only` for v1 (§6).

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

### 7.1 custom_startup.sh — full-desktop, no auto-launch
Not a respawn loop. Starts nothing on connect (the user opens tools from the
XFCE menu / desktop entries). Honours `DISABLE_CUSTOM_STARTUP` and the
`kasm_exec` contract for `docker exec` opens, but has no single `START_COMMAND`.

### 7.2 post-build.sh — installs the desktop experience
Firefox `policies.json` + OSINT bookmarks; Brave managed policy (+ forced
extension, §7); wallpaper; desktop entries + icons for every tool; the TL
Vault seed payload staged into the default-profile skel.

### 7.3 TL Vault seeding — new users only, never clobber a returning profile
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

### 7.4 Service posture
- **SpiderFoot** — user-launched via desktop entry (starts the web UI on
  `127.0.0.1:5001`), *not* a supervised container-init service. State under
  the user home so it persists.
- **Tor** — no system `tor` daemon auto-started; `tor-browser` bundles and
  manages its own tor. The `tor` CLI is available for tooling but idle by
  default. If any tool needs the daemon, it gets writable state under the
  user home, not `/var/lib/tor`.

## 6. Licensing & architecture (rev 2 — corrected)

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

## 7. Validation contract (rev 2 — expanded)

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
  (§5.3).
- A **no-GPU** launch succeeds (software rendering).
- **Failure of the `tracelabs` profile blocks its publication** (eval-gate /
  the future skipped-security gate).

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

For a public TraceLabs release, the contract must be concrete:

- **A requested-but-failed `tracelabs` profile is a HARD publication
  failure** — not skipped. (This is a behaviour change in `nix-publish` for
  `fat_store=false` desktop profiles: a desktop that failed to build must
  not silently vanish from the run while the pipeline goes green.)
- **candidate → test → promote**, or run the TraceLabs testbench check
  **synchronously before** its production tag is published (build+push a
  candidate tag, test it, promote to `:nix` on pass). "The future
  skipped-security gate" is not a sufficient contract for this image.

Update model: bump the profile/overlay refs, rebuild. CVE posture via the
existing `scan-nix` L3 path (scanning the composed image — the union per
§3.4.4) + security page. Custom packages (§4) each have an owner + a
documented manual-bump cadence until `github-releases` discovery is
implemented.

## 9. Phasing

- **Phase 0 (spike, gates the rest):** an early Resolute runtime spike —
  a minimal `tracelabs` profile (a couple of unique tools) that
  `requires = ["firefox","torbrowser"]`, assembled as a standalone image via
  a separate `--app-base-image nix-ubuntu-resolute` invocation (§3.5), to
  confirm: (a) the full XFCE desktop + composed browsers + tor-browser launch
  under the real seccomp profile with no GPU, and (b) the `profile-firefox`
  layer digest in the spike image **equals** the standalone `firefox:nix`
  digest (proves composition dedup before we build anything else).
- **Phase 1:** the four overlay derivations (§4) with owners + tests; the
  full `tracelabs` profile with `requires` at the recorded upstream commit
  (§2 inventory); `requires` dependency propagation (§3.4: selection,
  reverse-dependents, eval-gate key, scan union, composite provenance) with
  the Firefox-change test; `fat_store=false` + `fatApps`/`apps` split (§3.2)
  with the invariant test; the startup/wiring contract (§5) incl. correct TL
  Vault seeding.
- **Phase 2:** per-profile `app_base` selection (§3.5) if not already done in
  Phase 0; confirm exact layer-digest reuse across `tracelabs-osint:nix`,
  `firefox:nix`, and `nix-store:nix` (skopeo). **No browser-layer promotion**
  — composition already achieves the dedup.
- **Phase 3:** registry entry + seccomp/GPU run_config + full §7 testbench
  baselines with real publication gating (§8: hard-fail on failed tracelabs
  profile, candidate→test→promote); component licensing review (§6); publish.

## 10. Settled choices (rev 3)

- **Composition via `requires`, not layer promotion** — TraceLabs is a thin
  unique profile + wiring; `requires = [obsidian, chromium, firefox, brave,
  torbrowser]` references the existing profile delta blobs unchanged.
- Resolute base (per-profile `app_base`), validated by the Phase-0 spike;
  base differs from the catalog's Noble without breaking store-layer reuse.
- Image name `tracelabs-osint`.
- v1 = exact tools-script inventory + TL Vault/Obsidian workflow; adjacent
  tools + theHarvester/recon-ng in a later extension list.
- amd64-only unless tor-browser is made architecture-conditional.
- `fat_store = false` declarative metadata + `fatApps`/`apps` split, applied
  at every fat-store construction point.
- Reuse the catalog `firefox` profile (deviation from upstream `firefox-esr`
  recorded in the manifest) — a separate ESR profile would share nothing.
- Real publication gating: a failed `tracelabs` profile is a hard failure;
  candidate→test→promote (not the post-publish allow_failure testbench).
- No Maltego until licensing + first-run are explicitly approved.

## 11. Open questions

- Forced Brave extension: document-and-accept vs self-host vs drop for v1?
- Extension list contents/priority (theHarvester, recon-ng, maigret, …).
- Per-profile `app_base` now vs a separate Resolute build invocation for v1
  (both work; the former is the clean long-term answer).
- TL branding/vault redistribution terms (§6).

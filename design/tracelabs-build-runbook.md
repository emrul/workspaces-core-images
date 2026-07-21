# Trace Labs OSINT — build runbook & hard-won gotchas

Purpose: so the next agent (or human) doesn't re-derive the ~2-day debugging
odyssey. This is the operational companion to `design/tracelabs-osint-image.md`
(the design) and `design/tracelabs-vs-upstream.md` (the product diff).

**Status (2026-07-21, CI PIVOT COMPLETE):** TraceLabs is now a **first-class
catalog profile** — `[profiles.tracelabs]` lives in the MAIN `bin/nix-profiles.toml`
(`kasm_name = "tracelabs-osint"`, `fat_store = false`, `app_base = "resolute"`,
`platforms = ["amd64"]`), and the standard `kasm-nix` pipeline builds → CVE-scans
→ publishes → **attests/signs** `tracelabs-osint` end-to-end, exactly like every
other app. The forge hand-assembly + hand-push path is **retired** (kept below only
as a break-glass fallback). Verified green: pipeline 2693655030 (commit 2c1297d)
— `attested=35 no-sbom=1 failed=0`, `tracelabs-osint` signed with its CycloneDX
SBOM. The isolated spike config (`bin/nix-profiles-tracelabs-spike.toml` +
`runs/nix-portal/tracelabs-spike.sh`) is **DEPRECATED/redundant** — the main TOML
supersedes it; do not regenerate it. §§1–4 below are the SUPERSEDED single-store
Noble path (kept for history); §5+§5b describe the live Resolute shape; the
hard-won gotchas in §4/§5 still apply to the CI-built image.

**How to (re)build — the BAU CI path (default):**
Trigger a pipeline on the `kasm-nix` branch. The build job auto-derives
`RESOLUTE_APPS` from every `app_base="resolute"` profile in `bin/nix-profiles.toml`
(so `tracelabs` is picked up with no extra wiring) and passes
`RESOLUTE_BASE_IMAGE=localhost/nix-ubuntu-resolute:dev`. On a feature branch,
scope + attest it explicitly:
```
glab ci run -R kasm-technologies/labs-sandbox/kasm-nix -b kasm-nix \
  --variables-env NIX_PROFILES:tracelabs \
  --variables-env SBOM_BACKFILL:1 \
  --variables-env SKIP_FAT_SCAN:1 \
  --variables-env DISK_MIN_GB:60      # forge-only override; see the disk note below
```
Use `glab ci run --variables-env` (NOT `glab api POST .../pipeline -f
"variables[0][key]=…"` — that array form silently drops the vars). Verify with
`glab api .../pipelines/<id>/variables`. **Forge disk:** the `.gitlab-ci.yml`
default `DISK_MIN_GB=200` is the *production* pre-flight floor (provision ≥500G);
it is UNMEETABLE on the 465G physical forge (build nukes the warm cache and still
FATALs at 180G<200G) — so on forge you MUST override `DISK_MIN_GB` down (60 works;
a cold full-catalog build then runs the disk to 0–3G but completes). GC forge to
headroom first (`ci-scripts/nix-gc.sh` in the DinD; see §3 of the memory / the
DISK BUDGET note) if it's tight.

**How to hand-assemble locally (break-glass, no CI):**
Uses the MAIN TOML — no spike config, no `--config` flag needed (both
`build-nix-store-volume` and `dind-build.sh` default to `bin/nix-profiles.toml`):
1. Resolute base with jq: `ci-scripts/nix-base-build.sh` with
   `BASE_DISTROS=resolute` inside the forge DinD (see .gitlab-ci.yml `base:`
   job — mount `containers` + repo ro, pass `BASE_BUILT_SHA`). Do **NOT** set
   `NIX_STAGE_VOLUME` for the base bake: it mounts a foreign `/nix` into the
   `nixos/nix` container and dangles its `/etc/nix/nix.conf` symlink → the bake
   fails with `/etc/nix/nix.conf: No such file or directory`.
2. Build+assemble via `dind-build.sh` with the resolute envs (no `NIX_CONFIG_FILE`
   → main TOML):
   ```
   RESOLUTE_APPS=tracelabs \
   RESOLUTE_BASE_IMAGE=localhost/nix-ubuntu-resolute:dev \
   EMIT_APPS=1 \
   bash runs/nix-portal/dind-build.sh
   # dev shortcut — narrow the build (partial fat store) to just tracelabs' closure:
   #   SCOPED_BUILD=1 PROFILES=tracelabs,obsidian,chromium,firefox,brave,torbrowser
   ```
   Output: `localhost/nix-resolute-tracelabs:dev`. To re-run ONLY the assembly
   after a code fix (skip the nix build), invoke `bin/nix-crane-assemble` directly
   with `STAGING=<nix-build-stage-amd64 vol>/.build/layers` +
   `RESOLUTE_APPS=tracelabs RESOLUTE_BASE_IMAGE=…` — the partitions + blobs
   persist in the stage volume.
3. Push `:nix` with the throwaway-token recipe (§3), pull on `.140`. (Prefer the
   CI path — it publishes AND attests; a hand-push produces no attestation.)

## 0. The architecture decision (owner, 2026-07-20)

1. **Single-APP images stay single-app** — minimal lateral-security footprint,
   no desktop. Don't touch them.
2. **Multi-APP (desktop) images should use the DESKTOP base** (Resolute
   multi-store). TraceLabs is multi-app.
3. Since we already build a nix store for TraceLabs, mounting it as
   `/nix-stores/tracelabs` under Resolute (native multi-store) should be cheap
   (§5).

What's built *today* is the single-store Noble variant — a working stepping
stone and the thing this runbook documents. §5 is the proposed pivot.

## 1. Why Noble, not Resolute, for a *per-app-assembled* image

The per-app assembler (`bin/build-nix-store-volume` + `bin/nix-crane-assemble`)
bakes `/nix/store -> /store` — the **single-store** convention. The Resolute
base is **multi-store**: at boot `nix-compose` unions `/nix-stores/*` into
`/nix`. Building a per-app image on Resolute makes the two collide — `/nix/store`
becomes a **dangling symlink into a random store dir** (observed:
`/nix-stores/services/store/…-libpsl-…`), the profile paths never land in the
composed store, and **no tools resolve** even though the desktop renders and
the binaries physically exist at `/store/…-sherlock`.

Verify a base is single-store before assembling on it:
```
podman run --rm --entrypoint sh <base> -c \
  'ls /etc/container-init/units/ | grep -i compose || echo NO-COMPOSE; ls /nix-stores 2>/dev/null || echo NONE'
```
Noble (`localhost/nix-ubuntu:dev`): `NO-COMPOSE` / `NONE` → good.
Resolute: has the `nix-compose` unit + `/nix-stores` → **do not** per-app-assemble on it.

## 2. Build steps (single-store Noble) — SUPERSEDED

> **Historical.** This whole section is the original single-store Noble
> stepping-stone and its isolated spike TOML. TraceLabs is now the Resolute
> multi-store profile in the MAIN `bin/nix-profiles.toml`, built via CI (see the
> header). Do NOT use the spike TOML — it is deprecated. Kept only to explain the
> old shape and why the pivot happened (§5).

Everything runs on the **forge** (`ubuntu@51.195.190.65`) — that's where the
Nix staging volume + Noble base live. `.140` has no staging volume.

1. **Profile config** — an isolated spike TOML (gitignored,
   `bin/nix-profiles-tracelabs-spike.toml`, generated by
   `runs/nix-portal/tracelabs-spike.sh`): the catalog `[base]/[gpu]/[layers.*]`
   verbatim + only `tracelabs` (+ `firefox`/`torbrowser` as `requires`),
   firefox/torbrowser pinned to the **published** rev so blobs dedup.
   (Superseded: the main TOML's `[profiles.tracelabs]` now carries this — with
   `requires = [obsidian, chromium, firefox, brave, torbrowser]` riding the
   catalog's own published pins for the same three-way blob dedup.)
2. **Build** (inside the DinD, via `ci-scripts/dind-run.sh`):
   ```
   bash bin/build-nix-store-volume \
     --config /work/bin/nix-profiles-tracelabs-spike.toml \
     --profile tracelabs --profile firefox --profile torbrowser \
     --app-base-image localhost/nix-ubuntu:dev \      # NOBLE, not resolute
     --tag localhost/nix-store-amd64:spike --emit-app-images --keep-output
   ```
   Absolute `--config` path (relative → podman reads it as a volume *name*).
   Output: `127.0.0.1:5000/nix-tracelabs:spike` in the DinD podman store.
3. **Layer-patch for desktop-mode** (fast, NO nix rebuild — the store is fine,
   only the activation scripts change):
   ```
   FROM 127.0.0.1:5000/nix-tracelabs:spike
   COPY nix-activate /usr/local/bin/nix-activate
   COPY custom_startup.sh /dockerstartup/custom_startup.sh
   RUN chmod 0755 … && touch /etc/nix-desktop-mode      # desktop marker
   ```
   `podman build --pull=never` (the FROM is a local image).
4. **Verify before pushing** — `/nix/store -> /store` and a tool resolves:
   ```
   podman run --rm --entrypoint sh <img> -c 'readlink /nix/store; ls -d /nix/store/*sherlock*'
   ```
5. **Push** to the internal registry `:nix` (§3 for the push-cred recipe).
6. Kasm workspace `run_config = {hostname, user}` — **no seccomp** (§4.2).

## 3. Pushing from the forge (no standing registry creds there) — FALLBACK ONLY

> CI now publishes AND attests `tracelabs-osint` automatically (see header) — a
> hand-push produces no cosign attestation. Use this only to break-glass a
> locally hand-assembled image (§ "hand-assemble locally") when CI is unavailable.

`.140` holds only a *pull* deploy token; the forge holds none. Create a
throwaway `write_registry` token with `glab`, use it, revoke it:
```
glab api "projects/<id>/deploy_tokens" --method POST \
  --header 'Content-Type: application/json' --input - <<< \
  '{"name":"throwaway","scopes":["read_registry","write_registry"],"expires_at":"<date>"}'
# NOT -f 'scopes[]=' (glab won't array-encode it → "scopes is missing")
```
Push inside the DinD: mount the token file (NOT under `/run/<dir>` that already
exists), `podman login … --password-stdin < /tok`, tag, push, logout. Then
`glab api …/deploy_tokens/<id> --method DELETE`. Never echo the token.

## 4. Known gaps (as of 2026-07-20)

### 4.1 `requires` browsers don't activate — the jq gap (FIX: bake jq via nix)
`nix-activate` expands `requires` (firefox/torbrowser) and builds the menu
**with jq** — but jq was only installed build-side, so it wasn't on
nix-activate's *runtime* PATH. `expand_deps` silently skipped, only
`tracelabs` activated, and the composed browsers never appeared
(`NIX_APP_ACTIVE="tracelabs"` only; menu had just `nix-maltego.desktop`).
**Fix (owner direction 2026-07-20): bake jq via NIX into the Resolute base**,
the same way KasmVNC/profile-sync are — NOT apt (the base is moving off apt
deps). Three edits (done in source, need a Resolute base rebuild):
`bin/nix-kasm-overlay/flake.nix` adds `jq = pkgs.jq.bin` (nixpkgs passthrough —
`.bin` output is REQUIRED: `pkgs.jq` is multi-output and `nix build .#jq | tail
-1` grabbed the `-man` path with no `bin/jq`, so the base wiring silently
skipped it → `expand_deps` stayed broken. Fixed in 798dfd6);
`ci-scripts/nix-base-build.sh` adds `--pkg jq` to the `nix-bake-closure` call;
`dockerfile-nix-ubuntu-resolute` takes `JQ_STORE_PATH` and symlinks
`jq -> /usr/bin/jq`. (I first tried a jq-free `expand_deps`, then apt — both
wrong; nix-baked is the direction. The desktop-mode *signal* stays a jq-free
marker file since it runs before activation.) CLI tools (sherlock/sn0int) still
won't be in the *menu* (no `.desktop`); they're on PATH via the profile —
launch from a terminal.

### 4.2 security_opt: use the DESKTOP profile (apparmor=unconfined + bwrap.json) — CORRECTED
**Earlier (WRONG) conclusion:** "drop seccomp, run default." That was a
misdiagnosis. The blank/broken desktop was caused by the **0600 asset perms**
(§ the mutagen chmod fix) — a missing/unreadable icon fell back to
`image-missing.svg`, and glycin's SVG loader crashed the panel. Fixing the perms
fixed the desktop.

**Correct fix (matches every Nix desktop image, registry 4aa0d22):** the
TraceLabs workspace `run_config.security_opt` must be
`["apparmor=unconfined", "seccomp=<bwrap.json>"]` — the SAME two options the
`Nix Ubuntu - Resolute` / `Nix Fat Store` desktop workspaces use. Why:
- `bwrap.json` (src/common/seccomp/bwrap.json) = chrome.json + `pivot_root` +
  unconditional mount family. It permits unprivileged userns AND bwrap's mount
  setup, so **Chromium/Electron keep their namespace sandbox** (no
  `--no-sandbox` — the SUID sandbox helper can't be root:4755 in the read-only
  Nix store, so without userns Chrome/Electron/obsidian ABORT) and **glycin's
  bwrap SVG loader works** (panel renders).
- `apparmor=unconfined` is **required** too: under docker's default AppArmor,
  bwrap's mount ops are denied → glycin-svg fails → panel crash-loop, even with
  bwrap.json seccomp. Kasm applies both; a bare `docker run` with only
  `--security-opt seccomp=…` reproduces the CRASH (missing the apparmor half).

**Debug lesson:** to reproduce a Kasm launch with `docker run`, pass BOTH
`--security-opt apparmor=unconfined` AND `--security-opt seccomp=<bwrap.json>`
(and inspect a real working Kasm container's `HostConfig.SecurityOpt` to see
exactly what it applies). Chromium/obsidian failing = missing this security_opt,
NOT a GPU or nix-launch issue.

### 4.3 TL desktop assets not wired (Phase-1)
Missing: TL Vault, Obsidian, wallpaper, templates, OSINT Resources/
Investigations. `post-build.sh` only drops the desktop marker so far; Obsidian
isn't even in `requires` yet. These come from the §2/§5 wiring in the design —
unbuilt. Expected-missing on the current spike.

### 4.4 Maltego first-run stall at "loading modules"
Maltego (NetBeans platform, OpenJDK 21) reaches image-reader/LAF init then logs
`Falling back to master password encryption` (no secret-service/gnome-keyring
in the container) and stalls loading modules — not CPU/mem bound. Likely the
NetBeans keyring fallback and/or first-run module cache. Investigate: run a
secret-service, or `-J-Dorg.netbeans.modules.keyring.enabled=false`, or pre-warm
the module cache. Maltego-app-specific, separate from packaging.

## 5. The Resolute `/nix-stores/tracelabs` pivot — is it cheap? (assessment)

**Verdict: cheaper than first framed, and architecturally cleaner — the right
long-term shape.** Correction (owner, 2026-07-20): the TraceLabs store does
**NOT** need to be a runtime *mount*. It's a self-contained image — **bake the
store as a `/nix-stores/tracelabs` directory** into the image (exactly like the
Resolute base bakes services at `/nix-stores/services`), and register it with
`nix-compose` so it's unioned into `/nix` at boot. No `run_config` mount, no
separate store-mount image. It reuses machinery that already exists:

- We *already* build + bake the TraceLabs store into the image (today at
  `/store`); the only change is baking it at `/nix-stores/tracelabs` on the
  Resolute base instead of `/store` on Noble.
- Resolute *already* unions `/nix-stores/base` + `/nix-stores/services` via
  `nix-compose`. Adding `/nix-stores/tracelabs` to that union is a
  `nix-compose` registration.

What it *buys*:
- Runs on the **proven Resolute desktop** → **no desktop-mode nix-activate
  hack** (§ design 5.1) and **no seccomp fix** needed (the desktop base already
  renders on default seccomp). Both §4.1/§4.2 headaches largely evaporate.
- **Store-level dedup** with the fat store (shared paths overlaid, not copied).

What it *costs* / to check:
- Baking the TraceLabs store at `/nix-stores/tracelabs` + `nix-compose`
  registration + the Kasm `run_config` mount.
- The activation path: confirm the tools land on PATH / in the menu under the
  multi-store union (the §4.1 jq gap may or may not recur depending on whether
  activation still goes through `expand_deps`).
- The multi-store model is newer / less battle-tested than per-app.

**DONE (2026-07-21):** this sequence was followed to completion — the Noble
single-store variant is retired, TraceLabs ships as the Resolute multi-store
profile in the main TOML, and it builds/scans/publishes/attests via CI (header).
§4.1 was resolved by baking jq via nix into the Resolute base.

## 5b. v1 (full design-compliant) — BUILT 2026-07-20 (commit cf723d6)

The Resolute image is now the **full v1**, not just browsers+3-tools:
- **13 OSINT tools** resolve on PATH: nixpkgs (sherlock, sn0int, translate-shell,
  exiftool, steghide, stegseek, tor, shodan) + 4 overlay derivations
  (`bin/nix-kasm-overlay/pkgs/{spiderfoot,phoneinfoga,sublist3r,metagoofil}`,
  pinned to upstream tags — not in nixpkgs) + Maltego.
- **requires = [obsidian, chromium, firefox, brave, torbrowser]**, each pinned
  to its published rev (chromium/brave/firefox `61b7c44`, obsidian/torbrowser
  `fd146203`) so the deltas dedup byte-for-byte with the standalone images.
- **Maltego keyring fix**: `bin/nix-kasm-overlay/overlay.nix` wraps nixpkgs
  maltego with `-J-Dnetbeans.keyring.no.{native,master}=true` → the NetBeans
  keyring no-ops instead of stalling at "loading modules" (no secret-service
  in-container). NEEDS live GUI validation.
- **TL desktop assets** (`src/ubuntu/install/nix/tracelabs/`): `post-build.sh`
  seeds the TL Vault + CTF guides + launchers into
  `/home/kasm-default-profile/Desktop`, overrides `bg_default.png` with the
  TraceLabs wallpaper, and drops the Firefox OSINT policy at
  `/etc/firefox/policies/`. Staged by `nix-crane-assemble`'s
  `stage_resolute_wiring_tar` (post-build.sh only — no single-app custom_startup)
  wired into the RESOLUTE_APPS loop.

Rebuild recipe (now via the MAIN TOML — the spike script/TOML are deprecated):
prefer the **CI path** in the header. For a local break-glass build, run
`dind-build.sh` against the main `bin/nix-profiles.toml` (no `NIX_CONFIG_FILE`):
`RESOLUTE_APPS=tracelabs`, `RESOLUTE_BASE_IMAGE=localhost/nix-ubuntu-resolute:dev`,
`EMIT_APPS=1`, plus (dev shortcut) `SCOPED_BUILD=1
PROFILES=tracelabs,obsidian,chromium,firefox,brave,torbrowser` to narrow the
build to tracelabs' closure. Per-tool inventory: `design/tracelabs-manifest.tsv`.

Known-open (not blocking): Maltego GUI validation; browser OSINT *bookmark*
seeding (firefox distribution.ini / chromium initial_bookmarks are install-dir
mechanisms that don't map onto nix-store browsers — vault's `OSINT Resources.md`
carries the links for now); the OSINT app-menu categories
(`usr/share/desktop-directories/*.directory`) not yet wired.

## 6. Handy references
- Authoritative image: `tracelabs-osint:nix`, built + published + **attested** by
  CI on `kasm-nix` (pipeline 2693655030). Kasm caches by tag — force a re-pull if
  a relaunch looks stale (`docker rmi` + pull, or bump the tag).
- Profile source of truth: `[profiles.tracelabs]` in `bin/nix-profiles.toml`.
  CI wiring: `.gitlab-ci.yml` `build:` (RESOLUTE_APPS derivation),
  `runs/nix-portal/dind-build.sh` (RESOLUTE_APPS→`--resolute-app`),
  `bin/nix-crane-assemble` (resolute assembly), `ci-scripts/nix-scan-l3.sh`
  (mode-2 multi-store scan + resolute completeness skip),
  `ci-scripts/nix-publish.sh` (resolute publish pass).
- Key commits: `dad0341` (profile folded into main TOML), `121f597` (build/
  publish resolute path), `2c1297d` (scan-nix resolute-completeness fix →
  attestation green). Design at `design/tracelabs-osint-image.md`.
- Deprecated (do not use): `bin/nix-profiles-tracelabs-spike.toml`,
  `runs/nix-portal/tracelabs-spike.sh` — superseded by the main TOML; safe to
  delete once no local worktrees still reference them.

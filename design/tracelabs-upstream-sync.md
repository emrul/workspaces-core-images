# Trace Labs OSINT — upstream sync procedure (SOP)

**What this is.** The repeatable process for re-basing our Nix/Kasm
`tracelabs-osint` image onto a newer upstream Trace Labs release. Our image
is a *translation* of the upstream VM, not a copy: upstream installs tools
imperatively (`apt`/`pipx`/`go`/`cargo`) and ships desktop assets in an
overlay tree; we express the same result as a pinned Nix profile plus a
wiring layer. This doc says exactly how to carry an upstream delta across
that translation boundary, deterministically, each time.

**Companion docs — don't duplicate them:**
- `design/tracelabs-manifest.tsv` — the **inventory** (one row per tool/asset,
  upstream-source → mechanism, pinned to a commit). *This is the artifact you
  edit during a sync.*
- `design/tracelabs-vs-upstream.md` — the **deviation rationale** (why we
  differ where we differ). Update when a sync introduces/changes a deviation.
- `design/tracelabs-osint-image.md` — the **build design** (§2 scope, §3
  architecture, §5 wiring, §7 validation).
- `design/tracelabs-build-runbook.md` — the **build/test/attest mechanics**
  (how to actually rebuild and ship once translation is done).

---

## 0. Pinned upstream state (the thing a sync moves)

| | value |
|---|---|
| Upstream repo | `github.com/tracelabs/tlosint-vm` |
| Tool list (source of truth) | `scripts/tlosint-tools.sh` |
| VM recipe | `tlosint.yaml` (`$packages` list + overlay wiring) |
| Obsidian installer | `scripts/tl/install-obsidian.sh` |
| Desktop asset tree | `overlays/tl-overlays/` |
| **Current pinned commit** | `71d9815401ce3f061dbf65e509f57073fa1e2be1` |
| nixpkgs rev we verified against | `d407951447dcd00442e97087bf374aad70c04cea` |

The pinned commit is recorded in **two** places that must stay in lockstep —
the manifest header comment and the profile comment:
- `design/tracelabs-manifest.tsv` line 2 (`Source of truth: … @ <commit>`)
- `bin/nix-profiles.toml` `[profiles.tracelabs]` (add/keep a `# upstream: <commit>` line)

> ⚠️ Upstream moves files. `tlosint-tools.sh` was once optional-only; the vault
> has lived under different overlay paths. **Step 1 re-confirms the layout**
> before diffing — never assume the paths above are still current.

---

## 1. The artifact map (upstream → ours → how to translate)

This is the reverse index that makes a sync mechanical. For each upstream
change, find its row, edit the listed target, apply the rule. Grouped by the
kind of change, because the translation rule differs by kind.

### A. Tools (`tlosint-tools.sh` + `tlosint.yaml $packages`)

| Upstream form | Our target | Translation rule |
|---|---|---|
| apt / pipx / go / cargo install of tool X | `bin/nix-profiles.toml` `[profiles.tracelabs]` `pkgs` | If X ∈ nixpkgs → add `"nixpkgs#X"`. Verify availability (§4). |
| tool X, **not** in nixpkgs | `bin/nix-kasm-overlay/pkgs/X/package.nix` + `pkgs = ["path:/config/kasm-overlay#X"]` | Write a derivation (see the 4 existing: spiderfoot/phoneinfoga/sublist3r/metagoofil for py/go patterns). |
| a browser or Obsidian | `[profiles.tracelabs]` `requires = [...]` | These are catalog profiles composed by reference (dedup). Never add to `pkgs`. |
| tool removed upstream | same `pkgs`/`requires`/overlay | Remove the entry; delete the overlay dir if it was overlay-only. |
| version bump only | nixpkgs rev (whole profile) | Not per-tool — a nixpkgs ref bump moves *all* nixpkgs tools at once (§5). |

Every add/remove/keep also updates a **row in `tracelabs-manifest.tsv`**
(`tool | upstream-source | v1-included | mechanism | notes`).

### B. Desktop assets (`overlays/tl-overlays/`)

| Upstream path (under `tl-overlays/`) | Our target | Translation rule |
|---|---|---|
| `etc/skel/Desktop/TL-Vault/` (notes, templates, guides, `.obsidian/`) | `assets/desktop-seed/TL-Vault/` | Copy verbatim, then re-apply our two local overrides (§3). |
| `.obsidian/plugins/*`, `.obsidian/themes/*` | `assets/desktop-seed/TL-Vault/.obsidian/…` | Copy verbatim. If a plugin/theme is added, copy its full dir. |
| `usr/share/backgrounds/…` (wallpaper/branding) | `assets/backgrounds-tracelabs/` (+ `bg_default.png` copy in `post-build.sh`) | Re-export to our resolution set (1280/1920/3840 + base). |
| firefox prefs / `distribution/policies.json` / user.js | `assets/firefox-policies.json` | Translate prefs → Firefox **enterprise policy** JSON (not user.js). Preserve the hardening set (telemetry off, RFP, sanitise-on-shutdown, bookmarks). |
| chromium `master_preferences` / `initial_bookmarks` | `assets/bookmarks/managed-bookmarks.json` | Translate to **ManagedBookmarks** managed-policy JSON (Kasm requires managed, read-only). Same tree feeds Brave. |
| Brave forced extension / managed policy | `assets/bookmarks/managed-bookmarks.json` + brave policy block in `post-build.sh` | Managed policy; the forced extension auto-updates at runtime (not in SBOM — noted in vs-upstream §8). |
| `etc/skel/Desktop/*.desktop` launchers | `assets/desktop-seed/*.desktop` | Re-point `Exec=` at our `nix-*.desktop` shims / profile-bin paths (upstream Execs assume apt paths). |
| CTF guide PDFs | `assets/desktop-seed/*.pdf` | Copy verbatim; rename if upstream version-bumps the filename. |
| mimetype defaults | `assets/mimeapps.list` | Keep our nix-`.desktop`-shim targets; carry across any new associations. |
| category icon | `assets/tracelabs.svg` | Copy verbatim. |

### C. Obsidian install (`scripts/tl/install-obsidian.sh`)

Upstream downloads a specific Obsidian `.deb`/AppImage. **We do not follow the
pinned binary** — Obsidian comes from `requires = ["obsidian"]` (nixpkgs). What
matters on sync: if the upstream Obsidian **major version** moves, the
pre-trust leveldb seed may drift (§3), and the bundled community-plugin
versions in the vault should be checked for a minAppVersion bump.

### D. Things with **no upstream source** — ours only, never overwritten by a sync

These exist because we're a container, not a VM. A sync never touches them
except where noted:
- `assets/obsidian-userdata/` — pre-trusted Local-Storage leveldb (kills the
  vault-trust prompt). Regenerate **only** if Obsidian's major version moved
  (recipe in `assets/obsidian-userdata/README.md`).
- `assets/desktop-seed/TL-Vault/.obsidian/appearance.json` — our dark-theme
  pin (`"theme":"obsidian"`, **not** `baseColorScheme` — that key is silently
  dropped by Obsidian; see commit history). Re-apply after any vault copy.
- `post-build.sh` — the whole wiring layer (staging + `chmod a+rX`).
- SBOM attestation, CVE scan, testbench scenario, provenance labels.

---

## 2. The sync procedure

```sh
# --- Step 1: fetch upstream, re-confirm layout, set the two commits ---
OLD=71d9815401ce3f061dbf65e509f57073fa1e2be1        # = current pin (§0)
git clone --filter=blob:none https://github.com/tracelabs/tlosint-vm /tmp/tlosint-vm || \
  git -C /tmp/tlosint-vm fetch origin
NEW=$(git -C /tmp/tlosint-vm rev-parse origin/HEAD) # or a chosen release tag
# sanity: the paths in §0 still exist at $NEW
git -C /tmp/tlosint-vm ls-tree -r --name-only "$NEW" \
  | grep -E 'tlosint-tools|tlosint\.yaml|tl-overlays|install-obsidian' | sort
```

```sh
# --- Step 2: the delta, scoped to what we track ---
git -C /tmp/tlosint-vm diff "$OLD".."$NEW" -- \
  scripts/tlosint-tools.sh tlosint.yaml scripts/tl/install-obsidian.sh overlays/tl-overlays
```

**Step 3 — classify every hunk** into exactly one bucket:

| Bucket | Action |
|---|---|
| Tool add / remove / rename | §1.A rule → edit `nix-profiles.toml` (+overlay) + manifest row |
| Tool version pin change | Note it; handled by the nixpkgs ref bump, not per-tool (§5) |
| Vault / template / guide / plugin / theme content | §1.B — copy the changed files into `assets/desktop-seed/…` |
| Browser policy / bookmarks | §1.B — re-translate to policy JSON |
| Wallpaper / branding / icon / launcher | §1.B — re-export / re-point |
| **Installer machinery** (`ensure_*`, `apt_self_heal`, PATH persistence, rustup/GOPATH/pipx bootstrap, the OSINT-Updater, VM guest additions) | **IGNORE** — obviated by Nix (§3 of vs-upstream). Record in the sync note that you saw it and dropped it. |
| **Standing-drop item** (Docker, docker-compose, Owlculus, torbrowser-launcher, StegOSuite, Kali arsenal) | **DROP** per §3 below unless the owner reverses the decision |

**Step 4 — apply translations** per the map (§1). After copying any vault
files, re-apply the two local overrides in §1.D (appearance.json, and check
the pre-trust leveldb).

**Step 5 — update provenance:** set `OLD → NEW` in both pin locations (§0),
update `tracelabs-manifest.tsv` header commit + any changed rows, and add a
line to `vs-upstream.md` if a deviation changed.

**Step 6 — build, validate, ship:** follow `tracelabs-build-runbook.md`
(rebuild via the CI trigger with `NIX_CHANGED_FILES` scoped to the touched
tracelabs paths + `NIX_BASE_AFFECTED=0`), run the testbench `tracelabs.yaml`
scenario, confirm the publish + `cosign attest` step is green.

---

## 3. Standing scope decisions (so judgment is consistent every sync)

These were settled during v1 (design §2) and should **not** be re-litigated per
sync — only by an explicit owner decision, which then updates this table.

**Always drop:**
- Docker + docker-compose — nested containers unsupported in Kasm.
- Owlculus — Docker-compose stack; depends on the above.
- `torbrowser-launcher` — obviated by the `torbrowser` catalog profile (pinned, no runtime download).
- OSINT-Updater launcher — our update model is *rebuild*, not in-VM re-run.
- All self-heal / PATH / rustup / GOPATH / pipx bootstrap machinery — Nix puts tools on PATH by construction.
- VM guest additions, kernel/systemd assumptions — we're a container.
- StegOSuite — absent from nixpkgs, upstream treats as optional (`steghide`/`stegseek` cover the need).

**Always add (no upstream source):**
- Maltego (`nixpkgs#maltego`, unfree) — owner decision 2026-07-19; Kasm–Maltego partnership.
- Signed SBOM attestation, CVE scan, public security page, testbench validation.
- The container-only assets in §1.D.

**Deliberate per-tool deviations (keep unless upstream forces a change):**
- `firefox-esr` → `nixpkgs#firefox` (layer reuse; hardening policies preserved).
- `torbrowser-launcher` → `nixpkgs#tor-browser` (pinned, packaged). *amd64-only* until Tor Browser is made arch-conditional.

**Out of v1, into a separate extension list (don't add silently):**
`theharvester`, `recon-ng`, `maigret`, `holehe`, `amass`, … — none are in the
tools script.

---

## 4. Is a new tool in nixpkgs? (the availability check)

Run on the `.140` Nix host against the rev we build with:

```sh
# on .140 — does the attr exist and evaluate?
nix eval --raw "nixpkgs#<tool>.pname" 2>/dev/null && echo "in nixpkgs" || echo "NOT in nixpkgs → overlay"
# does it actually build (catches broken/marked-broken)?
nix build --no-link "nixpkgs#<tool>" 2>&1 | tail -3
```

- **In nixpkgs** → add `"nixpkgs#<tool>"` to `pkgs`; manifest mechanism =
  `tracelabs pkgs (nixpkgs)`.
- **Not in nixpkgs** → write an overlay derivation under
  `bin/nix-kasm-overlay/pkgs/<tool>/package.nix`. Use the closest existing
  pattern: `buildPythonApplication` (sublist3r, metagoofil),
  `buildGoModule` (phoneinfoga), or the spiderfoot pattern for a bundled app.
  Add `"path:/config/kasm-overlay#<tool>"` to `pkgs`; manifest mechanism =
  `overlay derivation`.

---

## 5. Two independent update axes (don't conflate them)

1. **Upstream content** (this doc) — Trace Labs changed *which* tools/assets.
   Moves the pinned upstream commit. May add/remove tools, change the vault.
2. **nixpkgs revision** — moves *versions* of the tools we already ship, on
   the normal eval-gate/testbench cadence. A security CVE bump is usually
   axis 2 alone (no upstream commit change).

A routine "keep current" sweep is often **axis 2 only**: bump the nixpkgs rev,
rebuild, testbench, attest — no upstream diff needed. Run the full §2
procedure only when Trace Labs actually ships a new release.

---

## 6. Checklist (copy into the sync commit / MR body)

```
[ ] Step 1  cloned tlosint-vm; confirmed tracked paths still exist at NEW
[ ] Step 2  diffed OLD..NEW over the 4 tracked paths
[ ] Step 3  every hunk classified (tool / asset / policy / machinery-ignored / standing-drop)
[ ] Step 4  translations applied; §1.D local overrides re-applied (appearance.json + leveldb check)
[ ] Step 5  pin bumped in nix-profiles.toml AND manifest header; manifest rows updated; vs-upstream deviations updated
[ ] Step 6  rebuilt (NIX_CHANGED_FILES scoped, NIX_BASE_AFFECTED=0); testbench tracelabs.yaml green; attest green
[ ] Noted:  standing-drop / installer-machinery items seen this sync and intentionally skipped
```

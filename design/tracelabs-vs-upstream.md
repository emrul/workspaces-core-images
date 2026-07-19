# Trace Labs OSINT — how our image differs from the upstream VM

Companion to `design/tracelabs-osint-image.md` (the build design). This doc
is the honest "what's different and why" record: what a Trace Labs
investigator who knows the official VM should expect from our Kasm workspace
image. Written to be publishable (we ship our build/package scripts; GPLv3).

Upstream reference: `github.com/tracelabs/tlosint-vm` (the Debian-13 VM) and
its optional `scripts/tlosint-tools.sh` toolset. Matched upstream commit is
recorded in the build manifest (`design/tracelabs-osint-image.md` §2).

## At a glance

| Dimension | Upstream Trace Labs VM | Our Nix/Kasm image |
|---|---|---|
| Delivery form | Full VM image (OVA/OVF/QEMU/raw/VMware/VirtualBox) | OCI container workspace, browser-accessed via KasmVNC |
| Base OS | Debian 13 (trixie) | Ubuntu **Resolute** (26.04) core, Nix-delivered services |
| Tool install | `apt` + `pipx` + `go install` + `rustup`/`cargo`, with self-heal loops | One pinned **Nix profile** (nixpkgs rev), tools on PATH by construction |
| Updates | In-VM "OSINT Updater" re-runs the installer | Rebuild on a nixpkgs ref bump; atomic, reproducible |
| Firefox | `firefox-esr` | standard `nixpkgs#firefox` (hardening policies still applied) |
| Tor Browser | `torbrowser-launcher` (downloads at runtime) | `nixpkgs#tor-browser` (packaged, pinned) |
| Docker / Compose | Installed | **Removed** — no nested Docker in a Kasm workspace |
| Owlculus | Installed (Docker-compose stack) | **Removed** (depends on nested Docker) |
| Maltego | not in the tools script | **Included** (nixpkgs, unfree; Kasm–Maltego partnership) |
| Supply-chain assurance | none | Signed **SBOM attestation** + CVE scan + public security page |
| Persistence | VM disk | Kasm profile-sync; TL Vault seeded for **new users only** |

## 1. It's a container workspace, not a VM

Upstream ships bootable VM images you run in VirtualBox/VMware/QEMU. Ours is
an OCI image you open in a browser through Kasm (KasmVNC streams the XFCE
desktop). Practical consequences:

- **No nested virtualisation.** Anything in the VM that assumed a full
  machine (its own kernel, systemd, VM tooling, VirtualBox guest additions)
  doesn't apply. Where a tool genuinely needed a VM boundary, it's out of
  scope for v1.
- **Ephemeral by default, persistent by profile.** A Kasm session is
  disposable; investigator state persists via Kasm profile-sync, not a VM
  disk. See §7.

## 2. Base OS is Ubuntu Resolute — and it doesn't affect the tools

Upstream is Debian 13 **because its installer is `apt`/`pipx`/`go`/`cargo`** —
the tools bind to Debian's libc and package set, so the distro choice is a
consequence of the install method. We install every tool from **nixpkgs**,
where each tool carries its own closure (its own glibc and dependencies) and
links against nothing from the host OS. So the base underneath is our free
choice; we use **Ubuntu Resolute (26.04)**, the "everything-from-Nix" core
where even the Kasm services are Nix packages.

Matching Debian 13 would buy nothing — we never touch Debian's packages. A
nixpkgs `sherlock`/`spiderfoot`/`tor-browser` behaves identically regardless
of the base. (Caveat: Nix removes libc/package-manager coupling, not *all*
host coupling — kernel, user namespaces, seccomp, GPU, D-Bus still matter;
that's what the Phase-0 runtime spike proves.)

## 3. Nix profile instead of the imperative installer

The upstream `tlosint-tools.sh` is ~980 lines of `apt`/`pipx`/`go`/`cargo`
wrapped in self-heal loops (`apt_self_heal`, `ensure_shodan_available`,
`ensure_rust_cargo_available`), four-shell PATH persistence, and a runtime
updater — machinery that exists *because the imperative install is flaky*.
We replace all of it with one Nix profile pinned to a single nixpkgs
revision:

- Every tool is on PATH by construction; no PATH-persistence hacks.
- Updates are a ref bump + rebuild — atomic and reproducible, not a
  best-effort re-run of a fragile script. The in-VM "OSINT Updater" desktop
  launcher has no analogue and is gone.
- The image is reproducible from pinned inputs and carries provenance
  labels; the VM's tool versions are whatever `apt`/`pip`/`go`/`cargo`
  happened to resolve at build time.
- Four tools not in nixpkgs (`spiderfoot`, `phoneinfoga`, `sublist3r`,
  `metagoofil`) are packaged as small Nix derivations in our overlay rather
  than pipx/go-installed at runtime.

## 4. Per-tool differences

**Firefox — `firefox-esr` → standard `nixpkgs#firefox`.** Upstream installs
the ESR channel; we use the regular Firefox from our catalog. The reason is
**layer reuse**: our image *composes* the existing catalog Firefox profile,
so anyone who already has our Firefox (or the shared "fat store") re-pulls
nothing. A separate ESR build would share no layers. The Firefox **hardening
policies** the VM applies (telemetry off, strict tracking protection,
resistFingerprinting, sanitise-on-shutdown, the OSINT bookmarks) are applied
to our Firefox too — so the *hardened-browser experience* is preserved even
though the channel differs. Recorded as an intentional deviation in the
manifest.

**Tor Browser — `torbrowser-launcher` → `nixpkgs#tor-browser`.** The VM
installs the launcher, which downloads Tor Browser at first run. We ship the
packaged, pinned `tor-browser` — no runtime download, reproducible version.
(Currently amd64-only: nixpkgs' Tor Browser is x86_64/i686.)

**Maltego — added (not in the tools script).** Upstream's `tlosint-tools.sh`
does not install Maltego. We include it because Kasm partners with Maltego
and already ships a stock `kasmweb/maltego` image, so redistribution is
covered by that relationship. It comes from nixpkgs (unfree; the Linux ZIP
artifact) and, like the VM's Maltego CE, requires an account login on first
run.

**Docker + docker-compose — removed.** The VM installs Docker Engine and
Compose. Nested Docker inside a Kasm workspace is not supported by default,
so they're dropped.

**Owlculus — removed.** The VM installs Owlculus, a Docker-compose web-app
stack, via the Docker it just installed. With Docker gone (and Owlculus
being a service stack rather than a desktop tool) it's out of v1. It can be
offered later as an external/self-hosted add-on.

**StegOSuite — skipped.** Absent from nixpkgs, and upstream already treats it
as optional. `steghide` and `stegseek` (both in nixpkgs) are included.

**Everything else is the same tool.** `sherlock`, `sn0int`, `shodan`,
`spiderfoot`, `phoneinfoga`, `sublist3r`, `metagoofil`, `exiftool`,
`steghide`, `stegseek`, `translate-shell`, the Brave browser + its forced
Forensic-OSINT extension, and the Tor CLI are the same tools the VM ships —
delivered via Nix (or our overlay) instead of apt/pipx/go/cargo.

## 5. What we add that the VM doesn't have

- **Signed SBOM attestation** per image (`cosign attest --type cyclonedx`),
  so anyone can verify the exact software inventory against our public key.
- **CVE scanning** (Syft→Grype over the `/nix/store` closure, plus a vulnix
  advisory) with results on a public security page.
- **Testbench validation** — each tool is exercised in a real session before
  the image is promoted to its production tag (see the build design §7/§9).

The upstream VM offers none of these; its assurance is "it built".

## 6. Tool provenance & versions

Upstream tool versions are whatever the distro/PyPI/Go/crates resolved when
the VM was built, and drift on each updater run. Ours are pinned to a nixpkgs
revision recorded in the image's provenance labels and SBOM; a version only
changes on a deliberate ref bump that goes through the eval-gate and
testbench. This is a genuine behavioural difference: our image is
*reproducible* and *auditable*; the VM is neither by construction.

## 7. Persistence & the Trace Labs vault

The VM keeps state on its disk. Our image is a container: session state
persists through **Kasm profile-sync**, and the **Trace Labs vault /
Obsidian workflow** (a defining part of the current VM) is seeded into a
**new** user's home only — a returning investigator's edited vault is never
overwritten. (Mechanically: the vault ships in the Kasm default-profile and
is copied in only on first use; see the build design §5.3.)

## 8. Things to keep an eye on (honest caveats)

- **amd64 only** in v1 (Tor Browser's nixpkgs platforms). arm64 needs Tor
  Browser made architecture-conditional.
- **Host coupling** still exists despite Nix isolation — the Phase-0 runtime
  spike validates that the desktop, the browsers, Tor Browser and Maltego
  actually launch on Resolute under the real Kasm seccomp profile.
- **The forced Brave extension** is fetched and auto-updated at runtime, so
  it isn't captured in the image SBOM — noted in our security posture, same
  as it would be on the VM.
- **Licensing** of bundled components (browsers, the Brave extension, the TL
  vault/branding, and Maltego's redistribution terms) is reviewed per
  component before we publish the image publicly.

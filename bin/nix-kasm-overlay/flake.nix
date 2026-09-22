{
  description = "Kasm self-hosted Nix packages: fast-cadence + not-in-nixpkgs apps. See design/nix-self-hosted-packages.md.";

  # Default nixpkgs pin. The BUILD ALWAYS overrides this input:
  #   nix profile install --override-input nixpkgs github:NixOS/nixpkgs/<rev> \
  #       path:/config/kasm-overlay#<app>
  # so each self-hosted app is realized against the SAME rev as its ref-class
  # peers → one glibc, full store dedup (design/nix-self-hosted-packages.md,
  # design/nix-dedup-gap.md). This concrete rev is used only for un-overridden
  # local `nix build`, and keeps the committed flake.lock stable so the
  # read-only (:ro) build mount never needs to re-lock. Bump with
  # `nix flake update` when convenient — production dedup does not depend on it.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d407951447dcd00442e97087bf374aad70c04cea";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # The single pkgs constructor for BOTH outputs below, so an override can
      # never apply to one and miss the other.
      #
      # Security backports live in overlays.default, SCOPED to the packages that
      # actually need them, and are deliberately NOT wired as
      # config.packageOverrides. Rebinding a top-level attribute like `perl`
      # changes it as a BUILD input across the tree: measured, the perl
      # CVE-2026-13221 fix costs 33 rebuilds scoped to exiftool, but 440+ when
      # global — enough to pull in clang/LLVM/ffmpeg and exhaust the build
      # host's disk. See pkgs/perl/security-override.nix.
      mkPkgs = system: import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
        config.allowUnfree = true;
      };
    in {
      overlays.default = import ./overlay.nix;

      # The whole of nixpkgs WITH the overlay applied, so a plain package can be
      # installed through it: path:/config/kasm-overlay#<attr>.
      #
      # This exists because `packages` cannot carry a security fix into a
      # transitive dependency. The perl backport (CVE-2026-13221) has to reach
      # everything that RUNS perl, and `nix profile install
      # github:NixOS/nixpkgs/<rev>#exiftool` evaluates against PLAIN nixpkgs —
      # no overrides, so unpatched perl in its closure. Resolving the same
      # attribute through here instead applies them to the whole graph.
      #
      # Runtime perl consumers, enumerated with `nix why-depends --precise`
      # over every profile in bin/nix-profiles.toml: kasmvnc (bin/kasmvncserver
      # is a Perl script, so EVERY image), exiftool (Perl script, tracelabs),
      # and xdg-utils (xdg-screensaver shells out to perl; on PATH via the
      # chromium/firefox/brave wrappers). Nothing else reaches it at runtime.
      #
      # Attribute paths are nixpkgs' own, nesting included (xorg.libX11), since
      # this IS a nixpkgs package set. Anything neither the overlay nor the
      # security overrides name passes through untouched — apart from a new
      # hash where patched perl is in its closure.
      legacyPackages = forAllSystems mkPkgs;

      # One packages.<system>.<profile> per self-hosted app. bin/nix-profiles.toml
      # references these as path:/config/kasm-overlay#<profile>.
      packages = forAllSystems (system:
        let
          pkgs = mkPkgs system;
        in {
          chrome       = pkgs.chrome;
          vivaldi      = pkgs.vivaldi;
          # OnlyOffice with the bundled Qt 5.9 stripped (CVE-2023-51714,
          # CVE-2024-36048); see overlay.nix. amd64 only.
          onlyoffice   = pkgs.onlyoffice;
          kasmvnc      = pkgs.kasmvnc;
          # jq: baked into the resolute base's /nix-stores/services so
          # nix-activate has it at RUNTIME (profile activation, `requires`
          # expansion, _meta.json reads). A plain nixpkgs passthrough — no
          # overlay build — but shipped via nix, not apt (nix-native base).
          # Select the `bin` output explicitly: pkgs.jq is multi-output
          # (bin/man/dev/lib/out) and `nix build .#jq | tail -1` otherwise
          # grabs the `-man` path (no bin/jq), so the base wiring skips it.
          jq           = pkgs.jq.bin;
          profile_sync = pkgs.profile_sync;
          audio_input  = pkgs.audio_input;
          recorder     = pkgs.recorder;
          webcam       = pkgs.webcam;
          gamepad      = pkgs.gamepad;
          # Maltego CE with the NetBeans keyring disabled (TraceLabs; see
          # overlay.nix). Unfree — allowUnfree is set above.
          maltego      = pkgs.maltego;
          # Trace Labs OSINT tools not in nixpkgs (design §4).
          spiderfoot   = pkgs.spiderfoot;
          phoneinfoga  = pkgs.phoneinfoga;
          sublist3r    = pkgs.sublist3r;
          metagoofil   = pkgs.metagoofil;
          # wine-assess's wine fork (Windows-app profiles require it). amd64 only.
          kasm-wine    = pkgs.kasm-wine;
          winetricks-headless = pkgs.winetricks-headless;
        }
        # Every pkgs/wine-apps/<slug> pin, exposed as wine-app-<slug> (see overlay.nix).
        // nixpkgs.lib.genAttrs
          (map (slug: "wine-app-${slug}")
            (builtins.attrNames (nixpkgs.lib.filterAttrs (n: t: t == "directory") (builtins.readDir ./pkgs/wine-apps))))
          (name: pkgs.${name})
        // {
          default      = pkgs.chrome;
        });
    };
}

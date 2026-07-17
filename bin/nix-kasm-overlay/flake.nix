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
    in {
      overlays.default = import ./overlay.nix;

      # One packages.<system>.<profile> per self-hosted app. bin/nix-profiles.toml
      # references these as path:/config/kasm-overlay#<profile>.
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
            config.allowUnfree = true;
          };
        in {
          chrome       = pkgs.chrome;
          vivaldi      = pkgs.vivaldi;
          kasmvnc      = pkgs.kasmvnc;
          profile_sync = pkgs.profile_sync;
          audio_input  = pkgs.audio_input;
          recorder     = pkgs.recorder;
          webcam       = pkgs.webcam;
          gamepad      = pkgs.gamepad;
          default      = pkgs.chrome;
        });
    };
}

# Kasm self-hosted package overlay.
#
# Each attribute is a profile that bin/nix-profiles.toml references as
# path:/config/kasm-overlay#<name>. Dependencies come from `prev` — the caller's
# nixpkgs, which the build overrides (--override-input nixpkgs) to the profile's
# ref-class rev — so every self-hosted app dedups with its peers (single glibc).
#
# Adding an app: create pkgs/<profile>/{package.nix,pin.json}, add a line here,
# and expose it in flake.nix `packages`. See design/nix-self-hosted-packages.md.
final: prev:
let
  loadPin = dir: builtins.fromJSON (builtins.readFile (dir + "/pin.json"));
in
{
  # Kind A (override): Google Chrome. Reuses nixpkgs' google-chrome packaging and
  # swaps only version+src from the committed pin, so we track Google's stable
  # channel faster than nixpkgs commits it (~12h via the twice-daily updater vs
  # nixpkgs' ~weekly). amd64 only — Google ships no arm64 Linux Chrome.
  chrome = import ./pkgs/chrome/package.nix {
    inherit prev;
    pin = loadPin ./pkgs/chrome;
  };
}

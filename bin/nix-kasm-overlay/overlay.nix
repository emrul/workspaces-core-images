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
  lib = prev.lib;

  # A package's committed pin (pkgs/<name>/pin.json) is the source of truth.
  # Any top-level string field can be overridden per-build from the environment,
  # so an engineer can test a PRIVATE build (their own commit/branch/hash)
  # WITHOUT editing the committed pin:
  #
  #   KASM_PIN_KASMVNC_COMMIT_ID=<sha> \
  #   KASM_PIN_KASMVNC_BRANCH=<branch> \
  #   KASM_PIN_KASMVNC_HASH=sha256-… \
  #     nix build --impure .#kasmvnc
  #
  # Env var name: KASM_PIN_<NAME>_<FIELD>, NAME and FIELD upper-cased (e.g.
  # commit_id -> COMMIT_ID). Overrides are honored ONLY under `nix build
  # --impure`; in normal (pure) evaluation builtins.getEnv returns "" and the
  # committed value always wins — so CI/production builds stay fully
  # deterministic and never depend on ambient environment. Nested objects
  # (e.g. chrome's per-system `hashes`) are not overridable; edit the pin for
  # those. See design/nix-self-hosted-packages.md § Pin config & private builds.
  loadPin = name: dir:
    let
      committed = builtins.fromJSON (builtins.readFile (dir + "/pin.json"));
      envFor = field:
        builtins.getEnv ("KASM_PIN_" + lib.toUpper name + "_" + lib.toUpper field);
      applyOverride = field: value:
        if builtins.isString value && envFor field != "" then envFor field else value;
    in
      builtins.mapAttrs applyOverride committed;
in
{
  # Kind A (override): Google Chrome. Reuses nixpkgs' google-chrome packaging and
  # swaps only version+src from the committed pin, so we track Google's stable
  # channel faster than nixpkgs commits it (~12h via the twice-daily updater vs
  # nixpkgs' ~weekly). amd64 only — Google ships no arm64 Linux Chrome.
  chrome = import ./pkgs/chrome/package.nix {
    inherit prev;
    pin = loadPin "chrome" ./pkgs/chrome;
  };

  # Kind A (override): Vivaldi with proprietary media codecs. Plain
  # nixpkgs#vivaldi ships without libffmpeg.so; the browser crash-loops at
  # startup trying to self-install it into the read-only store (testbench
  # catch 2026-07-17). The override symlinks vivaldi-ffmpeg-codecs'
  # libffmpeg.so into opt/vivaldi/lib — verified live on .140.
  vivaldi = prev.vivaldi.override { proprietaryCodecs = true; };

  # Kind B (from scratch): KasmVNC server built under Nix (fork of TigerVNC), so
  # the runtime base no longer needs a per-distro .deb/.rpm/.apk — unblocks new
  # distros (Resolute) and thins the base. SPIKE: iterate the build on the .140
  # host. See pkgs/kasmvnc/package.nix.
  kasmvnc = import ./pkgs/kasmvnc/package.nix {
    inherit prev;
    pin = loadPin "kasmvnc" ./pkgs/kasmvnc;
  };

  # Kind B (repackage S3 artifact): Kasm profile-sync client (v1 + v2). Another
  # base component (not a catalog app) — baked into distro bases via
  # nix-bake-closure, retiring the per-distro artifact matrix in
  # src/ubuntu/install/profile_sync/install_profile_sync.sh.
  profile_sync = import ./pkgs/profile_sync/package.nix {
    inherit prev;
    pin = loadPin "profile_sync" ./pkgs/profile_sync;
  };

  # Kind B (repackage S3 artifact): Kasm microphone capture server. A staticx
  # bundle (no autoPatchelf needed); baked into distro bases like the peers.
  audio_input = import ./pkgs/audio_input/package.nix {
    inherit prev;
    pin = loadPin "audio_input" ./pkgs/audio_input;
  };

  # More staticx-bundle base components (fetch/unpack, no autoPatchelf), baked in
  # like their peers: session recorder, virtual webcam, gamepad passthrough.
  recorder = import ./pkgs/recorder/package.nix {
    inherit prev;
    pin = loadPin "recorder" ./pkgs/recorder;
  };
  webcam = import ./pkgs/webcam/package.nix {
    inherit prev;
    pin = loadPin "webcam" ./pkgs/webcam;
  };
  gamepad = import ./pkgs/gamepad/package.nix {
    inherit prev;
    pin = loadPin "gamepad" ./pkgs/gamepad;
  };

  # Kind B (from scratch): Trace Labs OSINT tools absent from nixpkgs. Each is a
  # `{ prev }:` derivation pinned to an upstream tag. TraceLabs-unique (excluded
  # from the fat store); no committed pin.json — the tag is pinned in-package.
  # See design/tracelabs-osint-image.md §4.
  spiderfoot  = import ./pkgs/spiderfoot/package.nix  { inherit prev; };
  phoneinfoga = import ./pkgs/phoneinfoga/package.nix { inherit prev; };
  sublist3r   = import ./pkgs/sublist3r/package.nix   { inherit prev; };
  metagoofil  = import ./pkgs/metagoofil/package.nix  { inherit prev; };

  # Kind A (override): Maltego CE with the NetBeans keyring DISABLED. A Kasm
  # container has no secret-service (gnome-keyring/KWallet), so Maltego's
  # NetBeans platform falls back to master-password encryption and STALLS at
  # "loading modules" on first run. `-Dnetbeans.keyring.no.native` skips native
  # keyrings and `-Dnetbeans.keyring.no.master` skips the master-password
  # provider → the in-memory no-op provider (no prompt, no stall). Wrapping the
  # launcher (not editing the read-only store conf) survives nix-activate's shim
  # regeneration. TraceLabs-only (design/tracelabs-osint-image.md §2, runbook §4.4).
  maltego = prev.symlinkJoin {
    name = "maltego-nokeyring-${prev.maltego.version or "ce"}";
    paths = [ prev.maltego ];
    nativeBuildInputs = [ prev.makeWrapper ];
    postBuild = ''
      if [ -e "$out/bin/maltego" ]; then
        wrapProgram "$out/bin/maltego" \
          --add-flags "-J-Dnetbeans.keyring.no.native=true" \
          --add-flags "-J-Dnetbeans.keyring.no.master=true"
      fi
    '';
  };
}

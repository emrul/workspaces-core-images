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

  # Scoped security backports (currently perl CVE-2026-13221 -> exiftool).
  # Returns { retired, perl, exiftool }; self-retires once nixpkgs catches up.
  perlSecurity = import ./pkgs/perl/security-override.nix { inherit lib; } prev;

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

  # Kind A (override, vendored): OnlyOffice Desktop Editors pinned FORWARD of
  # nixpkgs (9.4.0 vs 9.1.0) with the bundled Qt 5.9.9 stripped — that copy
  # carries CVE-2023-51714 / CVE-2024-36048 (Critical) and upstream still ships
  # it in 9.4.0. nixpkgs hides the real derivation inside a buildFHSEnv, so the
  # file is vendored rather than overridden. REVERT to
  # nixpkgs#onlyoffice-desktopeditors when the condition in
  # pkgs/onlyoffice/derivation.nix's header holds.
  onlyoffice = import ./pkgs/onlyoffice/package.nix {
    inherit prev;
    pin = loadPin "onlyoffice" ./pkgs/onlyoffice;
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

  # Kind B (repackage artifact): kasm-session-runtime's MCP/CDP drive-session
  # binary. A base component like its neighbours above, not a catalog app --
  # baked into [base] (bin/nix-profiles.toml), present in every session,
  # inert until KASM_RUNTIME_SESSION_TOKEN is set. See package.nix's own doc
  # comment and kasm-session-runtime's docs/mcp-baked-in-delivery.md.
  kasm-session-runtime = import ./pkgs/kasm-session-runtime/package.nix {
    inherit prev;
    pin = loadPin "kasm-session-runtime" ./pkgs/kasm-session-runtime;
  };

  # Kind B (repackage artifact): the runtime's in-session sidebar -- web assets
  # for a second KasmVNC web root that kasm-setup materialises only when a
  # session sets KASM_VNC_PATH=/usr/share/kasmvnc-agent. Same release, same S3
  # prefix, pinned together with kasm-session-runtime. Files in the store
  # only; inert otherwise. See package.nix's doc comment.
  kasm-ai-runtime-sidebar = import ./pkgs/kasm-ai-runtime-sidebar/package.nix {
    inherit prev;
    pin = loadPin "kasm-ai-runtime-sidebar" ./pkgs/kasm-ai-runtime-sidebar;
  };

  # Kind B (source): wine-assess's wine fork for its packaged Windows apps
  # (wine-assess/docs/wine-nix-packaging.md). Upstream's tarball plus a vendored
  # patch series, built through nixpkgs' wineWow64 derivation; carries no
  # prefix -- every app profile ships its own. amd64 only. See package.nix.
  kasm-wine = import ./pkgs/kasm-wine/package.nix {
    inherit prev;
    pin = loadPin "kasm-wine" ./pkgs/kasm-wine;
  };

  # winetricks for the wine profile, minus its desktop entry: it is a tool the app
  # packages' bakes already ran, not something a session user launches, and the
  # Resolute desktop would otherwise show it next to the apps (seen 2026-09-18).
  winetricks-headless = prev.winetricks.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      rm -rf $out/share/applications $out/share/icons
    '';
  });

  # Wine apps from wine-assess: one attribute per pkgs/wine-apps/<slug>/pin.json,
  # all built by pkgs/wine-app/package.nix (the app's baked prefix as a fixed-output
  # fetch; see that file). Named wine-app-<slug>; each is a profile that requires the
  # wine profile the pin names.
  # (wineApps is spliced in below, after the attribute set, because a `//` inside a
  # rec-less set cannot refer to its own siblings: see the end of this file.)

  # Kind B (from scratch): Trace Labs OSINT tools absent from nixpkgs. Each is a
  # `{ prev }:` derivation pinned to an upstream tag. TraceLabs-unique (excluded
  # from the fat store); no committed pin.json — the tag is pinned in-package.
  # See design/tracelabs-osint-image.md §4.
  spiderfoot  = import ./pkgs/spiderfoot/package.nix  { inherit prev; };
  phoneinfoga = import ./pkgs/phoneinfoga/package.nix { inherit prev; };
  sublist3r   = import ./pkgs/sublist3r/package.nix   { inherit prev; };
  metagoofil  = import ./pkgs/metagoofil/package.nix  { inherit prev; };

  # Kind A (security backport, SCOPED): exiftool built against a perl carrying
  # the fix for CVE-2026-13221.
  #
  # Note what is NOT here: any rebinding of the top-level `perl` or `perl5`. That
  # would change perl as a build input across the tree (measured: 440+ rebuilds
  # including clang/LLVM/ffmpeg, which exhausted the build host's disk) to fix
  # packages whose only tie to perl is a `#!` line. exiftool is the sole runtime
  # consumer that COMPILES against the interpreter, so it is the sole package
  # rebound here — 33 rebuilds, everything else keeps its cached store paths.
  #
  # kasmvnc and xdg-utils are the other two runtime consumers and are handled by
  # VEX on non-reachability instead. Rationale and the assurance evidence:
  # pkgs/perl/security-override.nix and design/known_issues.md.
  #
  # `perlSecurity.perl` is exposed only so the base can bake the patched
  # interpreter if it ever needs to; it does not replace nixpkgs' perl.
  inherit (perlSecurity) exiftool;

  # Kind A (override): Maltego CE with the NetBeans keyring DISABLED. A Kasm
  # container has no secret-service (gnome-keyring/KWallet), so Maltego's
  # NetBeans platform falls back to master-password encryption and STALLS at
  # "loading modules" on first run. `-Dnetbeans.keyring.no.native` skips native
  # keyrings and `-Dnetbeans.keyring.no.master` skips the master-password
  # provider → the in-memory no-op provider (no prompt, no stall). Wrapping the
  # launcher (not editing the read-only store conf) survives nix-activate's shim
  # regeneration. TraceLabs-only (design/tracelabs-osint-image.md §2, runbook §4.4).
  #
  # Also pinned FORWARD of nixpkgs. nixpkgs ships 4.11.1 on every channel —
  # unstable and master included — and that build bundles undertow-core
  # 2.2.38.Final and bcprov-jdk18on 1.82, carrying CVE-2025-12543 and
  # CVE-2025-14813. Upstream 4.12.1 ships 2.2.39.Final and 1.84, which are
  # precisely the fixed versions, so the CVEs go away with the version rather
  # than with any patching of the bundle.
  #
  # Swapping the JARs in place was the alternative and is worse: bcprov is a
  # signed JCE provider, so only BouncyCastle's own artifact will load, it
  # appears in two NetBeans module directories, and NetBeans records a CRC per
  # file in update_tracking that would need rewriting to stay consistent.
  #
  # Revert to `prev.maltego` once nixpkgs catches up. Verified by listing the
  # bundled JAR manifests in the 4.12.1 zip before making the change.
  maltego-4-12-1 = prev.maltego.overrideAttrs (old: rec {
    version = "4.12.1";
    # The upstream derivation interpolates finalAttrs.version into the URL, so
    # the src must be restated to carry the matching hash. fetchzip hashes the
    # unpacked tree, not the archive.
    src = prev.fetchzip {
      url = "https://downloads.maltego.com/maltego-v4/linux/Maltego.v${version}.linux.zip";
      hash = "sha256-r9YS0Rg/8E0SMT9xbKkgBZc1u01H8hV3p+H1Xskfd4k=";
    };
  });

  maltego = prev.symlinkJoin {
    name = "maltego-nokeyring-${final.maltego-4-12-1.version}";
    paths = [ final.maltego-4-12-1 ];
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
// (
  let
    appsDir = ./pkgs/wine-apps;
    slugs = builtins.attrNames (lib.filterAttrs (n: t: t == "directory") (builtins.readDir appsDir));
  in
  lib.listToAttrs (map (slug: {
    name = "wine-app-${slug}";
    value = import ./pkgs/wine-app/package.nix {
      inherit prev final;
      pin = loadPin "wine-app-${slug}" (appsDir + "/${slug}");
    };
  }) slugs)
)

{
  description = "Kasm Workspaces — Nix app images PoC (nix2container)";

  # PoC / spike for design/nix. Builds the 5-app demo set
  # (chrome, chromium, vs-code, firefox, audacity) as OCI images with
  # nix2container. Two flavours:
  #
  #   .#<app>      .#fat       — bare images (no base). Used to MEASURE
  #                              cross-image layer dedup (see README).
  #   .#<app>-run  .#fat-run   — RUNNABLE: fromImage = nix-ubuntu
  #                              (kasm core + container-init + nix-activate),
  #                              plus a generated /nix/var/nix/profiles tree so
  #                              the existing activation wires apps into PATH and
  #                              the XFCE menu. Boots a KasmVNC desktop.
  #
  # KEY DESIGN POINT (M0 finding): nix2container's automatic `maxLayers` packing
  # does NOT dedup across images. Cross-image sharing comes from EXPLICIT layers
  # reused by every image: one shared `baseLayer` + one `appLayer` per app.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nix2container.url = "github:nlewo/nix2container";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nix2container, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # chrome + vs-code are unfree (real catalog need)
        };
        lib = pkgs.lib;
        n2c = nix2container.packages.${system}.nix2container;

        # ── Shared base closure (the design's `[base]`) — built once, reused ──
        basePkgs = with pkgs; [
          glibc openssl zlib libffi expat
          dbus alsa-lib fontconfig freetype
          nss nspr
          glib gtk3 pango cairo gdk-pixbuf atk at-spi2-core libxkbcommon
          libGL mesa
          xorg.libX11 xorg.libXext xorg.libXrender xorg.libXi xorg.libXrandr
          xorg.libXcomposite xorg.libXdamage xorg.libXfixes xorg.libxcb
        ];
        baseLayer = n2c.buildLayer { deps = basePkgs; };

        # The 5-app demo set. `exe` is the binary each image launches.
        apps = {
          chrome   = { pkg = pkgs.google-chrome; exe = "google-chrome-stable"; };
          chromium = { pkg = pkgs.chromium;      exe = "chromium"; };
          vscode   = { pkg = pkgs.vscode;        exe = "code"; };
          firefox  = { pkg = pkgs.firefox;       exe = "firefox"; };
          audacity = { pkg = pkgs.audacity;      exe = "audacity"; };
        };

        # One explicit per-app layer, defined ONCE and reused by per-app + fat +
        # runnable images so digests match => true cross-image dedup.
        appLayers = builtins.mapAttrs
          (name: { pkg, ... }: n2c.buildLayer { deps = [ pkg ]; layers = [ baseLayer ]; })
          apps;

        # ── GPU support (shared across runnable images) ──────────────────────
        # Nix VirtualGL (glibc-matched faker — the system /opt/VirtualGL faker
        # can't preload into a Nix binary) + Nix vulkan-loader (carries the
        # VK_KHR_surface/xcb WSI that chrome's bundled loader lacks, so
        # ANGLE-Vulkan reaches the real GPU instead of SwiftShader). Exposed at
        # /nix/var/nix/profiles/_gpu; /usr/local/bin/nix-gpu-run (from the base
        # nix-ubuntu image) references vglrun + libvulkan from there.
        gpuPkgs = with pkgs; [ virtualgl vulkan-loader ];
        gpuLayer = n2c.buildLayer { deps = gpuPkgs; layers = [ baseLayer ]; };
        gpuProfile = pkgs.buildEnv {
          name = "nix-profile-_gpu";
          paths = gpuPkgs;
          pathsToLink = [ "/bin" "/lib" ];
        };

        # ── dedup-proof images (no base image) ───────────────────────────────
        mkApp = name: { pkg, exe, ... }:
          n2c.buildImage {
            name = "nix-${name}";
            tag = "spike";
            layers = [ baseLayer appLayers.${name} ];
            config.Cmd = [ "${pkg}/bin/${exe}" ];
          };
        fat = n2c.buildImage {
          name = "nix-fat";
          tag = "spike";
          layers = [ baseLayer ] ++ builtins.attrValues appLayers;
          config.Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
        };
        appImages = builtins.mapAttrs mkApp apps;

        # ── runnable images: /nix profile layout for nix-activate ───────
        # A "profile" is a buildEnv symlink tree (bin/ + share/) like
        # `nix profile install` produces; activation reads <profile>/bin and
        # <profile>/share/applications/*.desktop.
        profiles = builtins.mapAttrs
          (name: { pkg, ... }: pkgs.buildEnv {
            name = "nix-profile-${name}";
            paths = [ pkg ];
            pathsToLink = [ "/bin" "/share" ];
          })
          apps;

        # _meta.json — schema read by nix-activate: {profiles:{<n>:{requires:[]}}}
        metaFor = subset: pkgs.writeText "nix-meta.json"
          (builtins.toJSON {
            profiles = builtins.mapAttrs (_: _: { ref = null; requires = [ ]; }) subset;
          });

        # /nix/var/nix/profiles/{<name> -> profile, _meta.json}; placed via
        # copyToRoot so it lands at the image's /nix/var/... (store paths the
        # symlinks target are carried by baseLayer + appLayers).
        nixVar = subset: pkgs.runCommand "nix-var" { } (''
          mkdir -p $out/nix/var/nix/profiles
          cp ${metaFor subset} $out/nix/var/nix/profiles/_meta.json
          ln -s ${gpuProfile} $out/nix/var/nix/profiles/_gpu
        '' + lib.concatStrings (lib.mapAttrsToList (n: _: ''
          ln -s ${profiles.${n}} $out/nix/var/nix/profiles/${n}
        '') subset));

        # Base = the nix-ubuntu image, pulled from the local registry via its
        # manifest (no global FOD hash needed). The manifest is a generated,
        # environment-specific artifact (gitignored — it pins YOUR locally-built
        # base), so it is NOT read from the flake source tree: a pure flake eval
        # only sees git-tracked/staged files, which forced a `git add -f` dance.
        # Instead take its absolute path from $NIX_UBUNTU_BASE_MANIFEST (exported
        # by the build wrapper) under `--impure`, falling back to a
        # staged/committed ./base-manifest.json. In pure eval getEnv returns ""
        # so the dedup-proof (no-base) outputs still evaluate.
        # Long-term: replace with n2c.pullImage + a committed digest once the
        # base lives in a real registry — see design/nix/LIMITATIONS.md.
        baseManifestEnv = builtins.getEnv "NIX_UBUNTU_BASE_MANIFEST";
        baseManifest =
          if baseManifestEnv != "" then (/. + baseManifestEnv)
          else if builtins.pathExists ./base-manifest.json then ./base-manifest.json
          else null;
        hasBase = baseManifest != null;
        baseImage = n2c.pullImageFromManifest {
          imageName = "nix-ubuntu";
          imageManifest = baseManifest;
          imageTag = "dev";
          tlsVerify = false;
          registryUrl = "localhost:5000";
        };

        # nix2container does NOT merge the base image's OCI config, so the
        # runnable images must restate the kasm-core runtime config
        # (entrypoint = container-init shim, env, ports). Captured from
        # `docker inspect localhost/nix-ubuntu:dev`.
        runConfig = {
          Entrypoint = [ "/usr/local/bin/kasm-entrypoint" ];
          Cmd = [ "--wait" ];
          User = "0";
          WorkingDir = "/home/kasm-user";
          ExposedPorts = { "4901/tcp" = { }; "5901/tcp" = { }; "6901/tcp" = { }; };
          Env = [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            "AUDIO_PORT=4901"
            "DEBIAN_FRONTEND=noninteractive"
            "DISPLAY=:1"
            "DISTRO=ubuntu"
            "GOMP_SPINCOUNT=0"
            "HOME=/home/kasm-user"
            "INST_SCRIPTS=/dockerstartup/install"
            "KASMVNC_AUTO_RECOVER=true"
            "KASM_VNC=1"
            "KASM_VNC_PATH=/usr/share/kasmvnc"
            "LANG=en_US.UTF-8"
            "LANGUAGE=en_US:en"
            "LC_ALL=en_US.UTF-8"
            "LD_LIBRARY_PATH=/opt/libjpeg-turbo/lib64/:/usr/local/lib/:/usr/lib/x86_64-linux-gnu:/usr/lib/i386-linux-gnu:/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
            "MAX_FRAME_RATE=24"
            "NO_VNC_PORT=6901"
            "OMP_WAIT_POLICY=PASSIVE"
            "PULSE_RUNTIME_PATH=/var/run/pulse"
            "SHELL=/bin/bash"
            "START_PULSEAUDIO=1"
            "STARTUPDIR=/dockerstartup"
            "START_XFCE4=1"
            "TERM=xterm"
            "VNC_COL_DEPTH=24"
            "VNCOPTIONS=-PreferBandwidth -DynamicQualityMin=4 -DynamicQualityMax=7 -DLP_ClipDelay=0"
            "VNC_PORT=5901"
            "VNC_PW=vncpassword"
            "VNC_RESOLUTION=1280x720"
            "VNC_VIEW_ONLY_PW=vncviewonlypassword"
            "TZ=Etc/UTC"
          ];
        };

        # Runnable image: restate core config, add explicit app layers + the
        # /nix profile tree that nix-activate reads.
        mkRun = name: spec: subset: n2c.buildImage {
          name = "nix-${name}-run";
          tag = "spike";
          fromImage = baseImage;
          # Bake NIX_APP_PROFILES so nix-activate wires the app(s) into the XFCE
          # menu + Desktop at boot. nix-activate has NO _meta.json fallback —
          # without this the image boots a bare desktop with nothing activated.
          # A runtime `-e NIX_APP_PROFILES=...` still overrides (the fat image is
          # meant to be selected that way). NOTE: this puts the app on the menu /
          # Desktop; it does NOT auto-launch it — a full single-app auto-launch
          # image (kiosk style) is the dockerfile-nix-angelfish pattern.
          config = runConfig // {
            Env = runConfig.Env
                  ++ [ "NIX_APP_PROFILES=${lib.concatStringsSep "," (builtins.attrNames subset)}" ];
          };
          layers = [ baseLayer gpuLayer ]
                   ++ builtins.attrValues (lib.getAttrs (builtins.attrNames subset) appLayers);
          copyToRoot = [ (nixVar subset) ];
        };
        runImages = lib.optionalAttrs hasBase (
          (lib.mapAttrs' (n: s: lib.nameValuePair "${n}-run" (mkRun n s { ${n} = s; })) apps)
          // { fat-run = mkRun "fat" null apps; }
        );
      in {
        packages = appImages // runImages // { inherit fat; default = fat; };
      });
}

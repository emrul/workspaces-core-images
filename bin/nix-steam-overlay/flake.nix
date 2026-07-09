{
  description = "Steam with VirtualGL inside its FHS sandbox: headless GLX for the 32-bit VGUI2 client";

  # Pin to the SAME nixpkgs rev the rest of the build resolves to (mirrors
  # bin/nix-gpu-overlay). This is what makes the fix correct: steam AND the
  # VirtualGL faker are then built from ONE nixpkgs, so the faker's glibc matches
  # steam's FHS glibc EXACTLY. The 2.42-vs-2.40 clash we hit came from version
  # skew between the pinned _gpu overlay and the floating `nixpkgs#steam` ref;
  # rebuilding steam here from the pinned rev removes it by construction. When
  # [nixpkgs].ref (bin/nix-profiles.toml) advances, re-pin this in the same change
  # (nix flake update) so faker/steam/base stay on one glibc.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d407951447dcd00442e97087bf374aad70c04cea";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];   # steam is amd64-only (see nix-profiles.toml)
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;   # steam is unfree
          };

          # Steam's client is a hybrid: the modern UI is 64-bit CEF
          # (steamwebhelper), but the top-level client process is the legacy
          # 32-bit VGUI2 shell (ubuntu12_32/steam). VGUI2 HARD-REQUIRES a GLX
          # visual at startup (glXChooseVisual → fatal assert if none), and on
          # KasmVNC's headless Xvnc the only source of a GLX visual is VirtualGL.
          # nix-launch's chromium-only GPU path never reaches steam, and a
          # host/system VGL faker can't be injected from outside the FHS (its
          # libGL/glibc deps aren't on the nix launcher's path). So VirtualGL must
          # live INSIDE the FHS, glibc-matched — which is exactly what this does.
          steamVgl = pkgs.steam.override {
            # 64-bit vglrun + faker into the FHS (targetPkgs).
            extraPkgs = p: [ p.virtualgl ];

            # BOTH arches of the faker into the FHS (multiPkgs). The 32-bit faker
            # is the piece the 32-bit VGUI2 client needs; steam's FHS is already
            # multiArch and ships 32-bit libGL, so the faker's deps resolve inside.
            # `virtualglLib` explicitly: nixpkgs keeps the faker .so in that
            # package (the `virtualgl` wrapper only carries vglrun), so we must
            # list it or the 64-bit /usr/lib faker is absent. multiPkgs builds
            # both i686 + x86_64 → faker lands in BOTH /usr/lib and /usr/lib32.
            extraLibraries = p: [ p.virtualgl p.virtualglLib ];

            # Run inside the FHS (sourced before steam starts): preload the faker
            # by SONAME so ld.so auto-selects 32/64-bit per process, and point VGL
            # at its EGL backend (the allocated GPU when present via KASM_EGL_CARD,
            # else mesa/swrast — enough to satisfy glXChooseVisual for the client
            # UI). libdlfaker is needed for VGL's dlopen interposition.
            extraProfile = ''
              export VGL_DISPLAY="''${VGL_DISPLAY:-egl}"
              export LD_PRELOAD="libvglfaker.so libdlfaker.so''${LD_PRELOAD:+ $LD_PRELOAD}"
            '';
          };
        in {
          steam-vgl = steamVgl;
          default = steamVgl;
        });
    };
}

{
  description = "Trimmed VirtualGL: drop FLTK vglconfig GUI so gcc/binutils/python3 leave the closure";

  # Pinned to the current HEAD of nixos-25.05 — which is what bin/nix-profiles.toml
  # [nixpkgs].ref (the floating branch) resolves to today. The trimmed VirtualGL's
  # deps (glibc, libjpeg-turbo, libglvnd, …) must match the rest of the build or it
  # ships a second glibc, so when the branch advances, re-pin this to the new HEAD
  # (nix flake update) in the same change. See design/nix-dedup-gap.md.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d407951447dcd00442e97087bf374aad70c04cea";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;

          # Trim the real derivation (virtualglLib).
          virtualglLibMin = pkgs.virtualglLib.overrideAttrs (old: {
            pname = "virtualgl-lib-min";

            # FLTK is only needed by the optional `vglconfig` GUI. It drags in the
            # full gcc toolchain: fltk/bin/fltk-config embeds CC=<gcc-wrapper>/bin/gcc,
            # pulling gcc + binutils + python3 into the runtime closure.
            #
            # Drop fltk, but add libX11 explicitly: it used to reach the build via
            # fltk's propagated inputs, and FindX11 needs X11_X11_LIB for the fbx target.
            buildInputs = builtins.filter
              (p: !(lib.hasPrefix "fltk" (lib.getName p)))
              old.buildInputs
              ++ [ pkgs.xorg.libX11 ];

            # -DVGL_SYSTEMFLTK is meaningless once we patch the FLTK block out.
            cmakeFlags = builtins.filter (f: f != "-DVGL_SYSTEMFLTK=1") old.cmakeFlags;

            # server/CMakeLists.txt always builds `vglconfig` (no cmake gate exists)
            # and links it against FLTK. We only ever run `vglrun -d egl <app>`, so
            # strip the FLTK detection block and the vglconfig target. The faker libs
            # keep vglconfigLauncher.cpp (which needs no FLTK), so vglrun is unaffected.
            postPatch = old.postPatch + ''
              # FindFLTK used to pull in find_package(X11) transitively; drop the
              # FLTK block but restore explicit X11 discovery (needed for X11_X11_LIB).
              sed -i "/^if(VGL_SYSTEMFLTK)/,/^endif()/d" server/CMakeLists.txt
              sed -i "1i find_package(X11 REQUIRED)" server/CMakeLists.txt
              sed -i "/FLTK_INCLUDE_DIR/d"                server/CMakeLists.txt
              sed -i "/^add_executable(vglconfig/d"       server/CMakeLists.txt
              sed -i "/target_link_libraries(vglconfig/d" server/CMakeLists.txt
              sed -i "/^install(TARGETS vglconfig/d"      server/CMakeLists.txt
              sed -i "/set_property(SOURCE vglconfig.cpp/,+1d" server/CMakeLists.txt
            '';
          });

          # Re-wrap with the trimmed lib. On x86_64 the stock virtualgl pulls in
          # pkgsi686Linux.virtualglLib (usei686VirtualglLib defaults true) — a full
          # i686 gcc/FLTK closure just for 32-bit .vglrun.vars32 support. We only run
          # 64-bit EGL apps, so disable it.
          virtualglMin = pkgs.virtualgl.override {
            virtualglLib = virtualglLibMin;
            usei686VirtualglLib = false;
          };
        in {
          virtualgl-min = virtualglMin;
          default = virtualglMin;
        });
    };
}

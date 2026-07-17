{
  description = "Trimmed VirtualGL: drop FLTK vglconfig GUI so gcc/binutils/python3 leave the closure";

  # Default pin only — the BUILD ALWAYS overrides this input to its pinned base
  # rev (build-nix-store-volume _gpu section, --override-input nixpkgs), so
  # vglrun/faker are glibc-matched to the apps they LD_PRELOAD into. The old
  # manual re-pin scheme drifted to an unstable rev and shipped a glibc-2.42
  # faker next to 2.40 apps — every GPU launch crashed with
  # "GLIBC_ABI_DT_X86_64_PLT not found" (testbench/blender 2026-07-17).
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
          # pkgsi686Linux.virtualglLib — a full i686 gcc/FLTK closure just for
          # 32-bit .vglrun.vars32 support. We only run 64-bit EGL apps, so
          # disable it. The knob is `usei686VirtualglLib` on unstable and
          # `virtualglLib32` on nixos-25.05 — pick whichever this nixpkgs has
          # (the build --override-input's nixpkgs to its pinned base rev so
          # vglrun is glibc-matched to the apps it LD_PRELOADs into; a NEWER
          # faker in an OLDER process dies with GLIBC_ABI_DT_X86_64_PLT).
          overrideArgs = pkgs.virtualgl.override.__functionArgs or {};
          no32 =
            if overrideArgs ? usei686VirtualglLib then { usei686VirtualglLib = false; }
            else if overrideArgs ? virtualglLib32 then { virtualglLib32 = null; }
            else {};
          virtualglMin = pkgs.virtualgl.override ({
            virtualglLib = virtualglLibMin;
          } // no32);
        in {
          virtualgl-min = virtualglMin;
          default = virtualglMin;
        });
    };
}

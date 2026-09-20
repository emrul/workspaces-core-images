# wine-app -- one generic derivation for every packaged Windows app from wine-assess
# (wine-assess/docs/wine-nix-packaging.md). Each app is a pin under pkgs/wine-apps/
# <slug>/pin.json; overlay.nix instantiates this once per pin as `wine-app-<slug>`.
#
# What a package is: the app's whole baked wine prefix (hives, dosdevices, drive_c with
# the app AND its runtimes -- dotnet, vcrun, whatever winetricks put there), archived by
# wine-assess's containers/wine-app/export-prefix.sh from the prefix its clean-room
# verdict ran in, fetched here as a fixed-output tarball. Prefix-global state (reported
# Windows version, dotnet flavour, DLL overrides) differs per app, so prefixes are never
# shared or merged: a workspace with several Wine apps carries several prefixes.
#
# No wine runs in this build. Wine runs at first launch: the store is read-only and
# wine writes to its prefix, so the launcher materialises $HOME/.wine-apps/<slug> --
# hives, dosdevices, users and ProgramData copied (small), Program Files and the
# windows tree symlinked into the store entry by entry (so Temp can be a real dir),
# anything the pin lists in copy_on_start copied instead (apps that write into their
# own install dir). .update-timestamp stays `disable` so the store wine, whose wine.inf
# mtime is the epoch, never runs wineboot -u over it.
#
# The launcher uses the image's own coreutils (cp --no-preserve=mode is GNU, which every
# Kasm base has) rather than a store coreutils: referencing prev.coreutils put a second
# coreutils build into every app's layer, next to the one already in the wine closure.
#
# pin.json: { slug, name, version, url, hash, size, wine, entrypoint, copy_on_start,
#             verbs, source } -- wine names the overlay package to run under
# ("kasm-wine" today); the app profile's `requires` must name the matching profile so
# the wine closure is subtracted from the app's layer.
{ prev, final, pin }:
let
  lib = prev.lib;
  slug = pin.slug;
  wine = final.${pin.wine};
  mesa = prev.mesa;
  copyOnStart = pin.copy_on_start or [ ];
  appDir = "share/wine-apps/${slug}";
  launcher = prev.writeShellScript "wine-app-${slug}" ''
    set -eu
    SRC=@out@/${appDir}/prefix
    ROOT="''${WINE_APPS_HOME:-$HOME/.wine-apps}"
    DST="$ROOT/${slug}"
    if [ ! -e "$DST/.materialised" ]; then
      rm -rf "$DST.partial"
      mkdir -p "$DST.partial/drive_c" "$DST.partial/dosdevices"
      cp --no-preserve=mode "$SRC"/*.reg "$DST.partial/"
      ln -s ../drive_c "$DST.partial/dosdevices/c:"
      ln -s / "$DST.partial/dosdevices/z:"
      for e in "$SRC"/drive_c/*; do
        n="$(basename "$e")"
        case "$n" in
          users|ProgramData) cp -r --no-preserve=mode "$e" "$DST.partial/drive_c/$n" ;;
          windows)
            mkdir "$DST.partial/drive_c/windows"
            for w in "$e"/*; do ln -s "$w" "$DST.partial/drive_c/windows/$(basename "$w")"; done
            rm -f "$DST.partial/drive_c/windows/Temp"; mkdir -p "$DST.partial/drive_c/windows/Temp" ;;
          *)
            if printf '%s\n' ${lib.escapeShellArgs copyOnStart} | grep -qxF -- "$n"; then
              cp -r --no-preserve=mode "$e" "$DST.partial/drive_c/$n"
            else
              ln -s "$e" "$DST.partial/drive_c/$n"
            fi ;;
        esac
      done
      printf 'disable\n' > "$DST.partial/.update-timestamp"
      printf '%s\n' "@out@" > "$DST.partial/.materialised"
      mv "$DST.partial" "$DST"
    fi
    export WINEPREFIX="$DST"
    export WINEDEBUG="''${WINEDEBUG:--all}"
    # Graphics. Two cases.
    #
    # GPU allocated (Kasm set KASM_EGL_CARD/KASM_RENDERD and the session owns the
    # device nodes): kasm-nix's nix-gpu-run has ALREADY staged the NVIDIA vendor libs,
    # pointed the Vulkan loader at the NVIDIA ICD and wrapped us in `vglrun -d egl` —
    # the same path that gives Chromium its real GPU. Touch nothing here: prepending
    # software mesa to LD_LIBRARY_PATH shadows the vendor stack and the app dies
    # before DXVK ever creates a device (measured on linbox 2026-09-20; removing just
    # that one line was the difference between no window and "Found device: NVIDIA
    # GeForce RTX 3090"). See wine-assess docs/gpu-acceleration.md.
    #
    # No GPU: the store wine's glvnd and Vulkan loader cannot use the host's mesa (a
    # different glibc; seen in a Kasm session as "couldn't initialize OpenGL" and DXVK
    # "Failed to create Vulkan instance"), so default to nixpkgs mesa's software stack:
    # llvmpipe for GL, lavapipe for Vulkan. kasm-nix's nix-launch has already cleared
    # the image's LD_LIBRARY_PATH before we get here.
    if [ -x /usr/local/bin/nix-gpu-run ] && /usr/local/bin/nix-gpu-run --available; then
      :
    else
      export VK_ICD_FILENAMES="''${VK_ICD_FILENAMES:-${mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json}"
      export __EGL_VENDOR_LIBRARY_DIRS="''${__EGL_VENDOR_LIBRARY_DIRS:-${mesa}/share/glvnd/egl_vendor.d}"
      export LIBGL_DRIVERS_PATH="''${LIBGL_DRIVERS_PATH:-${mesa}/lib/dri}"
      export LD_LIBRARY_PATH="${mesa}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    exec ${wine}/bin/wine ${lib.escapeShellArg pin.entrypoint} "$@"
  '';
in
prev.stdenvNoCC.mkDerivation {
  pname = "wine-app-${slug}";
  version = pin.version;
  src = prev.fetchurl {
    url = pin.url;
    hash = pin.hash;
  };
  nativeBuildInputs = [ prev.zstd prev.icoutils prev.imagemagick ];  # icoutils: wrestool only
  dontUnpack = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/${appDir}/prefix $out/bin $out/share/applications
    tar --zstd -xf $src -C $out/${appDir}/prefix
    test -f $out/${appDir}/prefix/system.reg
    test -d $out/${appDir}/prefix/drive_c
    sed "s#@out@#$out#g" ${launcher} > $out/bin/wine-app-${slug}
    chmod 755 $out/bin/wine-app-${slug}
    cp ${prev.writeText "app.json" (builtins.toJSON pin)} $out/${appDir}/app.json

    # The app's own icon, from the entrypoint's PE resources (wrestool for the icon
    # group, ImageMagick for the frames): the widest frame, resized into hicolor PNGs. Falls back to
    # the generic wine glass if the exe carries none. The entrypoint is a Windows
    # path under C:, mapped onto drive_c.
    exe="$out/${appDir}/prefix/drive_c/$(printf '%s' ${lib.escapeShellArg pin.entrypoint} | sed -e 's#^[A-Za-z]:\\##' -e 's#\\#/#g')"
    icon=wine
    if [ -f "$exe" ]; then
      # (explicit finds, not globs: the stdenv builder runs with nullglob, so an
      # unmatched icons/*.png would silently become a listing of the build dir)
      mkdir -p icons
      wrestool -x -t14 -o icons "$exe" 2>/dev/null || true
      first="$(find icons -maxdepth 1 -name '*.ico' | sort | head -n1)"
      if [ -n "$first" ]; then
        # ImageMagick reads the ICO's frames itself (icotool rejects some layouts,
        # e.g. Affinity's, over a bitmap size check); take the widest frame.
        idx="$(magick identify -format '%p %w\n' "$first" 2>/dev/null | sort -k2 -rn | head -n1 | cut -d' ' -f1)"
        if [ -n "$idx" ]; then
          for size in 256 128 64 48 32; do
            mkdir -p "$out/share/icons/hicolor/''${size}x''${size}/apps"
            magick "$first[$idx]" -resize "''${size}x''${size}" "$out/share/icons/hicolor/''${size}x''${size}/apps/wine-app-${slug}.png"
          done
          icon=wine-app-${slug}
        fi
      fi
    fi
    echo "icon: $icon"

    exeBase="$(basename "$exe" | tr 'A-Z' 'a-z')"
    cat > $out/share/applications/wine-app-${slug}.desktop <<DESKTOP
    [Desktop Entry]
    Type=Application
    Name=${pin.name}
    Comment=${pin.name} (Windows app under wine, packaged by wine-assess)
    Exec=wine-app-${slug} %F
    Icon=$icon
    Terminal=false
    Categories=Wine;
    StartupWMClass=$exeBase
    DESKTOP
    runHook postInstall
  '';
  passthru = {
    inherit pin wine;
  };
  meta = {
    description = "${pin.name}: a Windows app with its baked wine prefix, run under ${pin.wine}";
    platforms = [ "x86_64-linux" ];
  };
}

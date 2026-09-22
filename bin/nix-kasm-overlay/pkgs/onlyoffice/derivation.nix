# OnlyOffice Desktop Editors — vendored from nixpkgs (nixos-26.05,
# pkgs/by-name/on/onlyoffice-desktopeditors/package.nix) with two changes,
# both marked "KASM:" below:
#
#   1. version + src come from ../onlyoffice/pin.json (Kind A override):
#      upstream is at 9.4.0 while nixpkgs stable and unstable still package
#      9.1.0 (checked 2026-09-22).
#   2. the bundled Qt is STRIPPED and the editor is bound to nixpkgs' Qt 5.15
#      instead. Upstream's .deb — 9.4.0 included — ships its own Qt 5.9.9
#      (libQt5Core.so.5: "Qt 5.9.9 … by GCC 4.8.4"), which carries
#      CVE-2023-51714 and CVE-2024-36048 (Critical, fixed in 5.15.17). The
#      nixpkgs derivation lists qt5 only for autoPatchelf; the bundled copy is
#      what loads. Removing it makes autoPatchelf resolve the editor's Qt
#      NEEDED entries against qt5.qtbase/qtsvg/qtx11extras/qtmultimedia from
#      nixpkgs. Qt guarantees binary compatibility within the 5 series, so a
#      binary built against 5.9 runs on 5.15; the bundled 5.9 plugin
#      directories go too, and QT_PLUGIN_PATH points at nixpkgs' plugins.
#
# Vendored rather than overrideAttrs'd because nixpkgs wraps the real
# derivation in a buildFHSEnv and does not expose it: there is no attribute
# to override version/src/installPhase on.
#
# REVERT to nixpkgs#onlyoffice-desktopeditors (bin/nix-profiles.toml
# [profiles.onlyoffice]) once BOTH hold: nixpkgs packages a version at or past
# the one pinned here, AND either upstream ships a Qt >= 5.15.17 or nixpkgs'
# derivation stops using the bundled Qt. Until then this file must be
# re-synced with nixpkgs' by hand when their packaging changes.
{
  pin,
  stdenv,
  lib,
  fetchurl,
  buildFHSEnv,
  # Alphabetic ordering below
  alsa-lib,
  at-spi2-atk,
  atk,
  autoPatchelfHook,
  cairo,
  curl,
  dbus,
  dconf,
  dpkg,
  fontconfig,
  gcc-unwrapped,
  gdk-pixbuf,
  glib,
  glibc,
  gsettings-desktop-schemas,
  gst_all_1,
  gtk2,
  gtk3,
  libnotify,
  libpulseaudio,
  libudev0-shim,
  libdrm,
  makeWrapper,
  libgbm,
  noto-fonts-cjk-sans,
  nspr,
  nss,
  pulseaudio,
  qt5,
  wrapGAppsHook3,
  xkeyboard_config,
  libxtst,
  libxscrnsaver,
  libxrender,
  libxrandr,
  libxi,
  libxfixes,
  libxext,
  libxdamage,
  libxcursor,
  libxcomposite,
  libx11,
  libxcb,
}:
let

  # Note on fonts:
  #
  # OnlyOffice does not distribute unfree fonts, but makes it easy to pick up
  # any fonts you install. See:
  #
  # * https://helpcenter.onlyoffice.com/en/installation/docs-community-install-fonts-linux.aspx
  # * https://www.onlyoffice.com/blog/2020/04/how-to-add-new-fonts-to-onlyoffice-desktop-editors/
  #
  # As recommended there, you should download
  #
  #     arial.ttf, calibri.ttf, cour.ttf, symbol.ttf, times.ttf, wingding.ttf
  #
  # into `~/.local/share/fonts/`, otherwise the default template fonts, and
  # things like bullet points, will not look as expected.

  # TODO: Find out which of these fonts we'd be allowed to distribute along
  #       with this package, or how to make this easier for users otherwise.

  # KASM: nixpkgs' Qt 5.15 plugins, in place of the stripped bundled 5.9 ones.
  qtPluginPath = lib.concatMapStringsSep ":" (p: "${p.bin or p}/${qt5.qtbase.qtPluginPrefix}") [
    qt5.qtbase
    qt5.qtsvg
    qt5.qtmultimedia
    qt5.qtdeclarative
  ];

  runtimeLibs = lib.makeLibraryPath [
    curl
    glibc
    gcc-unwrapped.lib
    libudev0-shim
    pulseaudio
  ];

  derivation = stdenv.mkDerivation rec {
    pname = "onlyoffice-desktopeditors";
    # KASM: version + hash from pin.json
    version = pin.version;
    minor = null;
    src = fetchurl {
      url = "https://github.com/ONLYOFFICE/DesktopEditors/releases/download/v${version}/onlyoffice-desktopeditors_amd64.deb";
      hash = pin.hashes.x86_64-linux;
    };

    nativeBuildInputs = [
      autoPatchelfHook
      dpkg
      makeWrapper
      wrapGAppsHook3
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      atk
      cairo
      dbus
      dconf
      fontconfig
      gdk-pixbuf
      glib
      gsettings-desktop-schemas
      gst_all_1.gst-plugins-base
      gst_all_1.gstreamer
      gtk2
      gtk3
      libnotify
      libpulseaudio
      libdrm
      nspr
      nss
      libgbm
      qt5.qtbase
      qt5.qtdeclarative
      qt5.qtsvg
      qt5.qtwayland
      # KASM: the bundled Qt is removed below, so every Qt module the editor
      # links must be satisfiable from nixpkgs (autoPatchelf fails the build
      # otherwise — which is the point: no silent fallback to Qt 5.9).
      qt5.qtx11extras
      qt5.qtmultimedia
      libx11
      libxcb
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxrandr
      libxrender
      libxscrnsaver
      libxtst
    ];

    dontWrapQtApps = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/{bin,lib,share}

      mv usr/bin/* $out/bin
      mv usr/share/* $out/share/
      mv opt/onlyoffice/desktopeditors $out/share

      for f in $out/share/desktopeditors/asc-de-*.png; do
        size=$(basename "$f" ".png" | cut -d"-" -f3)
        res="''${size}x''${size}"
        mkdir -pv "$out/share/icons/hicolor/$res/apps"
        ln -s "$f" "$out/share/icons/hicolor/$res/apps/onlyoffice-desktopeditors.png"
      done;

      substituteInPlace $out/bin/onlyoffice-desktopeditors \
        --replace-fail "/opt/onlyoffice/" "$out/share/"

      ln -s $out/share/desktopeditors/DesktopEditors $out/bin/DesktopEditors

      # KASM: strip the bundled Qt 5.9.9 (CVE-2023-51714, CVE-2024-36048) and
      # its plugin directories; the editor binds to nixpkgs' Qt 5.15 instead.
      # Everything else in the bundle (CEF, ICU 52 for the document core,
      # SwiftShader, the converter) stays.
      rm -v $out/share/desktopeditors/libQt5*.so.5
      rm -v $out/share/desktopeditors/libqgsttools_p.so*
      for d in bearer iconengines imageformats mediaservice platforminputcontexts \
               platforms platformthemes playlistformats printsupport \
               xcbglintegrations; do
        rm -rv "$out/share/desktopeditors/$d"
      done
      if ls $out/share/desktopeditors/libQt5* >/dev/null 2>&1; then
        echo "bundled Qt still present after strip" >&2; exit 1
      fi

      runHook postInstall
    '';

    preFixup = ''
      gappsWrapperArgs+=(
        --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
        --set QT_XKB_CONFIG_ROOT "${xkeyboard_config}/share/X11/xkb" \
        --set QTCOMPOSE "${libx11.out}/share/X11/locale" \
        --set QT_QPA_PLATFORM "xcb" \
        --prefix QT_PLUGIN_PATH : "${qtPluginPath}"
        # KASM: QT_PLUGIN_PATH replaces the stripped bundled plugin dirs.
        # xcb stays the platform: KasmVNC is an X server (see launch).
      )
    '';
  };

in

# In order to download plugins, OnlyOffice uses /usr/bin/curl so we have to wrap it.
# Curl still needs to be in runtimeLibs because the library is used directly in other parts of the code.
# Fonts are also discovered by looking in /usr/share/fonts, so adding fonts to targetPkgs will include them
buildFHSEnv {
  inherit (derivation) pname version;

  targetPkgs = pkgs': [
    curl
    derivation
    noto-fonts-cjk-sans
  ];

  runScript = "/bin/onlyoffice-desktopeditors";

  extraInstallCommands = ''
    mkdir -p $out/share
    ln -s ${derivation}/share/icons $out/share
    cp -r ${derivation}/share/applications $out/share
    substituteInPlace $out/share/applications/onlyoffice-desktopeditors.desktop \
        --replace-fail "/usr/bin/onlyoffice-desktopeditors" "$out/bin/onlyoffice-desktopeditors"
  '';

  # KASM: no nixpkgs updateScript here; the pin is bumped by hand (see
  # manifest.toml) until the github-releases discoverer exists.

  meta = {
    description = "Office suite that combines text, spreadsheet and presentation editors allowing to create, view and edit local documents";
    homepage = "https://www.onlyoffice.com/";
    downloadPage = "https://github.com/ONLYOFFICE/DesktopEditors/releases";
    changelog = "https://github.com/ONLYOFFICE/DesktopEditors/blob/master/CHANGELOG.md";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    license = lib.licenses.agpl3Plus;
    maintainers = with lib.maintainers; [
      nh2
      gtrunsec
    ];
  };
}

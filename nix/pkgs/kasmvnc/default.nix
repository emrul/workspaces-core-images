# KasmVNC, repackaged from Kasm's prebuilt .deb (Option A — binary
# repackaging). See docs/nix-packaging-apps.md for the why and the
# alternative (Option B — build from source).
#
# This is the Nix analogue of src/ubuntu/install/kasm_vnc/install_kasm_vnc.sh,
# but the 200 lines of per-distro `if [[ DISTRO == ... ]]` collapse to a
# single derivation: Nix supplies every shared library from the store, so
# the result runs identically on any distro the nix-ubuntu image is based on.
#
# Update flow: bump `version` + `commit`, set the two hashes to
# lib.fakeHash, run `nix build`, copy the real hashes from the error.

{ lib
, stdenv
, fetchurl
, dpkg
, autoPatchelfHook
, makeWrapper
# ── link-time deps (mirror the .deb's `Depends:` ELF libs) ──
# Ubuntu's libcrypt1 is the old soname libcrypt.so.1; nixpkgs' default
# libxcrypt ships libcrypt.so.2, so use the -legacy compat output.
, libxcrypt-legacy
, freetype
, mesa            # libgbm
, libGL
, pixman
, libpng
, openssl
, zlib
, libunwind
, systemdLibs     # libsystemd0
, xorg
# ── run-time deps (perl interpreter + modules + X helpers on PATH) ──
, perl
, xkeyboard_config
, xkbcomp
, xauth
, procps
, hostname
# Override to build a feature-branch / dev artifact instead of the pinned
# release. Mirrors install_kasm_vnc.sh's KASMVNC_VER / BRANCH / COMMIT_ID.
# For a quick dev build where you don't know the hash yet, set the relevant
# arch hash to lib.fakeHash, run `nix build`, and copy the real hash from the
# error. See docs/nix-packaging-apps.md ("Dev / feature-branch builds").
, source ? {
    version = "1.5.0";
    commit  = "17265facc40ab50db5740cdf0d12c61173edafc9";
    branch  = "release";   # "release" => filename is just <version> (no suffix)
    hashes  = {
      amd64 = "sha256-9Zn+AuIXW5gXthZfdKXSvr3HMRjd6Rgbo0EJY77Xrh4=";
      arm64 = "sha256-yRmc9HUyCL+2n9AWqXgCQr6/xDNwzDjJfWHpCjx4PgQ=";
    };
  }
}:

let
  inherit (source) version commit branch hashes;

  # arch token used in the S3 artifact filename.
  debArch = {
    x86_64-linux = "amd64";
    aarch64-linux = "arm64";
  }.${stdenv.hostPlatform.system}
    or (throw "kasmvnc: unsupported system ${stdenv.hostPlatform.system}");

  # Same naming logic as install_kasm_vnc.sh: a release artifact is named
  # just <version>; a feature-branch artifact appends _<branch>_<commit6>.
  commitShort = builtins.substring 0 6 commit;
  verNamePart = if branch == "release"
                then version
                else "${version}_${branch}_${commitShort}";

  src = fetchurl {
    url = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasmvnc/${commit}/kasmvncserver_noble_${verNamePart}_${debArch}.deb";
    hash = hashes.${debArch};
  };

  # Perl modules the kasmvncserver script `use`s (from the .deb Depends:).
  # withPackages builds a perl whose @INC already includes these modules
  # AND their transitive deps (e.g. List::MoreUtils pulls Exporter::Tiny),
  # which a bare makePerlPath would miss.
  perlEnv = perl.withPackages (p: with p; [
    Switch
    YAMLTiny
    HashMergeSimple
    ListMoreUtils
    TryTiny
    DateTime
    DateTimeTimeZone
  ]);

  # X helpers the server shells out to at runtime.
  runtimePath = lib.makeBinPath [ xkbcomp xauth procps hostname ];
in
stdenv.mkDerivation {
  pname = "kasmvncserver";
  inherit version src;

  nativeBuildInputs = [ dpkg autoPatchelfHook makeWrapper ];

  # These replace every apt/dnf/apk/zypper install line in the bash
  # script. autoPatchelfHook rewrites each ELF's interpreter + RPATH to
  # resolve against exactly these store paths.
  buildInputs = [
    stdenv.cc.cc.lib   # libgcc_s, libstdc++
    libxcrypt-legacy
    freetype
    mesa
    libGL
    pixman
    libpng
    openssl
    zlib
    libunwind
    systemdLibs
    xorg.libX11
    xorg.libXau
    xorg.libXcursor
    xorg.libXdmcp
    xorg.libXext
    xorg.libXfixes
    xorg.libXfont2
    xorg.libXrandr
    xorg.libxshmfence
    xorg.libXtst
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a usr/. "$out/"
    [ -d etc ] && cp -a etc "$out/etc"

    # The .deb's postinst registers generic-named aliases via
    # update-alternatives (strip the "kasm" prefix): Xkasmvnc->Xvnc,
    # kasmvncpasswd->vncpasswd, etc. The perl server invokes those
    # generic names ($exedir."Xvnc"), so recreate the symlinks here.
    for kasm_command in kasmvncserver kasmvncpasswd kasmvncconfig Xkasmvnc kasmxproxy; do
      generic_command="''${kasm_command/kasm/}"
      ln -s "$out/bin/$kasm_command" "$out/bin/$generic_command"
    done

    # The .deb's perl scripts carry a literal `#!/usr/bin/perl` shebang,
    # which only resolves if the base image happens to ship perl. Repoint
    # it at the Nix perl so the package is self-contained on any distro.
    for f in "$out"/bin/*; do
      if head -c2 "$f" | grep -q '#!' && head -1 "$f" | grep -q perl; then
        substituteInPlace "$f" \
          --replace-quiet "#!/usr/bin/perl" "#!${perlEnv}/bin/perl" \
          --replace-quiet "#!/usr/bin/env perl" "#!${perlEnv}/bin/perl"
      fi
    done

    # KasmVNC's perl scripts resolve KASM_VNC_PATH-style assets relative
    # to /usr/share/kasmvnc; keep the layout but anchor under $out.
    # The perl entrypoint needs the perl interpreter + modules visible,
    # and xkbcomp/xauth/procps on PATH.
    for bin in kasmvncserver; do
      wrapProgram "$out/bin/$bin" \
        --prefix PATH : "${perlEnv}/bin:$out/bin:${runtimePath}" \
        --prefix PERL5LIB : "$out/share/perl5" \
        --set-default XKB_BINDIR "${xkbcomp}/bin" \
        --set-default XKB_CONFIG_ROOT "${xkeyboard_config}/share/X11/xkb"
    done

    runHook postInstall
  '';

  # The .deb ships systemd units + manpages we don't need at runtime;
  # autoPatchelf only cares about the ELF binaries under bin/ and lib/.
  dontStrip = true;

  meta = {
    description = "KasmVNC server (repackaged from Kasm prebuilt .deb)";
    homepage = "https://github.com/kasmtech/KasmVNC";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

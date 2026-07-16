# KasmVNC (Kind B) — repackage Kasm's prebuilt KasmVNC .deb as a Nix package.
#
# Goal: a distro-independent Nix build of the KasmVNC server so the runtime base
# no longer needs a per-distro .deb/.rpm/.apk — unblocking Ubuntu Resolute (26.04,
# which has no published KasmVNC build) and every future distro, and thinning the
# base toward distro-independence. First step of moving Kasm services into Nix.
#
# APPROACH: KasmVNC source is internal (not on public GitHub), but Kasm publishes
# the built artifacts to a PUBLIC S3 bucket. So — exactly like nixpkgs' google-chrome
# repackages Google's .deb — we fetch the prebuilt KasmVNC .deb and re-link it
# against Nix libraries with autoPatchelfHook. The .deb is built per-distro, but
# autoPatchelf discards its system-lib links and rebinds to the Nix closure, so a
# single build (from the `noble` .deb) runs on ANY host distro. URL is built from
# the same vars as src/ubuntu/install/kasm_vnc/install_kasm_vnc.sh
# (COMMIT_ID / BRANCH / KASMVNC_VER → KASM_VER_NAME_PART).
#
# ITERATION on .140 (`nix build`):
#   [ ] src hash — fill from the first build (pin.hash is lib.fakeHash now).
#   [ ] autoPatchelf will list any missing .so for Xkasmvnc/kasmxproxy/… — add the
#       provider to buildInputs and re-run until clean.
#   [ ] confirm the perl `kasmvncserver` launcher runs (PERL5LIB + X helpers).
{ prev, pin }:

let
  inherit (prev) lib stdenv fetchurl autoPatchelfHook dpkg makeWrapper;
  short = builtins.substring 0 6 pin.commit_id;
  # Matches install_kasm_vnc.sh: release → bare version; otherwise VER_BRANCH_SHORT6.
  verPart = if pin.branch == "release"
            then pin.kasmvnc_ver
            else "${pin.kasmvnc_ver}_${pin.branch}_${short}";
  url = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasmvnc/${pin.commit_id}"
      + "/kasmvncserver_${pin.codename}_${verPart}_${pin.arch}.deb";
  perlDeps = with prev.perlPackages; [
    Switch YAMLTiny HashMergeSimple ListMoreUtils TryTiny DateTime DateTimeTimeZone
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kasmvnc";
  version = pin.kasmvnc_ver;

  src = fetchurl { inherit url; hash = pin.hash; };

  nativeBuildInputs = [ autoPatchelfHook dpkg makeWrapper ];

  # Runtime .so providers for the KasmVNC ELF binaries (Xkasmvnc is an Xvnc fork,
  # so it pulls a lot). autoPatchelfHook rebinds against these; add any it reports
  # missing on the first .140 build.
  buildInputs = with prev; [
    stdenv.cc.cc.lib          # libstdc++/libgcc
    libxcrypt                 # libcrypt.so.1 (split out of modern glibc)
    zlib openssl libjpeg_turbo libpng libtiff giflib pixman ffmpeg
    libGL libgbm libdrm libunwind
    xorg.libX11 xorg.libXext xorg.libXtst xorg.libXrandr xorg.libXcursor
    xorg.libXfont2 xorg.libxshmfence xorg.libpciaccess xorg.libxkbfile
    xorg.libSM xorg.libICE xorg.libxcb xorg.libXdamage xorg.libXfixes
    xorg.libXau xorg.libXdmcp
  ] ++ perlDeps ++ [ perl ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  # Ship the .deb tree under $out (bin/lib/share) + the default config.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r usr/. "$out/"
    if [ -d etc ]; then mkdir -p "$out/etc"; cp -r etc/. "$out/etc/"; fi
    runHook postInstall
  '';

  # kasmvncserver is the perl launcher — give it its modules + X helpers.
  postFixup = ''
    if [ -e "$out/bin/kasmvncserver" ]; then
      wrapProgram "$out/bin/kasmvncserver" \
        --prefix PERL5LIB : "$PERL5LIB" \
        --prefix PATH : ${lib.makeBinPath (with prev.xorg; [ xkbcomp xauth setxkbmap ])}
    fi
  '';

  meta = {
    description = "KasmVNC server (Kasm) repackaged from the prebuilt .deb for cross-distro Nix use";
    homepage = "https://www.kasmweb.com/";
    license = lib.licenses.unfree;   # Kasm-built artifact; source is internal
    platforms = [ "x86_64-linux" ];
    mainProgram = "kasmvncserver";
  };
})

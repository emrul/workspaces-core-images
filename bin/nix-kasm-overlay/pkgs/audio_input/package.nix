# kasm-audio-input-server — Kasm's microphone-passthrough capture server,
# Nix-packaged from Kasm's public-S3 build.
#
# The artifact is a *staticx* bundle: a fully static ELF (no interpreter, no
# NEEDED libs) that self-extracts its bundled libc+libreadline to /tmp at
# runtime. So unlike pkgs/kasmvnc and pkgs/profile_sync there is nothing to
# autoPatchelf — we just fetch, unpack, and install the binary (and must NOT
# strip/patchelf it: that corrupts the .staticx.* sections). Being static it is
# already portable; packaging it here (a) unifies it under the overlay so distro
# bases can drop the per-distro S3 install and bake it in, and (b) sidesteps the
# staticx/readline fragility that needs a per-distro shim on some distros
# (see the openSUSE-16 hack in src/ubuntu/install/audio_input/install_audio_input.sh).
{ prev, pin }:
let
  inherit (prev) stdenv fetchurl;
  short = builtins.substring 0 6 pin.commit_id;
  src = fetchurl {
    url = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasm_audio_input_server/${pin.commit_id}/kasm_audio_input_server_${pin.arch}_${pin.branch}.${short}.tar.gz";
    hash = pin.hash;
  };
in
stdenv.mkDerivation {
  pname = "kasm-audio-input-server";
  version = "${pin.branch}-${short}";
  inherit src;

  dontUnpack = true;
  # staticx bundle: fully static + self-extracting. patchelf/strip would corrupt
  # the staticx sections, and there are no dynamic deps to resolve.
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    tar xzf ${src} -C $out/bin
    chmod +x $out/bin/kasm_audio_input_server
    runHook postInstall
  '';

  meta = {
    description = "Kasm microphone-passthrough capture server (staticx bundle), repackaged from Kasm's public S3 build";
    platforms = [ "x86_64-linux" ];
  };
}

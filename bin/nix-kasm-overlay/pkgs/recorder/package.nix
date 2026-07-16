# kasm-recorder-service — Kasm's session recorder, Nix-packaged from Kasm's
# public-S3 build. The artifact is a staticx bundle (fully static ELF, self-
# extracting) so there is nothing to autoPatchelf; we fetch/unpack/install and
# skip strip/patchelf (which would corrupt the .staticx.* sections). No ffmpeg
# or system daemon is needed — recording is driven by KasmVNC/Xvnc; the
# recorder-watch/recorder-drain units only supervise this binary at its expected
# path (/dockerstartup/recorder/kasm_recorder_service). Same pattern as
# pkgs/audio_input.
{ prev, pin }:
let
  inherit (prev) stdenv fetchurl;
  short = builtins.substring 0 6 pin.commit_id;
  src = fetchurl {
    url = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasm_recorder_service/${pin.commit_id}/kasm_recorder_service_${pin.arch}_${pin.branch}.${short}.tar.gz";
    hash = pin.hash;
  };
in
stdenv.mkDerivation {
  pname = "kasm-recorder-service";
  version = "${pin.branch}-${short}";
  inherit src;

  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    tar xzf ${src} -C $out/bin
    chmod +x $out/bin/kasm_recorder_service
    runHook postInstall
  '';

  meta = {
    description = "Kasm session recorder (staticx bundle), repackaged from Kasm's public S3 build";
    platforms = [ "x86_64-linux" ];
  };
}

# kasm-webcam-server — Kasm's virtual-webcam passthrough server, Nix-packaged
# from Kasm's public-S3 build. Staticx bundle (fully static ELF, self-
# extracting) → nothing to autoPatchelf; fetch/unpack/install, skip strip/patchelf.
#
# Runtime needs a host-provided /dev/video0 (v4l2loopback on the HOST — a
# limitation of stock Kasm too, not something the image can supply). When it is
# absent the server exits on connect and webcam.service gives up after
# StartLimitBurst instead of crash-looping, so the workspace stays healthy.
# Same pattern as pkgs/audio_input.
{ prev, pin }:
let
  inherit (prev) stdenv fetchurl;
  short = builtins.substring 0 6 pin.commit_id;
  src = fetchurl {
    url = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasm_webcam_server/${pin.commit_id}/kasm_webcam_server_${pin.arch}_${pin.branch}.${short}.tar.gz";
    hash = pin.hash;
  };
in
stdenv.mkDerivation {
  pname = "kasm-webcam-server";
  version = "${pin.branch}-${short}";
  inherit src;

  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    tar xzf ${src} -C $out/bin
    chmod +x $out/bin/kasm_webcam_server
    runHook postInstall
  '';

  meta = {
    description = "Kasm virtual-webcam passthrough server (staticx bundle), repackaged from Kasm's public S3 build";
    platforms = [ "x86_64-linux" ];
  };
}

# kasm-gamepad-server — Kasm's gamepad passthrough server, Nix-packaged from
# Kasm's public-S3 build. Staticx bundle (fully static ELF, self-extracting) →
# nothing to autoPatchelf; fetch/unpack/install, skip strip/patchelf. No uinput
# or kernel-module dependency (input events are routed through KasmVNC). Same
# pattern as pkgs/audio_input. (The gamepad.svg icon the install script also
# drops is UI-only and not required for the service to run.)
{ prev, pin }:
let
  inherit (prev) stdenv fetchurl;
  short = builtins.substring 0 6 pin.commit_id;
  src = fetchurl {
    url = "https://kasmweb-build-artifacts.s3.amazonaws.com/kasm_gamepad_server/${pin.commit_id}/kasm_gamepad_server_${pin.arch}_${pin.branch}.${short}.tar.gz";
    hash = pin.hash;
  };
in
stdenv.mkDerivation {
  pname = "kasm-gamepad-server";
  version = "${pin.branch}-${short}";
  inherit src;

  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    tar xzf ${src} -C $out/bin
    chmod +x $out/bin/kasm_gamepad_server
    runHook postInstall
  '';

  meta = {
    description = "Kasm gamepad passthrough server (staticx bundle), repackaged from Kasm's public S3 build";
    platforms = [ "x86_64-linux" ];
  };
}

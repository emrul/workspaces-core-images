# kasm-ai-runtime-sidebar — the in-session sidebar for kasm-session-runtime
# (gitlab.com/kasm-technologies/labs-sandbox/kasm-session-runtime, web/sidebar):
# a panel to the right of the KasmVNC viewer that streams what the runtime is
# doing (docs/viewer-sidebar-mechanism.md in that repo). Baked into every
# base image alongside kasm-session-runtime (see [base] in bin/nix-profiles.toml)
# and, like it, inert until a session asks for it:
#
#   - This package only puts files in the store: sidebar.js, sidebar.css and
#     install.sh under $out/share/kasm-ai-runtime-sidebar. Nothing references
#     them by default. The stock KasmVNC web root is not touched. Like the
#     runtime, the copy the container actually uses is the dockerfile-nix-*
#     ADD of the same object (/usr/local/share/kasm-ai-runtime-sidebar); the
#     [base] profile is closure/pin bookkeeping, not a runtime path (there is
#     no _base profile link in a running session), and kasm-setup only falls
#     back to the store path if the ADD is missing.
#   - A session opts in with KASM_VNC_PATH=/usr/share/kasmvnc-agent in its
#     environment. kasm-setup (src/common/kasm-go/scripts/kasm-setup, step 2b)
#     then materialises that second web root at boot -- a copy of the stock
#     www plus these assets and one line in vnc.html -- and kasm-xvnc serves it
#     via Xvnc's -httpd. Without the variable, or if anything here is missing,
#     kasm-xvnc falls back to the stock root and the viewer is exactly as
#     before.
#
# Kind B (repackage artifact), same shape as pkgs/kasm-session-runtime and
# published by the same CI job (that repo's .gitlab-ci.yml publish-s3) to the
# same public bucket and prefix, so the two are pinned together: one
# architecture-independent tarball per release, named
# kasm-ai-runtime-sidebar.tar.gz.<tag>.<short-commit> next to the two
# kasm-session-runtime-linux-<arch> objects. Why S3 and not the private
# GitLab project: see pkgs/kasm-session-runtime/package.nix.
{ prev, pin }:
let
  inherit (prev) stdenvNoCC fetchurl;
  hash =
    pin.hash
      or (throw "kasm-ai-runtime-sidebar: pin.json has no hash -- see pkgs/kasm-ai-runtime-sidebar/pin.json");
  short = builtins.substring 0 6 pin.commit_id;
  src = fetchurl {
    url = "https://kasm-labs-sandbox.s3.eu-north-1.amazonaws.com/kasm_session_runtime/${pin.commit_id}/kasm-ai-runtime-sidebar.tar.gz.${pin.branch}.${short}";
    inherit hash;
    # The published object's name ends in "<tag>.<short>", which stdenv's
    # unpackPhase would not recognise as an archive; name the store file so
    # it does.
    name = "kasm-ai-runtime-sidebar-${pin.branch}-${short}.tar.gz";
  };
in
stdenvNoCC.mkDerivation {
  pname = "kasm-ai-runtime-sidebar";
  version = "${pin.branch}-${short}";
  inherit src;

  # Plain web assets and a POSIX sh script: nothing to patch or strip.
  dontPatchELF = true;
  dontStrip = true;
  # The tarball unpacks to kasm-ai-runtime-sidebar/ -- default unpack + sourceRoot.
  sourceRoot = "kasm-ai-runtime-sidebar";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/kasm-ai-runtime-sidebar
    install -m0644 sidebar.js sidebar.css README.md $out/share/kasm-ai-runtime-sidebar/
    install -m0755 install.sh $out/share/kasm-ai-runtime-sidebar/install.sh
    runHook postInstall
  '';

  meta = {
    description = "kasm-session-runtime's in-session sidebar (KasmVNC viewer add-on), baked into every nix base image, inert until KASM_VNC_PATH selects it";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}

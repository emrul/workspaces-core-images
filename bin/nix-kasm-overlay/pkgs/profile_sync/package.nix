# kasm-profile-sync — Kasm's persistent-profile sync client, Nix-packaged from
# the prebuilt Go binaries Kasm publishes to the public S3 (repackage +
# autoPatchelf — same pattern as pkgs/kasmvnc). Distro-independent: we take the
# ubuntu_noble build and rebind it against the Nix closure, so every distro base
# (incl. resolute/26.04, which has no native profile-sync build) gets the same
# binary. Retires the per-distro artifact-selection matrix and the
# KASM_UBUNTU_ARTIFACT_CODENAME stopgap in
# src/ubuntu/install/profile_sync/install_profile_sync.sh.
#
# Ships BOTH protocol versions the boot selects via KASM_PROFILE_LDR
# (src/common/kasm-go/scripts/kasm-profile-pull):
#   kasm-profile-sync    (v1, standalone)        — LDR 0/1
#   kasm-profile-sync-2  (v2, links libarchive)  — LDR 2
{ prev, pin }:
let
  inherit (prev) stdenv fetchurl autoPatchelfHook libarchive zlib curl;
  base = "https://kasmweb-build-artifacts.s3.amazonaws.com/profile-sync";
  short = c: builtins.substring 0 6 c;
  mkUrl = branch: commit: suffix:
    "${base}/${commit}/${pin.profile_distro}_${branch}_${short commit}_${pin.arch}-kasm-profile-sync${suffix}";
  srcV1 = fetchurl { url = mkUrl pin.v1_branch pin.v1_commit_id "";   hash = pin.v1_hash; };
  srcV2 = fetchurl { url = mkUrl pin.v2_branch pin.v2_commit_id "-2"; hash = pin.v2_hash; };
in
stdenv.mkDerivation {
  pname = "kasm-profile-sync";
  version = pin.v2_version;

  dontUnpack = true;

  nativeBuildInputs = [ autoPatchelfHook ];
  # Both binaries link libcurl (they talk HTTP(S) to the Kasm API); v2 also links
  # libarchive (CGO). zlib is a common transitive dep. autoPatchelf rebinds both
  # against the Nix closure.
  buildInputs = [ stdenv.cc.cc.lib curl libarchive zlib ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m0755 ${srcV1} $out/bin/kasm-profile-sync
    install -m0755 ${srcV2} $out/bin/kasm-profile-sync-2
    runHook postInstall
  '';

  meta = {
    description = "Kasm persistent-profile sync client (v1 + v2), repackaged from Kasm's public S3 build";
    platforms = [ "x86_64-linux" ];
  };
}

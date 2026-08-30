# kasm-session-runtime — the D4 MCP/CDP drive-session binary
# (gitlab.com/kasm-technologies/labs-sandbox/kasm-session-runtime), baked into
# every base image (not a per-app catalog entry — see [base] in
# bin/nix-profiles.toml) so a session can serve MCP-over-HTTPS and, when
# KASM_ENABLE_CDP is also set, raw CDP passthrough, the moment
# KASM_RUNTIME_SESSION_TOKEN is set on it. No build or upload step at
# session-request time; see that repo's docs/mcp-baked-in-delivery.md for
# the full design and src/ubuntu/install/nix/units/kasm-session-runtime.service
# for the container-init unit that actually starts it.
#
# Kind B (repackage artifact), same shape as pkgs/recorder and
# pkgs/audio_input, with one real difference: those fetch a staticx bundle
# (fully static ELF via bundled-libc self-extraction); this fetches a plain
# CGO_ENABLED=0 Go binary, which is static in the ordinary sense (no
# interpreter, no DT_NEEDED entries at all) without any staticx machinery,
# so there is nothing to unpack (no tar) and nothing for autoPatchelf to
# rewrite either way.
#
# The artifact is mirrored to this public bucket specifically because the
# GitLab project it's built from is private (confirmed: the project 404s
# anonymously) and a hermetic nix fetchurl has no clean way to attach
# GitLab's own auth to a fetch -- every other self-hosted package in this
# overlay already solves the same problem the same way, fetching from a
# public S3 location rather than an authenticated one. This is that repo's
# OWN bucket (kasm-labs-sandbox, eu-north-1), not the shared production one
# recorder/audio_input/profile_sync fetch from -- do not assume the two are
# interchangeable if this ever needs updating. Published by that repo's own
# CI (.gitlab-ci.yml's publish-s3 job, using GitLab OIDC federation to
# assume a role scoped to this one bucket's kasm_session_runtime/ prefix --
# scripts/setup-aws-oidc.sh -- additive to its existing GitLab generic-
# package publish, not a replacement for it).
{ prev, pin }:
let
  inherit (prev) stdenvNoCC fetchurl;
  archMap = {
    x86_64-linux = "amd64";
    aarch64-linux = "arm64";
  };
  system = prev.stdenv.hostPlatform.system;
  arch =
    archMap.${system}
      or (throw "kasm-session-runtime: unsupported system ${system} (supported: ${builtins.concatStringsSep ", " (builtins.attrNames archMap)})");
  hash =
    pin.hashes.${system}
      or (throw "kasm-session-runtime: pin.json has no hash for ${system} -- see pkgs/kasm-session-runtime/pin.json");
  short = builtins.substring 0 6 pin.commit_id;
  src = fetchurl {
    # Regional endpoint, not the global kasmweb-build-artifacts-style
    # .s3.amazonaws.com form: kasm-labs-sandbox lives in eu-north-1, and an
    # explicit regional endpoint avoids relying on S3's cross-region
    # redirect behaviour inside a hermetic fetch.
    url = "https://kasm-labs-sandbox.s3.eu-north-1.amazonaws.com/kasm_session_runtime/${pin.commit_id}/kasm-session-runtime-linux-${arch}.${pin.branch}.${short}";
    inherit hash;
  };
in
stdenvNoCC.mkDerivation {
  pname = "kasm-session-runtime";
  version = "${pin.branch}-${short}";
  inherit src;

  dontUnpack = true;
  # A CGO_ENABLED=0 Go binary needs neither: no interpreter/RPATH to
  # rewrite (nothing dynamically linked at all), and stripping a Go binary
  # is a separate, non-default concern this build doesn't opt into --
  # matching the conservative "leave it exactly as published" choice
  # pkgs/recorder and pkgs/audio_input already make for their own
  # (differently-shaped) static artifacts.
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m0755 ${src} $out/bin/kasm-session-runtime
    runHook postInstall
  '';

  meta = {
    description = "kasm-session-runtime's MCP/CDP drive-session binary (D4), baked into every nix base image";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}

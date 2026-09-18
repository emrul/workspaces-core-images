# kasm-wine -- wine-assess's wine fork (gitlab.com/kasm-technologies/labs-sandbox/wine;
# ledger: wine-assess/docs/wine-fork.md), built through nixpkgs' wineWow64 derivation.
#
# Kind B (source). The fork is a private GitLab project, so a hermetic fetch cannot
# reach it -- but the fork *is* upstream's release tag plus a patch series, so that is
# how it is expressed here: upstream's public wine-<version>.tar.xz (hash in pin.json)
# plus patches/ = one file per fork commit over that tag, in series order, written by
# ./regen-patches.sh (not plain git-format-patch: some fork commits quote the original
# community patch in their message, which GNU patch would apply twice). On a fork move:
#
#   pkgs/kasm-wine/regen-patches.sh <fork checkout>     # after bumping pin.json
#   # bump pin.json version / fork_tag / hash together, then regenerate
#
# Why wineWow64Packages.unstableFull + overrideAttrs: that derivation already builds the
# new-WoW64 layout (--enable-archs=x86_64,i386 with the mingw cross compilers, so no
# i386 userspace at runtime) with the full support set (OpenCL, Vulkan, GStreamer,
# Wayland, PulseAudio, ...) and embeds gecko + mono under share/wine; only
# pname/version/src/patches change. Configure parity with
# wine-assess/containers/wine-kasm/Containerfile: OSS is off there, so off here too.
# The rest of that Containerfile's flags are nixpkgs' defaults for this variant.
#
# Consumers find the fork tag in $out/share/kasm-wine/TAG and the applied series in
# $out/share/kasm-wine/SERIES; `wine --version` reports upstream's version string.
{ prev, pin }:
let
  lib = prev.lib;
  patchDir = ./patches;
  series = builtins.sort builtins.lessThan (
    builtins.attrNames (
      lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".patch" n) (builtins.readDir patchDir)
    )
  );
  forkPatches = map (f: patchDir + "/${f}") series;
  upstream = prev.wineWow64Packages.unstableFull;
in
upstream.overrideAttrs (old: {
  pname = "kasm-wine";
  version = pin.version;
  src = prev.fetchurl {
    url = "https://dl.winehq.org/wine/source/${lib.versions.major pin.version}.x/wine-${pin.version}.tar.xz";
    hash = pin.hash;
  };
  # nixpkgs' own list holds cert-path.patch (a local file: wine then honours
  # NIX_SSL_CERT_FILE -- keep it) and, on some refs, fetchpatch'd upstream commits meant
  # for the older release nixpkgs packages. Those are already in our tarball and would
  # fail to apply, so only local files survive the filter.
  patches = (builtins.filter (p: !(lib.isDerivation p)) (old.patches or [ ])) ++ forkPatches;
  configureFlags = (old.configureFlags or [ ]) ++ [ "--without-oss" ];
  postInstall = (old.postInstall or "") + ''
    mkdir -p $out/share/kasm-wine
    printf '%s\n' ${lib.escapeShellArg pin.fork_tag} > $out/share/kasm-wine/TAG
    printf '%s\n' ${lib.escapeShellArgs series} > $out/share/kasm-wine/SERIES
  '';
  passthru = (old.passthru or { }) // {
    forkTag = pin.fork_tag;
    patchSeries = series;
  };
  meta = (old.meta or { }) // {
    description = "Wine ${pin.version} with wine-assess's patch set (${pin.fork_tag})";
    platforms = [ "x86_64-linux" ];
  };
})

# Chrome (Kind A — override).
#
# nixpkgs' google-chrome derivation *is* Google's official
# google-chrome-stable_<version>_amd64.deb repackaged. All the dependency wiring,
# autoPatchelf/FHS logic, and wrappers are generic — the only thing that lags
# nixpkgs is a maintainer committing the version+hash bump. So we reuse the whole
# derivation and override just those two fields from pin.json, refreshed by
# ./update from Google's version API on a twice-daily schedule.
#
# amd64 only: Google ships no arm64 Linux Chrome (.deb is amd64; nixpkgs marks
# platforms = darwin ++ x86_64-linux). On arm64 the chrome profile is skipped
# (platforms=["amd64"] in nix-profiles.toml) and chromium is the fallback.
{ prev, pin }:

prev.google-chrome.overrideAttrs (old: {
  version = pin.version;
  src = prev.fetchurl {
    url = "https://dl.google.com/linux/chrome/deb/pool/main/g/"
        + "google-chrome-stable/google-chrome-stable_${pin.version}-1_amd64.deb";
    hash = pin.hashes.x86_64-linux;
  };
})

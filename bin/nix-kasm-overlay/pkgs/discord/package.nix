# Discord (Kind A — override).
#
# nixpkgs' discord derivation *is* Discord's official linux tarball
# (dl.discordapp.net/apps/linux/<ver>/discord-<ver>.tar.gz) repackaged with the
# autoPatchelf/desktop wiring. Discord HARD-EXPIRES old clients: when the pinned
# build falls behind the server's minimum it launches an in-app updater that
# cannot write to the read-only Nix store, so the app is stuck. nixpkgs-unstable
# lags upstream by a few releases (seen: upstream 1.0.149 vs unstable 1.0.146,
# 2026-07-17), enough to trip that. So we reuse the whole derivation and override
# just version+src from pin.json, refreshed by nix-kasm-update from Discord's
# download endpoint on the twice-daily schedule — same model as chrome.
#
# amd64 only: Discord ships no arm64 Linux build (nixpkgs marks x86_64-linux).
{ prev, pin }:

# NB: match nixpkgs' current src format — the `full.distro` artifact
# (stable.dl2.discordapp.net/distro/…), NOT the legacy discord-<ver>.tar.gz
# (which unpacks to a different layout the derivation's installPhase can't
# handle). The `name` keeps the fetchurl store path readable.
prev.discord.overrideAttrs (old: {
  version = pin.version;
  src = prev.fetchurl {
    url = "https://stable.dl2.discordapp.net/distro/app/stable/linux/x64/${pin.version}/full.distro";
    name = "discord-${pin.version}-full.distro";
    hash = pin.hashes.x86_64-linux;
  };
})

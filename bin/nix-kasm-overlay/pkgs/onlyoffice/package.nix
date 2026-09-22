# OnlyOffice Desktop Editors (Kind A — override, vendored).
#
# Why this exists: CVE-2023-51714 and CVE-2024-36048 (Critical) in the Qt 5.9.9
# that upstream bundles inside every release, 9.4.0 included, and nixpkgs
# packaging three releases behind upstream (9.1.0 vs 9.4.0, 2026-09-22). The
# derivation is nixpkgs' own with version/src from pin.json and the bundled Qt
# stripped so the editor binds to nixpkgs' Qt 5.15 — see derivation.nix, and
# the REVERT condition in its header.
#
# amd64 only: upstream ships no arm64 Linux build (nixpkgs: platforms =
# x86_64-linux); the profile carries platforms = ["amd64"].
{ prev, pin }:

prev.callPackage ./derivation.nix { inherit pin; }

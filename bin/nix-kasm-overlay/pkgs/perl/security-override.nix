# perl CVE-2026-13221 — scoped security backport.
#
# When a long alternation of fixed strings compiles into a trie, the delta from
# the first branch to the shared tail is kept in a 16-bit field. Past U16_MAX
# regnodes it overflows and perl dies with "regexp memory corruption".
# Upstream: Perl/perl5 GH #23388, "Regexp memory corruption with large tries".
#
# ── The failure mode, measured rather than assumed ──
#
# It is a fatal runtime error, NOT silent mismatching. Reaching it needs TWO
# independent conditions, both verified here against stock perl 5.42.0:
#
#   1. a regex whose fixed-string alternation exceeds U16_MAX regnodes, and
#   2. regex debugging enabled (`use re "Debug"`, or -Mre=Debug via PERL5OPT).
#
# Without the pragma there is no crash — confirmed at the upstream reproducer's
# size, at 4x that size, and with a single huge alternation. With the pragma,
# the upstream reproducer dies rc=255 "regexp memory corruption".
#
#   stock   perl 5.42.0 + pragma -> rc=255, memory corruption
#   patched perl 5.42.0 + pragma -> rc=0,  clean
#
# That comparison — not the presence of a patch file — is the evidence the
# backport works. Note PERL5OPT=-Mre=Debug reproduces it without editing any
# script, so "our scripts don't enable Debug" is NOT by itself a safe argument;
# the load-bearing leg is condition 1, the absence of a qualifying alternation.
#
# ── Why this is scoped to exiftool and applied nowhere else ──
#
# Runtime perl consumers, enumerated with `nix why-depends --precise` over every
# profile in bin/nix-profiles.toml (everything else reaches perl not at all):
#
#   exiftool    a Perl script AND a Perl module set -> must COMPILE against the
#               interpreter, so it genuinely needs the patched perl.
#   kasmvnc     bin/.kasmvncserver-wrapped, a Perl script. Only tie is a shebang.
#   xdg-utils   bin/xdg-screensaver line ~1029 runs `perl -e`. Only tie is a
#               reference. Reaches the image via chromium/firefox/brave.
#
# Applying this globally (config.packageOverrides, let alone an overlay) changes
# perl as a BUILD input to half the tree. Measured: exiftool needs 33 rebuilds,
# xdg-utils 270, and kasmvnc pulled in clang/LLVM/ffmpeg and blew the 48 GB
# build host out of disk after 440 derivations. We would have been recompiling
# LLVM to change one `#!` line, for packages whose perl exposure is a reference
# rather than a compile.
#
# So kasmvnc and xdg-utils are handled as VEX (non-reachability) rather than by
# rebuilding. The assurance for that is recorded in design/known_issues.md;
# in short, compiled under -Mre=Debug on STOCK perl with a control canary that
# DOES crash under the same harness: kasmvncserver + all 16 bundled KasmVNC
# modules and the xdg-screensaver one-liner all compile clean, and neither
# builds an alternation dynamically (no `join "|"` anywhere).
#
# ── Why backport rather than bump to 5.42.3 ──
#
# nixpkgs builds perl as callPackage ./interpreter.nix { self = perl5; version;
# sha256; }, with the entire perlPackages set hanging off passthru. A version
# bump swaps src while leaving that scaffolding built around the old version,
# and no-sys-dirs.patch would need revalidating against a new tree. Carrying
# the upstream commit is the same outcome at a fraction of the risk — and it is
# what nixpkgs already does for the sibling advisory CVE-2026-8376, whose patch
# it applies to this same 5.42.0.
#
# The patch is the complete upstream commit, INCLUDING its t/re/pat_advanced.t
# hunk. Be clear about what that buys: nixpkgs sets doCheck = false for perl, so
# no checkPhase runs and the test is applied but NEVER EXECUTED during the
# build. It is carried to stay faithful to upstream and to start working the day
# checks are enabled — the stock-vs-patched reproducer is the actual evidence.
#
# ── This does NOT clear the scanner finding ──
#
# A backported 5.42.0 still honestly reports 5.42.0, so Grype keeps flagging it.
# Clearing the report needs VEX, which the remediator derives from applied-patch
# provenance (backport_provenance, lane 5). Patching buys the risk reduction;
# VEX buys the clean report. Both are required.
#
# ── Self-retiring ──
#
# Steps aside automatically once upstream catches up, so it cannot rot into a
# permanent backwards pin. The threshold is 5.42.3 and not "anything past
# 5.42.0" because 5.42.1 and 5.42.2 do NOT carry the guard — retiring on those
# would silently reintroduce the CVE. Verified by looking for
# `tail - startbranch >= U16_MAX` in regcomp_study.c at each tag. The upstream
# issue is still OPEN: commit 03f74bbb declines to build an overflowing trie
# rather than fixing the 16-bit field, and says so.
# Review by 2026-08-23 if nixpkgs still has not moved.
#
# CVE severity and the exact upstream release that first shipped the guard
# should be re-checked against NVD / the perl5 release notes before being cited
# in any customer-facing risk statement; they are not verified here.

{ lib }:

prev:

let
  upstreamFixed = lib.versionAtLeast prev.perl5.version "5.42.3";
  upstreamPatched = lib.any
    (p: lib.hasInfix "CVE-2026-13221" (baseNameOf (toString p)))
    (prev.perl5.patches or [ ]);

  retired = upstreamFixed || upstreamPatched;

  # `self = fixedPerl` is the load-bearing part. nixpkgs treats perl5 as
  # canonical (perl = perl5) and builds the whole perlPackages scope from
  # passthru, which is derived from `self`. Without rewiring it, the modules —
  # and so exiftool — would compile against the UNPATCHED interpreter while
  # `perl` alone looked fixed.
  fixedPerl = (prev.perl5.override { self = fixedPerl; }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./CVE-2026-13221.patch ];
  });

  warn = lib.warn ''
    kasm-overlay: the perl CVE-2026-13221 backport is now redundant — nixpkgs
    ships perl ${prev.perl5.version}${lib.optionalString upstreamPatched " with its own patch for it"}.
    Delete bin/nix-kasm-overlay/pkgs/perl/ and the perl/exiftool attributes in overlay.nix.
  '';
in
{
  inherit retired;

  # The patched interpreter, and the module scope built against it. Deliberately
  # NOT bound to the top-level `perl`/`perl5` attributes: doing that is what
  # turns a 33-derivation fix into a 440-derivation one.
  perl = if retired then warn prev.perl5 else fixedPerl;

  # nixpkgs defines `exiftool = perlPackages.ImageExifTool`, so resolving it
  # through the patched interpreter's own scope rebuilds exiftool and its Perl
  # module dependencies — and nothing else in the tree.
  exiftool =
    if retired then warn prev.exiftool else fixedPerl.pkgs.ImageExifTool;
}

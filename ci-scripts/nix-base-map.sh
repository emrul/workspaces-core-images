#!/usr/bin/env bash
# nix-base-map.sh — the ONE definition of "local base build tag → published
# kasm-core repo name". Sourced, never executed.
#
# Consumers:
#   nix-publish-base.sh   tags + pushes each of these to <NS>/<repo>:<tag>
#   nix-publish.sh        measures each one's uncompressed size for the registry
#
# Same reasoning as ci-scripts/nix-base-src.sh owning the distro → source-image
# mapping: this list used to live inline in nix-publish-base.sh, and a second
# consumer would have meant a second copy to drift out of step.
#
# One line per base, "<local image>|<published repo>". Add alpine/fedora/etc.
# here once their nix-base dockerfiles exist (dockerfile-nix-<distro> +
# src/<distro>/install/nix + a nix-base-build). The minimal core is the stripped
# base nix-<distro> builds FROM; publishing it is optional (build-time dep) but
# useful for reuse/reproducibility.
#
# fedora/alpine have no minimal core (dockerfile-kasm-core-minimal is apt-only),
# so nix-fedora/nix-alpine build on their standard cores. Alpine is musl: apps
# run (own glibc loader from /nix/store) but SOFTWARE-RENDER ONLY — the system
# mesa is musl (see dockerfile-nix-alpine / nix-activate musl skip). GPU on
# alpine is future work (glibc GL from nix/host-injection, not host musl mesa).
NIX_BASES_MAP="
localhost/nix-ubuntu:dev|kasm-core-ubuntu
localhost/kasm-core-ubuntu-noble-minimal:dev|kasm-core-ubuntu-minimal
localhost/nix-fedora:dev|kasm-core-fedora
localhost/nix-alpine:dev|kasm-core-alpine
localhost/nix-ubuntu-resolute:dev|kasm-core-ubuntu-resolute
"

#!/usr/bin/env bash
set -euo pipefail

# Security hardening for the minimal core image.  Removes tools that
# expand the attack surface of a runtime container:
#
#   openssh-client          — prevents using the container as an SSH
#                             jump-host or for outbound credential-bearing
#                             SSH connections
#   wget                    — build-time only; removing it blocks a common
#                             payload-download vector at runtime
#   software-properties-common / python3-software-properties
#                           — blocks add-apt-repository, preventing
#                             unauthorised APT-source injection at runtime
#   compiler toolchain      — gcc, g++, cpp, binutils, make,
#                             build-essential, *-dev headers; blocks
#                             on-the-fly exploit / SUID-helper compilation
#   llvm / libLLVM          — 137 MiB system LLVM pulled in by mesa-utils
#                             for llvmpipe software rendering. Not needed
#                             when downstream Nix apps (Chrome, Chromium,
#                             etc.) carry their own Mesa+LLVM in /nix/store.
#                             XFWM4 loses OpenGL compositing but falls back
#                             to XRender automatically.
#   libwebkit2gtk / libjavascriptcoregtk
#                           — 121 MiB WebKit engine dragged in as a stray
#                             XFCE/GTK dependency. Has no role in a
#                             browser-base image where the real browser is
#                             a Nix package.
#
# All removals are best-effort: dpkg --purge with --force-depends so that
# packages which soft-depend on these are not uninstalled; unknown/missing
# packages are silently skipped.
#
# This script is Ubuntu/Debian-only; it is a no-op on other distro families.

if [[ "${DISTRO}" == @(ubuntu|debian|kali|parrotos7) ]]; then
    TO_REMOVE=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E \
'^(openssh-client|wget|software-properties-common|python3-software-properties|\
gcc|gcc-[0-9]+|g\+\+|g\+\+-[0-9]+|cpp|cpp-[0-9]+|gfortran|gfortran-[0-9]+|\
build-essential|binutils|binutils-common|\
binutils-x86-64-linux-gnu|binutils-aarch64-linux-gnu|binutils-arm-linux-gnueabihf|\
make|libgcc-[0-9]+-dev|libstdc\+\+-[0-9]+-dev|libc-dev-bin|linux-libc-dev|\
llvm-[0-9]+-runtime|llvm-[0-9]+|libllvm[0-9]+|\
libwebkit2gtk-4\.[01]-0|libjavascriptcoregtk-4\.[01]-0)$' \
        || true)

    if [ -n "$TO_REMOVE" ]; then
        echo "$TO_REMOVE" | xargs dpkg --purge --force-depends 2>&1 || true
        apt-get autoremove -y 2>/dev/null || true
    fi

    # Belt-and-suspenders: remove the binary even if the package dep chain
    # prevents dpkg from dropping the parent package.
    rm -f /usr/bin/add-apt-repository

    apt-get clean
    rm -rf /var/lib/apt/lists/*
else
    echo "security_hardening: DISTRO=${DISTRO} not Debian/Ubuntu — skipping"
fi

# KasmVNC (Kind B — from scratch) — FIRST-CUT SPIKE, expect .140 iteration.
#
# Goal: a single glibc/x86_64 Nix build of Kasm's KasmVNC server (Xvnc fork +
# web stack + perl `vncserver` wrapper) so the runtime base no longer needs a
# per-distro .deb/.rpm/.apk. This unblocks Ubuntu Resolute and every future
# distro (no Kasm S3 artifact / codename matrix), and thins the base toward
# distro-independence. See design/nix/RUNBOOK.md and base-image-assessment.md.
#
# KasmVNC is a TigerVNC fork, so this cribs nixpkgs' `tigervnc` derivation
# (pkgs/by-name/ti/tigervnc/package.nix) — which already solves the hard part,
# building the Xvnc X-server fork under Nix — and adapts it:
#   • CMake flags per KasmVNC builder/build.sh: -DBUILD_VIEWER=OFF (no fltk viewer),
#     -DENABLE_GNUTLS=OFF (KasmVNC links openssl instead).
#   • Xvnc build: extract nixpkgs xorg-server.src into unix/xserver, apply
#     KasmVNC's unix/xserver21.patch (21.x — matches nixpkgs xorg-server 21.1.x),
#     configure+make. Identical shape to tigervnc's postBuild.
#   • Runtime: wrap the perl `vncserver` with the perl modules Kasm's debian/control
#     lists (YAML::Tiny, List::MoreUtils, DateTime, DateTime::TimeZone, Switch,
#     Try::Tiny, Hash::Merge::Simple) + xkbcomp/xauth/xkeyboard-config.
#
# ITERATION TODO (resolve on .140 via `nix build`):
#   [ ] src hash — fill from the first build (currently fakeHash).
#   [ ] the make Xvnc step: KasmVNC's hw/vnc Makefile may use TIGERVNC_SRC/
#       TIGERVNC_BUILDDIR (fork kept the name) or KASMVNC_*; adjust if make errors.
#   [ ] web UI: confirm whether kasmweb/ ships prebuilt or needs a buildNpmPackage
#       sub-derivation; install the www assets where vncserver expects them.
#   [ ] install layout: KasmVNC installs vncserver + Xvnc + libvnc.so + www +
#       yaml config; verify paths vs what src/.../kasm_vnc runtime expects.
{ prev, pin }:

let
  inherit (prev) lib stdenv fetchFromGitHub xorg;
  xorgServer = xorg.xorgserver;   # 21.1.x → matches unix/xserver21.patch
  perlDeps = with prev.perlPackages; [
    YAMLTiny ListMoreUtils TryTiny DateTime DateTimeTimeZone Switch HashMergeSimple
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kasmvnc";
  version = pin.version;

  src = fetchFromGitHub {
    owner = "kasmtech";
    repo = "KasmVNC";
    rev = pin.rev;
    hash = pin.hash;   # lib.fakeHash until the first .140 build reports the real one
  };

  # KasmVNC builds in-tree (cmake .), like tigervnc.
  dontUseCmakeBuildDir = true;

  nativeBuildInputs = with prev; [
    cmake gettext autoconf automake libtool pkg-config makeWrapper
    xorg.utilmacros xorg.fontutil gawk
  ] ++ xorgServer.nativeBuildInputs;

  buildInputs = with prev; [
    openssl zlib libjpeg_turbo libpng libtiff giflib pixman ffmpeg libGL libGLU
    libgbm nettle pam perl
    xorg.libXtst xorg.libXext xorg.libX11 xorg.libICE xorg.libXi xorg.libSM
    xorg.libXft xorg.libxkbfile xorg.libXfont2 xorg.libpciaccess xorg.libXrandr
    xorg.libXdamage xorg.libXcursor
  ] ++ xorgServer.buildInputs ++ perlDeps;

  propagatedBuildInputs = xorgServer.propagatedBuildInputs or [ ];

  # gcc-12 -Warray-bounds trips the Xvnc build (see builder/build.sh fail_on_gcc_12).
  env.NIX_CFLAGS_COMPILE = toString [ "-Wno-error=array-bounds" ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_VIEWER" false)
    (lib.cmakeBool "ENABLE_GNUTLS" false)
    (lib.cmakeFeature "CMAKE_BUILD_TYPE" "RelWithDebInfo")
  ];

  # After the KasmVNC libs/tools build, build Xvnc against nixpkgs xorg-server —
  # same procedure as tigervnc's postBuild.
  postBuild = ''
    export CXXFLAGS="$CXXFLAGS -fpermissive"
    tar xf ${xorgServer.src}
    cp -R xorg*/* unix/xserver
    pushd unix/xserver
    patch -p1 < ../xserver21.patch
    autoreconf -vfi
    ./configure $configureFlags --disable-devel-docs --disable-docs \
        --disable-xorg --disable-xnest --disable-xvfb --disable-dmx \
        --disable-xwin --disable-xephyr --disable-kdrive --with-pic \
        --disable-xorgcfg --disable-xprint --disable-static \
        --enable-composite --disable-xtrap --enable-xcsecurity \
        --disable-{a,c,m}fb --disable-xwayland \
        --disable-config-dbus --disable-config-udev --disable-config-hal \
        --disable-xevie --disable-dri --disable-dri2 --disable-dri3 --enable-glx \
        --enable-install-libxf86config \
        --prefix="$out" --disable-unit-tests \
        --with-xkb-path=${xorg.xkeyboardconfig}/share/X11/xkb \
        --with-xkb-bin-directory=${xorg.xkbcomp}/bin \
        --with-xkb-output=$out/share/X11/xkb/compiled
    make KASMVNC_SRC=$src KASMVNC_BUILDDIR=`pwd`/../.. -j$NIX_BUILD_CORES
    popd
  '';

  postInstall = ''
    pushd unix/xserver/hw/vnc
    make KASMVNC_SRC=$src KASMVNC_BUILDDIR=`pwd`/../../../.. install
    popd
    # perl vncserver wrapper needs its modules + X helpers on PATH.
    if [ -e "$out/bin/vncserver" ]; then
      wrapProgram $out/bin/vncserver \
        --prefix PATH : ${lib.makeBinPath (with prev.xorg; [ xkbcomp xauth setxkbmap ])} \
        --prefix PERL5LIB : "$PERL5LIB"
    fi
    # TODO(.140): install/point at the web UI assets (kasmweb) + default yaml config.
  '';

  meta = {
    description = "KasmVNC server (Kasm fork of TigerVNC) — Nix build for cross-distro use";
    homepage = "https://github.com/kasmtech/KasmVNC";
    license = lib.licenses.gpl2Plus;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "vncserver";
  };
})

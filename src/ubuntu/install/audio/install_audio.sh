#!/usr/bin/env bash
### every exit != 0 fails the script
set -ex

ARCH=$(arch | sed 's/aarch64/arm64/g' | sed 's/x86_64/amd64/g')
echo "Install Audio Requirements"
if [[ "${DISTRO}" == "oracle8" ]]; then
  dnf install -y curl git
  dnf config-manager --set-enabled ol8_codeready_builder
  dnf localinstall -y --nogpgcheck https://download1.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm
  dnf install -y ffmpeg pulseaudio-utils
elif [[ "${DISTRO}" == @(oracle9|rhel9) ]]; then
  dnf install -y --allowerasing curl git
  if [[ "${DISTRO}" == "oracle9" ]]; then
    dnf config-manager --set-enabled ol9_codeready_builder
  fi
  dnf localinstall -y --nogpgcheck https://download1.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm
  dnf install -y --allowerasing ffmpeg pulseaudio-utils pulseaudio
elif [[ "${DISTRO}" == @(rockylinux9|almalinux9) ]]; then
  dnf localinstall -y --nogpgcheck https://download1.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm
  dnf install -y --allowerasing ffmpeg pulseaudio-utils pulseaudio
elif [[ "${DISTRO}" == @(rockylinux8|almalinux8) ]]; then
  dnf localinstall -y --nogpgcheck https://download1.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm
  dnf install -y --allowerasing ffmpeg pulseaudio-utils pulseaudio
elif [[ "${DISTRO}" == "fedora42" ]]; then
  dnf install -y curl git
  dnf-3 localinstall -y --nogpgcheck https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-42.noarch.rpm
  dnf install -y --allowerasing ffmpeg pulseaudio pulseaudio-utils
elif [[ "${DISTRO}" == "fedora43" ]]; then
  dnf install -y curl git
  dnf-3 localinstall -y --nogpgcheck https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm
  dnf install -y --allowerasing ffmpeg pulseaudio pulseaudio-utils
elif [[ "${DISTRO}" == opensuse ]]; then
  zypper install -ny curl git
  if grep -q "16" /etc/os-release; then
    # Packman provides ffmpeg-4 compiled with x264/x265 support (required by KasmVNC
    # software encoder). The main repo ffmpeg-4 lacks those codecs.
    zypper addrepo -cfp 90 'https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Leap_$releasever/' packman
    zypper --gpg-auto-import-keys refresh packman
    zypper install -yn --allow-vendor-change ffmpeg-4 pulseaudio-utils \
    pipewire \
    pipewire-pulseaudio \
    wireplumber
    # Lock ffmpeg-7 — Packman provides it too and it breaks KasmVNC's libavcodec
    zypper addlock ffmpeg-7
    # Remove the Packman repo so later build steps can't accidentally pull more packages
    zypper removerepo packman
    # pipewire-pulseaudio replaces pulseaudio on openSUSE 16; wrap the binary so
    # START_PULSEAUDIO=1 works — pipewire-pulse doesn't understand --start.
    cat > /usr/local/bin/pulseaudio <<'EOF'
#!/bin/bash
# PipeWire needs XDG_RUNTIME_DIR for its socket
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run/pulse}"
mkdir -p "$XDG_RUNTIME_DIR"
# Start the core PipeWire daemon if needed
pgrep -x pipewire > /dev/null 2>&1 || /usr/bin/pipewire &
sleep 0.5
# Start the WirePlumber session manager if needed
pgrep -x wireplumber > /dev/null 2>&1 || /usr/bin/wireplumber &
sleep 0.3
# Start the PulseAudio compatibility server if needed
pgrep -x pipewire-pulse > /dev/null 2>&1 || /usr/bin/pipewire-pulse &
# Wait for the PulseAudio compat socket to be available (up to 5s).
# pipewire-pulse may place the socket at $XDG_RUNTIME_DIR/pulse/native
# (e.g. /var/run/pulse/pulse/native) rather than $XDG_RUNTIME_DIR/native.
# If that happens, symlink it to /var/run/pulse/native so that
# PULSE_RUNTIME_PATH and PULSE_SERVER both work correctly.
for _i in $(seq 1 10); do
    [ -S /var/run/pulse/native ] && break
    if [ -S /var/run/pulse/pulse/native ]; then
        ln -sf /var/run/pulse/pulse/native /var/run/pulse/native
        break
    fi
    sleep 0.5
done
EOF
    chmod +x /usr/local/bin/pulseaudio
    # ffmpeg-4 installs as /usr/bin/ffmpeg-4; create /usr/bin/ffmpeg so that
    # audio-out.service can call 'ffmpeg -f pulse ...' for audio streaming
    [[ -e /usr/bin/ffmpeg ]] || ln -s /usr/bin/ffmpeg-4 /usr/bin/ffmpeg
  fi
elif [[ "${DISTRO}" == "alpine" ]]; then
  apk add --no-cache \
    ffmpeg \
    ffplay \
    git \
    pulseaudio \
    pulseaudio-utils
else
  apt-get update
  apt-get install -y --no-install-recommends \
    curl \
    ffmpeg \
    git \
    pulseaudio \
    pulseaudio-utils
fi

mkdir -p /var/run/pulse

WS_COMMIT_ID="f7efb82dc59a02d1b99e2e2b3c6d127dc548ba72"
WS_BRANCH="develop"
WS_COMMIT_ID_SHORT=$(echo "${WS_COMMIT_ID}" | cut -c1-6)

cd $STARTUPDIR
mkdir jsmpeg
wget -qO- https://kasmweb-build-artifacts.s3.amazonaws.com/kasm_websocket_relay/${WS_COMMIT_ID}/kasm_websocket_relay_${ARCH}_${WS_BRANCH}.${WS_COMMIT_ID_SHORT}.tar.gz | tar xz --strip 1 -C $STARTUPDIR/jsmpeg
chmod +x $STARTUPDIR/jsmpeg/kasm_audio_out-linux

#!/usr/bin/env bash
set -ex

# Setup systemd based on distro type
if [[ "${DISTRO}" == @(ubuntu|debian|parrotos7|kali) ]] ; then
  # Install deps
  apt-get update
  apt-get install -y --no-install-recommends \
    dbus \
    iproute2 \
    iptables \
    kmod \
    libsystemd0 \
    sudo \
    systemd \
    systemd-sysv \
    udev
elif [[ "${DISTRO}" == @(oracle8|oracle9|rhel9|rockylinux9|rockylinux8|almalinux9|almalinux8|fedora42|fedora43) ]]; then
  # Install deps
  dnf install -y \
    dbus \
    iproute \
    iptables \
    kmod \
    sudo \
    systemd \
    udev
elif [ "${DISTRO}" == "opensuse" ]; then
  # Install deps
  zypper install -y \
    dbus-1 \
    iproute2 \
    iptables \
    kmod \
    sudo \
    systemd \
    udev
fi


# Disable systemd stuff that does not work
echo "ReadKMsg=no" >> /etc/systemd/journald.conf
systemctl mask \
  systemd-udevd.service \
  systemd-journald-audit.socket \
  systemd-udevd-kernel.socket \
  systemd-udevd-control.socket \
  systemd-modules-load.service \
  systemd-udev-trigger.service \
  sys-kernel-config.mount \
  sys-kernel-debug.mount \
  sys-kernel-tracing.mount
rm -f /usr/share/dbus-1/system-services/org.freedesktop.UPower.service

# Generate our standard init systemd service and init helper.
# Phase 6: sysbox is the only path where container-init is not PID 1
# (real systemd holds PID 1; container-init runs as a kasm.service
# child). EnvironmentFile=/envdump is still required because real
# systemd doesn't inherit `docker run -e ...` envvars by default —
# /kasm-sysbox-setup.sh below dumps /proc/1/environ into /envdump
# before kasm.service starts. container-init owns identity, OS-user
# rename, and per-service privilege drop via its own unit set, so the
# unit no longer needs User=/Group= lines.
cat >/etc/systemd/system/kasm.service<<EOL
[Unit]
Description=Kasm Workspaces Init (container-init under real systemd)
After=kasm-setup.service

[Service]
EnvironmentFile=/envdump
Type=simple
ExecStart=/usr/local/bin/container-init

[Install]
WantedBy=multi-user.target
EOL
cat >/etc/systemd/system/kasm-setup.service<<EOL
[Unit]
Description=Kasm Workspaces root level setup
Before=kasm.service

[Service]
Type=oneshot
ExecStart=/bin/bash /kasm-sysbox-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL
cat >/kasm-sysbox-setup.sh<<'EOL'
#!/bin/bash
set -eu
KASM_OS_USER="${KASM_OS_USER:-kasm-user}"
KASM_OS_GROUP="${KASM_OS_GROUP:-${KASM_OS_USER}}"
# Run any KASM_OS_* rename pre-emptively so /var/run/pulse can be
# chowned to the destination user, and so the kasm.service unit
# starts container-init under a system that already has the renamed
# user. container-init's own kasm-setup.service re-runs the rename
# (idempotent — see scripts/kasm-os-user-rename).
if [ -x /usr/local/bin/kasm-os-user-rename ] && [ "$KASM_OS_USER" != "kasm-user" ]; then
    /usr/local/bin/kasm-os-user-rename || true
fi
mkdir -p /var/run/pulse
chown "$KASM_OS_USER":"$KASM_OS_GROUP" /var/run/pulse
cat /proc/1/environ | xargs --null --max-args=1 > /envdump
if [ -f /usr/sbin/policy-rc.d ]; then
  printf '#!/bin/sh\nexit 0' > /usr/sbin/policy-rc.d
fi
systemctl disable gdm
systemctl disable power-profiles-daemon
systemctl disable sshd
systemctl disable unattended-upgrades
systemctl disable upower
systemctl disable wpa_supplicant
systemctl stop gdm
systemctl stop power-profiles-daemon
systemctl stop sshd
systemctl stop unattended-upgrades
systemctl stop upower
systemctl stop wpa_supplicant
EOL
chmod +x /kasm-sysbox-setup.sh
chmod 644 /etc/systemd/system/kasm.service /etc/systemd/system/kasm-setup.service
systemctl enable kasm kasm-setup

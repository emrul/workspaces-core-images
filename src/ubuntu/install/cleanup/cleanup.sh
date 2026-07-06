#!/usr/bin/env bash
set -ex

# Distro package cleanup
if [[ "${DISTRO}" == @(almalinux8|almalinux9|fedora42|fedora43|oracle8|oracle9|rhel9|rockylinux8|rockylinux9) ]]; then
  dnf clean all
elif [ "${DISTRO}" == "opensuse" ]; then
  zypper clean --all
elif [[ "${DISTRO}" == @(debian|kali|parrotos7|ubuntu) ]]; then
  # Uninstall unneccesary/vulnerable packages
  dpkg --purge ipp-usb #KASM-5266
  apt-get autoremove -y
  apt-get autoclean -y
fi

# Phase 6.7 — drop perl runtime by default. Nothing in the boot path
# needs perl: container-init's kasm-xvnc execs Xvnc directly,
# bypassing KasmVNC's perl `vncserver` wrapper (Phase 4.4); kasmvncpasswd
# and Xvnc themselves are C binaries. Kasm orchestrator stops
# containers, not vnc displays, so the standalone `vncserver -kill :1`
# / `-list` CLIs are unused. Saves ~70 MiB on Debian-family,
# ~50 MiB on RHEL-family, ~25 MiB on Alpine. Escape hatch:
# --build-arg INCLUDE_PERL=1 keeps the runtime in place for image
# authors who exec the standalone CLIs.
if [ "${INCLUDE_PERL:-0}" != "1" ]; then
    if [[ "${DISTRO}" == @(almalinux8|almalinux9|fedora42|fedora43|oracle8|oracle9|rhel9|rockylinux8|rockylinux9) ]]; then
        # KasmVNC RPM declares perl-interpreter as a hard Requires; --nodeps
        # is the only way to remove it without uninstalling KasmVNC.
        rpm -qa 'perl-*' perl perl-libs perl-interpreter 2>/dev/null \
            | sort -u | xargs -r rpm -e --nodeps 2>/dev/null || true
        dnf clean all
    elif [ "${DISTRO}" == "opensuse" ]; then
        rpm -qa 'perl-*' perl perl-base 2>/dev/null \
            | sort -u | xargs -r rpm -e --nodeps 2>/dev/null || true
        zypper clean --all
    elif [[ "${DISTRO}" == @(debian|kali|parrotos7|ubuntu) ]]; then
        # KasmVNC's deb declares `perl` as a hard Depends; --force-depends
        # is the only way to remove it without uninstalling KasmVNC.
        # `perl-base` is also Priority: required (Essential: yes), so
        # --force-remove-essential is required to drop /usr/bin/perl
        # itself. Enumerate packages dynamically — Debian-family ships
        # the perl interpreter, perl-base, perl-modules-5.X, libperl5.X,
        # and a long tail of `lib*-perl` modules pulled in by KasmVNC's
        # standalone wrapper.
        perl_pkgs=$(dpkg-query -W -f='${Package}\n' 2>/dev/null \
            | grep -E '^(perl|perl-.+|libperl[0-9].*|.+-perl)$' || true)
        if [ -n "$perl_pkgs" ]; then
            echo "$perl_pkgs" | xargs dpkg --remove \
                --force-depends --force-remove-essential 2>&1 \
                | tail -5 || true
        fi
        apt-get autoremove -y 2>/dev/null || true
    elif [ "${DISTRO}" == "alpine" ]; then
        apk del --no-network \
            perl perl-datetime perl-hash-merge-simple perl-list-moreutils \
            perl-switch perl-try-tiny perl-yaml-tiny perl-datetime-timezone \
            2>/dev/null || true
    fi
fi

# File cleanups
rm -Rf \
  /home/kasm-default-profile/.cache \
  /home/kasm-user/.cache \
  /tmp \
  /var/lib/apt/lists/* \
  /var/tmp/*
mkdir -m 1777 /tmp

# Tier A universal trim — these paths are useless in a runtime image
# regardless of language/region. Saves ~50 MiB on Ubuntu/Debian.
rm -rf \
  /usr/share/doc/* \
  /usr/share/man/* \
  /usr/share/info/* \
  /usr/libexec/gcc \
  /var/cache/apt/archives/*.deb 2>/dev/null || true

# Drop xfce4-{mail-reader,web-browser}.desktop launchers when no real
# mail/browser is installed. They exec `exo-open --launch X` which
# fails on the core-ubuntu-noble base (no firefox/chromium/thunderbird
# installed); the menu entry just confuses the user.
if ! command -v firefox >/dev/null 2>&1 \
        && ! command -v chromium >/dev/null 2>&1 \
        && ! command -v google-chrome >/dev/null 2>&1; then
    rm -f /usr/share/applications/xfce4-web-browser.desktop
fi
if ! command -v thunderbird >/dev/null 2>&1 \
        && ! command -v evolution >/dev/null 2>&1 \
        && ! command -v geary >/dev/null 2>&1; then
    rm -f /usr/share/applications/xfce4-mail-reader.desktop
fi

# Pre-create the X server's UNIX-socket directories so the session running as
# uid 1000 doesn't trip _IceTransmkdir / _XSERVTransmkdir errors at every boot.
install -d -m 1777 /tmp/.ICE-unix /tmp/.X11-unix

# Remove xfce4-screensaver bin if it exists
if which xfce4-screensaver; then
  rm -f $(which xfce4-screensaver)
fi

# Services we don't want to start disable in xfce init
rm -f \
  /etc/xdg/autostart/blueman.desktop \
  /etc/xdg/autostart/geoclue-demo-agent.desktop \
  /etc/xdg/autostart/gnome-keyring-pkcs11.desktop \
  /etc/xdg/autostart/gnome-keyring-secrets.desktop \
  /etc/xdg/autostart/gnome-keyring-ssh.desktop \
  /etc/xdg/autostart/gnome-shell-overrides-migration.desktop \
  /etc/xdg/autostart/light-locker.desktop \
  /etc/xdg/autostart/org.gnome.Evolution-alarm-notify.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.A11ySettings.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Color.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Datetime.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Housekeeping.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Keyboard.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.MediaKeys.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Power.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.PrintNotifications.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Rfkill.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.ScreensaverProxy.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Sharing.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Smartcard.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Sound.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.UsbProtection.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Wacom.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.Wwan.desktop \
  /etc/xdg/autostart/org.gnome.SettingsDaemon.XSettings.desktop \
  /etc/xdg/autostart/pulseaudio.desktop \
  /etc/xdg/autostart/xfce4-power-manager.desktop \
  /etc/xdg/autostart/xfce4-screensaver.desktop \
  /etc/xdg/autostart/xfce-polkit.desktop \
  /etc/xdg/autostart/xscreensaver.desktop \
  /etc/xdg/autostart/nm-applet.desktop \
  /etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop \
  /etc/xdg/autostart/xiccd.desktop \
  /etc/xdg/autostart/print-applet.desktop \
  /etc/xdg/autostart/system-config-printer.desktop

# gvfs volume monitors: removed by default (saves ~30 MiB across 4-5 monitor
# processes); image authors can opt in with `--build-arg KASM_ENABLE_GVFS=1`.
# Note: on Ubuntu/Debian the monitors are *not* registered as autostart
# desktop entries — they're spawned by gvfsd from .monitor descriptors in
# /usr/share/gvfs/remote-volume-monitors/. The .desktop fallback covers
# distros where they are.
if [[ "${KASM_ENABLE_GVFS:-0}" != "1" ]]; then
    rm -f /usr/share/gvfs/remote-volume-monitors/*.monitor
    rm -f /etc/xdg/autostart/gvfs-*-volume-monitor.desktop
fi

# Locale / font / IME profile trim — gated by KASM_LANG_PROFILE env var,
# passed in from the dockerfile build arg of the same name. Defaults
# to `full` (no trim) so the unmodified build is bit-compatible.
#
#   full   — keep every locale, langpack, font, and ibus dict shipped
#            by the base image. Default.
#   latin  — keep Latin-script European languages (and Cyrillic/Greek
#            neighbours commonly bundled together). Drops CJK Noto
#            fonts and ibus CJK dictionaries. Saves ~250 MiB on
#            ubuntu/debian; less on Alpine/RHEL where shipped data is
#            smaller.
#   en     — Strips all gettext .mo translation catalogs (locale-langpack
#            and locale) and rebuilds the glibc archive to en_* only.
#            Fonts are kept in full — including CJK — so browsers and
#            other apps can still render any language. Saves ~500 MiB on
#            ubuntu/debian.
#
# All steps are best-effort and silently no-op when the relevant
# files / commands aren't present (e.g. Alpine has no locale-archive,
# Fedora ships less locale data to begin with).
case "${KASM_LANG_PROFILE:-full}" in
    full)
        : # no trim
        ;;
    latin)
        # Latin-script European + Cyrillic/Greek neighbours.
        keep_dir_re='^(en|en_.*|es|es_.*|fr|fr_.*|de|de_.*|it|it_.*|pt|pt_.*|nl|nl_.*|pl|pl_.*|sv|sv_.*|da|da_.*|no|no_.*|nb|nn|fi|fi_.*|cs|cs_.*|hu|hu_.*|tr|tr_.*|ro|ro_.*|ru|ru_.*|uk|uk_.*|el|el_.*|bg|bg_.*|sr|sr_.*|hr|hr_.*|sk|sk_.*|sl|sl_.*|lt|lt_.*|lv|lv_.*|et|et_.*|ca|ca_.*|gl|gl_.*|eu|eu_.*|is|is_.*|mt|mt_.*|ga|ga_.*|cy|cy_.*|C|C\.UTF-8|POSIX)$'
        keep_arch_re='^(en_|es_|fr_|de_|it_|pt_|nl_|pl_|sv_|da_|no_|nb_|nn_|fi_|cs_|hu_|tr_|ro_|ru_|uk_|el_|bg_|sr_|hr_|sk_|sl_|lt_|lv_|et_|ca_|gl_|eu_|is_|mt_|ga_|cy_|C|POSIX)'

        # /usr/share/locale-langpack (Ubuntu/Debian translations).
        if [ -d /usr/share/locale-langpack ]; then
            for d in /usr/share/locale-langpack/*; do
                [ -d "$d" ] || continue
                name=$(basename "$d")
                echo "$name" | grep -qE "$keep_dir_re" || rm -rf "$d"
            done
        fi
        # /usr/share/locale (gettext catalogs from individual packages).
        if [ -d /usr/share/locale ]; then
            for d in /usr/share/locale/*; do
                [ -d "$d" ] || continue
                name=$(basename "$d")
                echo "$name" | grep -qE "$keep_dir_re" || rm -rf "$d"
            done
        fi
        # Rebuild glibc locale-archive to Latin-only.
        if command -v localedef >/dev/null 2>&1 && [ -f /usr/lib/locale/locale-archive ] && [ -d /usr/share/i18n/locales ]; then
            keep_list=$(localedef --list-archive 2>/dev/null | grep -E "$keep_arch_re" || true)
            rm -f /usr/lib/locale/locale-archive
            echo "$keep_list" | while IFS= read -r loc; do
                [ -z "$loc" ] && continue
                base=${loc%.*}
                charset=${loc#*.}
                case "$charset" in
                    utf8|UTF-8|UTF8|"$loc") cf=UTF-8 ;;
                    *) continue ;;
                esac
                [ "$base" = "C" ] || [ "$base" = "POSIX" ] && continue
                localedef -i "$base" -f "$cf" "${base}.UTF-8" 2>/dev/null || true
            done
        fi
        # /usr/share/i18n/locales (locale source files).
        if [ -d /usr/share/i18n/locales ]; then
            for f in /usr/share/i18n/locales/*; do
                [ -f "$f" ] || continue
                name=$(basename "$f")
                echo "$name" | grep -qE "$keep_dir_re" || rm -f "$f"
            done
        fi

        # Drop CJK Noto fonts and ibus CJK dictionaries.
        rm -f /usr/share/fonts/opentype/noto/NotoSansCJK*.ttc \
              /usr/share/fonts/opentype/noto/NotoSerifCJK*.ttc \
              /usr/share/fonts/truetype/noto/NotoSansCJK*.ttc \
              /usr/share/fonts/truetype/noto/NotoSerifCJK*.ttc 2>/dev/null || true
        rm -rf /usr/share/ibus/dicts 2>/dev/null || true
        ;;
    en)
        # Drop all gettext .mo translation catalogs entirely — these only
        # translate system utility UI strings and are never needed in a
        # browser-focused image. English is the runtime default regardless.
        rm -rf /usr/share/locale-langpack 2>/dev/null || true
        if [ -d /usr/share/locale ]; then
            for d in /usr/share/locale/*; do
                [ -d "$d" ] || continue
                name=$(basename "$d")
                echo "$name" | grep -qE '^(en|en_.*|C|C\.UTF-8|POSIX)$' || rm -rf "$d"
            done
        fi

        # Rebuild glibc locale-archive to en_* only.
        if command -v localedef >/dev/null 2>&1 && [ -f /usr/lib/locale/locale-archive ] && [ -d /usr/share/i18n/locales ]; then
            keep_list=$(localedef --list-archive 2>/dev/null | grep -E '^(en_|C|POSIX)' || true)
            rm -f /usr/lib/locale/locale-archive
            echo "$keep_list" | while IFS= read -r loc; do
                [ -z "$loc" ] && continue
                base=${loc%.*}
                charset=${loc#*.}
                case "$charset" in
                    utf8|UTF-8|UTF8|"$loc") cf=UTF-8 ;;
                    *) continue ;;
                esac
                [ "$base" = "C" ] || [ "$base" = "POSIX" ] && continue
                localedef -i "$base" -f "$cf" "${base}.UTF-8" 2>/dev/null || true
            done
        fi
        # /usr/share/i18n/locales (locale source files).
        if [ -d /usr/share/i18n/locales ]; then
            for f in /usr/share/i18n/locales/*; do
                [ -f "$f" ] || continue
                name=$(basename "$f")
                echo "$name" | grep -qE '^(en|en_.*|C|C\.UTF-8|POSIX)$' || rm -f "$f"
            done
        fi

        # Fonts are kept in full (including CJK) so browsers can render
        # any language. Drop only ibus input method dicts (not needed
        # when the system locale is English).
        rm -rf /usr/share/ibus/dicts 2>/dev/null || true
        ;;
    *)
        echo "WARN: unknown KASM_LANG_PROFILE='${KASM_LANG_PROFILE}' (expected: full|latin|en) — ignoring"
        ;;
esac

# Cleanup specific to KasmOS
if [ "$1" = "kasmos" ] ; then
  echo "Removing packages from base"
  packages=("konsole" "geeqie" "gwenview" "imagemagick-6.q16" "kate" "dolphin")
  for package in ${packages[@]}; do
    if [[ $(apt -qq list "$package") ]] ; then
      echo "Removing package $package."
      apt remove -y ${package}
    else
      echo "Package ${package} not found."
    fi
  done
 apt autoremove -y

fi

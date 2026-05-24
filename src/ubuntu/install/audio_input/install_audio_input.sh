#!/usr/bin/env bash
### every exit != 0 fails the script
set -e

COMMIT_ID="d42f0ca30311beaed2c9833fbd71ba56ddae7ec6"
BRANCH="develop"
COMMIT_ID_SHORT=$(echo "${COMMIT_ID}" | cut -c1-6)
ARCH=$(arch | sed 's/aarch64/arm64/g' | sed 's/x86_64/amd64/g')

mkdir -p $STARTUPDIR/audio_input
wget -qO- https://kasmweb-build-artifacts.s3.amazonaws.com/kasm_audio_input_server/${COMMIT_ID}/kasm_audio_input_server_${ARCH}_${BRANCH}.${COMMIT_ID_SHORT}.tar.gz | tar -xvz -C $STARTUPDIR/audio_input/
echo "${BRANCH}:${COMMIT_ID}" > $STARTUPDIR/audio_input/kasm_audio_input_server.version

if [ "${DISTRO}" == "opensuse" ] && grep -q "16" /etc/os-release; then
  # kasm_audio_input_server is a staticx binary that bundles libreadline 8.0/8.1
  # and sets LD_LIBRARY_PATH to its extraction dir. On openSUSE 16, bash is
  # compiled against readline 8.2 and requires rl_trim_arg_from_keyseq; loading
  # the full system libreadline fails because it needs GLIBC_2.38 which the
  # staticx bundled libc doesn't provide.
  zypper install -y gcc
  cat > /tmp/readline_compat.c << 'EOF'
/* Stubs for readline 8.2 symbols missing from the staticx bundled libreadline.
   All were added in readline 8.2; bash on openSUSE 16 requires them at load
   time even in non-interactive (/bin/sh -c) mode. */
__attribute__((visibility("default"))) int  rl_trim_arg_from_keyseq(void *k, unsigned long n, void *m) { return 0; }
__attribute__((visibility("default"))) int  rl_set_timeout(unsigned int s, unsigned int us) { return 0; }
__attribute__((visibility("default"))) int  rl_clear_timeout(void) { return 0; }
__attribute__((visibility("default"))) int  rl_timeout_remaining(unsigned int *s, unsigned int *us) { return 1; }
__attribute__((visibility("default"))) void rl_activate_mark(void) {}
__attribute__((visibility("default"))) void rl_deactivate_mark(void) {}
__attribute__((visibility("default"))) int  rl_mark_active_p(void) { return 0; }
EOF
  gcc -shared -fPIC -fno-stack-protector -nostdlib \
      -o /usr/local/lib/libreadline_compat.so /tmp/readline_compat.c
  rm /tmp/readline_compat.c
  zypper remove -y gcc || true

  mv $STARTUPDIR/audio_input/kasm_audio_input_server \
     $STARTUPDIR/audio_input/kasm_audio_input_server.bin
  cat > $STARTUPDIR/audio_input/kasm_audio_input_server << 'WRAPPER'
#!/bin/bash
exec env LD_PRELOAD=/usr/local/lib/libreadline_compat.so \
  /dockerstartup/audio_input/kasm_audio_input_server.bin "$@"
WRAPPER
  chmod +x $STARTUPDIR/audio_input/kasm_audio_input_server
  chmod +x $STARTUPDIR/audio_input/kasm_audio_input_server.bin
fi

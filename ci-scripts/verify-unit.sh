#!/bin/bash
set -euxo pipefail

if [[ -x /usr/bin/kasm-profile-sync-2 ]]; then
    /usr/bin/kasm-profile-sync-2 --help
else
    echo "skipping /usr/bin/kasm-profile-sync-2 test as it is not installed"
fi

# Phase 4.8 — verify container-init artifacts shipped and the unit set
# parses cleanly under the strict validator. The dockerfile RUN already
# invokes --validate at build time, but re-running here from the
# assembled image catches layer-order regressions and missing drop-ins.
if [[ -x /usr/local/bin/container-init ]]; then
    /usr/local/bin/container-init \
        --units /etc/container-init/units \
        --drop-in /etc/container-init.d \
        --strict-units \
        --validate
    test -x /usr/local/bin/kasm-xvnc
    test -x /usr/local/bin/kasm-entrypoint
else
    echo "skipping container-init verify (binary not present in this image)"
fi

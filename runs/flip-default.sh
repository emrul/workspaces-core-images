#!/usr/bin/env bash
# Phase 5 5.x.4 — flip default ENTRYPOINT path to container-init.
# Adds `ENV CONTAINER_INIT=1` immediately before each
# `ENTRYPOINT ["/usr/local/bin/kasm-entrypoint"]` line in the 7
# distro dockerfiles. kasm-entrypoint already honours
# CONTAINER_INIT=0 for fall-back to the bash chain.
set -euo pipefail

dockerfiles=(
    dockerfile-kasm-core
    dockerfile-kasm-core-alpine
    dockerfile-kasm-core-centos
    dockerfile-kasm-core-fedora
    dockerfile-kasm-core-kasmos
    dockerfile-kasm-core-oracle
    dockerfile-kasm-core-suse
)

for f in "${dockerfiles[@]}"; do
    if grep -qE '^ENV CONTAINER_INIT=1' "$f"; then
        echo "$f: already flipped — skipping"
        continue
    fi
    if ! grep -qE '^ENTRYPOINT \["/usr/local/bin/kasm-entrypoint"\]' "$f"; then
        echo "$f: ENTRYPOINT line not found — refusing to edit"
        continue
    fi
    python3 - "$f" <<'PY'
import sys, re
fn = sys.argv[1]
src = open(fn).read()
new = re.sub(
    r'(\nENTRYPOINT \["/usr/local/bin/kasm-entrypoint"\])',
    '\n# Phase 5 5.x.4: container-init is now the default boot path.\n'
    '# Bash chain remains selectable via `-e CONTAINER_INIT=0`.\n'
    'ENV CONTAINER_INIT=1\n'
    r'\1',
    src,
    count=1,
)
if new == src:
    print(f"{fn}: no change applied (regex miss)", file=sys.stderr)
    sys.exit(2)
open(fn, "w").write(new)
print(f"{fn}: flipped")
PY
done

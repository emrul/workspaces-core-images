#!/usr/bin/env bash
# Exercises artifact_keeper.sh against fixture package-source files via
# AK_TEST_ROOT, so the rewrite tables can be checked without a container
# runtime. Run it from anywhere: bash src/ubuntu/install/artifact_keeper/artifact_keeper_test.sh
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "$0")" && pwd)"
AK="${HERE}/artifact_keeper.sh"
AKU="https://artifact.example.com"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ # check <desc> <file> <grep-expr>
  if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (expected /$3/ in $2)"; fi
}
absent(){ if grep -qE -- "$3" "$2" 2>/dev/null; then bad "$1 (unexpected /$3/ in $2)"; else ok "$1"; fi }

fixture() {
  ROOT="$(mktemp -d)"
  mkdir -p "${ROOT}/etc/apt/sources.list.d" "${ROOT}/etc/yum.repos.d" "${ROOT}/etc/apk"
  # noble deb822
  cat >"${ROOT}/etc/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe
EOF
  # jammy-style .list
  cat >"${ROOT}/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu jammy main
deb https://security.ubuntu.com/ubuntu jammy-security main
deb http://ports.ubuntu.com/ubuntu-ports jammy main
EOF
  cat >"${ROOT}/etc/apk/repositories" <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.22/main
https://dl-cdn.alpinelinux.org/alpine/v3.22/community
EOF
  cat >"${ROOT}/etc/yum.repos.d/fedora.repo" <<'EOF'
[fedora]
name=Fedora $releasever - $basearch
#baseurl=http://download.example/pub/fedora/linux/releases/$releasever/Everything/$basearch/os/
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-$releasever&arch=$basearch
enabled=1
gpgcheck=1
EOF
  cat >"${ROOT}/etc/yum.repos.d/fedora-updates.repo" <<'EOF'
[updates]
name=Fedora $releasever - $basearch - Updates
#baseurl=http://download.example/pub/fedora/linux/updates/$releasever/Everything/$basearch/
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f$releasever&arch=$basearch
enabled=1
EOF
}

echo "== ubuntu: apply rewrites both deb822 and .list =="
fixture
AK_TEST_ROOT="$ROOT" AK_URL="$AKU" DISTRO=ubuntu bash "$AK" apply >/dev/null
check "deb822 archive -> AK"  "${ROOT}/etc/apt/sources.list.d/ubuntu.sources" "URIs: ${AKU}/debian/ubuntu-archive/"
check "deb822 security -> AK" "${ROOT}/etc/apt/sources.list.d/ubuntu.sources" "URIs: ${AKU}/debian/ubuntu-security/"
check ".list archive -> AK"   "${ROOT}/etc/apt/sources.list" "${AKU}/debian/ubuntu-archive jammy"
check ".list https security"  "${ROOT}/etc/apt/sources.list" "${AKU}/debian/ubuntu-security jammy-security"
check ".list ports -> AK"     "${ROOT}/etc/apt/sources.list" "${AKU}/debian/ubuntu-ports jammy"
absent "no upstream host left" "${ROOT}/etc/apt/sources.list" "archive\.ubuntu\.com"
[ -f "${ROOT}/etc/apt/sources.list.ak-orig" ] && ok "backup taken" || bad "backup taken"

echo "== ubuntu: revert restores byte-for-byte =="
cp "${ROOT}/etc/apt/sources.list.ak-orig" /tmp/ak-expect-list
AK_TEST_ROOT="$ROOT" AK_URL="$AKU" DISTRO=ubuntu bash "$AK" revert >/dev/null
if cmp -s /tmp/ak-expect-list "${ROOT}/etc/apt/sources.list"; then ok "sources.list identical to pre-apply"; else bad "sources.list differs after revert"; fi
absent "backups removed" <(ls "${ROOT}/etc/apt/") "ak-orig" 2>/dev/null || true
if ls "${ROOT}"/etc/apt/*.ak-orig >/dev/null 2>&1; then bad "backups removed"; else ok "backups removed"; fi

echo "== alpine =="
fixture
AK_TEST_ROOT="$ROOT" AK_URL="$AKU" DISTRO=alpine bash "$AK" apply >/dev/null
check "apk main preserves version path" "${ROOT}/etc/apk/repositories" "^${AKU}/alpine/alpine/v3\.22/main$"
check "apk community"                   "${ROOT}/etc/apk/repositories" "^${AKU}/alpine/alpine/v3\.22/community$"

echo "== fedora 42 =="
fixture
AK_TEST_ROOT="$ROOT" AK_URL="$AKU" DISTRO=fedora42 bash "$AK" apply >/dev/null
check "metalink disabled"      "${ROOT}/etc/yum.repos.d/fedora.repo" "^#ak-disabled-metalink="
absent "no live metalink"      "${ROOT}/etc/yum.repos.d/fedora.repo" "^metalink="
check "os baseurl + /os/"      "${ROOT}/etc/yum.repos.d/fedora.repo" "^baseurl=${AKU}/rpm/fedora-42-os/\\\$basearch/os/$"
check "updates baseurl, no os" "${ROOT}/etc/yum.repos.d/fedora-updates.repo" "^baseurl=${AKU}/rpm/fedora-42-updates/\\\$basearch/$"
absent "updates not given /os/" "${ROOT}/etc/yum.repos.d/fedora-updates.repo" "updates/\\\$basearch/os/"

echo "== off-path: AK_URL empty must change nothing =="
fixture
before="$(find "${ROOT}" -type f | sort | xargs shasum -a 256 | shasum -a 256)"
AK_TEST_ROOT="$ROOT" AK_URL="" DISTRO=ubuntu bash "$AK" apply >/dev/null
AK_TEST_ROOT="$ROOT" AK_URL="" DISTRO=ubuntu bash "$AK" revert >/dev/null
after="$(find "${ROOT}" -type f | sort | xargs shasum -a 256 | shasum -a 256)"
[ "$before" = "$after" ] && ok "tree unchanged with AK_URL empty" || bad "tree changed with AK_URL empty"

echo "== deferred distro must be a no-op even with AK_URL set =="
fixture
before="$(find "${ROOT}" -type f | sort | xargs shasum -a 256 | shasum -a 256)"
AK_TEST_ROOT="$ROOT" AK_URL="$AKU" DISTRO=kali bash "$AK" apply >/dev/null
after="$(find "${ROOT}" -type f | sort | xargs shasum -a 256 | shasum -a 256)"
[ "$before" = "$after" ] && ok "kali untouched" || bad "kali was modified"

echo "== apply twice must not poison the backup =="
fixture
AK_TEST_ROOT="$ROOT" AK_URL="$AKU" DISTRO=ubuntu bash "$AK" apply >/dev/null
AK_TEST_ROOT="$ROOT" AK_URL="$AKU" DISTRO=ubuntu bash "$AK" apply >/dev/null
absent "backup still pristine" "${ROOT}/etc/apt/sources.list.ak-orig" "artifact\.example\.com"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

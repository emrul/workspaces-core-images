#!/usr/bin/env bash
# Regenerate patches/ from the fork: one file per commit over the upstream tag, in
# series order. NOT plain `git format-patch`: several fork commits quote the original
# community patch verbatim in their message body, and GNU patch (what nixpkgs' patch
# phase runs) happily applies that quoted diff, then rejects the real one as already
# applied. So each file carries only the subject, the Source: trailer and the diff.
#   pkgs/kasm-wine/regen-patches.sh <fork checkout> [upstream-tag] [fork-tag]
set -euo pipefail
fork="${1:?fork checkout}"; base="${2:-wine-$(python3 -c 'import json;print(json.load(open("'"$(dirname "$0")"'/pin.json"))["version"])')}"
tag="${3:-$(python3 -c 'import json;print(json.load(open("'"$(dirname "$0")"'/pin.json"))["fork_tag"])')}"
out="$(cd "$(dirname "$0")" && pwd)/patches"
rm -f "$out"/*.patch; mkdir -p "$out"
n=0
for c in $(git -C "$fork" rev-list --reverse "$base..$tag"); do
    n=$((n+1))
    subject="$(git -C "$fork" log -1 --format=%s "$c")"
    slug="$(printf '%s' "$subject" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-60)"
    {
        printf 'Subject: %s\n' "$subject"
        printf 'Fork-Commit: %s\n' "$c"
        git -C "$fork" log -1 --format='%(trailers:key=Source)' "$c" | sed '/^$/d'
        printf '\n'
        git -C "$fork" diff-tree -p --binary --no-commit-id "$c"
    } > "$out/$(printf '%04d' "$n")-$slug.patch"
done
echo "wrote $n patches for $base..$tag into $out"

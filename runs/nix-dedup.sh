#!/usr/bin/env bash
# Measure cross-image OCI layer sharing for the Nix app images.
# Run under skopeo: `nix shell nixpkgs#skopeo --command bash runs/nix-dedup.sh`
# Reads the loaded docker-daemon images nix-<app>:spike + nix-fat:spike.
set -euo pipefail

imgs="${IMGS:-chrome chromium vscode firefox audacity fat}"
tag="${TAG:-spike}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

for img in $imgs; do
  skopeo inspect --raw "docker-daemon:nix-${img}:${tag}" \
    | jq -r '.layers[] | "\(.digest) \(.size)"' | sort -u > "$tmp/L-$img.txt"
done
human(){ numfmt --to=iec --suffix=B "${1:-0}"; }
sumsz(){ awk '{s+=$2} END{print s+0}' "$1"; }

echo "== Per-image (compressed layers / total bytes) =="
for img in $imgs; do
  printf '  %-9s %3s layers  %10s\n' "$img" "$(wc -l < "$tmp/L-$img.txt")" "$(human "$(sumsz "$tmp/L-$img.txt")")"
done

if [ -f "$tmp/L-fat.txt" ]; then
  echo
  echo "== Pull the fat image first, then each app costs: =="
  for app in $imgs; do
    [ "$app" = fat ] && continue
    read -r inf out < <(awk 'NR==FNR{f[$1];next}{if($1 in f){i+=$2}else{o+=$2}}END{print i+0, o+0}' \
      "$tmp/L-fat.txt" "$tmp/L-$app.txt")
    printf '  %-9s already-in-fat %9s  |  extra to pull %9s\n' "$app" "$(human "$inf")" "$(human "$out")"
  done
fi

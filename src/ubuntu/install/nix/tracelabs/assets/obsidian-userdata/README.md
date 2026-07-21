# Pre-trusted Obsidian state (Local Storage leveldb)

`Local Storage/leveldb/` is a **pre-trusted** Obsidian Electron store for the
seeded TL-Vault. Obsidian records "Restricted mode off" (i.e. the vault author is
trusted and community plugins may load) in this leveldb — **not** in any
`.obsidian/` vault file. Because each Kasm session gets a fresh home, without this
seed the *"Do you trust the author of this vault?"* prompt appears every session
and the bundled plugins (dataview, kanban, templater, quickadd, tag-wrangler)
stay disabled.

`post-build.sh` copies this into `/home/kasm-default-profile/.config/obsidian/`,
which `kasm-setup` clones into each new user's home.

## Version-pinned — regenerate when the `obsidian` nix package is bumped

The leveldb format is tied to the Obsidian/Electron version in the image. If it
drifts, worst case the seed is ignored and the trust prompt returns (no breakage).
To regenerate against the current image (`tracelabs-osint:nix`):

```sh
IMG=registry.gitlab.com/kasm-technologies/labs-sandbox/kasm-nix/tracelabs-osint:nix
cid=$(docker run -d --rm --shm-size=512m \
  --security-opt seccomp=<chrome.json> --security-opt apparmor=unconfined \
  -e VNC_PW=password "$IMG"); sleep 14
# launch Obsidian on the vault, wait for the trust modal
docker exec -u 1000 -d "$cid" sh -c \
  'DISPLAY=:1 /usr/local/bin/nix-launch /nix/var/nix/profiles/obsidian/bin/obsidian --disable-gpu'
sleep 22
# the "Trust author and enable plugins" button is focused → press Return
docker exec -u 1000 "$cid" sh -c 'DISPLAY=:1 <send XK_Return via XTEST>'
sleep 12   # let Electron journal the trust
# grab ONLY the Local Storage leveldb (the trust lives here; IndexedDB is just the
# note content index and is NOT needed)
docker exec "$cid" tar -C "/home/kasm-user/.config/obsidian" -czf /tmp/ls.tgz "Local Storage"
docker cp "$cid":/tmp/ls.tgz ./ls.tgz
# replace CURRENT + MANIFEST-* + *.log under Local Storage/leveldb/ here
```

Ship `CURRENT`, `MANIFEST-000001`, and the `*.log`; skip `LOCK` (runtime) and the
`LOG`/`LOG.old` debug logs.

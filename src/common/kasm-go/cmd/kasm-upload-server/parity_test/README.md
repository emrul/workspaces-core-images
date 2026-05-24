# kasm-upload-server parity tests

`run.sh` boots two containers from the same Kasm core image side by
side — one running the existing PyInstaller Flask helper at
`/dockerstartup/upload_server/kasm_upload_server`, one running the
Go drop-in built from `cmd/kasm-upload-server` — and asserts both
respond identically across the documented contract:

| Case | Asserted parity |
|---|---|
| missing Authorization header | status + body + Content-Type |
| wrong credentials             | status + body + Content-Type |
| Bearer (non-Basic) header     | status + body + Content-Type |
| garbage Authorization value   | status + body + Content-Type |
| missing required form field   | status only (Werkzeug's HTML 400 page is an implementation detail) |
| single-chunk happy path       | status + on-disk path / mode / owner / md5 |
| re-upload same name           | status (both return 400 "File already exists") |
| multi-chunk reassembly        | status of both chunks + final md5 + stat |

## Running

Phase 0/1/2 harness assumed: podman 4.8.2 in lima, log driver
forced to `k8s-file` (lima's default `journald` swallows
`podman logs`).

Build the Go binaries first:

```sh
make -C src/common/kasm-go upload
```

Then run:

```sh
src/common/kasm-go/cmd/kasm-upload-server/parity_test/run.sh
```

Override the image with `KASM_PARITY_IMAGE=<image>` if you want to
run the same harness against another distro's core image.

## Exit codes

- `0` — full parity
- `1` — at least one assertion failed (line-by-line diff in the output)
- `2` — Go binary not built (the harness can't proceed)

## What this does NOT cover

- Path-traversal sanitisation: Go's `mime/multipart` calls
  `filepath.Base` on part filenames before exposing them, so
  `../../../../etc/passwd-leak` lands as `passwd-leak` here vs the
  Python helper's `........etcpasswd-leak`. Both stay inside the
  upload dir; the noVNC client (file-picker source) never sends
  path-traversal filenames in production. Documented divergence,
  not asserted.
- HTTP/2: forced off in the Go binary
  (`TLSNextProto: empty map`) so the response start-line matches
  Werkzeug. Verified by ALPN advertising `http/1.1` only.

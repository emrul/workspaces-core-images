# extension-test-image

CI fixture exercising every documented `/etc/container-init.d/` worked
example against the production unit set. Layered on top of the
`kasm-prod-probe:latest` image produced by
`design/spike/scripts/probe-production.sh`.

## What it covers

| Pattern | File(s)                                             | What the probe asserts                                        |
| ------- | --------------------------------------------------- | ------------------------------------------------------------- |
| 1       | `dropins/myimage-init.service`                      | `Type=oneshot` spawn + sentinel `/tmp/extension-test/myimage-init.ran` |
| 2       | `dropins/myimage-app.service`                       | `Type=simple` spawn + sentinel `/tmp/extension-test/myimage-app.started` |
| 3       | `dropins/myhelper.{socket,service}`                 | `bound` event for `:5050`; helper inherits fd 3 with `LISTEN_FDS=1` |
| 4       | `dropins/kasmvnc.{socket,service}` (override-by-name) | `drop-in override: kasmvnc.service` log + `unit_overridden` trace event |
| 5       | `dropins/dbus-system.{socket,service}`              | AF_UNIX `bound` event at `/run/dbus/system_bus_socket`         |

## Running

```
design/spike/scripts/probe-extension.sh
```

The probe runs the fixture twice (default + headless) and writes
`design/spike/runs/probe-extension.{default,headless}.{trace.jsonl,stdout,...}`
for diffing on failure.

## Deviations from the README's worked examples

- **Pattern 2** depends on `kasm-setup.service` instead of
  `window-manager.service`, so the headless run (`KASM_VNC=0`) still
  exercises it. The README example targets headed deployments where
  the WM is the natural pre-req.
- **Pattern 5** runs a Python stub, not `dbus-daemon`. The fixture
  proves the supervisor activates the AF_UNIX socket and hands fd 3 to
  the consumer; image authors who actually want a system bus are
  expected to install `dbus` themselves.

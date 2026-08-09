# obs-1 — observability collector for Tetragon session monitoring

OCI `VM.Standard.A1.Flex` (2 OCPU / 12 GB, ARM64), Ubuntu 24.04,
region **us-phoenix-1** (same metro as the CIVO `phx1` cluster),
compartment `emrul-islam-dev`. Stack lives at `/opt/obs` on the host.

    ssh ubuntu@<obs-1 ip>
    cd /opt/obs && sudo docker compose ps

## Components

| | |
|---|---|
| Loki 3.6 | monolithic, filesystem, TSDB **v13** (required for structured metadata), 14-day retention enforced by the compactor |
| Prometheus 3.11 | health-only, 7-day retention, remote-write receiver enabled |
| Grafana 12.3 | anonymous auth disabled, Loki + Prometheus provisioned |
| Caddy 2.10 | TLS on :443 via its **internal CA**, basic-auth on the ingest paths |

## Endpoints

- `https://<ip>/loki/*` — push + query, basic auth
- `https://<ip>/prom/*` — remote-write, separate basic-auth credential
- `https://<ip>/` — Grafana

## Credentials

Generated on first boot into `/opt/obs/.secrets` (0600) and **never committed**.
Read them with `ssh ubuntu@<ip> 'sudo cat /opt/obs/.secrets'`. Rotate if they
leave the host.

## TLS

No public DNS name, so Caddy uses its own CA rather than ACME. Clients pin
`caddy-root-ca.crt` (committed here — it is a public certificate, not a secret).
A browser will warn unless you trust that CA locally.

## Gotchas hit while building this — do not re-learn them

1. **Compose interpolates `env_file` values.** A bcrypt hash contains `$`, so
   `$2a$14$...` arrived as 41 characters instead of 60 and auth silently failed
   with 401 on correct credentials. `caddy.env` stores hashes with `$$`.
2. **Do not name that file `.env`.** Compose auto-loads `.env` for its own
   interpolation, which mangles it before `env_file` is even considered.
3. **A bare `:443` Caddy block cannot serve an IP.** The internal CA has no name
   to issue for. Sites are declared explicitly, plus `default_sni`, because
   clients connecting to an IP send no SNI at all.
4. **OCI Ubuntu images reject everything except SSH.** A netfilter rule allows
   only :22; :443 must be inserted before the REJECT and persisted with
   `netfilter-persistent`. The OCI security list being correct is not enough.
5. **Network resources must go in the developer sandbox compartment**
   (`emrul-islam-dev`), not `development` directly — the IAM grant is scoped by
   a `Dev_tags.Owner_ID` tag match.

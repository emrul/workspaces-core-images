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

Base URL: `https://grafana.emrul.oci.dev.remotebrowser.net`

- `/loki/*` — push + query, basic auth
- `/prom/*` — remote-write, separate basic-auth credential
- `/` — Grafana

## Credentials

Generated on first boot into `/opt/obs/.secrets` (0600) and **never committed**.
Read them with `ssh ubuntu@<ip> 'sudo cat /opt/obs/.secrets'`. Rotate if they
leave the host.

## TLS

Real Let's Encrypt certificate for `grafana.emrul.oci.dev.remotebrowser.net`.
Clients verify normally — no CA pinning, no browser warning.

**Port 80 is open to 0.0.0.0/0 for the ACME HTTP-01 challenge**, which is what
lets renewals keep working unattended. **Port 443 remains restricted** to the
admin IP and the CIVO egress IP, so the actual data paths are not internet
exposed. Closing :80 would break renewal in ~60 days.

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
5. **Compose secrets keep the host file's ownership.** `.gf_admin` was created
   by `ubuntu` (uid 1001, mode 0600) while Grafana runs as uid 472, so Grafana
   got `Permission denied`, silently ignored `GF_SECURITY_ADMIN_PASSWORD__FILE`,
   and initialised the database with the built-in default password. No error,
   healthy container. The file must be `chown 472:472`.
   Note also that Grafana only applies the admin password when it *creates* the
   database — fixing permissions afterwards changes nothing, and the live
   account needs `grafana cli admin reset-admin-password`.
6. **Network resources must go in the developer sandbox compartment**
   (`emrul-islam-dev`), not `development` directly — the IAM grant is scoped by
   a `Dev_tags.Owner_ID` tag match.

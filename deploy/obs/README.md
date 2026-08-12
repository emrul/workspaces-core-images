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

## Rebuild from scratch

The files in this directory are the whole stack, but standing up the host is
manual. This sequence is **reconstructed from the running host's layout**, not
transcribed from a session — verify each step as you go rather than trusting it.
The cluster side is `deploy/civo/README.md` §2.12.

1. **VM.** `VM.Standard.A1.Flex`, 2 OCPU / 12 GB, Ubuntu 24.04 (ARM64),
   `us-phoenix-1`, compartment **`emrul-islam-dev`** — network resources must go in
   the developer sandbox compartment, not `development`, because the IAM grant is
   scoped by a `Dev_tags.Owner_ID` tag match (gotcha 6).
2. **Security list:** ingress `80/tcp` from `0.0.0.0/0` (ACME HTTP-01 — closing it
   breaks renewal in ~60 days) and `443/tcp` from the admin IP **and the CIVO
   cluster's egress IP** only.
3. **Host firewall** — the OCI security list is not enough (gotcha 4):
   ```bash
   sudo iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT
   sudo iptables -I INPUT 6 -p tcp --dport 80  -j ACCEPT
   sudo netfilter-persistent save
   ```
4. **DNS:** `grafana.emrul.oci.dev.remotebrowser.net` → the VM's public IP. Must
   resolve *before* Caddy starts, or the certificate order fails.
5. **Docker + compose plugin**, then copy this directory to `/opt/obs`.
6. **Secrets** — into `/opt/obs`, mode 0600, never committed:
   ```bash
   umask 077
   LOKI_PW=$(openssl rand -base64 24); PROM_PW=$(openssl rand -base64 24)
   GF_PW=$(openssl rand -base64 24)
   printf 'loki_user=civo_phx1\nloki_password=%s\nprom_password=%s\ngrafana_admin=%s\n' \
     "$LOKI_PW" "$PROM_PW" "$GF_PW" | sudo tee /opt/obs/.secrets >/dev/null

   # Hashes go in caddy.env with EVERY $ DOUBLED (gotcha 1), and the file must NOT
   # be named .env (gotcha 2).
   hash() { docker run --rm caddy:2.10-alpine caddy hash-password --plaintext "$1" | sed 's/\$/$$/g'; }
   { echo "LOKI_USER=civo_phx1";  echo "LOKI_HASH=$(hash "$LOKI_PW")"
     echo "PROM_USER=civo_phx1";  echo "PROM_HASH=$(hash "$PROM_PW")"; } \
     | sudo tee /opt/obs/caddy.env >/dev/null

   printf '%s' "$GF_PW" | sudo tee /opt/obs/.gf_admin >/dev/null
   sudo chown 472:472 /opt/obs/.gf_admin   # gotcha 5 — Grafana runs as uid 472
   ```
7. **Start:** `cd /opt/obs && sudo docker compose up -d`, then confirm Caddy has a
   real certificate (`curl -sI https://grafana.emrul.oci.dev.remotebrowser.net`
   with no `-k`) and that the Grafana admin password is the generated one — if the
   database was created before `.gf_admin` had the right ownership, the live account
   keeps the built-in default and needs
   `grafana cli admin reset-admin-password` (gotcha 5).
8. **Hand the ingest credentials to the cluster** — the `alloy-tetragon-creds`
   secret in `kasm-monitoring` (`deploy/civo/README.md` §2.11).

Dashboards, alert rules and datasources are provisioned from this directory
(`dashboards/`, `alerting/`, `grafana-*.yaml`), so they come up with the stack. The
Prometheus health-plane **alert rules are still not written** —
`design/tetragon-session-monitoring.md` §7.

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

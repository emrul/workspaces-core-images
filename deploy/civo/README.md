# CIVO deployment — recreate runbook

The Kasm deployment behind `tracelabs.kasm.com`: a 3-node CIVO k3s cluster running
Kasm 1.19.0 via the lifecycle operator, with Tetragon session monitoring shipping
to `obs-1` in OCI, and an optional compressed-memory (zswap) layer.

**Audience:** whoever has to rebuild this, possibly without the person who built
it. **Verified against live state 2026-08-12.** Where this document and the
cluster disagree, the cluster is right and this file is stale — fix it.

Read §3 before starting. Roughly a third of this deployment is not, and cannot
be, reproduced from files in this repo, and knowing which third is the difference
between a two-hour rebuild and a two-day one.

---

## 0. What is deployed

| Layer | Live value | Source of truth |
|---|---|---|
| Cluster | `kasm-tracelabs`, CIVO `phx1`, k3s `1.36.0-k3s1`, 3 × `g4m.kube.medium` (4 vCPU / 32 GB / 80 GB), Alpine 3.22, kernel 6.12.85-0-lts | `00-cluster.sh` |
| CIVO apps | `traefik2-nodeport`, `cert-manager` | `00-cluster.sh` |
| Firewall | `kasm-tracelabs-fw`: ingress 80, 443, 6443 from `0.0.0.0/0`; all egress | `00-cluster.sh` (`--create-firewall`) |
| Issuers | `letsencrypt-prod`, `letsencrypt-staging` (HTTP-01 via ingress class `traefik`) | `10-cluster-issuers.yaml` |
| Kasm platform | operator helm release `kasm-operator` 1.18.1 → `Kasm/kasm` CR, version 1.19.0, `deploymentSize: small` | `20-kasm.yaml` |
| Ingress path | 2 × Traefik `IngressRouteTCP`, TLS passthrough, SNI-matched | `21-ingressroute-tcp.yaml` |
| Image pre-pull | `KasmImagePuller/kasm-image-puller`, 3 images | `30-image-puller.yaml` |
| Seccomp installer | `KasmSeccompInstaller/kasm-kasmsecc` → `/var/lib/kubelet/seccomp/kasm` | operator-owned, auto-created |
| Detection | Tetragon 1.7.0 DaemonSet (`kube-system`), 6 tracing policies | `../tetragon/` |
| Shipping | Alloy DaemonSet in `kasm-monitoring` → Loki on obs-1 | `../tetragon/alloy*` |
| Collector | OCI `obs-1` (A1.Flex 2/12, us-phoenix-1): Loki 3.6, Prometheus 3.11, Grafana 12.3, Caddy | `../obs/` |
| **Optional** zswap | 10 GB swapfile + zswap zstd (pool 20%) on all 3 nodes, kubelet `LimitedSwap` | `optional-zswap/`, `runs/chrome-density/zswap-*.daemonset.yaml` |

Platform-side settings that are results, not defaults — do not "tidy" them:

- **`KASM_CPU_REQUEST_FACTOR=0.15`** on the agent. Sessions request 300m (2 cores ×
  0.15) with no limit, so they burst via CFS shares. This is what places 18
  sessions 6/node; a 2-core request fits ~1 session/node beside the control plane.
- **`hostUsers=false`** on every session pod, applied by the agent, not the CR.
  Container root maps to an unprivileged host uid — the control that makes
  unmediated `userns` creation tolerable on nodes with no AppArmor.
- **`nginxProbeTimeoutSeconds: 120` / `nginxReconcileIntervalSeconds: 30`** — raised
  while chasing the nginx-reload-at-provision failure.

---

## 1. What you must have before starting

| Input | Where it lives now | Notes |
|---|---|---|
| CIVO API key | `civo apikey ls` (profile `kasm`) | |
| GitLab pull creds for `registry.gitlab.com/kasm-technologies/playground/*` | `gitlab-pull` secret, `kasm-system` | every platform image is a private playground build |
| GitLab deploy token for `labs-sandbox/kasm-nix/*` | plaintext in the `KasmImagePuller` CR | **rotate it** — see §3 |
| Kasm license key | `licenses.license_key` in the Kasm DB | reissue required, see §3 |
| DNS control for `tracelabs.kasm.com` + `sessions.tracelabs.kasm.com` | — | both must resolve before issuance |
| Operator helm chart | local clone `~/dev/kasm/gitlab/kasm-kubernetes-operator`, branch `feat/userns-hostusers-oversub`, chart at `kasm-operator/helm` | not published to any repo |
| obs-1 basic-auth creds | `/opt/obs/.secrets` on obs-1 (0600) | regenerated on a fresh obs-1 |

---

## 2. Recreate, in order

Each step ends with the check that proves it worked. Ordering is not cosmetic:
issuance needs DNS, the Kasm CR needs the pull secret, and Tetragon's export
allowlist needs session pods to exist before it captures anything.

### 2.1 Cluster

```bash
cd deploy/civo && ./00-cluster.sh
```

Verify: 3 nodes `Ready`, Alpine 3.22, kernel ≥6.1, and `/sys/kernel/btf/vmlinux`
present (Tetragon's hard gate).

### 2.2 DNS

Point both `tracelabs.kasm.com` and `sessions.tracelabs.kasm.com` at a node's
external IP (`civo kubernetes show kasm-tracelabs`). Any node works — traefik runs
on all three via nodeport.

Verify: both names resolve, and `curl -sk https://<name>` reaches Traefik (a 404
is fine at this stage).

### 2.3 Issuers

```bash
kubectl apply -f 10-cluster-issuers.yaml
kubectl get clusterissuer     # both Ready=True
```

While iterating, switch the Kasm CR to `letsencrypt-staging`: prod rate-limits
duplicate certificates to 5/week per name set and a rebuild loop will burn it.

### 2.4 Pull secret

```bash
kubectl create ns kasm-system
kubectl -n kasm-system create secret docker-registry gitlab-pull \
  --docker-server=registry.gitlab.com \
  --docker-username="$GL_USER" --docker-password="$GL_TOKEN"
```

### 2.5 Operator

```bash
helm upgrade --install kasm-operator \
  ~/dev/kasm/gitlab/kasm-kubernetes-operator/kasm-operator/helm \
  -n kasm-system \
  --set imagePullSecrets.enabled=true --set imagePullSecrets.name=gitlab-pull \
  --set rbac.imagePullerAgent.namespaces={kasm-system} \
  --set rbac.seccompInstallerAgent.namespaces={kasm-system}
```

Those two `rbac.*` lists are required: without them the workspaces operator cannot
create the image-puller and seccomp-installer DaemonSets, which fails later and
looks like an image problem.

Verify: **15** `kasm.com` CRDs established (the chart ships exactly 15 — confirmed
by `helm template`) and the `kasm-operator` pod Running. The live cluster has 16:
`kasmegressinstallers.kasm.com` predates this chart revision and has no instances
here, so a rebuild is not missing anything by ending up with 15.

### 2.6 Kasm platform

```bash
kubectl apply -f 20-kasm.yaml
kubectl -n kasm-system get kasm kasm -w
```

Verify: `PHASE: Running`, and every condition `True` up to `AgentDeployed`.
`db-init` is a Job that must reach Complete before the API comes up.

### 2.7 Ingress path

```bash
kubectl apply -f 21-ingressroute-tcp.yaml
```

Verify: `https://tracelabs.kasm.com` serves the Kasm login page with a valid
Let's Encrypt certificate. **Nothing else exposes this deployment** — the CR sets
`ingress.enabled: false` and `service.type: ClusterIP`, so a rebuild that skips
this step has every pod Running and an unreachable site.

### 2.8 Platform configuration (manual — see §3)

The rest of the deployment lives in the Kasm database, not in any manifest. Log in
as `admin@kasm.local` (password from the `kasm-secrets` secret) and restore:

1. **License** — Settings → Licensing. A rebuild has a **new installation ID**, so
   the existing key will not validate; get a reissue before you need concurrency.
2. **Registries** — Workspaces → Registry:
   - `https://kasm-nix-registry.emrul.dev/` channel `nix` (auto-update on)
   - `https://registry.kasmweb.com/` channel `1.19.0-rolling-weekly` (auto-update on)
3. **Workspaces** — install from those registries; all three currently
   `cores=2`, `memory_bytes` 2768 MiB, `cpu_allocation_method=Inherit`:
   - Trace Labs OSINT — `…/labs-sandbox/kasm-nix/tracelabs-osint:nix`
   - Only Office — `…/labs-sandbox/kasm-nix/only-office:nix`
   - KasmOS — `kasmweb/kasmos-desktop:1.19.0-rolling-daily`

   The per-app `run_config` (bwrap/Chrome seccomp patch, `user: root`,
   `KASM_SKIP_STARTUP_SCRIPT=1`) comes **from the registry**, so installing the
   workspace restores it. Do not hand-write it.
4. **Concurrency limits** — three stacked caps, hit in this order:
   - server `max_simultaneous_sessions` → **30** (default 1 on the auto-registered
     k8s agent; the first thing that blocks a load test)
   - group setting `max_kasms_per_user` ("All Users") → **20** (default 5)
   - the **license** concurrent-session entitlement — a hard ceiling, not bypassable
5. **Other "All Users" settings** that differ from stock: `idle_disconnect=20`,
   `keepalive_expiration=3600` with action `delete`, webcam and gamepad **off**,
   `kasmvnc_mode_preference` = JPEG/WEBP + H.264 + H.265 + AV1.

Verify: launch one Trace Labs session and reach the desktop.

### 2.9 Image pre-pull

```bash
sed -e "s|__GITLAB_DEPLOY_USER__|$GL_DEPLOY_USER|" \
    -e "s|__GITLAB_DEPLOY_TOKEN__|$GL_DEPLOY_TOKEN|" \
    30-image-puller.yaml | kubectl apply -f -
```

Verify: `kubectl -n kasm-system get kasmimagepuller kasm-image-puller -o yaml`
shows `All images pulled on 3/3 nodes`. Budget ~21 GB of node disk for the image
store — that measurement is what caps swap sizing in §2.12.

### 2.10 Tetragon

```bash
helm repo add cilium https://helm.cilium.io && helm repo update
# Helm 4 takes a post-renderer PLUGIN NAME, not a path — install the plugin first
# (deploy/tetragon/tetragon-postrender.sh). It fixes the chart's hard-coded
# terminationGracePeriodSeconds: 1, which is too short to unload BPF sensors.
helm upgrade --install tetragon cilium/tetragon --version 1.7.0 \
  -n kube-system -f ../tetragon/values-tetragon.yaml \
  --post-renderer tetragon-postrender --wait

kubectl apply -f ../tetragon/policy-userns.yaml \
              -f ../tetragon/policy-runtime-sockets.yaml \
              -f ../tetragon/policy-bpf-perf.yaml \
              -f ../tetragon/policy-modules.yaml \
              -f ../tetragon/policy-foreign-binary.yaml \
              -f ../tetragon/policy-egress.yaml
```

Verify via **metrics, not `tetra`** (gRPC is deliberately off):
`tetragon_tracingpolicy_loaded` should read `enabled=6 error=0 load_error=0` on
every node. See `design/tetragon-session-monitoring.md` §5 for the settings that
fail silently when changed — read that before altering the values file.

### 2.11 Alloy shipper

```bash
kubectl apply -f ../tetragon/alloy-daemonset.yaml    # creates the kasm-monitoring ns

kubectl -n kasm-monitoring create secret generic alloy-tetragon-creds \
  --from-literal=loki_password="$LOKI_PW" \
  --from-literal=prom_password="$PROM_PW"     # from obs-1:/opt/obs/.secrets

kubectl -n kasm-monitoring create configmap alloy-tetragon-config \
  --from-file=config.alloy=../tetragon/alloy.alloy

kubectl -n kasm-monitoring rollout restart ds/alloy-tetragon
```

The DaemonSet manifest carries a `checksum/config: "REPLACED_AT_APPLY"` annotation
— stamp it (or `rollout restart`) whenever `alloy.alloy` changes, or the config
change is invisible to running pods.

Verify: a LogQL query for `{cluster="civo-phx1"}` returns events, and the events
contain no `node_labels` (Alloy strips it — Tetragon's field filters cannot).

### 2.12 Collector (obs-1)

See `../obs/README.md` — including its "Rebuild from scratch" section for VM
shape, firewall, and the secret-ownership traps.

### 2.13 Optional: zswap

**Skip for a plain rebuild.** Nothing in the Kasm deployment depends on it, and
the density work concluded it buys nothing at achievable concurrency (memory sits
at ~51% of node RAM at the 18-session peak; zswap never engaged). Its remaining
value is graceful degradation for heavy *per-session* memory, not density.

The precondition chain — all four, in order, or the gain is exactly zero:

```bash
# 1+2. host swap (10 GB) + zswap zstd, and it re-applies on node recycle
kubectl apply -f ../../runs/chrome-density/zswap-enabler.daemonset.yaml

# 3. kubelet LimitedSwap — per node, restarts k3s, does NOT survive recycle
./optional-zswap/apply-kubelet-swap.sh <node-name>

# 4. sessions need memory request < limit (Burstable). Kasm-launched sessions
#    historically got no memory request at all; the direct CR is the test harness:
kubectl apply -f ../../runs/chrome-density/zswap-test-session.yaml
```

Verify: `/proc/swaps` non-empty, `zswap/parameters/enabled=Y compressor=zstd`, and
a Burstable pod showing `memory.swap.max > 0`. **Never raise `SWAP_GB` above ~24**
— the 80 GB node disk also holds a ~21 GB image store under a
`nodefs.available<20%` eviction floor.

Teardown: `runs/chrome-density/zswap-teardown.daemonset.yaml`, then
`apply-kubelet-swap.sh <node> --revert` per node.

---

## 3. Not reproducible from this repo

Be honest about this list; it is the actual risk in a rebuild.

**Kasm database state.** Licence, registries, workspace definitions, group
settings, server limits, users. §2.8 lists the current values so they can be
re-entered by hand, but there is no export/import path here. A `pg_dump` of
`kasm-db-1-19-0-0` restored into a rebuilt deployment would carry the config —
along with the old installation ID and session history — and is untested. If this
environment ever becomes something we must restore rather than rebuild, that is
the gap to close first.

**The license is tied to installation `570a0983-aa94-4d0b-a86b-620141d493fd`.** A
rebuild generates a new ID, so the current key will not validate and a reissue is
required. The concurrent-session entitlement is a hard ceiling — the 18-session
load test needed a new license before it could run at all.

**Private, partly unmerged platform images.** Every Kasm image is a playground
build, and `kasm-agent:userns-20260809` plus
`kasm-workspaces-operator:refactor-smb-k3ssock-20260806` come from
`feat/userns-hostusers-oversub`, which is not merged. `hostUsers=false` and CPU
request shaping — two things this deployment's security and density posture depend
on — exist only there. If those tags are pruned, the rebuild cannot reproduce this
behaviour from any released artifact.

**The operator helm chart** is a directory in a local clone. There is no
`helm repo` and no OCI reference; `helm get values` proves the chart version
(1.18.1) but not its origin.

**obs-1 configuration files are committed; its provisioning is not automated.**
The VM, docker install, secret generation, netfilter rule and DNS are manual steps
documented in `../obs/README.md`.

**Node-level state does not survive recycle.** The kubelet swap drop-in is written
per node. CIVO reprovisions from an image, so a scaled or replaced node returns
with swap+zswap (DaemonSet) but no `LimitedSwap` — silently back to zero.

**Credentials to rotate, not to commit.** The `KasmImagePuller` CR holds a GitLab
deploy-token password in plaintext (readable by anyone who can `get
kasmimagepullers`), and `/etc/rancher/k3s/config.yaml` on each node holds the k3s
node join token. Both were exposed to a terminal during this review: **rotate the
deploy token** (regenerate it in the `labs-sandbox/kasm-nix` project, scoped to
`read_registry`, then re-apply `30-image-puller.yaml`). The node token cannot be
rotated on a managed CIVO cluster without replacing the cluster; treat that file as
secret and never copy it into a repo or a paste.

---

## 3a. Dependency check, 2026-08-12

Every external thing a rebuild pulls, verified on the day this was written. Re-run
these before trusting the runbook after a long gap — the failure mode is a tag or a
k3s version quietly disappearing, not the manifests going stale.

| Dependency | Result |
|---|---|
| Operator branch `feat/userns-hostusers-oversub` | pushed; `origin` == local at `86a9ef0`, so the chart and the agent source are not laptop-only |
| 8 private playground tags (agent, workspaces-operator, operator, nginx-sidecar, image-puller, seccomp-installer, video-device-plugin, egress-installer) | all `HTTP 200` on the registry manifest endpoint |
| Platform images `kasmweb/{api,manager,proxy,kasm-guac,postgres,rdp-gateway,rdp-https-gateway}:1.19.0` | public Docker Hub, released tags |
| CIVO `1.36.0-k3s1` | still offered — but maturity **development**; `1.35.0-k3s1` is the current stable default. Expect this pin to expire eventually |
| CIVO `g4m.kube.medium`, `traefik2-nodeport` 2.9.4, `cert-manager` v1.16.2 | all available |
| `cilium/tetragon` 1.7.0 | available |
| Operator chart renders with the §2.5 flags | yes — 15 CRDs, deployment, both RBAC sets |

**What has *not* been done: a clean rebuild.** Every artifact here is validated
against the running cluster (`kubectl diff` clean on the Kasm CR, server-side
dry-run clean on all four manifests) and every dependency resolves, but no
end-to-end run from `00-cluster.sh` to a launched session has been performed. The
steps most likely to need a fix on first attempt are the ones with no live
counterpart to check against: HTTP-01 timing against fresh DNS (§2.2–2.3) and the
order of the manual platform configuration (§2.8).

## 4. Drift found while reviewing, 2026-08-12

| Item | Doc says | Cluster says |
|---|---|---|
| Session CPU sizing | `design/workspace-density-zswap-k8s.md` §6.0a: "session config now `cores=1`" | images are `cores=2`; oversubscription is `KASM_CPU_REQUEST_FACTOR=0.15` on the agent instead (→ 300m request) |
| zswap teardown | §0 hard gate "before ~2026-08-13" | **still live** on all 3 nodes: 10 GB swap, zswap `enabled=Y`, 648 KB used |
| zswap node label | enabler comments claim `kasm.com/zswap=on` | not set — the busybox container has no `kubectl`, so the label step never happens. Use the DaemonSet's presence as the marker |
| Tetragon policies | design §4 header: "four loaded" | six loaded (the table below it already lists six) |
| Tetragon config home | design §7: "lives in a scratchpad" | committed under `deploy/tetragon/`, and the live helm values match it byte for byte |

---

## 5. Teardown

```bash
# optional zswap first, while the nodes still exist
kubectl delete -f ../../runs/chrome-density/zswap-enabler.daemonset.yaml
kubectl apply  -f ../../runs/chrome-density/zswap-teardown.daemonset.yaml
kubectl logs -n kube-system -l app=zswap-teardown          # confirm on all 3
kubectl delete -f ../../runs/chrome-density/zswap-teardown.daemonset.yaml
./optional-zswap/apply-kubelet-swap.sh <each-node> --revert

# detection: stop shipping before stopping collection, so nothing is lost mid-flight
kubectl -n kasm-monitoring delete ds alloy-tetragon
helm -n kube-system uninstall tetragon
# then confirm no BPF programs survived:
#   ls /sys/fs/bpf/tetragon   (via a privileged pod) must be empty

# the whole cluster
civo kubernetes delete kasm-tracelabs --region phx1
```

Deleting the cluster destroys the Kasm database with it, including the license
binding and every workspace definition — capture anything you need from §2.8 first.

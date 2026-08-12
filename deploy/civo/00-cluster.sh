#!/usr/bin/env bash
# Recreate the CIVO cluster that hosts the Kasm tracelabs deployment.
#
# Captured from the live cluster on 2026-08-12 (id 12aba142-…, created 2026-08-01).
# Everything after this script is in deploy/civo/README.md — this only gets you an
# empty k3s cluster with the two marketplace applications the deployment assumes.
#
# Node size is load-bearing, not a default: the 18-session density peak, the 10 GB
# swap sizing and the Tetragon export buffer are all sized against 4 vCPU / 32 GB /
# 80 GB nodes (design/workspace-density-zswap-k8s.md §2, §3.0a). Changing the size
# invalidates those numbers.
set -euo pipefail

CLUSTER="${CLUSTER:-kasm-tracelabs}"
REGION="${REGION:-phx1}"          # same metro as obs-1 in OCI us-phoenix-1
SIZE="${SIZE:-g4m.kube.medium}"   # 4 vCPU / 32 GB / 80 GB
NODES="${NODES:-3}"
K3S_VERSION="${K3S_VERSION:-1.36.0-k3s1}"

# traefik2-nodeport: serves :80/:443 on every node — the entrypoint the
#   IngressRouteTCPs in 21-ingressroute-tcp.yaml attach to ("websecure").
# cert-manager: installs the controller only. It creates NO issuer, so
#   10-cluster-issuers.yaml is still required.
APPS="${APPS:-traefik2-nodeport,cert-manager}"

log() { printf '\n=== %s\n' "$*"; }

log "creating $CLUSTER ($NODES x $SIZE, $REGION, k3s $K3S_VERSION)"
# --create-firewall opens 80, 443 and 6443 to 0.0.0.0/0, plus all egress, which is
# exactly the live firewall (kasm-tracelabs-fw, 4 rules). 6443 open to the world is
# how the CIVO-issued kubeconfig works; restrict it to admin CIDRs if you can.
civo kubernetes create "$CLUSTER" \
  --region "$REGION" \
  --size "$SIZE" \
  --nodes "$NODES" \
  --version "$K3S_VERSION" \
  --cluster-type k3s \
  --cni-plugin flannel \
  --applications "$APPS" \
  --create-firewall \
  --wait --yes

log "saving kubeconfig as context $CLUSTER"
civo kubernetes config "$CLUSTER" --region "$REGION" --save --switch

log "node facts to re-verify before trusting any sizing decision"
kubectl --context="$CLUSTER" get nodes -o wide
# Expected: Alpine Linux v3.22, kernel 6.12.x-lts, containerd 2.x-k3s1.
# Tetragon needs BTF (/sys/kernel/btf/vmlinux) and ≥6.1 for security_create_user_ns;
# these nodes have no AppArmor and no BPF LSM, which is why the security posture is
# detect-not-prevent (design/tetragon-session-monitoring.md §2, §5).

cat <<'EOF'

Next:
  1. DNS: point tracelabs.kasm.com AND sessions.tracelabs.kasm.com at a node's
     external IP (civo kubernetes show <cluster>). HTTP-01 issuance fails without it.
  2. kubectl apply -f 10-cluster-issuers.yaml
  3. Continue with deploy/civo/README.md §2.4 onwards.
EOF

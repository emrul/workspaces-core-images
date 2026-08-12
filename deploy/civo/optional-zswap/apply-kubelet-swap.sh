#!/usr/bin/env bash
# Enable (or revert) kubelet NodeSwap on ONE CIVO session node.
#
# OPTIONAL LAYER. Nothing in the Kasm deployment needs this; it exists for the
# compressed-memory density experiment (design/workspace-density-zswap-k8s.md).
# Skip it entirely for a plain rebuild — the zswap-enabler DaemonSet's host-side
# swap is harmless on its own, and pods simply get no swap.
#
# Why a script: this step was done by hand on three nodes and existed nowhere. It
# is also the one step that CANNOT be a DaemonSet — it restarts k3s, which bounces
# every pod on the node, and a restart loop inside a DaemonSet is how you lose a
# cluster. One node at a time, deliberately.
#
# ⚠️  RESTARTS k3s ON THE TARGET NODE. Every pod there is bounced, including live
#     sessions. Drain or accept the disruption first.
#
# ⚠️  DOES NOT SURVIVE NODE RECYCLE. CIVO reprovisions from an image, so a scaled
#     or replaced node comes back with swap+zswap (the DaemonSet re-applies) but
#     WITHOUT this kubelet config — silently back to swap.max=0. Re-run per new node.
#
#   ./apply-kubelet-swap.sh <node-name>            # enable
#   ./apply-kubelet-swap.sh <node-name> --revert    # restore the pre-change backup
#
# Order: host swap + zswap must already be on (kubectl apply -f
# ../../../runs/chrome-density/zswap-enabler.daemonset.yaml), and sessions need a
# memory request < limit, or this changes nothing.
set -euo pipefail

NODE="${1:?usage: $0 <node-name> [--revert]}"
MODE="${2:-apply}"
CTX="${KUBE_CONTEXT:-kasm-tracelabs}"
NS=kube-system
CFG=/etc/rancher/k3s/config.yaml
BAK=/etc/rancher/k3s/config.yaml.bak-zswap
DROPIN_DIR=/etc/rancher/k3s/kubelet.conf.d

# The zswap-enabler pod on that node is already privileged with hostPID and a
# hostPath mount of / — reuse it rather than minting another privileged surface.
POD=$(kubectl --context="$CTX" get pods -n "$NS" -l app=zswap-enabler \
        --field-selector "spec.nodeName=$NODE" -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "no zswap-enabler pod on $NODE — apply the DaemonSet first" >&2; exit 1; }

# Everything runs in the host mount namespace: the config and the service manager
# both live there, not in the pod.
host() { kubectl --context="$CTX" exec -n "$NS" "$POD" -- nsenter -t 1 -m -u -i -n -p -- sh -c "$1"; }

if [ "$MODE" = "--revert" ]; then
    echo "== reverting kubelet swap config on $NODE"
    host "[ -f $BAK ] && cp $BAK $CFG && echo restored || echo 'no backup — edit $CFG by hand'"
    host "rm -f $DROPIN_DIR/10-swap.conf; rmdir $DROPIN_DIR 2>/dev/null || true"
else
    echo "== enabling kubelet NodeSwap on $NODE"
    host "cp -n $CFG $BAK && echo 'backup -> $BAK' || echo 'backup already exists'"

    # Idempotent: append only the kubelet-arg entries that are missing. The file is
    # CIVO-managed and carries the node join token — never rewrite it wholesale.
    for arg in 'fail-swap-on=false' 'feature-gates=NodeSwap=true' "config-dir=$DROPIN_DIR"; do
        host "grep -qF -- '- $arg' $CFG || sed -i 's|^kubelet-arg:|kubelet-arg:\n- $arg|' $CFG"
    done

    host "mkdir -p $DROPIN_DIR"
    host "cat > $DROPIN_DIR/10-swap.conf <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
memorySwap:
  swapBehavior: LimitedSwap
EOF"
    host "head -20 $CFG | grep -v '^token:'"
fi

echo "== restarting k3s on $NODE (pods here will bounce)"
host 'rc-service k3s restart'

echo "== verify: a Burstable pod on this node must show memory.swap.max > 0"
cat <<EOF
  kubectl --context=$CTX apply -f ../../../runs/chrome-density/zswap-test-session.yaml
  # then, on the node:
  kubectl --context=$CTX exec -n $NS $POD -- sh -c \\
    'find /host/sys/fs/cgroup/kubepods.slice -name memory.swap.max | head; \\
     cat /host/proc/swaps'
A value of 0 means this did not take effect — check the drop-in was written to
$DROPIN_DIR and that config-dir is present in $CFG.
EOF

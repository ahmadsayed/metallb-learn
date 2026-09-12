#!/usr/bin/env bash
# Lesson 5 — install Calico on the phase-2 cluster.
#
# Two supported ways to install Calico Open Source:
#   * the tigera-operator (used here) — a controller that owns the install and
#     gives you an `Installation` CR to configure
#   * a plain `calico.yaml` manifest (one big apply, no operator)
#
# We use the operator because it exposes the pod-network settings as a CR you
# can read back later, which is nicer for a course than a 5,000 line manifest.
#
# Run with:  ./install-calico.sh          (idempotent)
set -euo pipefail

# Pin the version: Calico's service-IP advertisement has changed across
# releases (see the lesson's production notes), so "latest" is not a good
# default for a lab you want to reproduce.
CALICO_VERSION="${CALICO_VERSION:-v3.30.3}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"

echo "=== 1/4 Install the Tigera operator ($CALICO_VERSION) ==="
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" >/dev/null
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s | tail -1

echo "=== 2/4 Declare the Installation (no encapsulation, our pod CIDR) ==="
# ipipMode/vxlanMode Never = "all nodes share one L2 segment", which is exactly
# the on-premises topology this course simulates: nodes and the router on the
# same switch. If pod-to-pod traffic misbehaves in your environment, switch
# ipipMode to Always — the BGP parts of lesson 6 are unaffected.
kubectl apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: ${POD_CIDR}
        encapsulation: None
        natOutgoing: Enabled
        nodeSelector: all()
EOF

echo "=== 3/4 Wait for calico-node on every node ==="
# The nodes stay NotReady until the CNI is up. This is expected on a
# disableDefaultCNI cluster, not a failure.
for i in $(seq 1 60); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
  [ "$READY" = "3" ] && break
  sleep 5
done
kubectl get nodes

echo "=== 4/4 Calico components ==="
kubectl -n calico-system get pods 2>/dev/null | head -10 || kubectl -n kube-system get pods | grep calico
echo
echo "Next: install MetalLB controller-only, then run kubectl apply -f pool-controller-only.yaml"

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

echo "=== 1/5 Install the operator CRDs ($CALICO_VERSION) ==="
# IMPORTANT: tigera-operator.yaml does NOT contain the CRDs — it is only
# ~14 KB of namespace + RBAC + the operator Deployment. The 32 CRDs
# (including installations.operator.tigera.io) are in operator-crds.yaml,
# a ~2.6 MB manifest. Apply the CRDs first, or the Installation below fails
# with: no matches for kind "Installation" in version "operator.tigera.io/v1".
#
# `--server-side` is REQUIRED here, not cosmetic. Client-side `apply` records the
# whole object in the kubectl.kubernetes.io/last-applied-configuration
# annotation, and Kubernetes caps an annotation at 262144 bytes. The
# installations.operator.tigera.io CRD is 1.39 MB of YAML, so a client-side
# apply fails with:
#   The CustomResourceDefinition "installations.operator.tigera.io" is invalid:
#   metadata.annotations: Too long: may not be more than 262144 bytes
# Server-side apply tracks ownership in managedFields instead, with no
# annotation — which is the documented workaround for large CRDs.
#
# `--force-conflicts` makes re-runs take ownership of CRDs that a previous
# client-side `apply`/`create` left behind, instead of failing on a
# field-manager conflict.
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/operator-crds.yaml"
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=180s

echo "=== 2/5 Install the Tigera operator ==="
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" >/dev/null
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s | tail -1

echo "=== 3/5 Declare the Installation (no encapsulation, our pod CIDR) ==="
# encapsulation: None = "all nodes share one L2 segment", which is exactly the
# on-premises topology this course simulates: nodes and the router on the same
# switch, with Calico routing pod traffic over BGP instead of tunnelling it.
# If pod-to-pod traffic misbehaves in your environment, change it to IPIP (or
# VXLANCrossSubnet) and re-apply — the BGP parts of lesson 6 are unaffected.
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

echo "=== 4/5 Wait for calico-node on every node ==="
# The nodes stay NotReady until the CNI is up. This is expected on a
# disableDefaultCNI cluster, not a failure.
for i in $(seq 1 60); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
  [ "$READY" = "3" ] && break
  sleep 5
done
kubectl get nodes

echo "=== 5/5 Calico components ==="
kubectl -n calico-system get pods 2>/dev/null | head -10 || kubectl -n kube-system get pods | grep calico
echo
echo "Next: install MetalLB controller-only, then run kubectl apply -f pool-controller-only.yaml"

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
# THREE things here are not obvious, and each one cost real debugging time:
#
#   1. tigera-operator.yaml contains NO CRDs (it is ~14 KB of namespace + RBAC +
#      the operator Deployment). The CRDs are a separate 2.6 MB manifest.
#   2. Those CRDs must be applied with --server-side: client-side apply stores
#      the object in an annotation capped at 262144 bytes, and the
#      installations CRD alone is 1.39 MB.
#   3. The `Installation` gives you Calico *networking*. It does NOT give you
#      the `projectcalico.org/v3` API that every Calico doc and CR manifest
#      uses — that is served by an aggregated API server, deployed only when you
#      create an `APIServer` object. Without it:
#        kubectl apply -f <any calico CR> fails with
#        no matches for kind "BGPPeer" in version "projectcalico.org/v3"
#      even though `kubectl get crd | grep bgppeer` shows the CRD exists. The
#      CRDs publish crd.projectcalico.org/v1; v3 comes from the API server.
#
# Run with:  ./install-calico.sh          (idempotent)
set -euo pipefail

# Pin the version: Calico's service-IP advertisement has changed across
# releases (see the lesson's production notes), so "latest" is not a good
# default for a lab you want to reproduce.
CALICO_VERSION="${CALICO_VERSION:-v3.30.3}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"

echo "=== 1/6 Install the operator CRDs ($CALICO_VERSION) ==="
# `--server-side` is REQUIRED, not cosmetic (see note 2 at the top).
# `--force-conflicts` lets a re-run take ownership of CRDs a previous
# client-side apply/create left behind, instead of failing on a conflict.
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/operator-crds.yaml"
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=180s

echo "=== 2/6 Install the Tigera operator ==="
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" >/dev/null
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s | tail -1

echo "=== 3/6 Declare the Installation and the APIServer ==="
# encapsulation: None = "all nodes share one L2 segment", which is exactly the
# on-premises topology this course simulates: nodes and the router on the same
# switch, with Calico routing pod traffic over BGP instead of tunnelling it.
# If pod-to-pod traffic misbehaves in your environment, change it to IPIP (or
# VXLANCrossSubnet) and re-apply — the BGP parts of lesson 6 are unaffected.
#
# APIServer: this is what makes projectcalico.org/v3 exist (see note 3).
# Without it, every Calico CR manifest in this course fails to apply.
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
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

echo "=== 4/6 Wait for calico-node on every node ==="
# The nodes stay NotReady until the CNI is up. This is expected on a
# disableDefaultCNI cluster, not a failure.
for i in $(seq 1 60); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
  [ "$READY" = "3" ] && break
  sleep 5
done
kubectl get nodes

echo "=== 5/6 Wait for the Calico API server (serves projectcalico.org/v3) ==="
# The operator creates the calico-apiserver namespace a few seconds after the
# APIServer object, so retry rather than waiting once on a namespace that does
# not exist yet.
for i in $(seq 1 60); do
  kubectl -n calico-apiserver wait --for=condition=Available deploy/calico-apiserver --timeout=5s >/dev/null 2>&1 && break
  sleep 5
done
kubectl api-resources --api-group=projectcalico.org 2>/dev/null | head -4
echo "  (if that printed BGPPeer/BGPConfiguration, projectcalico.org/v3 is up)"

echo "=== 6/6 Calico components ==="
kubectl -n calico-system get pods 2>/dev/null | head -10 || kubectl -n kube-system get pods | grep calico
kubectl -n calico-apiserver get pods 2>/dev/null | head -3
echo
echo "Next: install MetalLB controller-only (lesson 5 step 5), then run kubectl apply -f pool-controller-only.yaml"

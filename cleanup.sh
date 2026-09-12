#!/usr/bin/env bash
# cleanup.sh — remove everything this course created on the host. Safe to re-run.
#
# The course runs in TWO phases, each with its own cluster:
#
#   phase 1 (lessons 0-4)   kind cluster "metallb-lab"     kindnet + MetalLB speaker (L2/ARP)
#   phase 2 (lessons 5-11)  kind cluster "metallb-calico"  Calico + MetalLB controller only (BGP)
#
# Usage:
#   ./cleanup.sh                     # both clusters, the lab containers, the built image
#   ./cleanup.sh metallb-calico      # just one cluster (containers/image are still cleaned)
#
# Nothing here needs sudo: the clusters are Docker containers you own.
set -uo pipefail

if [ "$#" -gt 0 ]; then
  CLUSTER_NAMES=("$@")
else
  CLUSTER_NAMES=(metallb-lab metallb-calico)
fi

ROUTER_NAME="${ROUTER_NAME:-metallb-router}"     # the FRR "datacenter router" (lessons 5-7)
CLIENT_NAME="${CLIENT_NAME:-metallb-client}"     # the routed client (lessons 5-7)
CAPTURE_NAME="${CAPTURE_NAME:-garp-capture}"     # the ARP capture container (lesson 4)
IMAGE="${IMAGE:-poolwatch:lab}"                  # built in lesson 11

echo "=== 1/6 kind clusters currently on this machine ==="
if kind get clusters 2>/dev/null | grep -q .; then
  kind get clusters 2>/dev/null | sed 's/^/  /'
else
  echo "  (none)"
fi

echo "=== 2/6 Delete the course clusters ==="
echo "    (this removes everything inside them: MetalLB, Calico, pools, Services, VIPs,"
echo "     the poolwatch namespace and the team-a namespace)"
for C in "${CLUSTER_NAMES[@]}"; do
  # `kind delete` and `docker rm -f` both exit 0 when the object does not
  # exist, so test for existence first: a cleanup script that reports work it
  # never did is worse than no script at all.
  if kind get clusters 2>/dev/null | grep -qx "$C"; then
    if kind delete cluster --name "$C" >/dev/null 2>&1; then echo "  ✓ $C deleted"; else echo "  ✗ $C could NOT be deleted"; fi
  else
    echo "  - $C not present"
  fi
done

echo "=== 3/6 Remove the lab containers ==="
for C in "$ROUTER_NAME" "$CLIENT_NAME" "$CAPTURE_NAME"; do
  if docker inspect "$C" >/dev/null 2>&1; then
    if docker rm -f "$C" >/dev/null 2>&1; then echo "  ✓ $C removed"; else echo "  ✗ $C could NOT be removed"; fi
  else
    echo "  - $C not found"
  fi
done

echo "=== 4/6 Remove the image built by the course ==="
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if docker rmi "$IMAGE" >/dev/null 2>&1; then echo "  ✓ $IMAGE removed"; else echo "  ✗ $IMAGE could NOT be removed (in use?)"; fi
else
  echo "  - $IMAGE not found"
fi
echo "    (images you *pulled* — kindest/node, metallb, frrouting, alpine — are left in place)"

echo "=== 5/6 Check for leftovers ==="
# Anonymous leftovers from the ARP-capture steps: an earlier version of lesson 4
# used `timeout docker run --rm`, which killed the docker *client* and left the
# container capturing for ever.
STRAY=$(docker ps -a --filter ancestor=alpine:3.20 --format '{{.Names}}' | tr '\n' ' ')
if [ -n "$STRAY" ]; then
  echo "  ! stray alpine containers (probably ARP captures): $STRAY"
  echo "    remove them with: docker rm -f $STRAY"
else
  echo "  ✓ no stray capture containers"
fi
for C in "${CLUSTER_NAMES[@]}"; do
  if kubectl config get-contexts "kind-$C" >/dev/null 2>&1; then
    echo "  ! kubectl context kind-$C survived; remove it with:"
    echo "      kubectl config delete-context kind-$C"
    echo "      kubectl config delete-cluster kind-$C"
  fi
done
EVIDENCE=$(ls /tmp/phase1-*.yaml /tmp/phase1-*.txt /tmp/probe.txt /tmp/garp.txt /tmp/syn*.pcap 2>/dev/null)
if [ -n "$EVIDENCE" ]; then
  echo "  ! evidence files captured during the lessons are still in /tmp:"
  echo "$EVIDENCE" | sed 's/^/      /'
else
  echo "  ✓ no lesson evidence files in /tmp"
fi

echo "=== 6/6 Course-related Docker resources still present ==="
LEFT=$(docker ps -a --format '{{.Names}}\t{{.Image}}' | grep -E 'metallb|kind' || true)
if [ -n "$LEFT" ]; then echo "$LEFT" | sed 's/^/  /'; else echo "  ✓ no course containers left"; fi
docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E 'kindest/node|metallb|frrouting|alpine|poolwatch' | sed 's/^/  image: /' || true

echo ""
echo "=== Done. Intentionally left untouched ==="
echo "  • Installed tools (docker, kubectl, kind, helm, go)"
echo "  • The Docker network 'kind' — kind reuses it for the next cluster"
echo "  • The MetalLB source checkout used by part II (./.src/metallb, gitignored)"
echo "  • Calico needs no host cleanup: its CRDs, IPPools, BGPPeers and its"
echo "    tigera-operator / calico-system namespaces all live inside the cluster"
echo "    and go away with it — no host files, no leftover binaries."
echo ""
echo "=== Start over ==="
echo "    phase 1:  kind create cluster --config lesson-01-cluster/kind-config.yaml"
echo "    phase 2:  kind create cluster --config lesson-05-calico-cluster/kind-config-calico.yaml"
echo "              cd lesson-05-calico-cluster && ./install-calico.sh"

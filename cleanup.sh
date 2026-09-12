#!/usr/bin/env bash
# cleanup.sh — tear down everything the lessons created (safe to re-run)
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-metallb-lab}"
ROUTER_NAME="${ROUTER_NAME:-metallb-router}"     # the FRR "router" container (Lessons 5-7)
CLIENT_NAME="${CLIENT_NAME:-metallb-client}"     # the routed client container (Lesson 5)
IMAGE="${IMAGE:-poolwatch:lab}"                  # built in Lesson 11

echo "=== 1/4 Delete the kind cluster ==="
echo "    (removes MetalLB, every pool, Service and VIP, the poolwatch namespace,"
echo "     the team-a namespace, and the router/client peers' sessions)"
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null && echo "  ✓ cluster deleted" || echo "  - no cluster named $CLUSTER_NAME"

echo "=== 2/4 Remove the lab containers ==="
for C in "$ROUTER_NAME" "$CLIENT_NAME"; do
  if docker rm -f "$C" >/dev/null 2>&1; then echo "  ✓ $C removed"; else echo "  - $C not found"; fi
done

echo "=== 3/4 Remove the image built in Lesson 11 ==="
if docker rmi "$IMAGE" >/dev/null 2>&1; then echo "  ✓ $IMAGE removed"; else echo "  - $IMAGE not found"; fi

echo "=== 4/4 Check for leftover kubectl context ==="
if kubectl config get-contexts "kind-$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "  ! context kind-$CLUSTER_NAME still present; remove it with:"
  echo "      kubectl config delete-context kind-$CLUSTER_NAME"
  echo "      kubectl config delete-cluster kind-$CLUSTER_NAME"
else
  echo "  ✓ no leftover context"
fi

echo ""
echo "=== Done. Intentionally left untouched ==="
echo "  • Installed tools (docker, kubectl, kind, helm, go)"
echo "  • The Docker network 'kind' — kind reuses it for the next cluster"
echo "  • The MetalLB source checkout, if you cloned it (./.src/metallb, gitignored)"
echo "  • Pulled images (kindest/node, quay.io/metallb/*, quay.io/frrouting/frr, alpine)"
echo ""
echo "=== To start over from a clean slate ==="
echo "    kind create cluster --config lesson-01-cluster/kind-config.yaml"

#!/usr/bin/env bash
# cleanup.sh — tear down everything created by the lessons (safe to re-run)
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-metallb-lab}"
ROUTER_NAME="${ROUTER_NAME:-metallb-router}"     # the FRR "router" container (Lessons 5-6)
CLIENT_NAME="${CLIENT_NAME:-metallb-client}"     # the BGP client container (Lesson 6)

echo "=== 1/4 Delete the kind cluster (removes every namespace, MetalLB, pools and VIPs) ==="
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null && echo "  ✓ cluster deleted" || echo "  - no cluster named $CLUSTER_NAME"

echo "=== 2/4 Remove the lab containers (router / client used for BGP) ==="
for C in "$ROUTER_NAME" "$CLIENT_NAME"; do
  if docker rm -f "$C" >/dev/null 2>&1; then echo "  ✓ $C removed"; else echo "  - $C not found"; fi
done

echo "=== 3/4 Remove the DNS entry the BGP lessons add for dig tests ==="
if [ -f /etc/hosts ] && grep -q "metallb-lab-vip" /etc/hosts 2>/dev/null; then
  echo "  ! /etc/hosts contains a metallb-lab-vip line — remove it by hand (needs sudo):"
  grep -n "metallb-lab-vip" /etc/hosts | sed 's/^/    /'
else
  echo "  - nothing to remove"
fi

echo "=== 4/4 Remaining Docker networks / images created by the lab ==="
docker network ls --format '{{.Name}}' | grep -E '^metallb-' | while read -r N; do
  docker network rm "$N" >/dev/null 2>&1 && echo "  ✓ network $N removed" || echo "  - network $N in use, skipped"
done
echo "  - leaving images in place (kindest/node, quay.io/metallb/*, frr, alpine)"

echo ""
echo "=== Done. Intentionally left untouched ==="
echo "  • Installed tools (docker, kubectl, kind, helm, go)"
echo "  • The Docker network 'kind' (kind recreates/reuses it automatically)"
echo "  • Any changes to your ~/.kube/config made by 'kind create cluster'"
echo ""
echo "=== If kubectl still points at the deleted cluster ==="
echo "    kubectl config delete-context kind-$CLUSTER_NAME"
echo "    kubectl config delete-cluster kind-$CLUSTER_NAME"

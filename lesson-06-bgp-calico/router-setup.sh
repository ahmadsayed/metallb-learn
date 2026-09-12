#!/usr/bin/env bash
# Lesson 6 — stand up the "datacenter router" that Calico will peer with.
#
# In production this is a switch/router your network team owns (Arista, Juniper,
# Cumulus…). In the lab it is an FRR container sitting on the same Docker
# network as the kind nodes, with a static address.
#
# It peers with every NODE, not with a Service and not with MetalLB: in this
# phase the BGP speaker on each node is calico-node.
#
# Run with:  ./router-setup.sh          (idempotent — recreates the container)
set -euo pipefail

ROUTER="${ROUTER:-metallb-router}"
ROUTER_IP="${ROUTER_IP:-172.19.0.100}"
NETWORK="${NETWORK:-kind}"
ROUTER_ASN="${ROUTER_ASN:-64513}"      # the router's AS
CALICO_ASN="${CALICO_ASN:-64512}"      # Calico's default global AS number
NODES=("${NODE1:-172.19.0.2}" "${NODE2:-172.19.0.3}" "${NODE3:-172.19.0.4}")

echo "=== 1/5 Recreate the FRR router container ($ROUTER at $ROUTER_IP) ==="
docker rm -f "$ROUTER" >/dev/null 2>&1 || true
docker run -d --name "$ROUTER" --hostname router \
  --network "$NETWORK" --ip "$ROUTER_IP" \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.fib_multipath_hash_policy=1 \
  quay.io/frrouting/frr:10.5.3 >/dev/null
echo "  ✓ started"
echo "  (fib_multipath_hash_policy=1 enables layer-4 ECMP hashing: without it a"
echo "   Linux router spreads by source/destination IP only, so every connection"
echo "   from one client lands on the same node. sysctls can only be set at"
echo "   container creation, hence they are passed to 'docker run'.)"

echo "=== 2/5 Enable bgpd (the FRR image ships it disabled) ==="
docker exec "$ROUTER" sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
docker restart "$ROUTER" >/dev/null
sleep 5
docker exec "$ROUTER" vtysh -c 'show version' | head -1 | sed 's/^/  /'

echo "=== 3/5 Seed the config files (silences FRR's startup warnings) ==="
docker exec "$ROUTER" touch /etc/frr/frr.conf /etc/frr/vtysh.conf

echo "=== 4/5 Install tcpdump (the FRR image has none) ==="
docker exec "$ROUTER" apk add --no-cache -q tcpdump >/dev/null 2>&1 && echo "  ✓ tcpdump available" || echo "  ! could not install tcpdump (needed only for the ECMP capture)"

echo "=== 5/5 Peer with every cluster node ($ROUTER_ASN <- $CALICO_ASN) ==="
ARGS=(-c 'configure terminal' -c "router bgp $ROUTER_ASN" -c 'no bgp ebgp-requires-policy')
for N in "${NODES[@]}"; do ARGS+=(-c "neighbor $N remote-as $CALICO_ASN"); done
ARGS+=(-c 'end')
docker exec "$ROUTER" vtysh "${ARGS[@]}" >/dev/null
docker exec "$ROUTER" vtysh -c 'write memory' >/dev/null 2>&1
docker exec "$ROUTER" vtysh -c 'show running-config' | sed -n '/router bgp/,/^exit/p' | sed 's/^/  /'

echo
echo "Router ready. Calico does not know about it yet — add the BGPPeer next:"
echo "  kubectl apply -f calico-bgp.yaml"
echo "  docker exec $ROUTER vtysh -c 'show bgp summary'"

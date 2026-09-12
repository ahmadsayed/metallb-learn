# Lesson 3 — Layer 2 mode: your first VIP

## Glossary
| Term | What it means |
|------|---------------|
| **IPAddressPool** | The CR that says *which* IPs MetalLB may hand out |
| **L2Advertisement** | The CR that says *how* they are announced in layer 2 mode (ARP/NDP) |
| **VIP** | The virtual IP clients connect to — it belongs to the Service, not to a machine |
| **ARP** | "Who has this IP? Tell me your MAC." |
| **gratuitous ARP** | Unsolicited ARP: "this IP is now at my MAC" (used on failover, Lesson 4) |
| **memberlist** | The gossip protocol speakers use to detect dead nodes |
| **announcing node** | The one node elected to answer ARP for a given VIP |

Two small YAML objects and a Service that has been `<pending>` since Lesson 1 gets a real, routable IP address.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `pool-and-l2.yaml` — an `IPAddressPool` (`172.19.255.200-172.19.255.250`) plus an `L2Advertisement` that announces it.

## Step 1 — Choose the address range (the only real design decision)

A layer 2 VIP must be an address that clients on the same Ethernet segment can ARP for. So it has to live **inside the nodes' own subnet**, and it must not collide with anything already using it.

From Lesson 1 Step 4 we know the nodes are on `172.19.0.0/16` (the Docker `kind` bridge). Docker hands out container addresses sequentially from the bottom (`172.19.0.2`, `.3`, `.4`, …), so we take the top of the range:

```
172.19.255.200 - 172.19.255.250      # 51 addresses, far from Docker's allocation
```

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.19.255.200-172.19.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
```

> 🧪 **Lab Hack:** using part of the *node* subnet works because the "network" is one flat Docker bridge that we fully control. **In production, never put a VIP pool inside your node/DHCP range** — you would eventually hand the same address to two machines. Instead reserve a small static range (or a separate subnet routed to the nodes) with your network team, and exclude it from DHCP.

## Step 2 — Apply it

```bash
kubectl apply -f pool-and-l2.yaml
```

```console
ipaddresspool.metallb.io/lab-pool created
l2advertisement.metallb.io/lab-l2 created
```

That is the entire configuration. No restarts, no ConfigMap, no agent config files.

## Step 3 — Watch the `<pending>` disappear

```bash
kubectl get svc whoami
```

```console
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)        AGE
whoami   LoadBalancer   10.96.233.4   172.19.255.200   80:31559/TCP   2m18s
```

```bash
kubectl get svc whoami -o jsonpath='{.status.loadBalancer}{"\n"}'
kubectl get events --field-selector involvedObject.name=whoami --sort-by=.lastTimestamp | tail -3
```

```console
{"ingress":[{"ip":"172.19.255.200","ipMode":"VIP"}]}
LAST SEEN   TYPE     REASON              OBJECT            MESSAGE
5s          Normal   IPAllocated         service/whoami    Assigned IP ["172.19.255.200"]
5s          Normal   nodeAssigned        service/whoami    announcing from node "metallb-lab-worker" with protocol "layer2"
```

Those two events are the two halves of MetalLB doing their jobs, in order: the **controller** allocated the IP (`IPAllocated`), then the **speaker** decided which node announces it (`nodeAssigned`). When you debug MetalLB, those event reasons are the first thing to grep for.

## Step 4 — Reach it from the host

```bash
curl -s http://172.19.255.200 | head -8
```

```console
Hostname: whoami-8644bfc655-hxlxx
IP: 127.0.0.1
IP: 10.244.2.2
RemoteAddr: 10.244.2.1:23455
GET / HTTP/1.1
Host: 172.19.255.200
```

It works — from outside the cluster, with no port-forward. Ask a few times and note that the VIP is not tied to a single pod:

```bash
for i in 1 2 3 4; do curl -s http://172.19.255.200 | grep '^Hostname:'; done
```

```console
Hostname: whoami-8644bfc655-tx66b
Hostname: whoami-8644bfc655-hxlxx
Hostname: whoami-8644bfc655-tx66b
Hostname: whoami-8644bfc655-hxlxx
```

Also notice `RemoteAddr` is `10.244.2.1` — **not** the host's IP. With the default `externalTrafficPolicy: Cluster`, `kube-proxy` SNATs the client so the pod sees the node as the source. Fixing that is a Lesson 4 experiment.

## Step 5 — Whose MAC address is it?

The VIP is not configured on any interface anywhere. So who answers when the host asks for it?

```bash
ip neigh show 172.19.255.200
docker exec metallb-lab-worker  ip -br link show eth0
docker exec metallb-lab-worker2 ip -br link show eth0
```

```console
172.19.255.200 dev br-44d120cb051d lladdr 1e:63:c1:b5:6f:e9 REACHABLE
eth0@if19        UP    1e:63:c1:b5:6f:e9 <BROADCAST,MULTICAST,UP,LOWER_UP>
eth0@if18        UP    3e:fe:37:3d:d5:2c <BROADCAST,MULTICAST,UP,LOWER_UP>
```

The host believes `172.19.255.200` is at `1e:63:c1:b5:6f:e9` — which is exactly **`metallb-lab-worker`'s own MAC**, not a MAC of a virtual interface the VIP was added to. MetalLB's speaker answered the ARP request *in software*, claiming the VIP for its node. This is the whole trick of layer 2 mode.

## Step 6 — See it on the wire

A fresh container has an empty neighbor cache, so its first request must ARP:

```bash
docker run --rm --network kind alpine:3.20 sh -c '
  apk add --no-cache -q tcpdump >/dev/null 2>&1
  tcpdump -i eth0 -n -e -l arp > /tmp/cap.txt 2>/dev/null &
  sleep 4
  wget -qO- --timeout=5 http://172.19.255.200 2>/dev/null | head -1
  sleep 2; kill %1 2>/dev/null
  cat /tmp/cap.txt'
```

```console
Hostname: whoami-8644bfc655-hxlxx
13:20:44.517871 2e:0c:73:eb:6d:25 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806): Request who-has 172.19.255.200 tell 172.19.0.5
13:20:44.518122 1e:63:c1:b5:6f:e9 > 2e:0c:73:eb:6d:25, ethertype ARP (0x0806): Reply 172.19.255.200 is-at 1e:63:c1:b5:6f:e9
```

Read it line by line:

- the client broadcast `who-has 172.19.255.200` to `ff:ff:ff:ff:ff:ff` (everyone on the segment, including all 3 nodes),
- **0.25 ms later** the worker replied `172.19.255.200 is-at 1e:63:c1:b5:6f:e9`,
- the other two nodes stayed silent — you can't see it in this capture, but that silence *is* the leader election.

> 🧪 **Lab Hack:** the capture runs inside a container because capturing on the Docker bridge from the host needs `CAP_NET_RAW`. In production you would run `sudo tcpdump -i eth0 -n -e arp` on a node and see the same two lines.

## Step 7 — Ask MetalLB which node is announcing

```bash
kubectl -n metallb-system get servicel2statuses -o yaml
```

```console
- apiVersion: metallb.io/v1beta1
  kind: ServiceL2Status
  metadata:
    labels:
      metallb.io/node: metallb-lab-worker
      metallb.io/service-name: whoami
      metallb.io/service-namespace: default
    name: l2-cf2xr
    ownerReferences:
    - apiVersion: v1
      kind: Pod
      name: metallb-speaker-krjq6          # the speaker pod that owns this announcement
  status:
    node: metallb-lab-worker
    serviceName: whoami
    serviceNamespace: default
```

This CR is the authoritative answer to "who is announcing?", better than guessing from logs. Keep it in mind for Lesson 4 and for the troubleshooting matrix in Lesson 8.

## Step 8 — Watch the pool accounting

New in v0.15: `IPAddressPool` now reports its own usage.

```bash
kubectl -n metallb-system get ipaddresspool lab-pool -o jsonpath='{.status}{"\n"}'
```

```console
{"assignedIPv4":1,"assignedIPv6":0,"availableIPv4":50,"availableIPv6":0}
```

One address in use, 50 left. In production this is what you alert on (Lesson 8) — a pool that hits zero turns every new `LoadBalancer` Service into a permanently `<pending>` one, exactly like Lesson 1, but this time with an event that says why.

## Expected outcome

| What | State |
|------|-------|
| `IPAddressPool/lab-pool` | created, 51 addresses, 1 assigned |
| `L2Advertisement/lab-l2` | created, announces `lab-pool` from every node |
| `whoami` EXTERNAL-IP | `172.19.255.200` (`ipMode: VIP`) |
| `curl` from the host | returns a `whoami` pod response |
| Host ARP entry | VIP → the announcing node's MAC |
| `ServiceL2Status` | `node: metallb-lab-worker` |

## Production note

- **Plan the pool like a network engineer**, not like a Kubernetes user: a range excluded from DHCP, documented, and (for L2) inside a segment your clients share. Write down who owns it.
- **`strictARP` matters if `kube-proxy` uses IPVS.** In IPVS mode the kubelet/kube-proxy may answer ARP for the VIP itself, breaking the election. Check with `kubectl -n kube-system get cm kube-proxy -o yaml | grep mode` and set `strictARP: true` in the `ipvs` section if needed. (This lab runs iptables mode.)
- **Announcing is interface-agnostic by default.** In a multi-homed node you will want `spec.interfaces: [eth1]` on the `L2Advertisement` (or `nodeSelectors` to restrict which nodes may announce). We do exactly that in Lesson 7.
- **Don't announce from every node in production "just in case".** Restricting announcements keeps the ARP noise down and makes the elected node predictable.

## Next
Continue to [Lesson 4 — Layer 2 deep dive](../lesson-04-l2-deep/README.md).

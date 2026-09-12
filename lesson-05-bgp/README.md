# Lesson 5 — BGP mode: peering with a real router

## Glossary
| Term | What it means |
|------|---------------|
| **BGP** | Border Gateway Protocol — the routing protocol that says "this prefix is reachable through me" |
| **AS / ASN** | Autonomous System (number): the identity each BGP speaker claims, e.g. `64512` |
| **eBGP / iBGP** | Session between *different* ASNs (eBGP) or *within* one ASN (iBGP) |
| **peer** | The other end of a BGP session — here, the router |
| **session state** | `Idle → Connect → Active → OpenSent → OpenConfirm → Established`. Only `Established` carries routes |
| **prefix** | The thing being advertised: `172.19.255.200/32` (one VIP) |
| **next-hop** | "To reach this prefix, send packets to *me*" — a node's IP |
| **update / withdraw** | BGP messages that add or remove a prefix from the router's table |
| **RIB / FIB** | Routing Information Base (BGP's table) / Forwarding Information Base (the kernel's actual routes) |
| **ECMP** | Equal-Cost Multi-Path: the router has several equally good next-hops and spreads *connections* over them |
| **hash policy** | What the router hashes on to pick a next-hop. L3-only = one node per client pair; L4/5-tuple = per connection |
| **`ebgp-requires-policy`** | FRR's safety default: eBGP routes are rejected unless a route-map accepts them |
| **withdraw** | The session pulling a prefix back (e.g. when a Service has no healthy pods) |

Layer 2 was the "no network team required" answer that bottlenecks on one node. BGP is the datacenter answer: **every** node advertises, and the router spreads the load.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `router-setup.sh` — creates and configures the FRR "datacenter router" container.
- `metallb-bgp.yaml` — `BGPPeer` + `BGPAdvertisement`.

## Step 1 — Stop announcing over ARP

An `L2Advertisement` and a `BGPAdvertisement` can both target the same pool, and MetalLB will happily do both — the same VIP answering ARP *and* being advertised as a route. That is almost never what you want, and it makes debugging a nightmare.

```bash
kubectl -n metallb-system delete l2advertisement lab-l2
```

```console
l2advertisement.metallb.io "lab-l2" deleted from metallb-system
```

From here on this cluster is a **BGP cluster**.

## Step 2 — Choose a BGP backend (and switch to one)

MetalLB does not implement BGP itself any more — it drives a real routing suite. Since v0.16 the default is **frr-k8s**; the course starts with the **native** implementation because it is small, self-contained and its log lines are the easiest to read.

```bash
helm upgrade metallb metallb/metallb -n metallb-system --version 0.16.1 \
  --set frrk8s.enabled=false --wait
kubectl -n metallb-system get pods -o wide
```

```console
STATUS: deployed
REVISION: 2
NAME                                  READY   STATUS    AGE   IP           NODE
metallb-controller-5d5dd498f9-hs78t   1/1     Running   32s   10.244.2.6   metallb-lab-worker
metallb-speaker-25s92                 1/1     Running   19s   172.19.0.4   metallb-lab-control-plane
metallb-speaker-4jgrl                 1/1     Running   7s    172.19.0.3   metallb-lab-worker
metallb-speaker-xtdtf                 1/1     Running   32s   172.19.0.2   metallb-lab-worker2
```

The five-container `metallb-frr-k8s` DaemonSet is gone — one pod set fewer, and no FRR processes on your nodes:

| Backend | How to select | What runs on each node |
|---|---|---|
| `frr-k8s` (**default**) | default | speaker + an FRR-K8s instance |
| `frr` (deprecated) | `--set speaker.frr.enabled=true` | speaker + FRR containers inside the speaker pod |
| `native` | `--set frrk8s.enabled=false` | just the speaker |

> 💡 Notice the speaker's security context did **not** change: it still holds only `NET_RAW`. The native implementation opens a normal TCP connection to port 179 — no `NET_ADMIN`, because it never touches the node's routing table. The FRR-backed modes are the ones that need real routing privileges.

> 🏭 **Production:** use the default (`frr-k8s`). You get BFD, IPv6 BGP/BFD, multi-protocol BGP, graceful restart, and the ability to merge your own FRR configuration into the same instance. Native is the lean option when you need plain IPv4/IPv6 unicast and nothing else — and we come back to frr-k8s in Lesson 6.

## Step 3 — Build a router

In production, a switch or router your network team owns peers with the nodes. Here, an FRR container joins the same Docker network:

```bash
./router-setup.sh
```

What that script does, and why each part matters:

| Step | Why |
|------|-----|
| `docker run --network kind --ip 172.19.0.100` | The router must be on the same L2 segment as the nodes, with a **stable** address (that address goes into the `BGPPeer` CR) |
| `--cap-add NET_ADMIN,NET_RAW,SYS_ADMIN` | FRR programs the kernel's routing table and binds low ports |
| `--sysctl net.ipv4.ip_forward=1` | A router that does not forward is a very expensive ping target |
| `--sysctl net.ipv4.fib_multipath_hash_policy=1` | **Layer-4 ECMP hashing** — the difference between "all traffic to one node" and real load spreading (Step 8) |
| `sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons` | The FRR image ships with **bgpd disabled**. This is a classic 20-minute debugging session if you forget it |
| `neighbor <node> remote-as 64512` | One session per node |

```console
router bgp 64513
 no bgp ebgp-requires-policy
 neighbor 172.19.0.2 remote-as 64512
 neighbor 172.19.0.3 remote-as 64512
 neighbor 172.19.0.4 remote-as 64512
exit
```

> 💡 **`no bgp ebgp-requires-policy`** exists because FRR (correctly) refuses to accept or send eBGP routes without an explicit policy — in the real world one typo can leak a routing table to the internet. We disable the requirement to keep the lab short. On a real router you would instead attach route-maps that accept exactly the VIP prefixes.

> 🧪 **Lab Hack:** the "router" is a container on a Docker bridge, so "the network" is one flat L2 segment. In production the router is hardware, the nodes are on their own subnet, and the VIP pool is a separate routed block — the BGP conversation is identical, only the plumbing differs.

## Step 4 — The MetalLB half

```bash
kubectl apply -f metallb-bgp.yaml
```

```yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: lab-router
  namespace: metallb-system
spec:
  myASN: 64512                  # who we claim to be
  peerASN: 64513                # who the router claims to be
  peerAddress: 172.19.0.100     # where to open the session
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: lab-bgp
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
```

The split is deliberate and worth internalising: **`BGPPeer` is about the session, `BGPAdvertisement` is about the content.** You can peer with three routers and advertise different pools to each. (`BGPPeer` is `v1beta2` in current MetalLB — `v1beta1` still works but is deprecated; `BGPAdvertisement` is still `v1beta1`.)

## Step 5 — Verify the sessions

```bash
docker exec metallb-router vtysh -c 'show bgp summary'
```

```console
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
172.19.0.2      4      64512         6         4        4    0    0 00:00:13            4        4 N/A
172.19.0.3      4      64512         6         4        4    0    0 00:00:13            4        4 N/A
172.19.0.4      4      64512         2         4        4    0    0 00:00:13            0        4 N/A
```

How to read it:

- `Up/Down 00:00:13` with a **numeric** `State/PfxRcd` means the session is **Established** — FRR replaces the state word with the number of prefixes received.
- `PfxRcd 4` on two nodes: they are advertising our four VIPs to us.
- **`PfxRcd 0` on `172.19.0.4`** — the control-plane is advertising *nothing*. That is not a bug, and finding out why is the most valuable part of this lesson.

## Step 6 — Why the control-plane stays silent

```bash
kubectl get node metallb-lab-control-plane -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep -i exclude

SPEAKER=$(kubectl -n metallb-system get pods \
  -l app.kubernetes.io/component=speaker \
  --field-selector spec.nodeName=metallb-lab-control-plane -o name)
kubectl -n metallb-system logs "$SPEAKER" | grep 'skipping should announce'
```

```console
"node.kubernetes.io/exclude-from-external-load-balancers":""
{"caller":"bgp_controller.go:179","event":"skipping should announce bgp","ips":["172.19.255.200"],"level":"warn",
 "pool":"lab-pool","protocol":"bgp","reason":"speaker's node has labeled 'node.kubernetes.io/exclude-from-external-load-balancers'",
 "service":"default/whoami",...}
```

kind (following kubeadm's convention, and the same way managed Kubernetes labels its control planes) marks control-plane nodes with that label — **with an empty value.** Existence is what counts, not the value, so MetalLB's speaker on that node refuses to announce anything.

This is exactly how you keep load-balancer traffic away from control-plane nodes in production, and it is why `kubectl get nodes -o wide` showing a ready speaker is not proof that a node announces. **Read the speaker's log; it tells you the reason in one line.**

If you *do* want control-plane nodes to announce (common in homelabs where they are the beefiest machines):

```bash
helm upgrade metallb metallb/metallb -n metallb-system --set speaker.ignoreExcludeLB=true
```

## Step 7 — Look at the routes

```bash
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast'
```

```console
     Network          Next Hop            Metric LocPrf Weight Path
 *>  172.19.255.200/32
                    172.19.0.2                             0 64512 i
 *=                   172.19.0.3                             0 64512 i
 *>  172.19.255.201/32
                    172.19.0.2                             0 64512 i
 *=                   172.19.0.3                             0 64512 i
...
Displayed 4 routes and 8 total paths
```

`*>` = the best path, `*=` = an additional path that is equal-cost (ECMP). Four VIPs × two nodes = 8 paths. And FRR's **zebra** pushed them into the kernel:

```bash
docker exec metallb-router ip route | grep 172.19.255
```

```console
172.19.255.200 nhid 13 proto bgp metric 20
172.19.255.201 nhid 13 proto bgp metric 20
172.19.255.202 nhid 13 proto bgp metric 20
172.19.255.203 nhid 13 proto bgp metric 20
```

`proto bgp` = these came from BGP, and the shared `nhid` is the multipath next-hop group.

## Step 8 — The VIP is now a *routed prefix*, not an ARP entry

With L2 mode, any client on the segment could reach the VIP by ARP. Watch what changed:

```bash
sudo ip neigh flush 172.19.255.200      # needs root: this edits the kernel's neighbour table
curl --max-time 6 http://172.19.255.200
ip neigh show 172.19.255.200
```

```console
curl 172.19.255.200 -> no answer
172.19.255.200 dev br-44d120cb051d FAILED
```

> 💡 **`ip neigh flush` needs root**, and without it the command fails silently in a copy-paste. You do not actually need it: the entry ages out on its own (`REACHABLE` → `STALE` → failed re-probe → `FAILED`) within about a minute. Or put the question to a **brand-new client**, whose neighbour cache is empty by definition — Lesson 3's throwaway container does exactly that:

**Nobody answers ARP for the VIP any more.** The host is on the same subnet so it tries to ARP for `172.19.255.200` and gets silence — the prefix only exists as a *route* now. Traffic has to arrive through the router, which is what happens naturally in a datacenter: clients are on other subnets and their default gateway *is* the router.

Let me build exactly that client:

```bash
docker run -d --name metallb-client --network kind --cap-add NET_ADMIN alpine:3.20 sleep 3600
docker exec metallb-client ip route add 172.19.255.0/24 via 172.19.0.100
docker exec metallb-client curl -s http://172.19.255.200 | head -3
```

```console
Hostname: whoami-8644bfc655-kjzj9
IP: 127.0.0.1
IP: ::1
```

The VIP works — because the client sends it to the router, and the router forwards it to a node that advertised the prefix.

> 💡 Two useful things to notice: the earlier `curl` from the *host* kept working for a minute after we deleted the `L2Advertisement`, because the host still had a cached ARP entry pointing at a node (DNAT in PREROUTING does not care how the packet arrived). And when that cache expired, the VIP became unreachable **from the host** while remaining perfectly reachable through the router. In an outage, "the VIP stopped answering" may be a *client routing* problem, not a MetalLB problem.

## Step 9 — Make ECMP actually spread (the most important experiment here)

Twenty connections from one client, and we count which node's MAC the router addressed each SYN to:

```bash
docker exec metallb-router rm -f /tmp/syn.pcap
docker exec -d metallb-router tcpdump -i eth0 -n -e -w /tmp/syn.pcap 'tcp[tcpflags] & tcp-syn != 0'
docker exec metallb-client sh -c 'for i in $(seq 1 20); do curl -s -o /dev/null http://172.19.255.200; done'
docker exec metallb-router pkill tcpdump
docker exec metallb-router tcpdump -r /tmp/syn.pcap -n -e | grep -oE '> [0-9a-f:]{17}' | sort | uniq -c
```

**With the Linux default (`fib_multipath_hash_policy = 0`, layer-3 hashing):**

```console
     20 > a6:1c:3c:ae:ff:68      # the SYN arriving at the router
     20 > ce:57:b8:07:95:ad      # ALL 20 forwarded to metallb-lab-worker
```

**After setting `net.ipv4.fib_multipath_hash_policy = 1` (layer-4 hashing):**

```console
     20 > a6:1c:3c:ae:ff:68      # arriving at the router
     11 > ce:57:b8:07:95:ad      # → metallb-lab-worker
      9 > 3e:fe:37:3d:d5:2c      # → metallb-lab-worker2
```

That is the whole promise of BGP mode in one diff. With the router's default hash, **every connection from one client to one VIP lands on the same node** — you have the L2 bottleneck again, plus more moving parts. Switch the hash to include ports and the same 20 connections spread across both nodes.

Hashes are per *connection*, never per packet: spreading the packets of one TCP connection across two nodes would cause reordering and break routing consistency (this is why the docs describe 3-tuple and 5-tuple hashing).

> 🧪 **Lab Hack:** we configured the hash on a Linux router. On real hardware this is a knob with names like `ip load-sharing per-packet|per-flow`, `hash-field-list`, or "resilient ECMP" — same concept, different CLI. **Ask your network team what it is set to**; for Kubernetes load balancing, L4 hashing is what you want.
>
> 💡 Remember this experiment when something "load balances" in a demo: with the wrong hash policy, the demo still shows a working VIP, and only the *distribution* is wrong. Measure, don't assume.

Also measured: the pods that actually answered the 20 requests came from three different replicas spread over both nodes (`6fbjq`, `v9767` on worker; `kjzj9` on worker2) — after the SYN reaches a node, `kube-proxy` still spreads across all ready pods cluster-wide (that is the `externalTrafficPolicy: Cluster` behaviour from Lesson 4).

## Expected outcome

| What | State |
|---|---|
| `L2Advertisement` | deleted — this is a BGP cluster now |
| BGP backend | `native` (frr-k8s removed via `helm upgrade`) |
| Router | FRR 10.5.3 at `172.19.0.100`, bgpd enabled, forwarding + L4 hashing |
| Sessions | `Established` on all 3 nodes |
| Prefixes received | 4 from each worker, **0 from the control-plane** (exclusion label) |
| Router RIB | 4 prefixes, 8 paths, `*>` + `*=` multipath |
| Router FIB | 4 `proto bgp` routes in the kernel |
| VIP from a host on the segment | no ARP answer — unreachable without a route via the router |
| VIP from a client routed via the router | works |
| 20 connections, L3 hash | 20/0 across nodes |
| 20 connections, L4 hash | 11/9 across nodes |

## Production note

- **Plan ASNs and peering like a network change**, because it is one: which ASN per cluster, which routers peer, aggregation (`/32` per VIP or an aggregate per pool), and how routes get filtered on the router side.
- **Never `no bgp ebgp-requires-policy` in production.** Attach prefix-lists/route-maps that accept exactly your pools.
- **Session count scales with nodes.** Every node peers with every router. `nodeSelectors` on the `BGPPeer` lets you restrict peering to designated nodes (e.g. two "border" nodes) when your routers have session limits.
- **Expect a one-time connection reset when the next-hop set changes** (node added/removed/restarted, or a pool change). Routers rehash, and connections land on a node that never saw them. Mitigations: resilient/stable ECMP hashing on the router, fewer advertising nodes, or an ingress layer in front.
- **Consider BFD** for sub-second failure detection instead of BGP hold timers — that is one of the reasons to use `frr-k8s` (Lesson 6).
- **Watch session state and prefix counts**, not just Service status. A VIP with a perfect `EXTERNAL-IP` and zero advertised prefixes is a black hole.

## Next
Continue to [Lesson 6 — BGP the modern way: frr-k8s, ECMP and traffic engineering](../lesson-06-bgp-frrk8s/README.md).

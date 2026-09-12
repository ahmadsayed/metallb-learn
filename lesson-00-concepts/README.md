# Lesson 0 — The Concepts: bare metal, VIPs, ARP and BGP

## Glossary
| Term | What it means |
|------|---------------|
| **bare metal** | Your own servers (or a laptop full of containers). There is no cloud API behind the cluster to ask for an IP. |
| **LoadBalancer Service** | A Kubernetes Service whose *contract* is: "something will fill in `status.loadBalancer.ingress` with an address, and traffic sent there will reach my pods." |
| **EXTERNAL-IP / `<pending>`** | The column that shows the result of that contract. `<pending>` = the contract has not been fulfilled. |
| **cloud-controller-manager (CCM)** | The cluster component that talks to a cloud API (AWS ELB, GCP LB…) to create a real load balancer. It is what fills in `EXTERNAL-IP` in the cloud. |
| **VIP** | The virtual IP clients connect to. It belongs to the *service*, not to any single machine. |
| **ARP** | IPv4 Address Resolution Protocol: "who has this IP? tell me your MAC address." |
| **NDP** | IPv6 Neighbor Discovery — the IPv6 equivalent of ARP. |
| **gratuitous ARP** | An *unsolicited* ARP announcement: "this IP now lives at my MAC" — how clients learn about a failover. |
| **BGP** | The routing protocol of the internet. A node tells a router "the VIP is reachable through me," and the router installs a route. |
| **AS / ASN** | Autonomous System number — the identity each BGP speaker uses when peering. |
| **ECMP** | Equal-Cost Multi-Path: the router has several equally good routes and spreads *connections* across them. |
| **kube-proxy** | Programs the DNAT rules (iptables/IPVS) that turn "packet to VIP" into "packet to a pod IP". |
| **CNI** | Pod networking plugin. kind ships `kindnet`; MetalLB works on top of whatever CNI you use. |
| **DaemonSet** | A controller that runs exactly one pod on every node. |
| **CRD** | Custom Resource Definition — how you configure MetalLB (`IPAddressPool`, `L2Advertisement`, …). |
| **memberlist** | The gossip protocol MetalLB's speakers use to know which nodes are still alive. |
| **FRR** | Free Range Routing, a real routing suite. MetalLB's FRR backends drive FRR to do the BGP talking. |

Everything in Lessons 1–11 exists to solve one problem:

## 1. The problem: a `LoadBalancer` Service with nobody to ask

```yaml
apiVersion: v1
kind: Service
metadata:
  name: whoami
spec:
  type: LoadBalancer      # ← "please give me an address the outside world can reach"
  selector:
    app: whoami
  ports:
    - port: 80
      targetPort: http
```

In a cloud, this happens: the **cloud-controller-manager** sees the new Service, calls the cloud API, a real load balancer is created with a public IP, and the IP is written back:

```yaml
status:
  loadBalancer:
    ingress:
      - ip: 203.0.113.10     # the cloud did this
```

On bare metal there is no cloud API and **no cloud-controller-manager**, so nothing happens. Ever:

```console
$ kubectl get svc whoami
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
whoami   LoadBalancer   10.96.233.4   <pending>     80/TCP    16s

$ kubectl describe svc whoami
...
Events:                   <none>          # ← no error, no warning, nothing
```

> **`<pending>` is not an error.** Kubernetes is waiting for a component that does not exist yet. Nothing is broken and nothing will time out — the Service will sit there forever.

Two things are missing, and they are the two halves of MetalLB:

1. **Somebody to decide** which IP the Service gets and to write it into `status`.
2. **Somebody to tell the network** that this IP is reachable — and through which node.

## 2. MetalLB's answer: split the job in two

![MetalLB architecture: controller allocates, speakers announce](../diagrams/metallb-architecture.svg)

| Component | Kind | Runs | Job |
|-----------|------|------|-----|
| **controller** | Deployment, 1 replica, leader-elected | Anywhere | Watches Services + `IPAddressPool`s, picks a free IP, writes `status.loadBalancer.ingress`, emits `nodeAssigned` events when speakers announce. |
| **speaker** | DaemonSet, one pod per node, `hostNetwork` | Every node | Decides which nodes announce which VIPs, then actually does it: answers ARP/NDP (L2), or speaks BGP with the router. |

The split is not arbitrary. **Allocation is a cluster-wide decision** — you need one brain to hand out unique IPs. **Announcement is a per-node action** — ARP replies and BGP sessions come out of a specific machine's NIC.

> **The mental model that makes everything else easy:** the controller never touches a packet. The speaker never allocates an IP. When something is wrong, first ask *"is this an allocation problem or an announcement problem?"* — Lesson 8's troubleshooting matrix is built on exactly that question.

## 3. Layer 2 mode: answer ARP for an IP you don't own

In L2 mode, one node per VIP pretends the VIP is one of its own addresses. It does this by **answering ARP/NDP requests** for it.

```
client:  who has 172.19.255.200? tell 172.19.0.1
worker:  172.19.255.200 is at 02:42:ac:13:00:03     ← the speaker, using the node's own MAC
```

The client caches that MAC and sends its packets to the node. The node's kernel then hands them to `kube-proxy`, which DNATs them to a pod.

**Why this works even though the VIP is never configured on any interface:** incoming packets to the VIP hit `kube-proxy`'s DNAT rule in the `nat` PREROUTING chain *before* the kernel decides whether the destination is local. The address is rewritten to a pod IP, and normal routing takes over from there. That is also why L2 mode needs `kube-proxy` (or an equivalent) on the node.

**Who announces?** A stateless election: every speaker builds the same sorted list of `hash(node + VIP)` for all *eligible* nodes and announces only if it is first in that list. No leader database, no consensus — and it means removing a node leaves the leader alone, while adding one can steal leadership.

**Liveness** comes from `memberlist`: when a speaker stops gossiping, the others consider its node dead and the next node in the sorted list takes over by sending **gratuitous ARP** ("the VIP moved to my MAC").

| L2 strengths | L2 limitations |
|---|---|
| Works on any flat Ethernet network — no router configuration, no special hardware | **Single-node bottleneck:** every packet for the VIP enters one node, so ingress bandwidth ≤ that node's NIC |
| Simple to reason about and debug (`tcpdump arp`) | **Failover depends on clients** respecting gratuitous ARP — usually seconds, occasionally worse on odd stacks |
| No cooperation needed from the network team | A confused speaker can compute a different node list → two nodes answering, or none ("brain split") |

> 🏭 **Production gotcha — `strictARP`.** If `kube-proxy` runs in **IPVS** mode, you must set `strictARP: true` in its config, otherwise the *node* answers ARP for every VIP itself and MetalLB's election becomes meaningless. We use iptables mode in this lab, where it is not needed. (In **L2 mode the node's kernel IP forwarding is not used** for the VIP: DNAT happens first.)

## 4. BGP mode: tell a router where the VIP lives

In BGP mode, every node opens a BGP session with a router and advertises each VIP as a `/32` (or `/128`) route with itself as next hop.

```
worker:   announce 172.19.255.200/32 next-hop 172.19.0.3
worker2:  announce 172.19.255.200/32 next-hop 172.19.0.2
router:   → FIB: 172.19.255.200/32 via {172.19.0.3, 172.19.0.2} (ECMP)
```

The router now spreads **connections** (per-connection hashing, typically 5-tuple) across those next hops. Real load balancing: ingress bandwidth scales with the number of nodes — the exact opposite of L2's single-node bottleneck.

| BGP strengths | BGP limitations |
|---|---|
| True multi-node load balancing through the router | Requires a BGP-capable router **you control** (and a network team willing to peer with your nodes) |
| Standard hardware, no bespoke load balancer | When the set of advertising nodes changes, routers **rehash** → most active connections are reset (a one-time clean break, not ongoing loss) |
| Anycast: withdraw the route when a service has no healthy pods, so the VIP stops being advertised | Needs care with router ECMP hashing ("resilient ECMP" helps a lot) |

**Which BGP implementation?** Since **v0.16**, MetalLB's default backend is **frr-k8s** (MetalLB generates configuration for a real FRR routing suite, which you can share with your own FRR config):

| Backend | Status in v0.16 | Use it when |
|---|---|---|
| `frr-k8s` | **Default** | Production. BFD, IPv6 BGP/BFD, multi-protocol BGP, graceful restart, sharing FRR with other actors. |
| `frr` | **Deprecated** (will be removed) | You are already running it; migrate. |
| `native` | Supported, "for deployments that require a smaller footprint" | You want no FRR processes/containers, and you only need plain IPv4/IPv6 unicast peering. |

In **this course**, phase 2 uses none of them: the BGP speaker is **Calico** (Lesson 6) and MetalLB keeps allocation only (Lesson 5). You still need to know these backends — plenty of clusters do let MetalLB speak BGP, and if you ever run both Calico's and MetalLB's BGP toward the same router they conflict (one session per node pair, Lesson 6).

## 5. Which mode should you actually use?

| Your situation | Use |
|---|---|
| Homelab, flat L2 network, no router you can configure | **L2** |
| Datacenter with a ToR router you can peer with; need >1 node of ingress bandwidth | **BGP** — MetalLB's own backend, or your CNI's (this course: Calico, Lesson 6) |
| You need the VIP to follow healthy pods across clusters (anycast) | **BGP** |
| Tiny cluster, no appetite for FRR containers | **BGP (native)** or **L2** |
| You need source-IP preservation (`externalTrafficPolicy: Local`) | Both support it; in L2 it pins the VIP to a node running a pod |

## 6. The packet path, end to end (L2, our lab)

Our cluster will use VIP `172.19.255.200`. A request from the host to the app:

1. Host has no ARP entry for `172.19.255.200` → broadcasts an ARP request on the Docker bridge (`172.19.0.0/16`).
2. **All three nodes** receive that broadcast; only the **elected speaker** replies with its node's MAC.
3. The host caches `VIP → node MAC` and sends the TCP SYN there.
4. The packet arrives on the node's `eth0`, goes through `nat` PREROUTING, where `kube-proxy`'s rule for the VIP rewrites the destination to a **pod IP**.
5. Routing delivers it to the pod (on this node or another — L2 mode reaches pods cluster-wide).
6. The pod replies; the connection is NAT'ed back.
7. If the leader node dies, another node wins the election and sends **gratuitous ARP**, updating step 3's cache.

## 7. What we will change on the wire

| Lesson | What we do | What proves it worked |
|---|---|---|
| 1 | Deploy `whoami` with `type: LoadBalancer` | `EXTERNAL-IP` is `<pending>` |
| 2 | Install MetalLB | controller + speaker pods running, 9 new CRDs |
| 3 | `IPAddressPool` + `L2Advertisement` | `EXTERNAL-IP` becomes a real IP; `curl` answers from the host |
| 4 | Kill the leader, flip `externalTrafficPolicy` | gratuitous ARP moves the VIP; source IP changes |
| 5 | Rebuild the cluster on Calico, MetalLB controller-only | an address is allocated and **nobody announces it** — by design |
| 6 | Let Calico advertise the VIPs | router shows the VIP `/32`s with three next-hops; connections spread |
| 7 | Share an IP, pin an address, select pools | one VIP serves two Services; a Service gets the IP you asked for |

## Next
Continue to [Lesson 1 — The cluster & the problem](../lesson-01-cluster/README.md).

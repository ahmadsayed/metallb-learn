# Lesson 6 — BGP the modern way: frr-k8s, communities and traffic engineering

## Glossary
| Term | What it means |
|------|---------------|
| **frr-k8s** | A Kubernetes wrapper around FRR with its own API (`FRRConfiguration`), used as MetalLB's default BGP backend since v0.16 |
| **Community** | A 32-bit tag attached to a BGP prefix (`64512:100`) that routers match on to apply policy |
| **LOCAL_PREF** | "How much I like this path" — an **intra-AS** attribute, not propagated over eBGP |
| **route-map** | FRR's policy engine: match conditions → set actions, applied inbound or outbound |
| **prefix-list** | A list of prefixes used as a match condition |
| **BFD** | Bidirectional Forwarding Detection — sub-second failure detection between routers |
| **graceful restart** | Keeping forwarding state while BGP restarts, so a daemon restart does not drop traffic |
| **withdraw** | Telling the router "stop using this prefix" (e.g. no healthy endpoints) |
| **`ServiceBGPStatus`** | MetalLB CR listing which Services a given node is advertising, and to which peers |

Lesson 5 used the **native** backend to keep the protocol visible. Production runs the default: **frr-k8s**. This lesson switches back to it, shows what you gain, and then uses BGP's real superpower — making the *network* enforce policy via communities.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `communities.yaml` — a `Community` CR plus a `BGPAdvertisement` that tags its prefixes and sets a local preference.

## Step 1 — Switch back to frr-k8s

```bash
helm upgrade metallb metallb/metallb -n metallb-system --version 0.16.1 \
  --set frrk8s.enabled=true --wait --timeout 6m
```

```console
STATUS: deployed
REVISION: 3
NAME                                            READY   STATUS    AGE   IP           NODE
metallb-controller-55846b4849-w8nfz             1/1     Running   44s   10.244.1.5   metallb-lab-worker2
metallb-frr-k8s-dkvnr                           5/5     Running   44s   172.19.0.3   metallb-lab-worker
metallb-frr-k8s-hj6pl                           5/5     Running   44s   172.19.0.4   metallb-lab-control-plane
metallb-frr-k8s-l2mtf                           5/5     Running   44s   172.19.0.2   metallb-lab-worker2
metallb-frr-k8s-statuscleaner-8bf664555-l9rpf   1/1     Running   44s   10.244.1.4   metallb-lab-worker2
metallb-speaker-52kj6                           1/1     Running   44s   172.19.0.2   metallb-lab-worker2
metallb-speaker-h27gr                           1/1     Running   44s   172.19.0.4   metallb-lab-control-plane
metallb-speaker-wf75h                           1/1     Running   44s   172.19.0.3   metallb-lab-worker
```

The FRR DaemonSet is back — and **the BGP sessions re-established themselves with no intervention**, from the router's point of view:

```console
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
172.19.0.2      4      64512        16        16       28    0    0 00:00:23            4
172.19.0.3      4      64512        18        18       28    0    0 00:00:09            4
172.19.0.4      4      64512        10        17       28    0    0 00:00:21            0
```

> 💡 That is worth pausing on: the *implementation* changed completely (MetalLB's own BGP code → real FRR daemons in pods) and the *observable protocol behaviour* did not. That is the sign of a well-drawn abstraction boundary — and the reason you can switch backends without touching a single `BGPPeer`.

## Step 2 — What frr-k8s gives you that native does not

| Capability | Why it matters |
|---|---|
| **BFD** | Sub-second peer failure detection instead of waiting for BGP hold timers (~seconds) |
| **IPv6 BGP and BFD** | Dual-stack clusters advertising IPv6 VIPs |
| **Multi-protocol BGP** | Carrying more than plain unicast |
| **Graceful restart** | A daemon restart does not drop the router's routes |
| **Merging your own FRR config** | The same FRR instance can serve your cluster's other routing needs, via the `FRRConfiguration` API |
| **First-class visibility CRs** | `BGPSessionState`, plus `ServiceBGPStatus` |

Two of those show up immediately. **Session state as a CR** — no `vtysh` needed, just `kubectl`:

```bash
kubectl -n metallb-system get bgpsessionstates -o yaml | head -45
```

```console
- apiVersion: frrk8s.metallb.io/v1beta1
  kind: BGPSessionState
  metadata:
    labels:
      frrk8s.metallb.io/node: metallb-lab-control-plane
      frrk8s.metallb.io/peer: 172.19.0.100
  ownerReferences:
  - kind: Pod
    name: metallb-frr-k8s-hj6pl
  status:
    bfdStatus: N/A
    bgpStatus: Established
    node: metallb-lab-control-plane
    peer: 172.19.0.100
```

…and **per-Service advertisement state**, which tells you exactly which node is advertising what, and to which peers:

```bash
kubectl -n metallb-system get servicebgpstatuses -o yaml
```

```console
- apiVersion: metallb.io/v1beta1
  kind: ServiceBGPStatus
  metadata:
    labels:
      metallb.io/node: metallb-lab-worker2
      metallb.io/service-name: whoami-b
  status:
    node: metallb-lab-worker2
    peers:
    - lab-router
    serviceName: whoami-b
    serviceNamespace: default
```

**These two CRs are how you debug BGP in production**: `bgpStatus: Established` proves the session, `ServiceBGPStatus` proves the advertisement. Neither requires shelling into a router.

## Step 3 — MetalLB is driving real FRR

The generated configuration lives inside the frr-k8s pod (`controller`, `frr`, `reloader`, `frr-metrics`, `frr-status`):

```bash
POD=$(kubectl -n metallb-system get pods -o name | grep frr-k8s | grep -v statuscleaner | head -1)
kubectl -n metallb-system exec $POD -c frr -- vtysh -c 'show running-config'
```

```console
router bgp 64512
 no bgp ebgp-requires-policy
 no bgp enforce-first-as
 no bgp hard-administrative-reset
 no bgp default ipv4-unicast
 bgp graceful-restart preserve-fw-state
 no bgp network import-check
 neighbor 172.19.0.100 remote-as 64513
 !
 address-family ipv4 unicast
  network 172.19.255.200/32
  network 172.19.255.201/32
  network 172.19.255.202/32
  network 172.19.255.203/32
  neighbor 172.19.0.100 activate
  neighbor 172.19.0.100 route-map 172.19.0.100-in in
  neighbor 172.19.0.100 route-map 172.19.0.100-out out
 exit-address-family
exit
```

This is real FRR syntax, generated from your CRs, with the in/out route-maps MetalLB manages for policy. Note `no bgp ebgp-requires-policy` — MetalLB supplies the route-maps itself, which is why it does not hit the safety default we had to disable by hand on the router in Lesson 5.

## Step 4 — Tag your prefixes with a community

Communities are the contract between Kubernetes and the network team: your cluster says "these VIPs are internet-facing", and the routers already know what to do with that tag.

```yaml
apiVersion: metallb.io/v1beta1
kind: Community
metadata:
  name: lab-community
  namespace: metallb-system
spec:
  communities:
    - name: lab-public
      value: 64512:100
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: lab-bgp
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
  communities:
    - lab-public        # by name, from the Community CR
  localPref: 200
```

```bash
kubectl apply -f communities.yaml
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast 172.19.255.200'
```

```console
BGP routing table entry for 172.19.255.200/32, version 29
Paths: (2 available, best #1, table default)
  64512
    172.19.0.2 from 172.19.0.2 (172.19.0.2)
      Origin IGP, metric 0, valid, external, multipath, best (Older Path)
      Community: 64512:100
      Last update: Sat Sep 12 13:34:15 2026
  64512
    172.19.0.3 from 172.19.0.3 (172.19.0.3)
      Origin IGP, metric 0, valid, external, multipath
      Community: 64512:100
```

The tag is on the wire, on every path. And here is how MetalLB implemented both settings — look at its generated outbound route-map:

```console
route-map 172.19.0.100-out permit 1
 match ip address prefix-list 172.19.0.100-200-ip-localpref-prefixes
 on-match next
 set local-preference 200
exit
route-map 172.19.0.100-out permit 2
 match ip address prefix-list 172.19.0.100-64512:100-ip-community-prefixes
 on-match next
 set community 64512:100 additive
exit
route-map 172.19.0.100-out permit 3
 match ip address prefix-list 172.19.0.100-allowed-ipv4
exit
```

> 💡 **`localPref` and eBGP — an honest note.** MetalLB does attach LOCAL_PREF (that `set local-preference 200` is real), but LOCAL_PREF is an *intra-AS* attribute: our router is in AS 64513, so it ignores the received value for path selection — you can see it is simply absent from the paths above (`Origin IGP, metric 0, valid, external…`, no localpref). LOCAL_PREF becomes meaningful when the router shares MetalLB's ASN (iBGP) — for example when your datacenter fabric is one AS and MetalLB peer ASNs match it. Communities, by contrast, work over eBGP and are the portable tool.

## Step 5 — Make the router act on the community

Policy on the router side: match the tag, prefer the path.

```bash
docker exec metallb-router vtysh \
  -c 'configure terminal' \
  -c 'bgp community-list standard LAB-PUBLIC permit 64512:100' \
  -c 'route-map LAB-IN permit 10' \
  -c 'match community LAB-PUBLIC' \
  -c 'set local-preference 500' \
  -c 'exit' \
  -c 'router bgp 64513' \
  -c 'neighbor 172.19.0.2 route-map LAB-IN in' \
  -c 'neighbor 172.19.0.3 route-map LAB-IN in' \
  -c 'neighbor 172.19.0.4 route-map LAB-IN in' \
  -c 'end'
docker exec metallb-router vtysh -c 'clear bgp * soft in'
```

```console
      Origin IGP, metric 0, localpref 500, valid, external, multipath, best (Older Path)
      Community: 64512:100
```

`localpref 500` on both paths: the router matched on the community our cluster attached and raised its preference. This is the pattern to design with — **the cluster tags, the network decides** (announce to transit? keep internal? prefer path A over B?) without ever teaching a router about individual Services.

## Step 6 — Withdrawal: what BGP does that L2 cannot

Scale the app to zero so no Service has a healthy endpoint:

```bash
kubectl scale deploy/whoami --replicas=0
sleep 20
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast'
kubectl get svc whoami -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
```

```console
     Network          Next Hop            Metric LocPrf Weight Path
                                                    # ← nothing. The prefixes are gone from BGP.
NAME     EXTERNAL-IP
whoami   172.19.255.200                             # ← but the Service still "has" an address
```

The speaker says exactly why:

```console
{"caller":"main.go:525","event":"serviceWithdrawn","ip":["172.19.255.202"],"level":"info",
 "msg":"withdrawing service announcement","pool":"lab-pool","protocol":"bgp",
 "reason":"noEndpoints","ts":"2026-09-12T13:34:30Z"}
```

Compare the two modes for the same situation:

| | Layer 2 (Lesson 4) | BGP (here) |
|---|---|---|
| `EXTERNAL-IP` in the Service | unchanged | unchanged |
| Announcement | speaker stops answering ARP; `ServiceL2Status` disappears | speaker **withdraws the prefix**; `ServiceBGPStatus` disappears |
| What the network knows | nothing (ARP is not a routing protocol) | the route is explicitly removed from the router's RIB/FIB |
| Recovery | wait for ARP caches to expire | route reappears, routers converge |

The BGP withdrawal is what makes **anycast/geo-redundancy** possible: advertise the same VIP from two clusters, and when one loses its endpoints it withdraws, so the router sends traffic to the surviving cluster.

Restore:

```bash
kubectl scale deploy/whoami --replicas=3
kubectl rollout status deploy/whoami
```

## Expected outcome

| What | State |
|---|---|
| Backend | `frr-k8s` (the v0.16 default), 3× 5-container pods |
| Sessions after the switch | `Established`, restored automatically |
| `BGPSessionState` | `bgpStatus: Established`, `bfdStatus: N/A` (no BFD profile configured) |
| `ServiceBGPStatus` | one row per Service per advertising node, listing peers |
| Community | `64512:100` on every advertised prefix, visible on the router |
| Router policy | community matched → `localpref 500` applied |
| No endpoints | prefixes withdrawn (`reason: noEndpoints`), Service keeps its IP |

## Production note

- **Run the default backend.** frr-k8s is where new BGP features land; the legacy `frr` mode is deprecated and the native mode is a deliberate trade-off (less to run, fewer features — and no BFD, which is usually the reason people choose FRR-based modes).
- **Design communities with your network team first.** They are the interface between "Kubernetes stuff" and "network policy"; deciding the tag scheme up front avoids per-Service router changes forever.
- **Alert on session state and prefix counts**, not just on `EXTERNAL-IP`. `BGPSessionState` gives you `Established`/`Idle` per node per peer, and a service with an IP but no `ServiceBGPStatus` is invisible to the network.
- **Plan for rehash**: any change in the set of advertising nodes resets connections that hash to a removed node. Graceful restart and stable ECMP hashing reduce the blast radius.
- **BFD if you need fast failover**: a `BFDProfile` plus BFD enabled on the peers gets you sub-second detection, which is the BGP answer to the L2 "clients ignore GARP" problem from Lesson 4.
- **Don't advertise everything to everyone.** `nodeSelectors` on `BGPPeer`, and per-Service selection (Lesson 7), keep the route count and the blast radius small.

## Next
Continue to [Lesson 7 — Advanced addressing and advertisement control](../lesson-07-advanced/README.md).

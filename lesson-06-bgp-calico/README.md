# Lesson 6 — BGP with Calico

## Glossary
| Term | What it means |
|------|---------------|
| **node-to-node mesh** | Calico's default: every node peers with every other node (iBGP) to exchange *pod* routes |
| **global `BGPPeer`** | A Calico peer object with no `nodeSelector` → every node opens that session |
| **`asNumber`** | The AS a peer belongs to. **Calico's default is `64512`** |
| **`BGPConfiguration`** | Cluster-wide BGP settings, including *which service addresses to advertise* |
| **`serviceLoadBalancerIPs`** | The CIDRs Calico announces for Services of type LoadBalancer |
| **`BGPFilter`** | Calico's route policy: ordered import/export rules with `Accept`/`Reject` (Calico's route-map) |
| **`CalicoNodeStatus`** | A CR reporting a node's BGP peers and their state — no shell into the node needed |
| **`encapsulation: None`** | Pod traffic is routed, not tunnelled (Lesson 5) — which is why the router sees real routes |

In Lesson 5 MetalLB allocated `172.19.255.200` and **nobody announced it**. This lesson is the other half: Calico is the BGP speaker, and you teach it what to say.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `router-setup.sh` — the FRR "datacenter router" container, peering with the Calico nodes (AS `64512`).
- `calico-bgp.yaml` — a global `BGPPeer` **and** the `default` `BGPConfiguration` (Step 3).
- `caliconodestatus.yaml` — ask a node for its BGP peer state (Step 3).
- `bgpfilter.yaml` — export/import policy for the router session (Step 7).

## Step 1 — Build the router

```bash
./router-setup.sh
```

Its neighbour list is `172.19.0.2/.3/.4` — the **node** IPs — because the BGP speaker is now `calico-node` on each node. Calico's default AS is `64512`, so the router expects that:

```console
router bgp 64513
 no bgp ebgp-requires-policy
 neighbor 172.19.0.2 remote-as 64512
 neighbor 172.19.0.3 remote-as 64512
 neighbor 172.19.0.4 remote-as 64512
exit
```

At this point the router has a config but **no sessions** — Calico has not been told the router exists:

```bash
docker exec metallb-router vtysh -c 'show bgp summary'
```

```console
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
172.19.0.2      4      64512         0         0        0    0    0    never         Idle        0 N/A
172.19.0.3      4      64512         0         0        0    0    0    never         Idle        0 N/A
172.19.0.4      4      64512         0         0        0    0    0    never         Idle        0 N/A
```

`Idle` (and later `Active`) means *not connected*. Each side must name the other — Step 3 makes Calico do that.

> 💡 The `no bgp ebgp-requires-policy` line is the same shortcut as in phase 1: FRR refuses to exchange eBGP routes without an explicit policy, and we are skipping the policy in the lab. In production you would attach route-maps on the router — or, on the Calico side, **`BGPFilter`** (Step 7).

> 🧪 **Lab Hack:** if your cluster handed out different node IPs, pass them: `NODE1=… NODE2=… NODE3=… ./router-setup.sh`. Check with `kubectl get nodes -o wide`.

## Step 2 — Look at what Calico ships with

```bash
kubectl get bgpconfiguration
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec}{"\n"}'
```

```console
No resources found
{"allowedUses":["Workload","Tunnel"],"assignmentMode":"Automatic","blockSize":26,"cidr":"192.168.0.0/16","natOutgoing":true,"nodeSelector":"all()"}
```

Two things surprise people here:

- **There is no `BGPConfiguration` object, and that is normal.** Calico only creates one when something needs to *change* a default. Absent means the built-in defaults apply: **AS `64512`** and the **node-to-node mesh on**. This is why Step 3 has to create it — `kubectl patch bgpconfiguration default` on a cluster like this fails with `NotFound`.
- **Nothing in the IPPool says "no encapsulation".** With `encapsulation: None` from Lesson 5, neither `ipipMode` nor `vxlanMode` appears, and the absence of both *is* the setting. The `ipipMode: Never` style you find in older blog posts is the IPPool-level equivalent.

> ⚠️ **If you ever disable the mesh**, Calico's docs are blunt: pod networking breaks until replacement `BGPPeer`s exist. Create the peers **first**, then disable. We keep the mesh here, so nothing breaks.

## Step 3 — Tell Calico about the router

```bash
kubectl apply -f calico-bgp.yaml
docker exec metallb-router vtysh -c 'show bgp summary'
```

```console
bgppeer.projectcalico.org/tor-router created
bgpconfiguration.projectcalico.org/default created

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
172.19.0.2      4      64512         4         6        6    0    0 00:00:22            3        3 N/A
172.19.0.3      4      64512         4         5        6    0    0 00:00:22            3        3 N/A
172.19.0.4      4      64512         4         6        6    0    0 00:00:22            3        3 N/A
```

The state word is gone: **a number means Established**. Three sessions, one per node — Calico's per-node speakers, exactly like MetalLB's were in phase 1.

> ⚠️ If instead you see `no matches for kind "BGPPeer" in version "projectcalico.org/v3"`, the Calico API server is missing — Lesson 5's third trap. `kubectl get crd | grep bgppeer` shows the CRD exists while `kubectl api-resources --api-group=projectcalico.org` returns nothing, because the CRDs publish `crd.projectcalico.org/v1` and `v3` is served by the aggregated API server.

And you will see more than VIPs — Calico advertises the pod CIDRs, which is its day job:

```bash
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast'
```

```console
     Network          Next Hop            Metric LocPrf Weight Path
 *>  192.168.64.64/26 172.19.0.2                             0 64512 i
 *=                   172.19.0.3                             0 64512 i
 *=                   172.19.0.4                             0 64512 i
 *>  192.168.81.192/26
                    172.19.0.2                             0 64512 i
 *=                   172.19.0.3                             0 64512 i
 *=                   172.19.0.4                             0 64512 i
 *>  192.168.237.192/26
                    172.19.0.2                             0 64512 i
 *=                   172.19.0.3                             0 64512 i
 *=                   172.19.0.4                             0 64512 i

Displayed 3 routes and 9 total paths
```

Your ToR learning pod routes is normal and useful: it is what makes `encapsulation: None` work, and the cross-node test in Lesson 5 proved it does. If you want a table containing *only* service addresses, that is what `BGPFilter` is for (Step 7).

Verify from Calico's side without shelling into a node:

```bash
kubectl apply -f caliconodestatus.yaml
kubectl get caliconodestatus worker-status \
  -o jsonpath='{range .status.bgp.peersV4[*]}{.peerIP}{"  "}{.state}{"  "}{.type}{"\n"}{end}'
```

```console
172.19.0.4  Established  NodeMesh
172.19.0.2  Established  NodeMesh
172.19.0.100  Established  GlobalPeer
```

Two details worth noting: `updatePeriodSeconds` is **required** by the CRD (omit it and the API rejects the object with `Invalid value: "null"`), and every peer is labelled by `type` — `NodeMesh` for Calico's internal mesh, `GlobalPeer` for our `BGPPeer`. That distinction is what you want in a runbook: one is the pod network, the other is your service advertisement.

> 🏭 **Production:** on a real node, `calicoctl node status` gives the same view (it talks to the local Calico agent, so it must run *on* the node). `CalicoNodeStatus` is the API-side equivalent, and is what you would query from CI or scrape.

## Step 4 — Teach Calico which addresses to announce

MetalLB stopped at "here is your address". Calico needs the equivalent of `BGPAdvertisement`:

```bash
kubectl patch bgpconfiguration default --type=merge -p \
  '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "172.19.255.0/24"}]}}'
```

```bash
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast 172.19.255.0/24'
docker exec metallb-router ip route show 172.19.255.0/24
```

```console
BGP routing table entry for 172.19.255.0/24, version 15
Paths: (9 available, best #1, table default)
  64512
    172.19.0.2 from 172.19.0.2 (172.19.0.2)
      Origin IGP, valid, external, multipath, best (Nothing left to compare)
...
172.19.255.0/24 nhid 27 proto bgp metric 20
	nexthop via 172.19.0.2 dev eth0 weight 1
	nexthop via 172.19.0.4 dev eth0 weight 1
	nexthop via 172.19.0.3 dev eth0 weight 1
```

**Every node advertises it, so the router installs three equal-cost next hops.** That is the fan-out that makes ECMP possible — and unlike phase 1, all three nodes participate, control-plane included (no node carries the `exclude-from-external-load-balancers` label here).

> 🐞 **`/32` entries are not advertised in Calico 3.30.3 — use a CIDR.** The per-address form was tried first:
>
> ```bash
> # produces NO advertisements on 3.30.3 — verified, 0 routes after 60 seconds
> kubectl patch bgpconfiguration default --type=merge -p \
>   '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "172.19.255.200/32"},{"cidr":"172.19.255.201/32"}]}}'
> ```
>
> `172.19.255.0/24` appeared within seconds; the identical list written as four `/32`s stayed invisible for a full minute, while `calico-node` logged `Updates included service advertisement changes` — Calico accepted the config and advertised nothing. That matches the `/32` regressions in the 3.30 line: [`/32` rejected in `serviceExternalIPs` on 3.30+](https://github.com/projectcalico/calico/issues/10945) and a [/32 LoadBalancer fix](https://github.com/projectcalico/calico/pull/11917) that landed on the 3.29 branch. **Check your version before designing around `/32`s.**
>
> The practical consequence: **Calico 3.30 gives you block-level advertisement only.** MetalLB's per-Service granularity has no equivalent, which changes two things:
>
> - **Unused addresses get announced too.** Every address in the block is advertised whether or not a Service uses it, so clients can reach a black hole. There is no "withdraw when the Service has no endpoints" behaviour to rely on.
> - **"Internal-only VIP" becomes a *pool* decision, not an address decision** (Lesson 7): keep a pool whose CIDR is simply absent from `serviceLoadBalancerIPs`.

## Step 5 — Reach it from a routed client

```bash
# netshoot has curl and ip; nothing to install
docker run -d --name metallb-client --network kind --cap-add NET_ADMIN \
  nicolaka/netshoot sleep infinity
docker exec metallb-client ip route add 172.19.255.0/24 via 172.19.0.100
docker exec metallb-client curl -s http://172.19.255.200 | head -3
```

```console
Hostname: whoami-8644bfc655-8lh9m
IP: 127.0.0.1
IP: ::1
```

Same shape as phase 1 — client → router → node → `kube-proxy` DNAT → pod — with `calico-node` instead of a MetalLB speaker as the advertiser:

| Box | Decision | Learned from |
|---|---|---|
| client `172.19.0.x` | VIPs → `172.19.0.100` | the static route you just added |
| router `172.19.0.100` | `172.19.255.0/24` → three nodes | **BGP, from calico-node** |
| node `172.19.0.x` | VIP → pod `192.168.x.y` | `kube-proxy` DNAT rules |

## Step 6 — Make ECMP actually spread

Twenty connections from the client, counting which node's MAC the router sent each new connection to. **Start the traffic first, then capture in the foreground** — see the note below for why that ordering matters:

```bash
# 1. the traffic, in the background
( for i in $(seq 1 20); do
    docker exec metallb-client curl -sS -o /dev/null -m 3 http://172.19.255.200
    sleep 0.2
  done ) &

# 2. the capture, in the foreground: exits after 40 SYNs or 30s, whichever comes first
docker exec metallb-router timeout 30 tcpdump -i eth0 -n -e -c 40 \
  'tcp[tcpflags] & tcp-syn != 0' > /tmp/syn.txt 2>/dev/null
wait

# 3. where did the router send them?
grep -oE '> [0-9a-f:]{17}' /tmp/syn.txt | sort | uniq -c
```

```console
captured lines: 39
      7 > 02:75:73:9e:3a:90
      9 > 12:6f:20:6f:b5:a4
     19 > 2a:d4:01:9a:98:c2
      3 > a2:ef:11:de:43:b3
```

Decode against each node's own MAC — they are assigned when the container is created, so yours will differ:

```bash
for n in metallb-calico-worker metallb-calico-worker2 metallb-calico-control-plane metallb-router; do
  printf '%-30s %s\n' "$n" "$(docker exec $n ip -br link show eth0 | awk '{print $3}')"
done
```

```console
metallb-calico-worker          02:75:73:9e:3a:90     ← 7 connections
metallb-calico-worker2         12:6f:20:6f:b5:a4     ← 9 connections
metallb-calico-control-plane   a2:ef:11:de:43:b3     ← 3 connections
metallb-router                 2a:d4:01:9a:98:c2     ← the 19 SYNs arriving
```

**19 connections, all three nodes, no single-node bottleneck.** (The 20th request reused an existing connection, so it produced no SYN — with keep-alive or HTTP reuse you will always see slightly fewer SYNs than requests.)

**This is the whole promise of BGP mode, demonstrated.** Compare phase 1, where one elected node owned the VIP and every packet had to enter it. The cost is the block-level granularity from Step 4 and a static list to maintain.

> ⚠️ **Do not capture with `docker exec -d` + `-w file`.** That form looks tidier but **silently produces an empty capture** often enough to waste an hour: the detached tcpdump is running, the traffic is flowing, and the file sits at its 24-byte pcap header with zero packets. (It is not a filter problem — the filter above is fine, and so is the file-writing form *when it works*.) The foreground `-c N` + `timeout` version cannot fail quietly: it prints packets as they arrive and exits on its own, so an empty result means genuinely no matching traffic.

> 💡 If all connections land on one node, your router is hashing on layer 3 only. `router-setup.sh` sets `net.ipv4.fib_multipath_hash_policy=1` for exactly this reason, and it can only be set at container creation.

## Step 7 — `BGPFilter`: Calico's route policy

One CIDR list means one policy for every peer. To control what crosses a specific session, attach a `BGPFilter` — this is the mechanism that stops your cluster telling the whole network about its pod blocks.

**What the docs suggest does not work**, so start from the measured version — it is in `bgpfilter.yaml`:

```yaml
spec:
  exportV4:
    - action: Accept
      matchOperator: In
      cidr: 172.19.255.0/24     # the VIP block: let it out
    - action: Reject
      matchOperator: NotIn
      cidr: 172.19.255.0/24     # everything else: keep it in
  importV4:
    - action: Reject
      matchOperator: NotIn
      cidr: 172.19.255.0/24
```

```bash
kubectl apply -f bgpfilter.yaml
kubectl patch bgppeer tor-router --type=merge -p '{"spec":{"filters":["services-only"]}}'
```

Before and after, on the router:

```console
# before — Calico's pod blocks as well as the VIP block
192.168.64.64/26      # control-plane
192.168.81.192/26     # worker
192.168.237.192/26    # worker2
172.19.255.0/24       # the VIP block

# after — only what we agreed to advertise
172.19.255.0/24
```

Two things make this safe, and both were verified: the **mesh is untouched** (a pod on `worker` still reached a pod on `worker2`, so `encapsulation: None` keeps working), and the **VIP still answers** (`200` from the routed client). A `BGPPeer` filter governs that one session with the router, not Calico's internal routing.

> ⚠️ **Why the obvious version fails.** Calico's own examples use rules like `action: Reject, source: RemotePeers` and `action: Reject, interface: '*.calico'` as if they were catch-alls. They are not:
>
> - `source: RemotePeers` matches routes **learned from** a peer — a transit-prevention rule. Calico's pod CIDRs are locally originated, so they match nothing.
> - **Rules are ordered, the first match wins, and if nothing matches the default is `Accept`.** So a filter whose only `Reject` rule is "routes from remote peers" exports your pod blocks anyway.
>
> Measured, with exactly that filter applied and the session `Established`: the router's table was **unchanged** — all three `/26`s still present. That is the failure mode to watch for: a filter that looks like policy and changes nothing. The explicit `Accept In` + `Reject NotIn` pair above is what actually narrows the session.

> 💡 This also carries the lesson from phase 1: **an over-narrow export filter is a black hole that looks like a healthy session.** The session stays `Established` while the prefix never appears. Whenever you touch filters, check the *prefix list* on the router, not the session state.

## What you gave up, and what you gained

| | MetalLB speaker (phase 1 design) | Calico (now) |
|---|---|---|
| Speaker per node | extra DaemonSet | already there (`calico-node`) |
| Per-Service advertisement | `serviceSelectors` on `BGPAdvertisement` | **none** — block-level CIDRs only |
| Per-address `/32` advertisement | the default behaviour | **not advertised in 3.30.3** (Step 4) |
| Withdraw when no healthy endpoints | yes (`reason: noEndpoints`) | no — a listed block stays announced |
| Communities / `localPref` | yes | no (filters are CIDR-based) |
| Route policy | router-side route-maps | `BGPFilter` (per peer, ordered) |
| Announcement visibility | `ServiceBGPStatus`, `BGPSessionState` | `CalicoNodeStatus`, `calicoctl node status`, router RIB |
| Allocation | MetalLB `IPAddressPool` | MetalLB `IPAddressPool` (**unchanged** — that is the point) |

## Expected outcome

| What | State |
|---|---|
| Router sessions | 3, `Established` (numeric `State/PfxRcd`), AS `64512` |
| Router RIB | 3 pod CIDRs × 3 paths, plus the advertised VIP block |
| VIP in the router FIB | `172.19.255.0/24` with **3** nexthops |
| Client via the router | `curl` returns a `whoami` pod |
| 20 connections | spread across all 3 nodes (7 / 9 / 3 in our run) |
| `CalicoNodeStatus` | 2 × `NodeMesh` + 1 × `GlobalPeer`, all `Established` |
| `whoami` from the host | still unreachable — the host has no route via the router |

## Production note

- **Pin Calico and test the advertisement path specifically.** `/32` handling has real churn in the 3.30 line (Step 4), and its failure is silent: a healthy session with no prefix.
- **Design for block-level advertisement.** Segregate VIP classes into separate blocks — public, internal, per-tenant — because that block list is the only granularity on offer. It replaces the per-Service selectors you may be used to.
- **Never point the block at addresses you cannot serve.** With no withdraw-on-empty behaviour, an announced-but-dead address is a black hole for clients.
- **Keep the mesh on** unless you are deliberately moving to ToR peering or route reflectors; disabling it breaks pod routing until replacement peers exist.
- **Install the Calico `APIServer`** if you want to manage Calico with `kubectl` and the documented `projectcalico.org/v3` manifests (Lesson 5, trap 3).
- **Watch prefix counts, not just session state.** `Established` with the wrong prefixes is this design's characteristic failure.

## Next
Continue to [Lesson 7 — Advanced addressing](../lesson-07-advanced/README.md), which has been updated for this Calico cluster.

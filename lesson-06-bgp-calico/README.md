# Lesson 6 — BGP with Calico

## Glossary
| Term | What it means |
|------|---------------|
| **node-to-node mesh** | Calico's default: every node peers with every other node (iBGP) to exchange *pod* routes |
| **global `BGPPeer`** | A Calico peer object with no `nodeSelector` → every node opens that session |
| **`asNumber`** | The AS a peer belongs to. **Calico's default is `64512`** |
| **`BGPConfiguration`** | Cluster-wide BGP settings, including *which service IPs to advertise* |
| **`serviceLoadBalancerIPs`** | The CIDRs (or `/32`s) Calico announces for Services of type LoadBalancer |
| **`BGPFilter`** | Calico's route policy: ordered import/export rules with `Accept`/`Reject` (Calico's route-map) |
| **`CalicoNodeStatus`** | A CR that reports a node's BGP session state — `calicoctl node status` without shelling into the node |
| **per-`/32`** | Advertising one address instead of a block. Calico's documented behaviour with `externalTrafficPolicy: Local` |
| **`encapsulation: None`** | Pod traffic is routed, not tunnelled (Lesson 5) — which is why the router sees real routes |

In Lesson 5 MetalLB allocated `172.19.255.200` and **nobody announced it**. This lesson is the other half: Calico is the BGP speaker, and you teach it what to say.

> ⚠️ **This lesson's `console` blocks are *expected* output, not captured transcripts** (see the note in Lesson 5). Run them, then paste your real output back so they can be replaced with the genuine article.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `router-setup.sh` — the FRR "datacenter router" container, peering with the Calico nodes (AS `64512`).
- `calico-bgp.yaml` — a global `BGPPeer` pointing at that router.

## Step 1 — Build the router

```bash
./router-setup.sh
```

Its neighbour list is `172.19.0.2/.3/.4` — the **node** IPs — because the BGP speaker is now `calico-node` on each node. Calico's default AS is `64512`, so the router expects that:

```console
# expected
router bgp 64513
 no bgp ebgp-requires-policy
 neighbor 172.19.0.2 remote-as 64512
 neighbor 172.19.0.3 remote-as 64512
 neighbor 172.19.0.4 remote-as 64512
exit
```

> 💡 The `no bgp ebgp-requires-policy` line is the same shortcut as before: FRR refuses to exchange eBGP routes without an explicit policy, and we are skipping the policy in the lab. In production you would attach route-maps — or, on the Calico side, **`BGPFilter`** (Step 7).

> 🧪 **Lab Hack:** if your new cluster handed out different node IPs, pass them: `NODE1=… NODE2=… NODE3=… ./router-setup.sh`. Check with `kubectl get nodes -o wide`.

At this point the router has a config but **no sessions** — Calico has not been told the router exists:

```bash
docker exec metallb-router vtysh -c 'show bgp summary'
```

```console
# expected
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
172.19.0.2      4      64512         0         0        0    0    0    never      Active
172.19.0.3      4      64512         0         0        0    0    0    never      Active
172.19.0.4      4      64512         0         0        0    0    0    never      Active
```

`Active` sounds healthy — it means *"not connected, retrying"*. Each side must name the other.

## Step 2 — Look at what Calico already does

```bash
kubectl get bgpconfiguration default -o yaml
kubectl get ippools.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr,ENCAP:.spec.ipipMode
```

```console
# expected
spec:
  asNumber: "64512"                # the default global AS
  nodeToNodeMeshEnabled: true      # every node peers with every other node
```

Two things to notice:

- **The mesh is on.** That is how pod routes get around the cluster (with `encapsulation: None` from Lesson 5, BGP *is* the pod network). Leave it alone: it is doing a different job from the router peering.
- **`asNumber: 64512`** — the same number MetalLB used in the old lesson, coincidentally, because 64512 is the default AS for both projects.

> ⚠️ **If you ever disable the mesh**, Calico's docs are blunt: pod networking breaks until replacement `BGPPeer`s exist. Create the peers **first**, then disable. We keep the mesh here, so nothing breaks.

## Step 3 — Tell Calico about the router

```bash
kubectl apply -f calico-bgp.yaml
docker exec metallb-router vtysh -c 'show bgp summary'
```

```console
# expected
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
172.19.0.2      4      64512        12        10        7    0    0 00:00:14            2
172.19.0.3      4      64512        12        10        7    0    0 00:00:14            2
172.19.0.4      4      64512        12        10        7    0    0 00:00:14            2
```

The state word is gone: **a number means Established**. Three sessions, one per node — Calico's per-node speakers, exactly like MetalLB's were in the old design.

And you will see more than VIPs:

```bash
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast'
```

```console
# expected — pod CIDRs as well as service addresses
 *>  172.19.255.200/32   172.19.0.3      0 64512 i
 *>  192.168.1.0/26      172.19.0.2      0 64512 i
 *>  192.168.2.0/26      172.19.0.3      0 64512 i
```

**Calico advertises workload routes too** — that is its day job. Your ToR learning pod CIDRs is normal and useful (it is what makes `encapsulation: None` work). If you want a clean table containing only service addresses, that is what `BGPFilter` is for (Step 7).

Verify from Calico's side without shelling into a node:

```bash
kubectl apply -f - <<'EOF'
apiVersion: projectcalico.org/v3
kind: CalicoNodeStatus
metadata:
  name: worker-status
spec:
  node: metallb-calico-worker
  classes:
    - BGP
EOF
kubectl get caliconodestatus worker-status -o yaml | grep -A6 'bgp:'
```

```console
# expected
  bgp:
    peers:
      - peerIP: 172.19.0.100
        state: Established
```

> 🏭 **Production:** on a real node, `calicoctl node status` gives the same view (it talks to the local Calico agent, so it must run *on* the node). `CalicoNodeStatus` is the API-side equivalent and is what you would scrape or query from CI.

## Step 4 — Teach Calico which addresses to announce

MetalLB stopped at "here is your address". Calico needs the equivalent of `BGPAdvertisement`:

```bash
kubectl patch bgpconfiguration default --type=merge -p \
  '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "172.19.255.200/32"},{"cidr": "172.19.255.201/32"},{"cidr": "172.19.255.202/32"},{"cidr": "172.19.255.203/32"}]}}'
```

```bash
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast' | grep 172.19.255
```

```console
# expected
 *>  172.19.255.200/32   172.19.0.2      0 64512 i
 *=                    172.19.0.3      0 64512 i
 *=                    172.19.0.4      0 64512 i
```

**One entry per VIP, and every node advertises it** — that is the multi-path fan-out that makes ECMP possible, and it is why the router now has three next-hops for each address.

`--type=merge` matters: a plain `kubectl apply` of a whole `BGPConfiguration` would replace the object and could drop settings Calico's operator put there (like the mesh flag). Patch, don't clobber.

> 💡 **CIDR vs `/32` — the one trade-off to internalise.** You can list the whole block instead:
> ```
> serviceLoadBalancerIPs: [{"cidr": "172.19.255.200/24"}]
> ```
> Calico then announces **the entire block** whether or not a Service exists in it — an address nobody is serving still gets advertised, so clients can reach a black hole. Listing `/32`s gives you MetalLB-like per-address granularity, at the cost of maintaining the list by hand. Lesson 7's "internal-only VIP" pattern follows from this: an address whose `/32` is *not* in the list simply does not exist for the network.

## Step 5 — Reach it from a routed client

```bash
# netshoot has curl and ip; nothing to install
docker run -d --name metallb-client --network kind --cap-add NET_ADMIN \
  nicolaka/netshoot sleep infinity
docker exec metallb-client ip route add 172.19.255.0/24 via 172.19.0.100
docker exec metallb-client curl -s http://172.19.255.200 | head -3
```

```console
# expected
Hostname: whoami-xxxxxxxxx-yyyyy
IP: 127.0.0.1
IP: ::1
```

Same shape as the old Lesson 5 — client → router → node → `kube-proxy` DNAT → pod — with `calico-node` instead of a MetalLB speaker as the advertiser:

| Box | Decision | Learned from |
|---|---|---|
| client `172.19.0.6` | VIPs → `172.19.0.100` | the static route you just added |
| router `172.19.0.100` | VIP/32 → node `172.19.0.2` | **BGP, from calico-node** |
| node `172.19.0.2` | VIP → pod `192.168.x.y` | `kube-proxy` DNAT rules |

## Step 6 — Make ECMP actually spread

The measure-twice experiment from the old course, unchanged — run 20 connections and count which node's MAC each SYN was sent to:

```bash
docker exec metallb-router rm -f /tmp/syn.pcap
docker exec -d metallb-router tcpdump -i eth0 -n -e -w /tmp/syn.pcap 'tcp[tcpflags] & tcp-syn != 0'
docker exec metallb-client sh -c 'for i in $(seq 1 20); do curl -s -o /dev/null http://172.19.255.200; done'
docker exec metallb-router pkill tcpdump
docker exec metallb-router tcpdump -r /tmp/syn.pcap -n -e | grep -oE '> [0-9a-f:]{17}' | sort | uniq -c
```

```console
# expected — with fib_multipath_hash_policy=1 set by router-setup.sh
     20 > <router's own MAC>     # the incoming SYN
     11 > <worker MAC>           # forwarded to one node
      9 > <worker2 MAC>          # and to the other
```

If all 20 land on one node, your router is hashing on layer 3 only — `router-setup.sh` sets `net.ipv4.fib_multipath_hash_policy=1` for exactly this reason, and it can only be set at container creation.

## Step 7 — `BGPFilter`: Calico's route policy

One CIDR/`/32` list means one policy for every peer. To control what crosses a specific session, attach a `BGPFilter`:

```yaml
apiVersion: projectcalico.org/v3
kind: BGPFilter
metadata:
  name: services-only
spec:
  exportV4:
    - action: Accept
      matchOperator: In
      cidr: 172.19.255.0/24      # only the VIP block leaves the cluster
    - action: Reject
      source: RemotePeers
  importV4:
    - action: Reject
      matchOperator: NotIn
      cidr: 172.19.255.0/24
```

Attach it to the peer:

```bash
kubectl patch bgppeer tor-router --type=merge -p '{"spec":{"filters":["services-only"]}}'
```

Now the router's table contains only the VIPs — no pod CIDRs. Two rules of thumb:

- **rules are ordered**, and the **first match wins**; if nothing matches, the default is `Accept`. So a filter that only contains `Reject`s rejects nothing you did not name — but a filter with one narrow `Accept` and no catch-all `Reject` still lets everything else through.
- This is Calico's equivalent of the router-side route-map you meet in Lesson 7 — and it carries the same failure mode: **an over-narrow export filter is a black hole that looks like a healthy session.** The session stays `Established` while the prefix never appears.

> 💡 What `BGPFilter` cannot do: match on **communities** or set `localPref`. If your network team's policy depends on community tags per pool, that is a MetalLB feature Calico does not replace.

## What you gave up, and what you gained

| | MetalLB speaker (old Lessons 5–6) | Calico (now) |
|---|---|---|
| Speaker per node | extra DaemonSet | already there (`calico-node`) |
| Per-Service advertisement | `serviceSelectors` on `BGPAdvertisement` | CIDR/`/32` lists only |
| Withdraw when no healthy endpoints | yes (`reason: noEndpoints`) | **no** — a static `/32` stays announced |
| Communities / `localPref` | yes | no (filters are CIDR-based) |
| Route policy | router-side route-maps | `BGPFilter` (per peer, ordered) |
| Announcement visibility | `ServiceBGPStatus`, `BGPSessionState`, `metallb_speaker_announced` | `CalicoNodeStatus`, `calicoctl node status`, router RIB |
| Allocation | MetalLB `IPAddressPool` | MetalLB `IPAddressPool` (**unchanged** — that is the point) |

## Expected outcome

| What | State |
|---|---|
| Router sessions | 3, `Established` (numeric `State/PfxRcd`) |
| `BGPConfiguration` | `asNumber: 64512`, mesh on, `serviceLoadBalancerIPs` set |
| Router RIB | the VIP `/32`s, each with three next-hops (plus pod CIDRs unless filtered) |
| Client via the router | `curl` returns a `whoami` pod |
| 20 connections | spread across nodes (11/9 with L4 hashing) |
| `CalicoNodeStatus` | `state: Established` for peer `172.19.0.100` |

## Production note

- **Pin Calico and test this path specifically.** `/32` handling has had recent churn: [`/32` rejected in `serviceExternalIPs` on 3.30+](https://github.com/projectcalico/calico/issues/10945) and [/32 LB IPs from an IPPool needed a fix](https://github.com/projectcalico/calico/pull/11917). Also check [issue #6074](https://github.com/projectcalico/calico/issues/6074) (advertisement vs `externalTrafficPolicy: Local` for LB services) against your version before relying on the per-`/32` behaviour.
- **Design the topology on purpose.** Full-mesh suits ≲100 nodes; beyond that use route reflectors, and for ToR peering follow Calico's guidance on disabling the mesh *after* the replacement peers exist.
- **One exporter of routes per node.** If you ever re-enable MetalLB's speaker with BGP, you are back to the session conflict — the constraint that started this whole phase.
- **Watch the router's prefix count, not just session state.** `Established` with the wrong prefixes is the failure mode this design is most prone to (static lists + filters).
- **Own the boundary with your network team** either way: who allocates (`IPAddressPool`), what is announced (`serviceLoadBalancerIPs`), and what is accepted (their route-maps, your `BGPFilter`).

## Next
Continue to [Lesson 7 — Advanced addressing](../lesson-07-advanced/README.md), which has been updated for this Calico cluster.

# Lesson 8 — Operations and troubleshooting

## Glossary
| Term | What it means |
|------|---------------|
| **allocation vs announcement** | The two independent halves of a working VIP: an address being *assigned* to a Service, and that address being *reachable* on the network |
| **`AllocationFailed`** | The event reason MetalLB's controller uses when it cannot give a Service an address |
| **`IPAddressPool.status`** | Per-pool `assignedIPv4` / `availableIPv4` — your capacity numbers |
| **`ConfigurationState`** | The CR where MetalLB reports whether it managed to apply your CRs |
| **advertised block** | A CIDR in `BGPConfiguration.spec.serviceLoadBalancerIPs` (Lesson 7) |
| **`CalicoNodeStatus`** | A CR reporting a node's BGP peers and their state (Lesson 6) |

In phase 1 one component did both halves. In phase 2 they are split: **MetalLB's controller allocates, Calico announces.** Almost every incident is an allocation problem, an announcement problem, or a network-side problem — and that first question now also tells you which component to open.

## Files
- `alerts.yaml` — Prometheus rules for the four things worth alerting on. Not applied by this lab (there is no Prometheus); it is the artifact you keep in Git.

## Step 1 — The one question that halves your debugging time

```
Is this a problem of ALLOCATION, or of ANNOUNCEMENT?
```

| Ask | Allocation (MetalLB controller) | Announcement (Calico + the router) |
|---|---|---|
| Does the Service have an address? | `kubectl get svc <name>` → `EXTERNAL-IP` | irrelevant |
| What proves it happened? | `IPAllocated` event, `IPAddressPool.status` | `CalicoNodeStatus`, the router's RIB and FIB |
| Who logs it? | `metallb-controller` | `calico-node`, the ToR |
| Typical causes | no pool, pool exhausted, namespace/pool mismatch, pinned IP not owned | block missing from `serviceLoadBalancerIPs`, block dropped by a `BGPFilter`, node excluded by the `BGPPeer`, no route past the router |

A Service with a perfect `EXTERNAL-IP` can be completely unreachable. We hit that three separate ways in this course: no endpoints (Lesson 4), the control-plane label (Lesson 5), and a route filter (Lesson 6/7).

## Step 2 — The five commands to run first

```bash
# 1. What does Kubernetes think, and what did it complain about?
kubectl get svc <name> -o wide
kubectl describe svc <name> | sed -n '/Events/,$p'

# 2. Was there an address to give out, and how much room is left?
kubectl -n metallb-system get ipaddresspool \
  -o custom-columns=POOL:.metadata.name,AUTO:.spec.autoAssign,USED:.status.assignedIPv4,FREE:.status.availableIPv4

# 3. Did MetalLB accept my CRs at all?
kubectl -n metallb-system get configurationstates -o yaml | grep -E 'name:|reason:|message:'

# 4. Are the BGP sessions up? (the object comes from Lesson 6)
kubectl get caliconodestatus worker-status \
  -o jsonpath='{range .status.bgp.peersV4[*]}{.peerIP}{"  "}{.state}{"  "}{.type}{"\n"}{end}'

# 5. Does the network actually have the prefix?
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast'
docker exec metallb-router ip route show
```

```console
POOL                AUTO    USED   FREE
lab-pool            true    2      49
lab-pool-internal   false   1      13
lab-pool-public     false   1      9
lab-pool-reserved   false   2      8
lab-pool-team-a     false   1      9

    name: controller
      message: ""
      reason: Reconciled

172.19.0.2  Established  NodeMesh
172.19.0.3  Established  NodeMesh
172.19.0.100  Established  GlobalPeer
```

`reason: Reconciled` means MetalLB accepted every CR you gave it — when a CR is wrong, the reason and message are here and nowhere else. Then, and only then, look at the network.

## Step 3 — What you can measure, and what you cannot

The controller serves metrics over **HTTPS with RBAC**. Its pod IP is not routable from your workstation in this lab, so port-forward:

```bash
kubectl -n metallb-system port-forward pod/$(kubectl -n metallb-system get pod \
  -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}') 9120:9120
# in another shell:
TOKEN=$(kubectl -n metallb-system create token metallb-controller --duration=10m)
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:9120/metrics                          # 401
curl -sk -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" https://127.0.0.1:9120/metrics   # 200
```

```console
401
200
```

Grant the documented permission (`get` on the non-resource URL `/metrics`) and a scrape works:

```bash
kubectl create clusterrole metallb-metrics-reader --non-resource-url=/metrics --verb=get
kubectl create clusterrolebinding metallb-metrics-reader \
  --clusterrole=metallb-metrics-reader \
  --serviceaccount=metallb-system:metallb-controller
```

What the controller exposes in v0.16.1 — the complete list:

```console
metallb_allocator_addresses_in_use_total{pool="lab-pool"} 2
metallb_allocator_addresses_in_use_total{pool="lab-pool-reserved"} 2
metallb_allocator_addresses_total{pool="lab-pool"} 51
metallb_allocator_addresses_total{pool="lab-pool-reserved"} 10
metallb_allocator_ipv4_addresses_in_use_total{pool="lab-pool"} 2
metallb_k8s_client_config_loaded_bool 1
metallb_k8s_client_config_stale_bool 0
metallb_k8s_client_update_errors_total 12
metallb_k8s_client_updates_total 106
```

Those two families are the whole surface: **pool capacity** and **client health**. A pool over 90% is a countdown; `config_stale_bool == 1` means the controller is running on a configuration it could not apply.

What is *not* there, and what to do instead:

| You want | Reality in phase 2 |
|---|---|
| "Which Services are announced right now?" | There is no `metallb_speaker_announced` and no `ServiceL2Status`/`ServiceBGPStatus` — those are speaker CRs and metrics, and there is no speaker. Read `BGPConfiguration` plus the router. |
| "Are BGP sessions up?" | `CalicoNodeStatus` (Step 2), or `show bgp summary` on the router. Calico's own Prometheus endpoint is off by default (`spec.prometheusMetricsPort` is unset in the `FelixConfiguration`). |
| "How many allocation failures?" | `AllocationFailed` is an **event**, not a metric. Alert on events, or watch Service status. |

## Step 4 — Four alerts worth having

They are in `alerts.yaml`:

| Alert | Signal | Catches |
|---|---|---|
| `MetalLBPoolExhausted` | `in_use / total > 0.9` per pool | the next Service waits forever for an address |
| `MetalLBConfigStale` | `config_stale_bool == 1` | the controller could not apply your CRs and is running on old config |
| `MetalLBUpdateErrors` | `increase(update_errors_total[15m]) > 0` | API/webhook failures before they become a stale config |
| `MetalLBVIPUnreachable` | a blackbox probe on the VIP | "allocated but not announced" — the failure that looks healthy in `kubectl get svc` |

The fourth one matters most and it is not a MetalLB metric at all: in phase 2, whether a VIP is *on the wire* is Calico's answer, and the only vendor-neutral way to ask is to try it.

## Step 5 — The troubleshooting matrix

| Symptom | First check | Root cause we hit | Fix |
|---|---|---|---|
| `EXTERNAL-IP: <pending>`, **no events at all** | `kubectl -n metallb-system get ipaddresspool` | no pool exists, or none is selectable — nothing to allocate from | create the pool (Lesson 3/7) |
| `AllocationFailed: requested loadBalancer IP(s) … is not compatible with requested address pool` | the pinned address vs the pool it names | asked for an address outside the named pool | pin an address inside it (Lesson 7) |
| `AllocationFailed: pool X not compatible for ip assignment` | `IPAddressPool.spec.serviceAllocation` | pool restricted to another namespace | move the Service, or widen `serviceAllocation` (Lesson 7) |
| `AllocationFailed: no available IPs in pool X` | `status.availableIPv4` on the pool | pool exhausted | add addresses, free some, or split pools per team |
| `apply` rejected: `admission webhook … overlaps with already defined CIDR` | pool ranges as CIDRs, not as intuition | two pools covering the same addresses | make the ranges disjoint |
| Block advertised in the config, **no route on the router** | `BGPFilter` attached to the `BGPPeer`, then its CIDR list | the block was added to `serviceLoadBalancerIPs` but not to the filter — session stays `Established` | add the block to the filter (Lesson 7) |
| One node never advertises | `BGPPeer.spec.nodeSelector` | the peer selects only some nodes | widen the selector, or remove it for a global peer (Lesson 7) |
| Prefix present on the router, client still fails | client's route and cache, router's FIB | the client was never taught the block | add the route / fix the client (Lesson 5/7) |
| Traffic all lands on one node despite ECMP | the router's hash policy | Linux default L3 hashing = one next hop per client pair | set L4/5-tuple hashing (Lesson 6) |
| VIP answers from inside the cluster but not from outside | `show bgp ipv4 unicast` on the router | the block is deliberately unannounced (internal-only) | that is the design; announce the block if it should be public (Lesson 7) |

## Step 6 — A workflow, not a checklist

```
1. kubectl describe svc → events?
     AllocationFailed ─────────────► allocation: pools, ranges, namespaces, exhaustion
     IPAllocated ──────────────────► MetalLB did its job; go to step 2
     nothing at all ───────────────► no pool selected for this Service

2. Is the block advertised, and does the router have it?
     not in serviceLoadBalancerIPs ► add it (want)
     in the config, not on the router ► BGPFilter, or the BGPPeer selects no node
     on the router ────────────────► go to step 3

3. Can the packet get there?
     client route, router FIB and hash policy, Service endpoints
     ──────────────────────────────► network-side problem, not MetalLB
```

## Step 7 — Upgrading safely

The lab has been through several upgrades, each changing the BGP backend. In phase 2 you upgrade **the controller only** — keep that explicit:

```bash
# 1. Read the release notes for the version you are moving to.
helm search repo metallb/metallb --versions | head

# 2. Record the current state, so you can prove what changed.
kubectl -n metallb-system get ipaddresspools -o yaml > /tmp/metallb-pools-backup.yaml
kubectl get svc -A -o wide > /tmp/metallb-svcs-before.txt

# 3. Upgrade, keeping the phase-2 settings explicit.
helm upgrade metallb metallb/metallb -n metallb-system --version 0.16.1 \
  --set speaker.enabled=false --set frrk8s.enabled=false --wait --timeout 6m

# 4. Verify, in order: components, accepted configs, then the network.
kubectl -n metallb-system get pods
kubectl -n metallb-system get configurationstates | grep -v Reconciled
kubectl get svc -A -o wide | grep LoadBalancer
docker exec metallb-router vtysh -c 'show bgp summary'
```

- **An upgrade restarts the controller only.** No speaker means no L2 re-election and no session flap: the addresses are already in `status.loadBalancer.ingress` and Calico's sessions do not move.
- **Always pass your non-default values explicitly** (`--set speaker.enabled=false` above). A `helm upgrade` that silently re-enables the speaker puts two BGP speakers on every node, and only one can hold a session.
- **CRDs are upgraded separately.** If the release notes mention API changes, apply the CRD bundle from the release first.

## Step 8 — What to keep in Git

```bash
kubectl -n metallb-system get ipaddresspools -o yaml
kubectl get bgpconfiguration,bgppeer,bgpfilter -o yaml
kubectl get svc -A -o yaml | grep -B5 'metallb.io/'   # Services that pin or restrict
```

Pools, the `BGPConfiguration` block list, `BGPPeer`s, `BGPFilter`s, and any Service that pins an address or names a pool. There is no hidden state: allocation lives in `status.loadBalancer.ingress`, and advertisement is entirely in those CRs.

> 💡 Two things that are *not* in those CRs and decide whether any of it works: the `BGPPeer`'s `nodeSelector` (which nodes hold a session) and router-side policy (what the ToR accepts). Both live outside MetalLB.

## Expected outcome

| What | State |
|---|---|
| Controller metrics | `:9120` HTTPS, needs RBAC; `401` without a token, `200` with `get` on `/metrics` |
| Metric surface | `metallb_allocator_*` (capacity) and `metallb_k8s_client_*` (client health) — that is all |
| Announcement signals | `CalicoNodeStatus`, the router's RIB/FIB; no MetalLB speaker CRs exist |
| Allocation failures | visible as `AllocationFailed` events on the Service |
| Troubleshooting matrix | 10 real failure modes with the command that identifies each |

## Production note

- **Instrument the VIP, not the CR.** The failure that hurts is a Service that looks healthy in `kubectl get svc` and does not answer. A probe on every announced address catches it in both phases.
- **Watch pool capacity as a first-class resource** — like disk, or IPs in a DHCP scope. Exhaustion is silent until a deployment cannot get an address, and the fix is easy, so alert early.
- **Watch `config_stale_bool`.** It is the difference between "my CR was accepted" and "my CR was ignored", and everything downstream of it is wrong.
- **Own the boundary with your network team.** Which blocks you announce, which filter lets them out, which nodes peer, and what their route policy accepts — write it down, because half of these knobs are outside your cluster.
- **Keep the five commands from Step 2 in the runbook**, ordered. Nearly every incident ends in one of the matrix rows.

## Next
Part II starts here: [Lesson 9 — Tour of the Go codebase](../lesson-09-go-tour/README.md).

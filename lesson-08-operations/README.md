# Lesson 8 — Operations and troubleshooting

## Glossary
| Term | What it means |
|------|---------------|
| **allocation vs announcement** | The two independent halves of MetalLB: an address being *assigned* to a Service, and that address being *made reachable* on the network |
| **`AllocationFailed`** | The event reason the controller uses when it cannot give a Service an address |
| **`ServiceL2Status` / `ServiceBGPStatus`** | The CRs that record what is *currently announced*, per node |
| **`ConfigurationState`** | The CR where MetalLB reports whether your CRs were accepted by the controller/speakers |
| **`metallb_speaker_announced`** | The speaker metric that says "this node is announcing this VIP right now" |
| **`frrk8s_bgp_session_up`** | The per-peer session gauge exposed by the frr-k8s backend |
| **implicit deny** | Route-maps (and firewall rules) end with "and drop everything else" — the cause of a whole class of "MetalLB looks fine" outages |

Everything in this lesson comes from failures we actually hit while building the course. That is the point: almost all MetalLB incidents are **allocation** problems, **announcement** problems, or **network-side** problems, and each leaves a different fingerprint.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- none — this lesson is diagnostics, metrics and procedures against the running lab.

> 🔀 **Read this if you are on the phase-2 (Calico) cluster.** The lesson was written against phase 1, where MetalLB's **speaker** announced. In phase 2 there is no speaker and no frr-k8s, so the *announcement* half of every table below lives in Calico instead:
>
> | Phase 1 artifact | Phase 2 replacement |
> |---|---|
> | `metallb-speaker` metrics (`metallb_speaker_announced`) | gone — scrape `calico-node`, or check the router's prefix count |
> | `frrk8s_bgp_session_up`, `frrk8s_bgp_announced_prefixes_total` (port 9141) | gone — `CalicoNodeStatus` CR, `calicoctl node status`, router RIB |
> | `ServiceL2Status` / `ServiceBGPStatus` / `BGPSessionState` CRs | gone — `BGPConfiguration.spec.serviceLoadBalancerIPs` + router state |
> | `metallb_allocator_*` (port 9120) | **unchanged** — the controller still owns allocation |
> | The `MetalLBServiceNotAnnounced` alert | must read Calico's state, otherwise it fires on every Service, forever |
>
> The *shape* of the workflow is identical — allocation problems still surface as `AllocationFailed` events on the Service, announcement problems still surface as "the network has no route" — only the tool you inspect changes.

## Step 1 — The one question that halves your debugging time

```
Is this a problem of ALLOCATION, or of ANNOUNCEMENT?
```

| Ask | Allocation side (controller) | Announcement side (speaker) |
|---|---|---|
| Does the Service have an address? | `kubectl get svc <name>` → `EXTERNAL-IP` | irrelevant |
| What proves it happened? | `IPAllocated` event, `metallb_allocator_addresses_in_use_total` | `nodeAssigned` event, `ServiceL2Status`/`ServiceBGPStatus`, `metallb_speaker_announced` |
| Who logs it? | `metallb-controller` | `metallb-speaker` (+ frr-k8s pods in BGP mode) |
| Typical causes | no pool, pool not advertised, pool exhausted, namespace/pool mismatch, pinned IP not owned | no healthy endpoints, node excluded by label, `serviceSelectors` mismatch, node down, router filtering the route |

A Service with a perfect `EXTERNAL-IP` can be completely unreachable. We hit that three separate ways in this course (Lesson 4: no endpoints; Lesson 5: control-plane label; Lesson 7: route-map filter).

## Step 2 — The five commands to run first

```bash
# 1. What does Kubernetes think?
kubectl get svc <name> -o wide
kubectl describe svc <name> | sed -n '/Events/,$p'

# 2. What does MetalLB think it is announcing, and from where?
kubectl -n metallb-system get servicel2statuses,servicebgpstatuses -o wide

# 3. What did MetalLB say while making the decision?
kubectl -n metallb-system logs ds/metallb-speaker \
  | grep -E 'serviceAnnounced|serviceWithdrawn|skipping should announce'

# 4. Did MetalLB accept my CRs at all?
kubectl -n metallb-system get configurationstates -o yaml \
  | grep -E 'name:|reason:|message:'

# 5. Was an address even available?
kubectl -n metallb-system get ipaddresspool \
  -o custom-columns=POOL:.metadata.name,AUTO:.spec.autoAssign,USED:.status.assignedIPv4,FREE:.status.availableIPv4
```

Then, and only then, look at the network — because that is where the expensive mistakes are.

## Step 3 — Metrics that actually predict outages

MetalLB v0.16 serves metrics over **HTTPS with RBAC**. A scrape without the right permission gets `HTTP 403`:

```console
$ curl -sk -H "Authorization: Bearer $TOKEN" https://$SPEAKER_IP:9120/metrics
HTTP 403
```

Grant the documented permission (`get` on the non-resource URL `/metrics`) and it returns `HTTP 200`:

```bash
kubectl create clusterrole metallb-metrics-reader \
  --non-resource-url=/metrics --verb=get
kubectl create clusterrolebinding metallb-metrics-reader \
  --clusterrole=metallb-metrics-reader \
  --serviceaccount=metallb-system:metallb-speaker
```

| Endpoint | Port | What it gives you |
|---|---|---|
| `metallb-controller` | 9120 (HTTPS) | allocator: addresses in use / total, per pool |
| `metallb-speaker` | 9120 (HTTPS) | `metallb_speaker_announced{ip,node,protocol,service}` |
| `frr-k8s` (BGP backend) | 9141 (HTTPS, hostPort) | `frrk8s_bgp_session_up`, `frrk8s_bgp_announced_prefixes_total`, update counters |

Real values from the running lab:

```console
# controller: how full is each pool?
metallb_allocator_addresses_in_use_total{pool="lab-pool-public"} 2
metallb_allocator_addresses_in_use_total{pool="lab-pool-reserved"} 2
metallb_allocator_addresses_in_use_total{pool="lab-pool-team-a"} 1
metallb_allocator_addresses_total{pool="lab-pool"} 51
metallb_allocator_addresses_total{pool="lab-pool-tiny"} 2

# speaker: this node is announcing these VIPs right now
metallb_speaker_announced{ip="172.19.254.15",node="metallb-lab-control-plane",protocol="bgp",service="default/whoami-pinned"} 1
metallb_speaker_announced{ip="172.19.255.200",node="metallb-lab-control-plane",protocol="bgp",service="default/whoami"} 1

# frr-k8s: session and prefix state, per peer
frrk8s_bgp_session_up{peer="172.19.0.100",vrf="default"} 1
frrk8s_bgp_announced_prefixes_total{peer="172.19.0.100",vrf="default"} 9
```

`metallb_speaker_announced` is the single most valuable series in MetalLB: it is the only metric that distinguishes "allocated" from "actually on the wire", and it is per node, per Service, per protocol.

Alert on these five things:

```yaml
groups:
  - name: metallb
    rules:
      # 1. A pool is (nearly) exhausted — the next Service will be <pending> forever.
      - alert: MetalLBPoolExhausted
        expr: >
          metallb_allocator_addresses_in_use_total
            / on(pool) metallb_allocator_addresses_total > 0.9
        for: 10m

      # 2. A Service has an address that nobody announces — "allocated but black-holed".
      - alert: MetalLBServiceNotAnnounced
        expr: >
          count by (service) (kube_service_spec_type{type="LoadBalancer"}) unless
          count by (service) (metallb_speaker_announced) > 0
        for: 5m

      # 3. BGP session down (frr-k8s backend).
      - alert: MetalLBBGPSessionDown
        expr: frrk8s_bgp_session_up == 0
        for: 2m

      # 4. Session up but advertising nothing.
      - alert: MetalLBBGPNoPrefixes
        expr: frrk8s_bgp_session_up == 1 and frrk8s_bgp_announced_prefixes_total == 0
        for: 10m

      # 5. Allocation failures happening at all.
      - alert: MetalLBAllocationFailures
        expr: increase(metallb_allocator_allocations_total{result="failed"}[15m]) > 0
```

(The last series name differs by version — check `curl -k https://<controller>:9120/metrics | grep allocator`, and prefer the Kubernetes events route if you have an event exporter: `reason=AllocationFailed` is the authoritative signal.)

## Step 4 — The troubleshooting matrix (all of these happened in this course)

| Symptom | First check | Root cause we hit | Fix |
|---|---|---|---|
| `EXTERNAL-IP: <pending>`, **no events at all** | `kubectl -n metallb-system get ipaddresspool` | MetalLB installed but no pool exists — nothing to allocate from | create the pool **and** an advertisement (Lesson 2/3) |
| `<pending>` with `AllocationFailed: requested loadBalancer IP(s) … is not compatible with requested address pool` | the pinned address vs the pool it names | asked for an address outside the pool | pin an address inside the pool, or add the pool (Lesson 7) |
| `AllocationFailed: pool X not compatible for ip assignment` | `IPAddressPool.spec.serviceAllocation` | pool restricted to another namespace | move the Service, or widen `serviceAllocation` (Lesson 7) |
| `AllocationFailed: no available IPs in pool X` | `status.availableIPv4` on the pool | **pool exhausted** (2-address pool, 3 Services) | add addresses / free some / split pools per team (Lesson 8) |
| `apply` rejected: `admission webhook … overlaps with already defined CIDR` | pool ranges as CIDRs, not as intuition | two pools covering the same addresses | make ranges disjoint (Lesson 7) |
| Address assigned but **nothing answers** | `get servicel2statuses,servicebgpstatuses` | no healthy endpoints → announcement withdrawn (`reason: noEndpoints`) | fix the pods (Lesson 4/6) |
| One node never announces | speaker log `skipping should announce …` | node labelled `exclude-from-external-load-balancers` (empty value counts) | `speaker.ignoreExcludeLB=true`, or accept it (Lesson 5) |
| Address allocated, advertised by MetalLB, **router has no route** | `vtysh -c 'show bgp ipv4 unicast <ip>'` on the router, then route-map counters | inbound route-map with an implicit deny filtered the prefix | make the policy additive (`permit 20`), or tag the pool with the expected community (Lesson 7) |
| VIP reachable from one client only / "failover is slow" | client's neighbour cache, `ip neigh` | stale `REACHABLE` ARP entry after leadership moved | keep the old leader up during planned moves; fix buggy clients (Lesson 4) |
| Traffic all lands on one node despite ECMP | router's hash policy | Linux default L3 hashing = one next-hop per client pair | set L4/5-tuple hashing (Lesson 5) |
| Load "not balanced" across pods with BGP + `Local` | pod-to-node distribution | each node counts as one unit of load | use anti-affinity to spread pods evenly (Lesson 6 concepts) |
| L2 mode: two nodes answer ARP for one VIP | `memberlist` health, `servicel2statuses` | brain split — speakers disagree about who is alive | check memberlist networking (7946 TCP/UDP), or the disabled-memberlist edge case |
| L2 mode on IPVS clusters: node answers for the VIP itself | `kube-proxy` mode + `strictARP` | IPVS kube-proxy needs `strictARP: true` | set it in the kube-proxy config |
| Nothing announced anywhere; no pool errors | arp: `metallb-excludel2` ConfigMap; bgp: `nodeSelectors` on the advertisement | the advertisement selects no node/interface | fix selectors, or the interface patterns |

## Step 5 — A workflow, not a checklist

```
1. kubectl describe svc → events?
     AllocationFailed ─────────────► allocation problem: pools, ranges, namespaces, exhaustion
     IPAllocated + nodeAssigned ───► MetalLB did its job; go to step 3
     nothing at all ───────────────► no pool selected / no advertisement references it

2. Servicel2status / ServiceBGPStatus rows?
     missing ──────────────────────► announcement problem: endpoints, node labels, serviceSelectors
     present ──────────────────────► MetalLB believes it is announcing; go to step 3

3. Can the packet even get there?
     ARP mode: client's ip neigh entry + tcpdump arp
     BGP mode: router's show bgp ipv4 unicast + show route-map counters
     ──────────────────────────────► network-side problem: hash policy, filters, client caches, routes
```

## Step 6 — Upgrading MetalLB safely

The lab has been upgraded three times in this course (`REVISION: 1 → 2 → 3`), each time changing the BGP backend. The procedure that keeps it boring:

```bash
# 1. Read the release notes for the version you are moving to.
#    (v0.16 changed the DEFAULT BGP backend; v0.14 removed the legacy AddressPool API.)
helm search repo metallb/metallb --versions | head

# 2. Record the current state, so you can prove what changed.
kubectl -n metallb-system get ipaddresspools,bgppeers,bgpadvertisements,l2advertisements -o yaml > /tmp/metallb-crs-backup.yaml
kubectl -n metallb-system get svc -A -o wide > /tmp/metallb-svcs-before.txt

# 3. Upgrade, keeping the settings you depend on explicitly.
helm upgrade metallb metallb/metallb -n metallb-system \
  --version 0.16.1 --set frrk8s.enabled=true --set speaker.ignoreExcludeLB=true --wait --timeout 6m

# 4. Verify the three layers, in order.
kubectl -n metallb-system get pods                                    # components healthy
kubectl -n metallb-system get configurationstates | grep -v Reconciled # accepted configs
kubectl -n metallb-system get servicel2statuses,servicebgpstatuses     # still announcing
docker exec metallb-router vtysh -c 'show bgp summary'                 # sessions Established
```

Notes that matter in production:

- **Upgrades restart speakers.** In L2 mode that means a leader re-election (and gratuitous ARP); in BGP mode it means session flaps. Do it in a window, and roll one node at a time if your availability budget is tight.
- **Always pass your non-default values explicitly** (`--set speaker.ignoreExcludeLB=true` above). A `helm upgrade` that silently drops a setting is a self-inflicted outage waiting for the next restart.
- **CRDs are upgraded separately.** `helm upgrade` does not always update CRDs; if the release notes mention API changes, apply the CRD bundle from the release first.
- **Allocations survive controller restarts** — the address is in `status.loadBalancer.ingress`, and MetalLB re-reads it. A restart does not shuffle your VIPs.

## Step 7 — What to keep in Git

The cluster's entire MetalLB configuration is CRs, which makes GitOps natural:

```bash
kubectl -n metallb-system get ipaddresspools,bgppeers,bgpadvertisements,l2advertisements,communities -o yaml
```

Keep in Git: pools, advertisements, peers, communities, the Helm values file, and any Service that pins an address. Keep out of Git: nothing else — there is no hidden state to lose.

> 💡 Two things that are *not* in the CRs and bite people: the **node label** `exclude-from-external-load-balancers` (it decides who can announce) and **router-side policy** (it decides what is accepted). Both live outside this cluster and both have caused an outage in this course.

## Expected outcome

| What | State |
|---|---|
| Metrics | controller 9120, speaker 9120, frr-k8s 9141 — all HTTPS, all needing `/metrics` RBAC |
| `metallb_speaker_announced` | one series per announced VIP per node |
| `frrk8s_bgp_session_up` | `1` per peer |
| Pool exhaustion | reproduced: `no available IPs in pool lab-pool-tiny`, `availableIPv4: 0` |
| Troubleshooting matrix | 13 real failure modes with the commands that identify each |

## Production note

- **Instrument announcement, not allocation.** The failure that hurts is a Service that *looks* healthy in `kubectl get svc` and is unreachable in reality. `metallb_speaker_announced` (plus `ServiceBGPStatus`/`ServiceL2Status`) is what catches it.
- **Watch pool capacity as a first-class resource** — like disk or IPs in a DHCP scope. Exhaustion is silent until a deployment cannot get an address, and the fix (adding a pool) is easy, so alert early.
- **Own the boundary with your network team.** Communities for what you advertise, route-map/prefix-list acceptance on their side, and a documented agreement about which ranges are yours and which nodes may peer.
- **Test failover on purpose, in daylight.** This course did it with `docker stop`; in production it is `kubectl drain`, a node reboot, or a session reset. Know your real numbers instead of trusting the docs' "a few seconds".
- **Keep a runbook with the five commands from Step 2**, ordered. Nearly every incident ends in one of the matrix rows.

## Next
Part II starts here: [Lesson 9 — Tour of the Go codebase](../lesson-09-go-tour/README.md).

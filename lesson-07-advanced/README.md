# Lesson 7 — Advanced addressing and advertisement control

## Glossary
| Term | What it means |
|------|---------------|
| **`autoAssign: false`** | A pool that never hands out addresses automatically — Services must ask for it explicitly |
| **pinning** | Requesting one exact address (`metallb.io/loadBalancerIPs`) |
| **sharing key** | The `metallb.io/allow-shared-ip` annotation value that lets two Services colocate on one address |
| **`serviceSelectors`** | On an advertisement: only matching Services get announced (v0.16+) |
| **`serviceAllocation`** | On a pool: which namespaces/Services may allocate from it |
| **`priority`** | Tie-breaker when several pools could serve the same Service |
| **`ignoreExcludeLB`** | Helm value that makes speakers ignore the `exclude-from-external-load-balancers` node label |
| **`aggregationLength`** | BGP: roll many `/32`s up into one larger prefix |
| **internal-only VIP** | An address allocated to a Service but deliberately never advertised |

Lesson 3 gave every Service an address, first-come-first-served. Real clusters need *control*: which addresses exist, who may take them, what the network is allowed to see, and how to keep some Services private.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `reserved-pool.yaml` — an `autoAssign: false` pool plus its advertisement.
- `pinned-and-shared.yaml` — a pinned Service and two Services sharing one VIP.
- `service-selectors.yaml` — advertisement gated by a Service label.
- `pool-access.yaml` — a pool restricted to one namespace (+ a Service that tries to steal from it).

> 🔀 **Phase-2 adaptation.** This lesson was written on the phase-1 cluster, where MetalLB's speaker announced. On the Calico cluster (Lessons 5–6) the split changes, and it is worth knowing exactly how:
>
> | Recipe | In phase 2 |
> |---|---|
> | 1, 2, 3, 5 (pools, pinning, sharing, namespace rules) | **unchanged** — these are all *allocation*, which is still MetalLB's controller |
> | The `BGPAdvertisement` companion in the YAML files | replace with adding the pool's addresses to `BGPConfiguration.spec.serviceLoadBalancerIPs` (Lesson 6) |
> | 4 (advertisement `serviceSelectors`) | **does not exist in Calico.** The equivalent is negative: an address whose `/32` is *absent* from `serviceLoadBalancerIPs` is invisible to the network — see the rewritten Recipe 4 |
> | 6 (`speaker.ignoreExcludeLB`) | no speaker to configure; Calico honours the same node label — see the rewritten Recipe 6 |
>
> Recipes 4 and 6 below have been rewritten for phase 2; the YAML files for them stay as phase-1 artifacts for reference.

## Recipe 1 — A pool nobody can take from by accident

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool-reserved
  namespace: metallb-system
spec:
  addresses:
    - 172.19.254.10-172.19.254.19
  autoAssign: false
```

With `autoAssign: false`, a random `type: LoadBalancer` Service can never consume these addresses — it keeps getting one from `lab-pool`. Proof:

```bash
kubectl create svc loadbalancer whoami-random --tcp=80:80 --dry-run=client -o yaml | kubectl apply -f -
kubectl patch svc whoami-random -p '{"spec":{"selector":{"app":"whoami"}}}'
kubectl get svc whoami-random -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
kubectl -n metallb-system get ipaddresspool -o custom-columns=POOL:.metadata.name,AUTOASSIGN:.spec.autoAssign,ASSIGNED:.status.assignedIPv4,AVAILABLE:.status.availableIPv4
```

```console
whoami-random   172.19.255.204          # from lab-pool, as intended
POOL                AUTOASSIGN   ASSIGNED   AVAILABLE
lab-pool            true         4          47
lab-pool-reserved   false        2          8
```

> ⚠️ **A pool also has to be referenced by an advertisement to be usable at all.** A pool with no `L2Advertisement`/`BGPAdvertisement` pointing at it will not serve allocations — a genuinely confusing state if you forget the second half of the pair.

## Recipe 2 — Pin an exact address (and what happens when you can't)

```yaml
metadata:
  annotations:
    metallb.io/address-pool: lab-pool-reserved
    metallb.io/loadBalancerIPs: 172.19.254.15
```

```console
NAME            EXTERNAL-IP
whoami-pinned   172.19.254.15
```

> 💡 Prefer the annotation over `spec.loadBalancerIP`: the field is deprecated in the Kubernetes API and cannot express dual-stack. The annotation accepts a comma-separated list (`metallb.io/loadBalancerIPs: 172.19.254.15,2001:db8::15`).

Now the two failures you will actually hit.

**Asking for an address that is not in a pool you own** — MetalLB does not improvise, it reports:

```console
Warning  AllocationFailed  service/whoami-pinned
  Failed to allocate IP for "default/whoami-pinned": requested loadBalancer IP(s) ["172.19.255.235"]
  is not compatible with requested address pool lab-pool-reserved
```

**Overlapping pools are rejected at admission time** (our first attempt used `172.19.255.230-239`, inside `lab-pool`'s `172.19.255.200-250`):

```console
Error from server (Forbidden): error when creating "reserved-pool.yaml":
  admission webhook "ipaddresspoolvalidationwebhook.metallb.io" denied the request:
  CIDR "172.19.255.230/31" in pool "lab-pool-reserved" overlaps with already defined CIDR "172.19.255.224/28"
```

Two different layers, two different reports: the **webhook** validates your *intent* at `apply` time; the **controller** reports per-Service allocation failures as events. When a Service stays without an address, check `kubectl describe svc` first — the reason is almost always right there.

## Recipe 3 — One address, two Services

```yaml
metadata:
  annotations:
    metallb.io/address-pool: lab-pool-reserved
    metallb.io/loadBalancerIPs: 172.19.254.16
    metallb.io/allow-shared-ip: "lab-shared-1"
```

Two Services (`whoami-shared-a` on port 80, `whoami-shared-b` on 8080) with the same sharing key and the same pinned address:

```console
NAME              EXTERNAL-IP
whoami-shared-a   172.19.254.16
whoami-shared-b   172.19.254.16
```

And one address really does serve both. The client from Lesson 5 only has a route for `172.19.255.0/24`, so teach it this lesson's range first:

```bash
docker exec metallb-client ip route add 172.19.254.0/24 via 172.19.0.100
docker exec metallb-client curl -s http://172.19.254.16:80   | head -2
docker exec metallb-client curl -s http://172.19.254.16:8080 | head -2
```

```console
# port 80   → whoami-shared-a
Hostname: whoami-8644bfc655-5cz9s
# port 8080 → whoami-shared-b
Hostname: whoami-8644bfc655-krrlf
```

The conditions MetalLB enforces are strict, and each one exists for a reason:

| Condition | Why it is required |
|---|---|
| Same sharing key | Sharing must be explicit; two Services never silently collide |
| Different ports | Two Services cannot claim `tcp/80` on the same address |
| Both `Cluster` policy, or **exactly** the same pod selector | With `Local`, different Services would disagree about which nodes are eligible |
| Pinning makes it deterministic | Otherwise MetalLB *may* colocate — it does not have to |

On the wire this is also visible: the router holds **one** prefix for that address, because the prefix is per address, not per Service (`9 routes` at this point in the lab, for 10 Services).

## Recipe 4 — Decide what the network is allowed to see

Allocating an address and *advertising* it are separate decisions — Lesson 4 showed that by accident (no endpoints), this recipe does it on purpose.

```yaml
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: lab-bgp-public
spec:
  ipAddressPools:
    - lab-pool-public
  communities:
    - lab-public
  serviceSelectors:
    - matchLabels:
        expose: public
```

Two Services, same pool, one label of difference:

```console
NAME             EXTERNAL-IP      LABELS
whoami-public    172.19.254.100   map[expose:public]
whoami-private   172.19.254.101   <none>
```

```console
$ docker exec metallb-router vtysh -c 'show bgp ipv4 unicast' | grep 172.19.254.10
 *>  172.19.254.100/32                      # only the labelled one exists for the network

$ kubectl -n metallb-system get servicebgpstatuses | grep -E 'public|private'
whoami-public     metallb-lab-worker
whoami-public     metallb-lab-worker2      # no rows for whoami-private
```

`whoami-private` has a working address and is reachable **inside** the cluster — and it is invisible to every router. That is a better internal-only VIP than a firewall rule, because there is nothing to leak: the route is never born.

> 💡 **BGP gotcha:** because the selector is evaluated per Service, "label it to publish" becomes a deployment-time decision, and `ServiceBGPStatus` is your audit trail of what is currently published. The same `serviceSelectors` field exists on `L2Advertisement` for ARP-based clusters.

**🔀 Phase 2 (Calico): the same outcome, inverted.** Calico has no per-Service selector, so instead of *positively* selecting what to publish, you publish a list of addresses and everything else stays invisible:

```bash
# only whoami-public's /32 is announced; whoami-private is deliberately absent
kubectl patch bgpconfiguration default --type=merge -p \
  '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "172.19.254.100/32"}]}}'
```

```console
# expected — the router knows one of the two addresses
172.19.254.100/32   172.19.0.2      0 64512 i
172.19.254.101      (absent)
```

The trade-off shifts from "which Services?" to "which addresses, maintained where?":

| | Phase 1 (MetalLB `serviceSelectors`) | Phase 2 (Calico `serviceLoadBalancerIPs`) |
|---|---|---|
| The gate | a Service label | presence of the address in a list |
| Changes at deploy time? | yes — label the Service | no — someone must edit `/32` list in `BGPConfiguration` |
| Audit trail | `ServiceBGPStatus` | the `BGPConfiguration` object itself |

That last row is the real cost: with Calico the "what is published" answer lives in one cluster-wide object, not next to each Service. Keep it in Git (Lesson 8).

## Recipe 5 — A pool only one namespace may use

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool-team-a
spec:
  addresses:
    - 172.19.254.200-172.19.254.209
  autoAssign: false
  serviceAllocation:
    namespaces:
      - team-a
```

A Service in `team-a` gets `172.19.254.200`. An identical Service in `default` asking for the same pool:

```console
Warning  AllocationFailed  service/whoami-thief
  Failed to allocate IP for "default/whoami-thief": pool lab-pool-team-a not compatible for ip assignment
```

`serviceAllocation` also accepts `namespaceSelectors` (label-based, so teams can own their own namespace labels), `serviceSelectors`, and `priority` for resolving competition between pools.

> 🏭 **Production pattern:** one pool per tenant, `autoAssign: false`, `serviceAllocation.namespaces` set, and communities per pool so each tenant's VIPs are advertised with different policy. Your network team then reasons about tenants with `show bgp` instead of reading Kubernetes objects.

## Recipe 6 — Let the control-plane advertise

Lesson 5's mystery, solved deliberately:

```bash
helm upgrade metallb metallb/metallb -n metallb-system --version 0.16.1 \
  --set frrk8s.enabled=true --set speaker.ignoreExcludeLB=true --wait
```

```console
$ docker exec metallb-router vtysh -c 'show bgp summary' | sed -n '/Neighbor/,/Total/p'
172.19.0.2      4      64512        63        51       77    0    0 00:05:49            9
172.19.0.3      4      64512        64        53       77    0    0 00:05:35            9
172.19.0.4      4      64512        37        52       77    0    0 00:05:47            9      # was 0

$ docker exec metallb-router vtysh -c 'show bgp ipv4 unicast 172.19.255.200' | grep -E 'from 172|Paths'
Paths: (3 available, best #1, table default)
    172.19.0.2 from 172.19.0.2 (172.19.0.2)
    172.19.0.3 from 172.19.0.3 (172.19.0.3)
    172.19.0.4 from 172.19.0.4 (172.19.0.4)
```

More advertisers = more ECMP spread, at the cost of running a speaker on the control-plane (and of depending on it for traffic). A homelab with three beefy control-planes usually wants this; a production cluster with tainted, small control-planes usually does not.

**🔀 Phase 2 (Calico): there is no speaker to configure.** The same node label decides whether a node advertises — but it is applied to *Calico's* view, not MetalLB's:

```bash
kubectl label node metallb-calico-control-plane \
  node.kubernetes.io/exclude-from-external-load-balancers=true
```

Calico's docs list exactly this as the way to keep control-plane nodes out of service advertisement, so every conclusion from Lesson 5 still holds — including the surprise that mattered most: **the label exists with an empty value**, and existence is what counts. The difference is that in phase 2 you cannot override it with a Helm flag, because there is no MetalLB speaker whose opinion could differ. Want the control-plane to advertise? Remove the label.

## The gotcha this lesson created for itself

While building Recipe 4 we hit a failure that is worth more than the recipe: after Lesson 6 we left an inbound route-map on the router:

```console
route-map LAB-IN permit 10
 match community LAB-PUBLIC
 set local-preference 500
```

Route-maps have an **implicit deny** at the end. So every prefix *without* the `64512:100` community — namely the entire new `lab-pool-reserved` pool — was silently dropped by the router, even though MetalLB reported it as announced:

```console
$ kubectl -n metallb-system get servicebgpstatuses | grep pinned
whoami-pinned  metallb-lab-worker   [lab-router]      # MetalLB says: announced
whoami-pinned  metallb-lab-worker2  [lab-router]

$ docker exec metallb-router vtysh -c 'show bgp ipv4 unicast 172.19.254.15'
% Network not in table                               # the router says: never heard of it
```

The fix is one line — make the policy additive:

```bash
docker exec metallb-router vtysh -c 'configure terminal' -c 'route-map LAB-IN permit 20' -c 'end'
```

…after which the router learned all 6 prefixes (`Displayed 6 routes and 12 total paths`).

**The lesson:** when a VIP works from inside the cluster but the network cannot reach it, the fault may be **on the network side, not in MetalLB**. "MetalLB says it is advertising" and "the router has the route" are two different facts, and you have to check both. We put this in the troubleshooting matrix in Lesson 8.

## Cheat sheet — where each behaviour is configured

| I want to… | Use |
|---|---|
| Keep addresses out of the automatic pool | `IPAddressPool.spec.autoAssign: false` |
| Give a Service a specific address | annotation `metallb.io/loadBalancerIPs` |
| Choose the pool per Service | annotation `metallb.io/address-pool` |
| Put two Services on one address | `metallb.io/allow-shared-ip` (+ pin the address) |
| Limit a pool to namespaces/teams | `IPAddressPool.spec.serviceAllocation` |
| Advertise only labelled Services | `BGPAdvertisement`/`L2Advertisement` `.spec.serviceSelectors` |
| Advertise only from some nodes / interfaces | `.spec.nodeSelectors`, `L2Advertisement.spec.interfaces` |
| Roll `/32`s up into one prefix | `BGPAdvertisement.spec.aggregationLength` |
| Keep a VIP internal only | Allocate from a pool with **no** advertisement covering it, or gate it with `serviceSelectors` |
| Make control-plane nodes advertise | `speaker.ignoreExcludeLB=true` |
| Dual-stack VIPs | give ≥1 pool both v4 and v6 addresses; use the `loadBalancerIPs` annotation; BGP dual-stack requires an FRR-based backend |

## Expected outcome

| Recipe | Result |
|---|---|
| 1. `autoAssign: false` | new Service got `172.19.255.204` from `lab-pool`; reserved pool untouched |
| 2. Pinning | `whoami-pinned` = `172.19.254.15`; out-of-pool request → `AllocationFailed`; overlapping pool → webhook denial |
| 3. Sharing | both Services on `172.19.254.16`, ports 80 and 8080 both serve |
| 4. `serviceSelectors` | `172.19.254.100` advertised, `172.19.254.101` allocated but invisible |
| 5. Pool access | `team-a` got `172.19.254.200`; `default` got an `AllocationFailed` event |
| 6. `ignoreExcludeLB` | control-plane advertises 9 prefixes; VIP went from 2 to 3 paths |
| Gotcha | route-map implicit deny blackholed a pool until a `permit 20` was added |

## Cleanup for this lesson

```bash
kubectl delete -f lesson-07-advanced/
kubectl delete namespace team-a
```

## Production note

- **Treat pool design as network design.** Overlaps are rejected, but *adjacency* problems are not: a pool inside your DHCP range, or inside a subnet the router will not route, is a real outage you can only prevent on paper.
- **Use `autoAssign: false` + explicit pools for anything important.** Automatic allocation is convenient for labs and dangerous when a stray Service can consume your last public address.
- **Prefer `serviceSelectors` over firewall rules for internal VIPs.** No route, nothing to leak.
- **`aggregationLength` is the scaling lever for BGP.** Thousands of `/32`s can exhaust a router's FIB; rolling them into a handful of aggregates keeps the fabric small — but understand the trade-off: an aggregate is announced as long as *any* address in it is live.
- **Document the annotations you rely on.** They are invisible in `kubectl get svc` output unless you ask for them, which is exactly why this lesson ends with a cheat sheet instead of a wall of YAML.

## Next
Continue to [Lesson 8 — Operations and troubleshooting](../lesson-08-operations/README.md).

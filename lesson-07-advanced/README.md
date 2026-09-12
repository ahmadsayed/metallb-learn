# Lesson 7 — Advanced addressing and advertisement control

## Glossary
| Term | What it means |
|------|---------------|
| **`autoAssign: false`** | A pool that never hands out addresses automatically — Services must ask for it explicitly |
| **pinning** | Requesting one exact address (`metallb.io/loadBalancerIPs`) |
| **sharing key** | The `metallb.io/allow-shared-ip` annotation value that lets two Services colocate on one address |
| **`serviceAllocation`** | On a pool: which namespaces/Services may allocate from it |
| **`priority`** | Tie-breaker when several pools could serve the same Service |
| **advertised block** | A CIDR listed in `BGPConfiguration.spec.serviceLoadBalancerIPs` — Calico's unit of advertisement |
| **`BGPFilter`** | Per-peer route policy: which of those blocks may actually cross the session |
| **internal-only VIP** | An address allocated to a Service but deliberately never advertised |

Lesson 3 gave every Service an address, first-come-first-served. This lesson adds control on both halves: which addresses exist and who may take them (MetalLB), and which addresses the network is allowed to see (Calico).

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `reserved-pool.yaml` — an `autoAssign: false` pool (recipe 1).
- `pinned-and-shared.yaml` — a pinned Service, a second app, and two Services sharing one VIP (recipes 2–3).
- `public-and-internal-pools.yaml` — two pools, one inside an announced block and one not (recipe 4).
- `pool-access.yaml` — a pool restricted to one namespace, plus a Service that tries to steal from it (recipe 5).

## Recipe 1 — A pool nobody can take from by accident

```bash
kubectl apply -f reserved-pool.yaml
kubectl create svc loadbalancer whoami-random --tcp=80:80 --dry-run=client -o yaml | kubectl apply -f -
kubectl patch svc whoami-random -p '{"spec":{"selector":{"app":"whoami"}}}'
kubectl get svc whoami-random -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
kubectl -n metallb-system get ipaddresspool -o custom-columns=POOL:.metadata.name,AUTOASSIGN:.spec.autoAssign,ASSIGNED:.status.assignedIPv4,AVAILABLE:.status.availableIPv4
```

```console
ipaddresspool.metallb.io/lab-pool-reserved created
service/whoami-random created
service/whoami-random patched
NAME            EXTERNAL-IP
whoami-random   172.19.255.201
POOL                AUTOASSIGN   ASSIGNED   AVAILABLE
lab-pool            true         2          49
lab-pool-reserved   false        0          10
```

`whoami-random` asked for nothing, so it landed in `lab-pool` like every other Service. The reserved pool stayed at **0 assigned, 10 available** — a random `type: LoadBalancer` can never consume it. Only an explicit request (recipes 2 and 3) can.

## Recipe 2 — Pin an exact address

```bash
kubectl apply -f pinned-and-shared.yaml
kubectl get svc whoami-pinned -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
```

```console
service/whoami-pinned created
deployment.apps/whoami-b created
NAME              EXTERNAL-IP
whoami-pinned     172.19.254.15
```

> 💡 Prefer the annotation over `spec.loadBalancerIP`: the field is deprecated in the Kubernetes API and cannot express dual-stack.

Now ask for an address the pool does not own. MetalLB does not improvise — it reports:

```bash
kubectl patch svc whoami-pinned -p '{"metadata":{"annotations":{"metallb.io/loadBalancerIPs":"172.19.255.235"}}}'
kubectl describe svc whoami-pinned | sed -n '/Events/,$p'
```

```console
service/whoami-pinned patched
Events:
  Type     Reason            Age              From                Message
  ----     ------            ----             ----                -------
  Normal   IPAllocated       8s               metallb-controller  Assigned IP ["172.19.254.15"]
  Warning  AllocationFailed  4s (x3 over 4s)  metallb-controller  Failed to allocate IP for "default/whoami-pinned": requested loadBalancer IP(s) ["172.19.255.235"] is not compatible with requested address pool lab-pool-reserved
```

`172.19.255.235` is a perfectly good address from `lab-pool` — it is simply not in the pool this Service names. The Service drops back to `<pending>`, and the fix is one annotation away:

```bash
kubectl patch svc whoami-pinned -p '{"metadata":{"annotations":{"metallb.io/loadBalancerIPs":"172.19.254.15"}}}'
```

**When a Service stays without an address, `kubectl describe svc` is the first place to look** — the reason is almost always in the events.

## Recipe 3 — One address, two Services

`pinned-and-shared.yaml` also carries `whoami-shared-a` (port 80 → the `whoami` pods) and `whoami-shared-b` (port 8080 → a second deployment, `whoami-b`). Same sharing key, same pinned address:

```bash
kubectl get svc whoami-shared-a whoami-shared-b -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip,PORTS:.spec.ports[*].port
```

```console
NAME              EXTERNAL-IP     PORTS
whoami-shared-a   172.19.254.16   80
whoami-shared-b   172.19.254.16   8080
```

MetalLB only colocates Services when they are explicit about it, and each condition exists for a reason:

| Condition | Why it is required |
|---|---|
| Same sharing key | Sharing must be explicit; two Services never silently collide |
| Different ports | Two Services cannot both claim `tcp/80` on the same address |
| Both `Cluster` policy, or **exactly** the same pod selector | With `Local`, different Services would disagree about which nodes are eligible |
| Pinning makes it deterministic | Otherwise MetalLB *may* colocate — it does not have to |

Recipe 4 proves the pair actually serves two different backends on that one address.

## Recipe 4 — Decide what the network is allowed to see

Allocating an address and advertising it are separate decisions, and in phase 2 they belong to different components. MetalLB hands out the addresses; Calico announces the **blocks** they live in:

| Pool | Addresses | Block | Announced? |
|---|---|---|---|
| `lab-pool` | 172.19.255.200-250 | `172.19.255.0/24` | yes (Lesson 6) |
| `lab-pool-reserved` | 172.19.254.10-19 | `172.19.254.0/24` | add it now |
| `lab-pool-public` | 172.19.254.100-109 | `172.19.254.0/24` | same block |
| `lab-pool-internal` | 172.19.252.1-14 | `172.19.252.0/28` | **never** |

```bash
kubectl apply -f public-and-internal-pools.yaml

# what we want the network to see: two blocks
kubectl patch bgpconfiguration default --type=merge -p \
  '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "172.19.255.0/24"},{"cidr": "172.19.254.0/24"}]}}'

# what may actually leave: the filter from Lesson 6 lists blocks too
kubectl apply -f ../lesson-06-bgp-calico/bgpfilter.yaml
```

```console
ipaddresspool.metallb.io/lab-pool-public created
ipaddresspool.metallb.io/lab-pool-internal created
service/whoami-public created
service/whoami-internal created
bgpconfiguration.projectcalico.org/default patched
bgpfilter.projectcalico.org/services-only configured
NAME              EXTERNAL-IP
whoami-public     172.19.254.100
whoami-internal   172.19.252.1
```

Both Services have an address. Only one of them can be reached from outside:

```bash
docker exec metallb-router vtysh -c 'show bgp ipv4 unicast' | grep -E '^ \*>?\s*172\.19\.25'
docker exec metallb-router ip route show 172.19.254.0/24
```

```console
 *>  172.19.254.0/24  172.19.0.2                             0 64512 i
 *>  172.19.255.0/24  172.19.0.3                             0 64512 i
172.19.254.0/24 nhid 23 proto bgp metric 20 
	nexthop via 172.19.0.2 dev eth0 weight 1 
	nexthop via 172.19.0.3 dev eth0 weight 1 
	nexthop via 172.19.0.4 dev eth0 weight 1 
```

Two blocks, three next hops each. `172.19.252.0/28` is nowhere — it was never listed.

> ⚠️ **A block must pass both gates.** `serviceLoadBalancerIPs` is what you *want* advertised; the `BGPFilter` is what *may* leave. Adding a block to the first and not the second produces the classic silent failure: sessions stay `Established`, `calico-node` logs `Updates included service advertisement changes`, and the prefix never reaches the router. When a block is announced in the config but missing from the router, check the filter first.

From the routed client — teach it the two new blocks, then ask all four addresses:

```bash
docker exec metallb-client ip route add 172.19.254.0/24 via 172.19.0.100
docker exec metallb-client ip route add 172.19.252.0/24 via 172.19.0.100
docker exec metallb-client curl -sS -m 5 http://172.19.254.16:80   | head -1   # shared, port 80
docker exec metallb-client curl -sS -m 5 http://172.19.254.16:8080 | head -1   # shared, port 8080
docker exec metallb-client curl -sS -m 5 http://172.19.254.100     | head -1   # public pool
docker exec metallb-client curl -sS -m 5 http://172.19.252.1       | head -1   # internal pool
```

```console
Hostname: whoami-8644bfc655-rkm4k
Hostname: whoami-b-76bf57f4f5-tc5sf
Hostname: whoami-8644bfc655-tgkk7
curl: (7) Failed to connect to 172.19.252.1:80 after 3048 ms: Could not connect to server
```

One address, two ports, two different backends (`whoami-…` on 80, `whoami-b-…` on 8080) — recipe 3 verified from outside the cluster. The internal VIP is unreachable from the network even though the client knows a route to it; the router simply has nowhere to send it.

It is still perfectly usable **inside** the cluster:

```bash
kubectl run inttest --rm -i --restart=Never --image=nginx --command -- curl -sS -m 5 http://172.19.252.1 | head -1
```

```console
Hostname: whoami-8644bfc655-4shnn
```

That is a better internal-only VIP than a firewall rule: there is nothing to leak, because the route is never born. The price is granularity — one whole block per exposure class, so **plan block boundaries like a network engineer**: public, internal, per-tenant, sized so you never need to announce "part of" one.

> 🏭 **Production:** this is the phase-2 replacement for per-Service advertisement. Keep the block list in Git (Lesson 8) — it is a single cluster-wide object, and nothing next to the Service records that it is private.

## Recipe 5 — A pool only one namespace may use

```bash
kubectl apply -f pool-access.yaml
kubectl -n team-a get svc whoami-team-a -o custom-columns=NAME:.metadata.name,NS:.metadata.namespace,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
kubectl get svc whoami-thief -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
```

```console
namespace/team-a created
ipaddresspool.metallb.io/lab-pool-team-a created
deployment.apps/whoami created
service/whoami-team-a created
service/whoami-thief created
NAME            NS       EXTERNAL-IP
whoami-team-a   team-a   172.19.254.200
NAME           EXTERNAL-IP
whoami-thief   <none>
```

`whoami-thief` lives in `default` and asks for `team-a`'s pool:

```console
Warning  AllocationFailed  metallb-controller
  Failed to allocate IP for "default/whoami-thief": pool lab-pool-team-a not compatible for ip assignment
```

`serviceAllocation` also accepts `namespaceSelectors` (label-based, so teams can own their own namespace labels), `serviceSelectors`, and `priority` for resolving competition between pools.

> 🏭 **Production pattern:** one pool per tenant, `autoAssign: false`, `serviceAllocation.namespaces` set, and one announced block per tenant. Your network team then reasons about tenants with `show bgp` instead of reading Kubernetes objects.

## Recipe 6 — Keep a node out of the advertisement

Every Calico node in the cluster peers with the router, so every node advertises. Which nodes talk to the ToR is a property of the **`BGPPeer`**, not of a node label:

```bash
# before: every node holds a session, so every node advertises
docker exec metallb-router ip route show 172.19.255.0/24 | grep nexthop

# drop the control-plane out of the session
kubectl patch bgppeer tor-router --type=merge \
  -p '{"spec":{"nodeSelector":"kubernetes.io/hostname != \"metallb-calico-control-plane\""}}'

# after
docker exec metallb-router ip route show 172.19.255.0/24 | grep nexthop
```

```console
	nexthop via 172.19.0.2 dev eth0 weight 1 
	nexthop via 172.19.0.3 dev eth0 weight 1 
	nexthop via 172.19.0.4 dev eth0 weight 1 
bgppeer.projectcalico.org/tor-router patched
	nexthop via 172.19.0.3 dev eth0 weight 1 
	nexthop via 172.19.0.4 dev eth0 weight 1 
```

Three next hops become two: the control-plane (in this build, `172.19.0.2`) no longer holds a session with the router, so it cannot advertise to it. Remove the `nodeSelector` and it comes back — that is what a *global* `BGPPeer` means:

```bash
kubectl patch bgppeer tor-router --type=merge -p '{"spec":{"nodeSelector":null}}'
```

> ⚠️ **Kubernetes' `exclude-from-external-load-balancers` label does nothing here.** It is what tells phase 1's MetalLB speaker to skip a node, and kind sets it (empty) on the control-plane, so it is tempting to assume Calico honours it too. It does not: with the label set to `true` on the control-plane, the router still saw all three next hops.

Fewer advertisers means less ECMP spread but a smaller failure domain: a node holding a session participates in every advertised block. Lesson 6's ECMP numbers came from all three.

## Cheat sheet — where each behaviour is configured

| I want to… | Use | Half |
|---|---|---|
| Keep addresses out of the automatic pool | `IPAddressPool.spec.autoAssign: false` | allocation |
| Give a Service a specific address | annotation `metallb.io/loadBalancerIPs` | allocation |
| Choose the pool per Service | annotation `metallb.io/address-pool` | allocation |
| Put two Services on one address | `metallb.io/allow-shared-ip` (+ pin the address) | allocation |
| Limit a pool to namespaces/teams | `IPAddressPool.spec.serviceAllocation` | allocation |
| Advertise a range | add its CIDR to `BGPConfiguration.spec.serviceLoadBalancerIPs` | announcement |
| Keep a VIP internal only | allocate from a pool whose block is not listed | announcement |
| Control what may leave a session | `BGPFilter` (+ `BGPPeer.spec.filters`) | announcement |
| Choose which nodes peer with the ToR | `BGPPeer.spec.nodeSelector` | announcement |
| Dual-stack | give ≥1 pool both v4 and v6 addresses; advertisement is per block as usual | both |

## Expected outcome

| Recipe | Result |
|---|---|
| 1. `autoAssign: false` | new Service got `172.19.255.201` from `lab-pool`; reserved pool stayed at 0 assigned |
| 2. Pinning | `whoami-pinned` = `172.19.254.15`; an out-of-pool request produced `AllocationFailed` |
| 3. Sharing | both Services on `172.19.254.16`, ports 80 and 8080 |
| 4. Block advertisement | router holds `172.19.254.0/24` and `172.19.255.0/24`, three next hops each; `172.19.252.0/28` never appears |
| 4. Reachability | public + shared VIPs answer from the client; the internal VIP answers only inside the cluster |
| 5. Pool access | `team-a` got `172.19.254.200`; `default` got an `AllocationFailed` event |
| 6. Node exclusion | control-plane dropped out of the session: three next hops became two |

## Cleanup for this lesson

```bash
kubectl delete -f .          # pools, Services, the team-a namespace
kubectl delete svc whoami-random
kubectl patch bgpconfiguration default --type=merge -p \
  '{"spec": {"serviceLoadBalancerIPs": [{"cidr": "172.19.255.0/24"}]}}'
```

## Production note

- **Treat pool design as network design.** Overlaps are rejected at admission, but *adjacency* problems are not: a pool inside your DHCP range, or inside a subnet the router will not route, is an outage you can only prevent on paper.
- **Use `autoAssign: false` for anything important.** Automatic allocation is convenient in a lab and dangerous when a stray Service can take your last public address.
- **Segregate VIP classes into blocks.** Public, internal, per-tenant — that block list is the only granularity Calico offers, and it replaces the per-Service selectors you may be used to.
- **Keep the two gates in sync.** A block missing from either `serviceLoadBalancerIPs` or the `BGPFilter` is invisible while every health signal looks green.
- **Document the annotations you rely on.** They are invisible in `kubectl get svc` output unless you ask for them, which is why this lesson ends with a cheat sheet instead of a wall of YAML.

## Next
Continue to [Lesson 8 — Operations and troubleshooting](../lesson-08-operations/README.md).

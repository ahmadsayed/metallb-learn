# Lesson 4 — Layer 2 deep dive: elections, failover and source IPs

## Glossary
| Term | What it means |
|------|---------------|
| **candidate set** | The nodes that *could* announce a VIP (they run a speaker, are alive, and — with `Local` policy — have a ready local pod) |
| **stateless election** | Each speaker sorts `hash(node + VIP)` independently and announces only if it is first — no leader database, no consensus |
| **gratuitous ARP (GARP)** | An unsolicited ARP broadcast: "this VIP is at my MAC now" |
| **memberlist** | The gossip protocol speakers use to notice that another node died |
| **externalTrafficPolicy** | `Cluster` (any node may accept, client IP is SNAT'ed) or `Local` (only nodes with a local pod, source IP preserved) |
| **healthCheckNodePort** | The extra NodePort Kubernetes allocates only when the policy is `Local`, so the cloud/LB layer can probe which nodes are eligible |
| **SNAT** | Source NAT: rewriting the client's IP to the node's, which is why pods see a node IP instead of the real client |
| **ServiceL2Status** | MetalLB's CR that records *which node* is currently announcing a Service |
| **REACHABLE / STALE** | Kernel neighbour-cache states. A `REACHABLE` entry is trusted for ~30 s before the kernel re-probes |

Lesson 3 proved the happy path. This lesson is about everything that makes L2 mode *hard in production*: who gets elected, what happens when a node dies, and where the client's IP goes.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `more-services.yaml` — three extra `LoadBalancer` Services selecting the same pods, so we can watch the election distribute VIPs across nodes.

## Experiment 1 — The election is **per VIP**, not per cluster

```bash
kubectl apply -f more-services.yaml
kubectl get svc whoami whoami-b whoami-c whoami-d -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
```

```console
NAME       TYPE           EXTERNAL-IP
whoami     LoadBalancer   172.19.255.200
whoami-b   LoadBalancer   172.19.255.201
whoami-c   LoadBalancer   172.19.255.202
whoami-d   LoadBalancer   172.19.255.203
```

```bash
kubectl -n metallb-system get servicel2statuses -o custom-columns=SVC:.status.serviceName,NODE:.status.node --no-headers | sort
```

```console
whoami-b   metallb-lab-worker2
whoami-c   metallb-lab-worker
whoami-d   metallb-lab-worker2
whoami     metallb-lab-worker
```

Four VIPs, announced by **two different nodes** (and with more nodes you would see more). Every speaker computes the same sorted list of `hash(node + VIP)` for the candidate set and announces only the entry it wins. That is the whole algorithm — there is no leader object, no lease, no coordinator to fail.

> 💡 Consequence worth internalising: because nothing is stored, the "leader" can be recomputed at any time from cluster state. That is a strength (no gossip consensus to break) and a trap (two speakers with different views can both think they won — the "brain split" the docs warn about).

## Experiment 2 — Kill the node that announces

We announce `whoami` (`172.19.255.200`) from `metallb-lab-worker`. Let's murder it properly: stop the whole node container, the way a server would actually die.

**Before** — capture what the host believes:

```bash
kubectl -n metallb-system get servicel2statuses -o custom-columns=SVC:.status.serviceName,NODE:.status.node --no-headers | sort
ip neigh show 172.19.255.200
```

```console
whoami     metallb-lab-worker
172.19.255.200 dev br-44d120cb051d lladdr 1e:63:c1:b5:6f:e9 STALE       # worker's MAC
```

**During** — capture ARP on the segment and probe the VIP once a second:

```bash
timeout 90 docker run --rm --network kind alpine:3.20 sh -c \
  'apk add --no-cache -q tcpdump >/dev/null 2>&1; tcpdump -i eth0 -n -e -l arp' > /tmp/garp.txt 2>&1 &

for i in $(seq 1 50); do
  printf '%s %s\n' "$(date +%T)" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://172.19.255.200)"
  sleep 1
done > /tmp/probe.txt &

docker stop metallb-lab-worker        # unplanned death of the announcing node
```

**The gratuitous ARP, straight off the wire:**

```console
13:23:43.411803 3e:fe:37:3d:d5:2c > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Request who-has 172.19.255.201 (ff:ff:ff:ff:ff:ff) tell 172.19.255.201
13:23:43.412005 3e:fe:37:3d:d5:2c > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Reply 172.19.255.201 is-at 3e:fe:37:3d:d5:2c
13:23:43.412195 3e:fe:37:3d:d5:2c > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Request who-has 172.19.255.202 (ff:ff:ff:ff:ff:ff) tell 172.19.255.202
13:23:43.413983 3e:fe:37:3d:d5:2c > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Request who-has 172.19.255.200 (ff:ff:ff:ff:ff:ff) tell 172.19.255.200
13:23:43.414112 3e:fe:37:3d:d5:2c > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Reply 172.19.255.200 is-at 3e:fe:37:3d:d5:2c
```

Reading it:

- The sender is `3e:fe:37:3d:d5:2c` — **`metallb-lab-worker2`'s MAC**, the node that won the new election.
- `Request who-has X tell X` is the classic gratuitous-ARP form: an ARP *request* whose target IP equals the sender IP, broadcast to `ff:ff:ff:ff:ff:ff`. It asks nobody and announces to everybody.
- It was repeated **5 times per VIP**, about 1.1 s apart (repetition because GARP is unreliable — it is a broadcast, not a handshake).

**The timing, measured** (probe output, condensed):

| Time | Result | What was happening |
|------|--------|-------------------|
| 21:23:40 – 21:23:43 | `200` | normal, served by worker |
| 21:23:44 | *timeout* | `docker stop` began; electing/announcing in flight |
| 21:23:47 – 21:24:02 | flapping `200` / *timeout* | worker2 announced (GARP at 21:23:43), but the client's cached entry was still pointing at the dead node |
| 21:24:03 – 21:24:20 | *timeouts* | neighbour cache re-probe / endpoint reconvergence |
| 21:24:21 → | `200` steady | fully failed over |

**After** — the host has updated its mind:

```bash
ip neigh show 172.19.255.200
```

```console
172.19.255.200 dev br-44d120cb051d lladdr 3e:fe:37:3d:d5:2c REACHABLE    # worker2's MAC now
```

> 💡 **The lesson is in the gap.** The announcement moved in under a second — the GARP went out in the *same second* the node died — but the traffic took ~35 s to become reliable. The bottleneck was not MetalLB: it was the **client's neighbour cache**, which had a `REACHABLE` entry pointing at the dead node's MAC and kept using it until the kernel re-probed. This is exactly the "failover depends on cooperation from clients" caveat in MetalLB's documentation, and it is why:
> - planned failovers should **keep the old node up for a couple of minutes** after flipping leadership (so stale clients still get served),
> - "MetalLB L2 failover is slow" bug reports are usually client ARP behaviour, not MetalLB.
>
> 🧪 **Lab Hack:** our measurement is pessimistic because `docker stop` has a 10 s graceful-shutdown grace period and because the *host* (the Docker bridge) is an unusually long-lived client. A real client with a shorter cache timer, or one that honours GARP properly, switches in about a second.

## Experiment 3 — Bring the node back: the VIP does not come home

```bash
docker start metallb-lab-worker
```

```console
whoami-b   metallb-lab-worker2
whoami-c   metallb-lab-worker2
whoami-d   metallb-lab-worker2
whoami     metallb-lab-worker2
```

`metallb-lab-worker` is `Ready` again with a healthy speaker — and it still announces nothing. This is the documented behaviour of the stateless election: **removing a node does not change the leader, and adding a node changes it only if the new node becomes the first element of the sorted list.** There is no "give it back" logic, because there is no memory of who had it.

(Later in this lesson, when we scale the pods to zero and back, the election is recomputed from scratch and `whoami` returns to `metallb-lab-worker` — the same input state produces the same winner, deterministically.)

## Experiment 4 — Where did the client's IP go? (`externalTrafficPolicy`)

```bash
curl -s http://172.19.255.200 | grep -E '^(Hostname|RemoteAddr)'
```

```console
Hostname: whoami-8644bfc655-84rkr
RemoteAddr: 10.244.1.1:5502          # ← a CNI gateway, NOT the client
```

The client is the host at `172.19.0.1`, but the pod sees `10.244.1.1`. With the default `externalTrafficPolicy: Cluster`, any node may accept VIP traffic for any pod, so `kube-proxy` **SNATs** the connection to make the reply path work. Your application loses the client IP, and any IP-based logging, rate limiting or geo-lookup breaks.

Now switch to `Local` and ask again:

```bash
kubectl patch svc whoami -p '{"spec":{"externalTrafficPolicy":"Local"}}'
curl -s http://172.19.255.200 | grep -E '^(Hostname|RemoteAddr)'
kubectl get svc whoami -o jsonpath='{.spec.externalTrafficPolicy}{"  healthCheckNodePort="}{.spec.healthCheckNodePort}{"\n"}'
```

```console
RemoteAddr: 172.19.0.1:52476         # ← the real client, preserved
Local  healthCheckNodePort=31988
```

The real source IP is back, and Kubernetes silently allocated a `healthCheckNodePort` (needed because load-balancer health checks must now target *specific eligible nodes*).

Mechanically, `Local` changes two things at once:

| | `Cluster` (default) | `Local` |
|---|---|---|
| Which nodes may accept the VIP | any node with a speaker | only nodes running a ready pod of the Service |
| Candidate set for the L2 election | all speakers | speakers whose node has a local ready endpoint |
| Client IP seen by the pod | SNAT'ed to a node/CNI address | the real client IP |
| Extra hop | possible (node A → pod on node B) | never (traffic is served by a local pod) |
| Risk | none for connectivity | if the elected node has no ready pod, the VIP goes dark |

That last row is the next experiment, and it is the single most common L2 outage.

## Experiment 5 — Allocated is not the same as reachable

Scale the app to zero so no node has a ready endpoint, while the policy is `Local`:

```bash
kubectl scale deploy/whoami --replicas=0
```

```bash
kubectl get svc whoami -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[*].ip
kubectl -n metallb-system get servicel2statuses --no-headers
curl -s -o /dev/null -w '%{http_code}\n' --max-time 4 http://172.19.255.200
```

```console
whoami     172.19.255.200        # ← still "has" an address
                                 # ← ServiceL2Status: NO ROWS AT ALL
000                              # ← and nothing answers
```

Three things to take away:

1. **`EXTERNAL-IP` means "an address was allocated", not "traffic works".** The controller's job (`IPAllocated`) is independent of the speaker's job (`nodeAssigned`). Here the first is done and the second is impossible.
2. **`ServiceL2Status` is your ground truth for L2.** No `ServiceL2Status` row (or `status.node` empty) = nothing is announcing, whatever the Service says.
3. This is why Lesson 8's alerting is built around *announcement*, not allocation.

Restore, and watch it recover:

```bash
kubectl scale deploy/whoami --replicas=3
kubectl rollout status deploy/whoami
curl -s http://172.19.255.200 | grep RemoteAddr
kubectl -n metallb-system get servicel2statuses -o custom-columns=SVC:.status.serviceName,NODE:.status.node --no-headers | sort
```

```console
RemoteAddr: 172.19.0.1:49546
whoami-b   metallb-lab-worker2
whoami-c   metallb-lab-worker
whoami-d   metallb-lab-worker2
whoami     metallb-lab-worker
```

## What the speaker says while doing all this

The speaker logs its decisions as structured JSON — the `event` field is what to grep for:

```bash
kubectl -n metallb-system logs <speaker-pod> | grep -i 'serviceAnnounced'
```

```console
{"caller":"main.go:481","event":"serviceAnnounced","ips":["172.19.255.200"],"level":"info","msg":"service has IP, announcing","pool":"lab-pool","protocol":"layer2","ts":"2026-09-12T13:25:45Z"}
```

Its counterpart events are `serviceWithdrawn` (stopped announcing) and `nodeAssigned` on the Service itself. If you ever need to know *why* a VIP is not on the wire, these three plus `ServiceL2Status` answer it.

## Expected outcome

| Experiment | Result |
|---|---|
| 4 VIPs | announced by 2 different nodes (per-VIP election) |
| Announcing node killed | VIP moved to `worker2`; GARP broadcast in <1 s; traffic reliable after ~35 s |
| Node restarted | **stays** on `worker2` (election has no memory) |
| `externalTrafficPolicy: Local` | pod sees the real client IP `172.19.0.1`, `healthCheckNodePort` allocated |
| No ready endpoints + `Local` | address still allocated, `ServiceL2Status` gone, VIP dead |
| Restore to `Cluster` | `whoami` announced by `metallb-lab-worker` again |

## Production note

- **Choose the policy deliberately.** `Cluster` = survives pod churn, loses client IPs. `Local` = preserves client IPs, but couples the VIP's health to *the pods on the elected node*.
- **Plan failovers, don't just take them.** For maintenance, drain pods away first, then let leadership move; keep the old node up for a couple of minutes so clients with sticky neighbour caches keep working.
- **Watch for the "allocated but not announced" state.** It is invisible in `kubectl get svc`. Alert on Services whose `ServiceL2Status` has no announcing node (Lesson 8).
- **`Local` + rolling updates is a known trap**: if the last pod on the elected node is replaced, the VIP has no announcer for that window. It is one more argument for BGP mode (Lessons 5–6), where the router re-hashes instead of a single node owning the VIP.
- **L2 does not scale with nodes.** All the VIP traffic for a Service still enters one node. That is a property of ARP, not a MetalLB limitation.

## Next
Continue to [Lesson 5 — BGP mode](../lesson-05-bgp/README.md).

# Lesson 9 — Tour of the Go codebase

## Glossary
| Term | What it means |
|------|---------------|
| **go module** | Go's dependency unit — MetalLB is `go.universe.tf/metallb` |
| **client-go** | The Kubernetes client library; its **informers** keep a local cache of cluster objects |
| **reconcile loop** | "Look at desired state, make reality match, repeat forever" — level-triggered, not event-driven |
| **level-triggered** | The loop reacts to the *current state*, so a missed event is harmless and a restart is safe |
| **CRD types** | Go structs generated from the CRDs (`api/v1beta1`), what the controller reads and writes |
| **`caller` log field** | `main.go:481` in a log line points at the source line that produced it — your best entry point into unfamiliar code |
| **table-driven test** | A slice of input/expected structs run through one loop: the dominant test style in this repo |

Eight lessons of black-box behaviour, now with the lid off. This lesson is about finding your way around 213 Go files without reading all of them.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- none — this lesson works in `.src/metallb` (gitignored in this repo).

## Step 1 — Get the source and build it

```bash
mkdir -p .src && cd .src
git clone --depth 1 --branch v0.16.1 https://github.com/metallb/metallb
cd metallb
go build ./...
```

```console
$ head -3 go.mod
module go.universe.tf/metallb
go 1.25.0

$ go build ./...
(no output = success)
```

> 💡 Clone the **tag**, not `main`, so the code matches the behaviour you observed (`v0.16.1` is what the lab runs). The build needs Go 1.25+; this lab machine has Go 1.26.

## Step 2 — The map

213 Go files (excluding the website). The ones that matter:

| Path | What lives there | Where you met it |
|---|---|---|
| `controller/` | The controller binary: `main.go` (wiring, webhooks) and `service.go` (the allocation reconcile loop) | Lesson 2: the 1-replica Deployment |
| `speaker/` | The speaker binary: `main.go` (the announcement loop), `layer2_controller.go`, `bgp_controller.go` | Lessons 3–7: every `nodeAssigned` event |
| `internal/allocator/` | IP allocation: `allocator.go` (23 KB), `allocation.go`, `stats.go` | Lesson 7: pinning, sharing, pool selection, exhaustion |
| `internal/layer2/` | The ARP/NDP machinery: `announcer.go`, `arp.go`, `ndp.go` | Lesson 3: the ARP reply on the wire |
| `internal/bgp/` | The native BGP implementation | Lesson 5 |
| `internal/speakerlist/` | `memberlist` membership (who is alive) | Lesson 4: failover detection |
| `internal/k8s/` | Kubernetes client helpers, event recording, CRD watchers | every event you saw |
| `internal/config/` | The internal representation of your CRs (pools, advertisements, peers) | Lesson 2: the CRDs |
| `api/` | The Go types for the CRDs | building a controller against them (Lesson 11) |
| `e2etest/`, `dev-env/` | The project's own end-to-end tests and kind/dev environment | if you want to contribute |
| `frr-tools/`, `configmaptocrs/`, `charts/` | FRR templates, the ConfigMap→CR migrator, the Helm chart | Lesson 2: `helm install` |

## Step 3 — Follow one Service end to end

Pick a `type: LoadBalancer` Service and trace it. Two halves, two binaries.

**Half 1 — allocation (`controller/service.go`):**

```
convergeBalancer   (service.go:49)   ← the reconcile entry point
  allocateIPs      (service.go:252)  ← asks the allocator for addresses
  isServiceAllocated (service.go:301)
```

which calls into `internal/allocator`:

| Function | Job |
|---|---|
| `Allocate(svc, ports)` | Pick a free address for a Service (the normal path) |
| `Assign(svcKey, svc, ips, ports, sharingKey, backendKey)` | Adopt a specific address (pinning, or re-adopting after a restart) |
| `Unassign(svc)` | Give an address back |
| `Pool(svc)` / `IPs(svc)` / `AllocationKey(svc)` | Read back what a Service currently holds |
| `PoolForIP(ips)` | Which pool owns this address? (used when a user pins one) |
| `CountersForPool(name)` | The numbers behind the pool `status` and the metrics |

`internal/allocator/allocation.go` holds the small `alloc` bookkeeping type; `allocator.go` holds the policy (pools, sharing, families, pinning). That separation — *bookkeeping* vs *policy* — is why the 52 KB test file can exercise allocation without a cluster.

**Half 2 — announcement (`speaker/main.go`).** Here is the code that produced the log line we saw in Lesson 3:

```go
if deleteReason := handler.ShouldAnnounce(l, name, lbIPs, pool, svc, eps, c.nodes); deleteReason != "" {
    return c.deleteBalancerProtocol(l, protocol, name, deleteReason)
}
if err := handler.SetBalancer(l, name, lbIPs, pool, c.client, svc); err != nil { … }

for _, ip := range lbIPs {
    announcing.With(prometheus.Labels{
        "protocol": string(protocol),
        "service":  name,
        "node":     c.myNode,
        "ip":       ip.String(),
    }).Set(1)
}
level.Info(l).Log("event", "serviceAnnounced", "msg", "service has IP, announcing", "protocol", protocol)
c.client.Infof(svc, "nodeAssigned", "announcing from node %q with protocol %q", c.myNode, protocol)
```

Everything from the lab is in those fifteen lines:

- `ShouldAnnounce` returns a **reason string** — that is the `"reason":"noEndpoints"` and `"skipping should announce bgp"` output you read in Lessons 4–6. `handler` is an interface with one implementation per protocol (`layer2Controller`, `bgpController`), which is why L2 and BGP share this loop.
- `SetBalancer` does the protocol-specific work (start answering ARP; start advertising a prefix).
- `announcing.With(...).Set(1)` **is** the `metallb_speaker_announced` metric you alerted on in Lesson 8.
- `c.client.Infof(svc, "nodeAssigned", …)` **is** the event you read in `kubectl describe svc`.

## Step 4 — Where the metrics are defined

`internal/allocator/stats.go` declares the gauges; the names appear at scrape time:

```go
poolCapacity: prometheus.NewGaugeVec(prometheus.GaugeOpts{ … })   // → metallb_allocator_addresses_total
ipv4PoolActive: …                                                 // → metallb_allocator_addresses_in_use_total
poolAllocated: …                                                  // → allocation counters
```

```console
$ kubectl … curl https://<controller>:9120/metrics | grep allocator_addresses
metallb_allocator_addresses_in_use_total{pool="lab-pool-public"} 2
metallb_allocator_addresses_total{pool="lab-pool"} 51
```

Reading a metric name, finding the gauge, and reading the code around it is the fastest way to understand an unfamiliar subsystem: the metric tells you *what the authors considered worth watching*.

## Step 5 — Run the tests

```bash
go test ./internal/layer2/... ./internal/allocator/... ./speaker/...
```

```console
ok  	go.universe.tf/metallb/internal/layer2	0.028s
ok  	go.universe.tf/metallb/internal/allocator	0.017s
?   	go.universe.tf/metallb/internal/allocator/k8salloc	[no test files]
ok  	go.universe.tf/metallb/speaker	0.025s
```

31 tests, no cluster required — they are the specification of the behaviour you watched:

| Test | What it pins | Where you saw the behaviour |
|---|---|---|
| `TestARPResponder` | The ARP request/reply logic | Lesson 3's wire capture |
| `TestSetBalancer_AddsToAnnouncedServices` | Which interfaces announce which VIPs | Lesson 3/4 |
| `TestL2ElectionConsistentButAdsPerNode` | The election is deterministic across speakers | Lesson 4's per-VIP leaders |
| `TestShouldAnnounceExcludeLB` | Nodes with the exclusion label never announce | Lesson 5's silent control-plane |
| `TestShouldAnnounceBGPServiceSelectors` / `TestL2ServiceSelectors` | Advertisement `serviceSelectors` filtering | Lesson 7's internal-only VIP |
| `TestL2ServiceSelectorFiltersCandidateNodes` | Selectors also shrink the candidate set | Lesson 7 |
| `TestNodeSelectors` | Per-node peering/announcement | Lesson 6's `nodeSelectors` |

```bash
go test ./speaker/... -v -run 'TestShouldAnnounceExcludeLB|TestL2ElectionConsistentButAdsPerNode'
```

> 💡 **Tests are the cheapest documentation in the repo.** When you want to know whether something is intended behaviour or a bug, look for a test with its name on it. `TestShouldAnnounceExcludeLB` existing is the answer to "is the silent control-plane a bug?" — no, it is a documented, tested decision.

## Step 6 — Building the binaries yourself

```bash
go build -o /tmp/speaker ./speaker
go build -o /tmp/controller ./controller
/tmp/speaker --help 2>&1 | head -20
```

Compare the flags with what the cluster actually runs:

```bash
kubectl -n metallb-system get ds metallb-speaker -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
kubectl -n metallb-system get deploy metallb-controller -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
```

```console
["--port=9120","--log-level=info"]                      # speaker
["--port=9120","--log-level=info","--webhook-mode=enabled"]   # controller
```

Every flag is a knob the Helm chart sets for you. This is how you find the setting you need *before* searching the docs — and `--log-level=all` on the speaker is the one people want most when debugging.

## Step 7 — The technique that got us here

You do not need to read this codebase front to back. Use the logs:

1. Take a log line from the lab: `{"caller":"main.go:481","event":"serviceAnnounced",…}`.
2. Open `speaker/main.go` at line 481.
3. Read outward until you find the decision (`ShouldAnnounce`), then follow *that* into the protocol-specific file.

Two jumps from a running-cluster symptom to the exact branch that decided it. `caller` is a `go-kit/log` field the project wires up for exactly this reason.

## Exercises

1. Find the function that decides whether a node may announce at all, and locate the two places that can exclude a node (hint: one is a Kubernetes label, one is your `L2Advertisement`).
2. `grep -rn 'noEndpoints' --include='*.go'` — where is the string that ended up in the speaker log in Lesson 4? Which code path sets it?
3. Run `go test ./internal/allocator/... -run TestPool -v` and match two test names to the Lesson 7 recipes.
4. Find where the controller writes `status.loadBalancer.ingress`. That single write is the entire "contract" from Lesson 0.

## Production note

- **Vendor the version you run.** When you debug a live incident you want the source of *that* image — `git checkout v0.16.1`, and check the image tag against the release.
- **The repo's `troubleshooting/` directory and `e2etest/` are worth reading before you file a bug**: the e2e tests document supported topologies, and the troubleshooting notes list known-bad CNI/kube-proxy interactions.
- **If you plan to contribute**, `dev-env/` spins up the project's own kind environment, and `tasks.py` drives the e2e suite — the same tests CI runs.

## Next
Continue to [Lesson 10 — Inside `internal/layer2`](../lesson-10-go-layer2/README.md).

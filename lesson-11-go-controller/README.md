# Lesson 11 — Write your own Go controller (`poolwatch`)

## Glossary
| Term | What it means |
|------|---------------|
| **controller-runtime** | The library the Kubernetes ecosystem uses to write controllers |
| **Manager** | Owns the caches, clients, metrics and the reconcile workers |
| **cache / informer** | A local, always-current copy of the objects you watch (no polling in your code) |
| **Reconcile** | Your function: given an object's name, make reality match the desired state |
| **predicate** | A filter that stops irrelevant events from reaching your reconciler |
| **secondary watch** | Watching object B so that a change in B re-reconciles object A (via a `mapFunc`) |
| **least-privilege RBAC** | The controller may read Services and MetalLB CRs, and create Events — nothing else |
| **static binary** | `CGO_ENABLED=0` output that runs in an empty container |

Ten lessons of consuming MetalLB, and now one where you produce something for it. We will build the tool that Lesson 8 could only describe:

> **`poolwatch`** — a controller that alerts when a `LoadBalancer` Service has an address that no node is announcing.

It also implements the pool-exhaustion alert for real, and it is small enough (≈250 lines) to read in one sitting.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `poolwatch/main.go` — the controller.
- `poolwatch/go.mod` — its dependencies (including MetalLB's own API package).
- `poolwatch/Dockerfile` — a static binary in an Alpine image.
- `deploy.yaml` — Namespace, ServiceAccount, least-privilege RBAC, Deployment, metrics Service.

## Step 1 — A module that consumes MetalLB's API

```bash
mkdir poolwatch && cd poolwatch
cat > go.mod <<'EOF'
module metallb-learn/poolwatch

go 1.24

require (
	github.com/prometheus/client_golang v1.23.2
	go.universe.tf/metallb v0.16.1
	k8s.io/api v0.34.1
	k8s.io/apimachinery v0.34.1
	k8s.io/client-go v0.34.1
	sigs.k8s.io/controller-runtime v0.22.3
)
EOF
go mod tidy
```

The interesting line is `go.universe.tf/metallb`: because MetalLB publishes its CRD types as a Go package (`api/v1beta1`), you can import `metallbv1beta1.ServiceL2Status` and get compile-time safety on someone else's CRD:

```go
var l2List metallbv1beta1.ServiceL2StatusList
r.List(ctx, &l2List, client.InNamespace("metallb-system"), selector)
for _, s := range l2List.Items {
    if s.Status.Node != "" { … }        // typed, no map[string]interface{} anywhere
}
```

> 💡 This is the pattern for **any** operator ecosystem: publish `api/` as an importable module and consumers stop hand-rolling unstructured objects. MetalLB's status CRs, which we have been reading with `kubectl`, have real Go structs with `status.node`, `status.serviceName`, `status.peers`.

## Step 2 — The reconcile loop

The core question is one function: *"this Service has address X — is anybody announcing it?"*

```go
ips := loadBalancerIPs(&svc)
if len(ips) == 0 {
    pending.WithLabelValues(svc.Namespace, svc.Name).Set(1)   // allocated? no
    return ctrl.Result{}, nil
}

// MetalLB records announcements in CRs labelled with the Service name.
selector := client.MatchingLabels{
    "metallb.io/service-name":      svc.Name,
    "metallb.io/service-namespace": svc.Namespace,
}
// … List ServiceL2Status (layer2) and ServiceBGPStatus (bgp) in metallb-system …

if !announcing {
    orphaned.WithLabelValues(svc.Namespace, svc.Name, ip).Set(1)
    r.Recorder.Eventf(&svc, corev1.EventTypeWarning, "NotAnnounced",
        "LoadBalancer IP %v is assigned but no node is announcing it", ips)
}
```

Three behaviours worth copying into your own controllers:

1. **Clear your own series first.** `clearSeries(namespace, name)` deletes this Service's metric labels before recomputing them. Reconcile runs many times for the same object; a controller that only sets metrics leaks series for deleted objects.
2. **Use the labels MetalLB already provides.** `metallb.io/service-name` / `metallb.io/service-namespace` on the status CRs (we saw them in Lesson 3) mean we never have to parse a `generateName`.
3. **Emit Events, not just logs.** The Event lands on the Service, next to MetalLB's own `IPAllocated` — so the next person to run `kubectl describe svc` sees both halves of the story.

## Step 3 — The watch that makes it correct

A naive version reconciles Services when Services change. But the state we care about lives in *other* objects: a Service can stay identical while its announcement disappears (pods died, a speaker went away). So we watch the status CRs too, and map them back:

```go
statusToService := handler.EnqueueRequestsFromMapFunc(func(_ context.Context, obj client.Object) []reconcile.Request {
    name := obj.GetLabels()["metallb.io/service-name"]
    ns := obj.GetLabels()["metallb.io/service-namespace"]
    return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: ns, Name: name}}}
})

return ctrl.NewControllerManagedBy(mgr).
    Named("service-announcement").
    For(&corev1.Service{}, builder.WithPredicates(onlyLoadBalancers)).
    Watches(&metallbv1beta1.ServiceL2Status{}, statusToService).
    Watches(&metallbv1beta1.ServiceBGPStatus{}, statusToService).
    Complete(r)
```

plus a predicate so we only ever look at `type: LoadBalancer` Services, and a 30-second `SyncPeriod` so anything missed is re-checked:

```go
onlyLoadBalancers := predicate.Funcs{
    CreateFunc: func(e event.CreateEvent) bool { return isLoadBalancer(e.Object) },
    // … Update/Delete/Generic …
}
```

> 💡 **This is the mental model for controller writing**: the objects you *report on* and the objects that *carry the state* are usually different, and a controller that watches only the first one will be subtly wrong at exactly the moment you need it.

## Step 4 — Pool usage, from the pool's own status

MetalLB v0.15+ maintains `status.assignedIPv4/availableIPv4` on each pool, so a second tiny reconciler is enough:

```go
ratio := float64(used) / float64(used+free)
poolUsage.WithLabelValues(pool.Name).Set(ratio)
if ratio > 0.9 {
    ctrl.LoggerFrom(ctx).Info("pool is nearly exhausted", "pool", pool.Name, "ratio", …, "used", used, "total", total)
}
```

No math on CIDR ranges, no counting Services — the component that owns the number publishes it, and we just watch it.

## Step 5 — Build and deploy it into the lab

```bash
CGO_ENABLED=0 go build -o poolwatch .
docker build -t poolwatch:lab .
kind load docker-image poolwatch:lab --name metallb-lab
cd .. && kubectl apply -f deploy.yaml
```

```console
sha256:f1b188a98e0eeaa9aa162d26e5764fd0a44765a5e65444c5701e213b6ada29b2
Image: "poolwatch:lab" with ID "sha256:f1b188…" not yet present on node "metallb-lab-worker", loading...
namespace/poolwatch created
serviceaccount/poolwatch created
clusterrole.rbac.authorization.k8s.io/poolwatch created
clusterrolebinding.rbac.authorization.k8s.io/poolwatch created
deployment.apps/poolwatch created
service/poolwatch created
NAME                         READY   STATUS    RESTARTS   AGE
poolwatch-64fcb5d448-hlqvh   1/1     Running   0          15s
```

> 🧪 **Lab Hack:** `kind load docker-image` copies a locally built image into the kind nodes, so no registry is needed. In production you push to a registry and let the Deployment pull it.

> 🏭 **Production note — build it properly.** The lab Dockerfile copies a binary built on the host (fast, and it makes the "static binary" point visible). For CI, use a multi-stage build:
> ```dockerfile
> FROM golang:1.25 AS build
> WORKDIR /src
> COPY go.mod go.sum ./
> RUN go mod download
> COPY . .
> RUN CGO_ENABLED=0 go build -o /out/poolwatch .
>
> FROM gcr.io/distroless/static:nonroot
> COPY --from=build /out/poolwatch /poolwatch
> USER 65532:65532
> ENTRYPOINT ["/poolwatch"]
> ```

## Step 6 — What it found on the live cluster

It reconciled the whole lab, and immediately reported the states we had created by hand in Lessons 7 and 8:

```console
INFO  ORPHANED: address assigned but nobody announces it
      service=default/whoami-private  ips=[172.19.254.101]
      hint="no ready endpoints, no matching advertisement, or the service is not selected by one"

INFO  service is pending an address   service=default/tiny-3          # pool exhausted
INFO  service is pending an address   service=default/whoami-thief    # pool restricted to team-a
```

The metrics endpoint (plain HTTP on `:9090` — our own, so no HTTPS/RBAC dance):

```console
$ curl -s http://127.0.0.1:19090/metrics | grep '^poolwatch_'
poolwatch_pool_usage_ratio{pool="lab-pool"} 0.09803921568627451
poolwatch_pool_usage_ratio{pool="lab-pool-public"} 0.2
poolwatch_pool_usage_ratio{pool="lab-pool-reserved"} 0.2
poolwatch_pool_usage_ratio{pool="lab-pool-team-a"} 0.1
poolwatch_pool_usage_ratio{pool="lab-pool-tiny"} 1          # ← exhausted (lesson 8)
poolwatch_service_announced{ip="172.19.254.100",protocol="bgp",service="whoami-public"} 1
poolwatch_service_announced{ip="172.19.255.200",protocol="bgp",service="whoami"} 1
…
poolwatch_service_orphaned{ip="172.19.254.101",service="whoami-private"} 1
poolwatch_service_pending{service="tiny-3"} 1
poolwatch_service_pending{service="whoami-thief"} 1
```

And the Event it wrote sits on the Service right next to MetalLB's own:

```console
$ kubectl describe svc whoami-private | sed -n '/Events/,$p'
  Type     Reason        Age    From                Message
  Normal   IPAllocated   7m26s  metallb-controller  Assigned IP ["172.19.254.101"]
  Warning  NotAnnounced  23s    poolwatch           LoadBalancer IP [172.19.254.101] is assigned but no node is announcing it
```

## Step 7 — Prove it is live, not a snapshot

Metrics that are only correct at startup are worse than none. Scale the app to zero and wait one sync period:

```bash
kubectl scale deploy/whoami --replicas=0
sleep 40
kubectl -n poolwatch logs deploy/poolwatch | grep -c ORPHANED
kubectl scale deploy/whoami --replicas=3
```

```console
18
```

Eighteen detections: every Service that lost its endpoints — including `whoami`, `whoami-b`, `whoami-c`, `whoami-d` and `whoami-random`, which were perfectly announced a minute earlier. That is the Lesson 6 withdrawal behaviour, observed from the outside, by code we wrote.

> 💡 This is the loop that makes an operator useful: **desired state in, observed state out, on a timer and on every relevant change.** We did not write a single `for { sleep }` — the cache, the watches and the sync period do that work.

## Exercises

1. Add `poolwatch_pool_free{pool}` (a gauge of remaining addresses) and alert on `poolwatch_pool_usage_ratio == 1`. Bonus: make the ratio alert fire *before* exhaustion (review Lesson 8's PromQL).
2. Make the orphan report distinguish the three causes by checking, in order: does the Service have ready endpoints; is it selected by any advertisement; would the node label exclude its speakers? Each maps to a Lesson 4–7 experiment.
3. Add a `--once` flag that prints a report and exits (useful in CI: "no orphaned Services allowed").
4. Watch `ServiceL2Status` in an L2 cluster and confirm the reconciler works identically there — the CRs are the same shape, only the protocol label changes.
5. Break it deliberately: remove `events` from the ClusterRole and watch the Event creation fail in the logs. Least privilege makes failures visible, which is a feature.

## Production note

- **Give it leader election if you scale it** (`ctrl.Options{LeaderElection: true, LeaderElectionID: …}`), otherwise two replicas both emit Events and race on metrics.
- **Namespace-scope the cache when you can.** This controller reads status CRs from `metallb-system` and Services from everywhere; a controller that only cares about one namespace can restrict its cache and cut API load a lot.
- **Keep custom metrics clearly namespaced.** `poolwatch_*` cannot collide with `metallb_*`, and the name says who owns the series. Never re-implement a metric the upstream component already exports — watch it instead.
- **Prefer the upstream status CRs to scraping the upstream logs.** Everything here used CRs and one metric; the log lines were only ever for humans.
- **A controller is a product**: version it, test the reconcile function with `envtest`, and check it into Git with its RBAC. `sigs.k8s.io/controller-runtime/pkg/envtest` runs a real API server locally — the natural next step from this lesson.

## Where to go from here

| If you want to… | Do this |
|---|---|
| Understand MetalLB end to end | You have: [Lesson 0](../lesson-00-concepts/README.md) for the model, [Lesson 10](../lesson-10-go-layer2/README.md) for the wire behaviour |
| Contribute upstream | `dev-env/` + `e2etest/` in the clone; CI runs the same suite |
| Run this in production | Start from [Lesson 8](../lesson-08-operations/README.md): metrics, alerts, upgrade procedure |
| Extend MetalLB itself | Add an API field in `api/v1beta1`, wire it in `internal/config`, use it in `speaker/` — the pattern is identical to what you wrote here |
| Build more operators | `poolwatch` is a template: cache + predicate + secondary watch + status CRs + your own metrics |

## Next
Back to the [course index](../README.md), or revisit any lesson — the cluster is still running.

# MetalLB on Bare Metal — a hands-on course

Learn how a bare-metal Kubernetes cluster gets `LoadBalancer` services: from a Service stuck at `<pending>` forever, to **ARP/NDP-announced VIPs** and **real BGP peering** with a router — all simulated on a single Linux machine (kind + an FRR container), and then straight into the **Go code** that does the work.

## The lessons (run them in order)

**Part I — Operations: make `LoadBalancer` work**

| # | Lesson | What you do |
|---|--------|-------------|
| **0** | [Concepts](lesson-00-concepts/README.md) | why `<pending>` happens, controller vs speaker, L2 vs BGP, the packet path |
| **1** | [The cluster & the problem](lesson-01-cluster/README.md) | build a 3-node kind cluster, deploy an app, watch `EXTERNAL-IP` stay `<pending>` |
| **2** | [Install MetalLB](lesson-02-install/README.md) | Helm install, tour every component and CRD it creates |
| **3** | [Layer 2 mode: your first VIP](lesson-03-l2/README.md) | `IPAddressPool` + `L2Advertisement`, then watch ARP hand you the VIP |
| **4** | [Layer 2 deep dive](lesson-04-l2-deep/README.md) | per-service leader election, real failover, GARP, `externalTrafficPolicy`, metrics |
| **5** | [BGP mode](lesson-05-bgp/README.md) | peer with a real router (FRR in Docker), advertise VIPs, see routes appear |
| **6** | [BGP the modern way](lesson-06-bgp-frrk8s/README.md) | frr-k8s (the v0.16 default backend), ECMP load spreading, communities and local-pref |
| **7** | [Advanced addressing](lesson-07-advanced/README.md) | IP sharing, address pinning, pool selectors, `autoAssign`, dual-stack |
| **8** | [Operations & troubleshooting](lesson-08-operations/README.md) | metrics, alerts, a failure-mode matrix, safe upgrades |

**Part II — Internals: read and extend the Go code**

| # | Lesson | What you do |
|---|--------|-------------|
| **9** | [Tour of the Go codebase](lesson-09-go-tour/README.md) | clone `metallb/metallb`, build it, run the unit tests, follow the controller's reconcile loop and the allocator |
| **10** | [Inside `internal/layer2`](lesson-10-go-layer2/README.md) | the ARP/NDP responder, memberlist leader election, and the tests that pin their behaviour |
| **11** | [Write a Go controller](lesson-11-go-controller/README.md) | build `poolwatch`: a small controller-runtime operator that watches MetalLB's CRDs and reports pool exhaustion |

## Prerequisites

- Linux with **Docker** and **kind** (`docker` must be usable without `sudo`) — no GPU, no cloud account
- **kubectl**, **helm**, **curl**, **tcpdump**, and **Go 1.24+** (Part II)
- ~8 GB of free RAM for the 3-node cluster + router container

## The big picture

![MetalLB architecture: controller allocates, speakers announce](diagrams/metallb-architecture.svg)

MetalLB is two programs. The **controller** watches Services, hands out addresses from an `IPAddressPool`, and writes them into `status.loadBalancer.ingress`. The **speaker** runs on every node (a DaemonSet) and makes the rest of the network believe those addresses live on a node — by answering ARP/NDP (**layer 2 mode**) or by advertising them over BGP (**BGP mode**).

![Layer 2 vs BGP: one node answers ARP, or every node advertises a route](diagrams/l2-vs-bgp.svg)

**What is real here and what is simulated:** the protocols are real — real ARP packets on the wire, a real BGP session with a real FRR daemon, real `kube-proxy` DNAT, real MetalLB binaries. What a single laptop cannot give you is *hardware*: the "router" is a container, the "network" is a Docker bridge, and there is no physical redundancy or wire-speed ECMP fabric. The API and the packet paths are exactly the production ones.

## How this course was built

Every command in these lessons was executed on the lab machine (Nobara Linux, Docker, kind v0.31, Kubernetes v1.34) and the outputs pasted verbatim. Where a step exists only because of the kind simulation it is tagged 🧪 **Lab Hack**, and the production equivalent is noted as 🏭 **Production**.

## Cleanup

Tear down everything the lessons created:

```bash
./cleanup.sh
```

It is idempotent — safe to run at any time. It deletes the kind cluster, the router container and the Docker network the lab added, and leaves your Docker images and tools in place.

## Reference

- MetalLB docs: <https://metallb.io>
- MetalLB source: <https://github.com/metallb/metallb>

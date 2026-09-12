# Lesson 5 — Phase 2: rebuild the cluster on Calico

## Glossary
| Term | What it means |
|------|---------------|
| **CNI** | The plugin that gives pods their network (kindnet in phase 1, Calico now) |
| **Calico** | A CNI + network-policy engine that runs an agent (`calico-node`) on every node |
| **tigera-operator** | The controller that installs and owns Calico; you configure it with an `Installation` CR |
| **`Installation`** | Calico's CR describing the pod network (pod CIDR, encapsulation, MTU) |
| **encapsulation** | IPIP/VXLAN (pods tunnelled between nodes) vs **none** (nodes route pod traffic directly — requires one L2 segment) |
| **`disableDefaultCNI`** | kind setting: do not install kindnet, because Calico will do the job |
| **controller-only** | MetalLB installed with `speaker.enabled=false` — allocation without announcement |

Phase 1 (Lessons 0–4) needed nothing from the network: a flat Ethernet segment and ARP were enough. Phase 2 needs a **real BGP speaker on every node** — and BGP allows exactly **one session per pair of nodes**, so there can only be one speaker per node peering with the router. Calico's agent is already on every node. MetalLB therefore keeps the half it is uniquely good at: **allocation**.

> ⚠️ **About this lesson's output blocks.** Lessons 0–4 show output captured on the lab machine. This lesson and Lesson 6 were written while the phase-1 cluster was still in use, so their `console` blocks describe **what you should see**, not captured transcripts. Run them and paste your output back — they will be replaced with the real thing, the same way every other lesson was built.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `kind-config-calico.yaml` — 3 nodes, no default CNI, pod subnet matched to Calico's IPPool.
- `install-calico.sh` — installs the Tigera operator and declares the `Installation` (no encapsulation).
- `pool-controller-only.yaml` — the `IPAddressPool` (allocation only — no advertisements anywhere).
- the app itself is reused from phase 1: `../lesson-01-cluster/whoami.yaml`.

## Step 1 — Capture phase 1, then tear it down

The L2 evidence from Lessons 3–4 only exists in the running cluster. Save what you want to keep **before** destroying it:

```bash
kubectl -n metallb-system get servicel2statuses -o yaml > /tmp/phase1-l2status.yaml
kubectl get svc -A -o wide > /tmp/phase1-services.txt
./cleanup.sh
```

> 💡 `cleanup.sh` removes **both** phase clusters (`metallb-lab` and `metallb-calico`), the router/client/capture containers and the `poolwatch:lab` image. Pass a name to remove just one — `./cleanup.sh metallb-lab` — which is what you want here if you intend to keep a phase-2 cluster around. Your `~/.kube/config` context goes away with its cluster.

## Step 2 — Create the phase-2 cluster

```bash
kind create cluster --config kind-config-calico.yaml
```

Two settings in that file are doing real work:

| Setting | Why |
|---|---|
| `disableDefaultCNI: true` | Without it, kindnet and Calico both try to own pod networking |
| `podSubnet: 192.168.0.0/16` | Calico's default IPPool is `192.168.0.0/16`, kind's default pod subnet is `10.244.0.0/16`. Make them agree here rather than patching Calico afterwards |

```console
# expected
Creating cluster "metallb-calico" ...
 ✓ Ensuring node image (kindest/node:v1.35.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
```

**No `✓ Installing CNI` line** — that is the point, and it is why the next step matters: with no CNI the nodes stay `NotReady`.

```bash
kubectl get nodes
```

```console
# expected
NAME                            STATUS     ROLES           AGE   VERSION
metallb-calico-control-plane    NotReady   control-plane   45s   v1.35.0
metallb-calico-worker           NotReady   <none>          30s   v1.35.0
metallb-calico-worker2          NotReady   <none>          30s   v1.35.0
```

## Step 3 — Install Calico

```bash
./install-calico.sh
```

The script pinned a Calico version, installs the operator, then declares an `Installation` with **no encapsulation**:

```yaml
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: 192.168.0.0/16
        encapsulation: None
        natOutgoing: Enabled
        nodeSelector: all()
```

> 💡 **Why no encapsulation?** All three nodes (and, later, the router) share one Docker bridge — the same "one L2 segment" topology as phase 1, and the on-premises topology Calico expects when peering with a ToR. With `encapsulation: None`, Calico routes pod traffic directly between nodes over BGP instead of tunnelling it, which is what makes the next lesson's routing table meaningful. If pod-to-pod traffic misbehaves in your environment, change `encapsulation` to `IPIP` and re-apply — the BGP parts of Lesson 6 are unaffected either way.

> ⚠️ **Two failures this script exists to prevent**, both of which cost real time if you install Calico by hand:
>
> 1. **`tigera-operator.yaml` contains no CRDs** (~14 KB: namespace, RBAC, Deployment). The 32 CRDs live in a separate `operator-crds.yaml` (~2.6 MB). Skip it and the `Installation` fails with `no matches for kind "Installation" in version "operator.tigera.io/v1"`.
> 2. **The CRDs need `kubectl apply --server-side`.** Client-side apply stores the whole object in the `last-applied-configuration` annotation, and annotations are capped at 262144 bytes — while `installations.operator.tigera.io` alone is **1.39 MB** of YAML. Client-side apply dies with `metadata.annotations: Too long`. Server-side apply tracks ownership in `managedFields` instead, so it has no such limit. (`gatewayapis.operator.tigera.io` at 303 KB survives client-side apply only because the limit applies to the JSON copy in the annotation, which encodes smaller than the YAML.)

Nodes go `Ready` once `calico-node` is running on each one:

```console
# expected
NAME                            STATUS   ROLES           AGE   VERSION
metallb-calico-control-plane    Ready    control-plane   2m    v1.35.0
metallb-calico-worker           Ready    <none>          2m    v1.35.0
metallb-calico-worker2          Ready    <none>          2m    v1.35.0
```

## Step 4 — Prove pod networking works before touching load balancing

Split the check in two: **did the pod get an address**, then **does egress work**. Asking both at once tells you nothing when it fails — a pod with no network just hangs inside `apk add`, and `kubectl run -i` waits for ever instead of reporting anything.

```bash
kubectl run nettest --image=alpine:3.20 --restart=Never --command -- sleep 300
kubectl wait --for=condition=Ready pod/nettest --timeout=60s || kubectl describe pod nettest | tail -15
```

```console
# expected
pod/nettest condition met
```

```bash
kubectl get pod nettest -o wide          # expect a 192.168.x.y pod IP and a node
kubectl exec nettest -- sh -c \
  'apk add --no-cache -q curl >/dev/null && curl -s -m 5 https://example.com -o /dev/null && echo "egress OK"; ip -4 addr show eth0 | grep inet'
kubectl delete pod nettest
```

```console
# expected
egress OK
    inet 192.168.xx.yy/32 scope global eth0
```

> ⚠️ **If `kubectl wait` times out**, the pod has no network and the smoke test was never going to work. `kubectl describe pod nettest` names the reason (`network plugin`, `failed to set up sandbox`, …). Check in this order:
> ```bash
> kubectl get nodes                              # NotReady = still no CNI
> kubectl get installation default               # was the Installation applied at all?
> kubectl get tigerastatus                       # Calico's own component health
> kubectl -n calico-system get pods -o wide      # calico-node on every node?
> ```
> The usual cause is Step 3 not having finished — most often the CRDs (`Installation` rejected) or the `Installation` never applied.

Note the pod IP: `192.168.x.x`, not phase 1's `10.244.x.x`. Every pod-IP output in Lessons 1–4 changes accordingly — the lesson's *behaviour* does not.

## Step 5 — Install MetalLB with everything except the controller disabled

```bash
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb --namespace metallb-system --create-namespace \
  --version 0.16.1 \
  --set speaker.enabled=false \
  --set frrk8s.enabled=false \
  --wait --timeout 5m
```

```bash
kubectl -n metallb-system get pods
```

```console
# expected — one pod, and that is the whole point
NAME                                  READY   STATUS    RESTARTS   AGE
metallb-controller-7c9f8d6b5b-x2vqk   1/1     Running   0          60s
```

| Component | State | Why |
|---|---|---|
| `metallb-controller` | **running** | Allocation + webhook |
| `metallb-speaker` | disabled | Calico announces. Also: it *couldn't* peer even if enabled — one session per node pair |
| `metallb-frr-k8s` | disabled | Existed only to give the speaker an FRR backend. No speaker, no FRR |

The chart is built for this: with `speaker.enabled=false` it skips the speaker DaemonSet **and** the `metallb-excludel2` ConfigMap, which only the L2 responder reads.

> 💡 Also delete any leftover advertisement CRs if you are re-running this on a cluster that used to have them. They are inert without a speaker, but they confuse the next reader:
> ```bash
> kubectl -n metallb-system delete bgppeer,bgpadvertisement,l2advertisement --all 2>/dev/null
> ```

## Step 6 — Allocate an address with no announcer in sight

```bash
kubectl apply -f pool-controller-only.yaml
kubectl apply -f ../lesson-01-cluster/whoami.yaml
kubectl get svc whoami
```

```console
# expected
NAME     TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
whoami   LoadBalancer   10.96.x.y      172.19.255.200   80:31xxx/TCP   20s
```

```bash
kubectl get events --field-selector involvedObject.name=whoami --sort-by=.lastTimestamp | tail -2
kubectl -n metallb-system get servicel2statuses,servicebgpstatuses
```

```console
# expected
Normal   IPAllocated   service/whoami   Assigned IP ["172.19.255.200"]
# and: no ServiceL2Status, no ServiceBGPStatus — nothing is announcing
```

**This is the state Lesson 4 called a failure, and here it is by design.** The address exists; the network has never heard of it. Confirm it is genuinely unreachable:

```bash
ip neigh flush 172.19.255.200 2>/dev/null; curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://172.19.255.200
```

```console
# expected
000
```

Lesson 6 makes it real.

## What changed since phase 1

| | Phase 1 (Lessons 0–4) | Phase 2 (now) |
|---|---|---|
| CNI | kindnet | Calico |
| Pod IPs | `10.244.x.x` | `192.168.x.x` (Calico IPPool) |
| MetalLB install | controller + speaker + frr-k8s | **controller only** |
| Announcer | `metallb-speaker` (ARP/NDP) | Calico (`calico-node`, BGP) |
| `EXTERNAL-IP` assigned by | MetalLB controller | MetalLB controller (unchanged) |
| Reachability proof | host ARP cache + GARP capture | router's BGP table (Lesson 6) |
| `ServiceL2Status` | present | **does not exist** — the speaker creates it |

## Expected outcome

| What | State |
|---|---|
| Cluster | `metallb-calico`, 3 nodes, Calico, **no encapsulation** |
| Node status | `Ready` after `calico-node` starts |
| Pod IPs | `192.168.x.x` |
| `metallb-system` pods | **only** `metallb-controller` |
| `whoami` | `EXTERNAL-IP: 172.19.255.200` allocated |
| Announcement | none — unreachable, intentionally |

## Production note

- **Pin your Calico version.** Calico's service-IP advertisement changed across releases (Lesson 6 lists the specific issues), and a course or a runbook that says "latest" is not reproducible.
- **Decide the dataplane deliberately.** No-encapsulation means the fabric must route pod CIDRs — fine when you peer with ToRs (Lesson 6 shows your router learning them), wrong if your network can't. VXLAN/IPIP are the alternatives.
- **Keep `kube-proxy`.** Calico's eBPF mode replaces it; that changes the ingress DNAT path this course teaches, and mixing it with L2/VIP experiments adds variables you don't want while learning.
- **Two CRs, one decision:** MetalLB owns the *address*, Calico owns the *route*. Write that down for whoever is on call — the failure modes land in different components (Lesson 8).

## Next
Continue to [Lesson 6 — BGP with Calico](../lesson-06-bgp-calico/README.md).

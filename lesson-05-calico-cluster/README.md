# Lesson 5 — Phase 2: rebuild the cluster on Calico

## Glossary
| Term | What it means |
|------|---------------|
| **CNI** | The plugin that gives pods their network (kindnet in phase 1, Calico now) |
| **Calico** | A CNI + network-policy engine that runs an agent (`calico-node`) on every node |
| **tigera-operator** | The controller that installs and owns Calico; you configure it with an `Installation` CR |
| **`Installation`** | Calico's CR describing the pod network (pod CIDR, encapsulation, MTU) |
| **`APIServer`** | The CR that deploys Calico's aggregated API server — the thing that serves `projectcalico.org/v3` |
| **encapsulation** | IPIP/VXLAN (pods tunnelled between nodes) vs **none** (nodes route pod traffic directly — requires one L2 segment) |
| **`disableDefaultCNI`** | kind setting: do not install kindnet, because Calico will do the job |
| **controller-only** | MetalLB installed with `speaker.enabled=false` — allocation without announcement |

Phase 1 needed nothing from the network: a flat Ethernet segment and ARP were enough. Phase 2 needs a **real BGP speaker on every node** — and BGP allows exactly **one session per pair of nodes**, so only one speaker per node can peer with the router. Calico's agent is already on every node. MetalLB therefore keeps the half it is uniquely good at: **allocation**.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `kind-config-calico.yaml` — 3 nodes, no default CNI, pod subnet matched to Calico's IPPool.
- `install-calico.sh` — installs the operator CRDs, the operator, then `calico-installation.yaml`.
- `calico-installation.yaml` — the `Installation` (pod CIDR, no encapsulation) **and the `APIServer`** (Step 3).
- `controller-only-rbac.yaml` — workaround for the chart 0.16.1 RBAC bug (Step 5).
- `pool-controller-only.yaml` — the `IPAddressPool` (allocation only — no advertisements anywhere).
- the app itself is reused from phase 1: `../lesson-01-cluster/whoami.yaml`.

## Step 1 — Capture phase 1, then tear it down

The L2 evidence from Lessons 3–4 only exists in the running cluster. Save what you want to keep **before** destroying it:

```bash
kubectl -n metallb-system get servicel2statuses -o yaml > /tmp/phase1-l2status.yaml
kubectl get svc -A -o wide > /tmp/phase1-services.txt
./cleanup.sh
```

```console
=== 2/6 Delete the course clusters ===
  - metallb-lab not present
  ✓ metallb-calico deleted
=== 3/6 Remove the lab containers ===
  ✓ metallb-router removed
```

> 💡 `cleanup.sh` removes **both** phase clusters. Pass a name to remove just one — `./cleanup.sh metallb-lab` — if you want to keep a phase-2 cluster around. Your `~/.kube/config` context goes away with its cluster.

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
Set kubectl context to "kind-metallb-calico"
You can now use your cluster with:
kubectl cluster-info --context kind-metallb-calico
```

**No `✓ Installing CNI` line** — that is the point, and it is why the next step matters: with no CNI the nodes stay `NotReady`.

```bash
kubectl get nodes
```

```console
NAME                           STATUS     ROLES           AGE   VERSION
metallb-calico-control-plane   NotReady   control-plane   9s    v1.35.0
metallb-calico-worker          NotReady   <none>          0s    v1.35.0
metallb-calico-worker2         NotReady   <none>          0s    v1.35.0
```

Note the node IPs now — Lesson 6's router peers with them:

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,IP:.status.addresses[0].address --no-headers
```

```console
metallb-calico-control-plane   172.19.0.4
metallb-calico-worker          172.19.0.3
metallb-calico-worker2         172.19.0.2
```

> ⚠️ Docker hands out node IPs in start order, so on a rebuild the roles and IPs can swap. `router-setup.sh` defaults to the set `{.2, .3, .4}`, which covers any arrangement; if yours differ, pass them: `NODE1=… NODE2=… NODE3=… ./router-setup.sh`.

## Step 3 — Install Calico

```bash
./install-calico.sh        # applies calico-installation.yaml part-way through
```

```console
=== 1/6 Install the operator CRDs (v3.30.3) ===
customresourcedefinition.apiextensions.k8s.io/apiservers.operator.tigera.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/installations.operator.tigera.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/bgppeers.crd.projectcalico.org serverside-applied
...
customresourcedefinition.apiextensions.k8s.io/installations.operator.tigera.io condition met
=== 2/6 Install the Tigera operator ===
deployment "tigera-operator" successfully rolled out
=== 3/6 Declare the Installation and the APIServer ===
installation.operator.tigera.io/default created
apiserver.operator.tigera.io/default created
=== 4/6 Wait for calico-node on every node ===
NAME                           STATUS   ROLES           AGE   VERSION
metallb-calico-control-plane   Ready    control-plane   45s   v1.35.0
metallb-calico-worker          Ready    <none>          36s   v1.35.0
metallb-calico-worker2         Ready    <none>          36s   v1.35.0
=== 5/6 Wait for the Calico API server (serves projectcalico.org/v3) ===
bgpconfigurations   bgpconfig,bgpconfigs   projectcalico.org/v3   false   BGPConfiguration
bgpfilters                                 projectcalico.org/v3   false   BGPFilter
bgppeers                                   projectcalico.org/v3   false   BGPPeer
```

> 💡 **Why a script instead of three copy-pasted commands.** Calico's install has two sharp edges: `tigera-operator.yaml` ships **no CRDs** (they are in a separate 2.6 MB `operator-crds.yaml`, and they need `--server-side`), and the `Installation` gives you networking but not the `projectcalico.org/v3` API — that comes from the `APIServer` object. Skip either and `kubectl apply` answers `no matches for kind …`. The script does all three in order and waits for each.

All components land in `calico-system`:

```bash
kubectl -n calico-system get pods -o wide
```

```console
NAME                                       READY   STATUS    RESTARTS   AGE   IP                NODE
calico-kube-controllers-8644666ff9-9xn82   1/1     Running   0          65s   192.168.64.64     metallb-calico-control-plane
calico-node-22v2r                          1/1     Running   0          65s   172.19.0.3        metallb-calico-worker
calico-node-57tln                          1/1     Running   0          65s   172.19.0.2        metallb-calico-worker2
calico-node-lg72t                          1/1     Running   0          65s   172.19.0.4        metallb-calico-control-plane
calico-typha-77f8767766-6hf84              1/1     Running   0          57s   172.19.0.3        metallb-calico-worker
calico-typha-77f8767766-tpmqw              1/1     Running   0          65s   172.19.0.2        metallb-calico-worker2
csi-node-driver-5jfqm                      2/2     Running   0          65s   192.168.64.68     metallb-calico-control-plane
csi-node-driver-j4s2v                      2/2     Running   0          65s   192.168.81.192    metallb-calico-worker
csi-node-driver-ld7wz                      2/2     Running   0          65s   192.168.237.192   metallb-calico-worker2
```

`calico-node` has a **node IP** (`172.19.0.x` — `hostNetwork`), everything else has a pod IP. That node IP is what Lesson 6's router will peer with.

> 💡 **Why `encapsulation: None`?** All three nodes (and, later, the router) share one Docker bridge — the same "one L2 segment" topology as phase 1, and the on-premises topology Calico expects when peering with a ToR. With no encapsulation, Calico routes pod traffic directly between nodes over BGP instead of tunnelling it, which is what makes Lesson 6's routing table meaningful. Step 4 proves it actually works.

## Step 4 — Prove pod networking works before touching load balancing

Split the check in two: **did the pod get an address**, then **does egress work**.

```bash
kubectl run nettest --image=nginx --restart=Never --command -- sleep 300
kubectl wait --for=condition=Ready pod/nettest --timeout=60s || kubectl describe pod nettest | tail -15
kubectl exec nettest -- curl -s -m 5 http://httpbin.org/headers
kubectl delete pod nettest
```

```console
pod/nettest condition met
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/8.14.1",
    "X-Amzn-Trace-Id": "Root=1-6aa586ff-7397bbe649a5c81a2ce9657e"
  }
}
```

`httpbin.org` echoes your request headers back, so this proves DNS resolved and traffic left the cluster. If the pod never becomes `Ready`, there is no CNI — check `kubectl get nodes` and `kubectl -n calico-system get pods`.

Note the pod IP: `192.168.x.x`, not phase 1's `10.244.x.x`. Every pod-IP output in Lessons 1–4 changes accordingly — the behaviour does not.

One more check while you are here: **pod-to-pod across two nodes**, which is what this cluster's `encapsulation: None` actually bets on (egress works in any mode):

```bash
kubectl apply -f ../lesson-01-cluster/whoami.yaml
kubectl get pods -l app=whoami -o wide

# pick a pod and a target on a DIFFERENT node, and print both before using them
PODS=$(kubectl get pods -l app=whoami \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.podIP}{"\n"}{end}')
NODE_A=$(echo "$PODS" | head -1 | awk '{print $1}')
POD_B=$(echo "$PODS"  | tail -1 | awk '{print $2}')
echo "from $NODE_A -> pod $POD_B"

kubectl run crossnode --rm -i --restart=Never --image=nginx \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"$NODE_A\"}}" \
  -- curl -sS -m 5 http://$POD_B | head -3
```

```console
NAME                      READY   STATUS    RESTARTS   AGE   IP                NODE
whoami-8644bfc655-5xwfx   1/1     Running   0          10s   192.168.81.194    metallb-calico-worker
whoami-8644bfc655-8lh9m   1/1     Running   0          10s   192.168.237.194   metallb-calico-worker2
whoami-8644bfc655-v44jj   1/1     Running   0          10s   192.168.81.193    metallb-calico-worker

Hostname: whoami-8644bfc655-8lh9m
IP: 192.168.237.194
```

A `Hostname: whoami-…` answer means `worker` reached a pod on `worker2` with **no tunnel**: `encapsulation: None` works. A timeout means it did not — switch `encapsulation` to `IPIP` and re-apply; Lesson 6 is unaffected either way.

## Step 5 — Install MetalLB with everything except the controller disabled

Three commands, and **the order matters** — the chart has a bug (below) that makes the obvious order fail:

```bash
kubectl create namespace metallb-system
kubectl apply -f controller-only-rbac.yaml
helm install metallb metallb/metallb --namespace metallb-system \
  --version 0.16.1 --set speaker.enabled=false --set frrk8s.enabled=false \
  --wait --timeout 5m
```

```console
namespace/metallb-system created
role.rbac.authorization.k8s.io/metallb-pod-lister created
rolebinding.rbac.authorization.k8s.io/metallb-pod-lister created
...
NAME                                  READY   STATUS    RESTARTS   AGE
metallb-controller-5d85bd46d8-nhdlq   1/1     Running   0          14s
```

```bash
kubectl -n metallb-system get pods
```

```console
NAME                                  READY   STATUS    RESTARTS   AGE
metallb-controller-5d85bd46d8-nhdlq   1/1     Running   0          14s
```

| Component | State | Why |
|---|---|---|
| `metallb-controller` | **running** | Allocation + webhook |
| `metallb-speaker` | disabled | Calico announces. Also: it *couldn't* peer even if enabled — one session per node pair |
| `metallb-frr-k8s` | disabled | Existed only to give the speaker an FRR backend. No speaker, no FRR |

> 🐞 **Chart 0.16.1 bug — this is why the order is namespace → RBAC → install.** The chart renders the `metallb-pod-lister` Role and RoleBinding inside `{{- if .Values.speaker.enabled }}`, but the **controller** is what uses them (its own Pod for owner references, plus the CRs it reads to allocate). Disable the speaker without the workaround and the controller crash-loops on `cannot get resource "pods"`, and `--wait` dies with `INSTALLATION FAILED: context deadline exceeded`. Fixed upstream in [PR #3069](https://github.com/metallb/metallb/pull/3069), merged after the 0.16.1 release — once a chart ships it, drop `controller-only-rbac.yaml`.

## Step 6 — Allocate an address with no announcer in sight

```bash
kubectl apply -f pool-controller-only.yaml
kubectl get svc whoami
```

```console
ipaddresspool.metallb.io/lab-pool created
NAME     TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
whoami   LoadBalancer   10.96.118.48   172.19.255.200   80:31110/TCP   6m6s
```

```bash
kubectl get svc whoami -o jsonpath='{.status.loadBalancer}{"\n"}'
kubectl get events --field-selector involvedObject.name=whoami --sort-by=.lastTimestamp | tail -1
kubectl -n metallb-system get servicel2statuses,servicebgpstatuses
```

```console
{"ingress":[{"ip":"172.19.255.200","ipMode":"VIP"}]}
6s   Normal   IPAllocated   service/whoami   Assigned IP ["172.19.255.200"]
No resources found in metallb-system namespace.
```

**This is the state Lesson 4 called a failure, and here it is by design.** The address exists; the network has never heard of it. Confirm it is genuinely unreachable:

```bash
curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://172.19.255.200
```

```console
000
```

Lesson 6 makes it real.

## What changed since phase 1

| | Phase 1 (Lessons 0–4) | Phase 2 (now) |
|---|---|---|
| CNI | kindnet | Calico (operator-installed, no encapsulation) |
| Pod IPs | `10.244.x.x` | `192.168.x.x` (Calico IPPool) |
| MetalLB install | controller + speaker + frr-k8s | **controller only** |
| Announcer | `metallb-speaker` (ARP/NDP) | Calico (`calico-node`, BGP) |
| `EXTERNAL-IP` assigned by | MetalLB controller | MetalLB controller (unchanged) |
| Reachability proof | host ARP cache + GARP capture | router's BGP table (Lesson 6) |
| `ServiceL2Status` | present | **does not exist** — the speaker creates it |

## Expected outcome

| What | State |
|---|---|
| Cluster | `metallb-calico`, 3 nodes, Calico v3.30.3, **no encapsulation** |
| Node status | `Ready` once `calico-node` starts |
| Pod IPs | `192.168.x.x` |
| Egress + cross-node pod-to-pod | both work |
| `metallb-system` pods | **only** `metallb-controller` (1/1 Running) |
| `whoami` | `EXTERNAL-IP: 172.19.255.200` allocated |
| Announcement | none — unreachable (`000`), intentionally |

## Production note

- **Pin your Calico version.** Calico's service-IP advertisement changed across releases, and a runbook that says "latest" is not reproducible.
- **Decide the dataplane deliberately.** No-encapsulation means the fabric must route pod CIDRs — fine when you peer with ToRs (Lesson 6 shows your router learning them), wrong if your network can't. VXLAN and IPIP are the alternatives.
- **Install the `APIServer` if you want `projectcalico.org/v3`.** Many real clusters skip it and manage Calico with `calicoctl`, which talks to the datastore directly. With plain `kubectl` and the documented `v3` manifests, you need it.
- **Two CRs, one decision:** MetalLB owns the *address*, Calico owns the *route*. Write that down for whoever is on call — the failure modes land in different components (Lesson 8).

## Next
Continue to [Lesson 6 — BGP with Calico](../lesson-06-bgp-calico/README.md).

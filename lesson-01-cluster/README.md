# Lesson 1 — The cluster & the problem

## Glossary
| Term | What it means |
|------|---------------|
| **kind** | Kubernetes-in-Docker: each cluster "node" is a container on your machine |
| **node container** | A Docker container that runs a full kubelet + containerd, i.e. one cluster node |
| **kindnet** | The CNI (pod network) that kind installs by default |
| **kube-proxy** | Programs the iptables/IPVS rules that make Service IPs work on every node |
| **ClusterIP** | The Service's internal address — reachable **only** from inside the cluster |
| **EndpointSlice** | The object listing the pod IPs behind a Service |
| **EXTERNAL-IP** | The address a `LoadBalancer` Service promises you; `<pending>` means nobody has provided one |
| **Docker bridge network** | The virtual L2 switch kind attaches all node containers to (here: `172.19.0.0/16`) |

Create a cluster that has exactly the problem MetalLB solves: a `LoadBalancer` Service with no external address, on a network where *nothing* will ever provide one.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `kind-config.yaml` — 1 control-plane + 2 workers. Deliberately boring: MetalLB needs a *cluster*, not special hardware.
- `whoami.yaml` — a 3-replica Deployment plus a `type: LoadBalancer` Service that will stay `<pending>` until Lesson 3.

## Step 1 — Check the tools

```bash
docker version --format '{{.Server.Version}}'
kind version
kubectl version --client | head -1
helm version --short
```

## Step 2 — Create the cluster

```bash
kind create cluster --config kind-config.yaml
```

```console
Creating cluster "metallb-lab" ...
 • Ensuring node image (kindest/node:v1.35.0) 🖼  ...
 ✓ Ensuring node image (kindest/node:v1.35.0) 🖼
 • Preparing nodes 📦 📦 📦   ...
 ✓ Preparing nodes 📦 📦 📦
 • Writing configuration 📜  ...
 ✓ Writing configuration 📜
 • Starting control-plane 🕹️  ...
 ✓ Starting control-plane 🕹️
 • Installing CNI 🔌  ...
 ✓ Installing CNI 🔌
 • Installing StorageClass 💾  ...
 ✓ Installing StorageClass 💾
 • Joining worker nodes 🚜  ...
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-metallb-lab"
```

> 🏭 **Production:** this is the *only* step that changes completely — real servers, a real CNI (Calico/Cilium), 3+ nodes, and often `kube-proxy` in IPVS mode. Everything from Lesson 2 onward is identical.

## Step 3 — Look at your "datacenter"

```bash
kubectl get nodes -o wide
```

```console
NAME                        STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION                    CONTAINER-RUNTIME
metallb-lab-control-plane   Ready    control-plane   2m33s v1.35.0   172.19.0.4    <none>        Debian GNU/Linux 12 (bookworm)   7.2.3-200.nobara.fc44.x86_64      containerd://2.2.0
metallb-lab-worker          Ready    <none>          2m20s v1.35.0   172.19.0.3    <none>        Debian GNU/Linux 12 (bookworm)   7.2.3-200.nobara.fc44.x86_64      containerd://2.2.0
metallb-lab-worker2         Ready    <none>          2m20s v1.35.0   172.19.0.2    <none>        Debian GNU/Linux 12 (bookworm)   7.2.3-200.nobara.fc44.x86_64      containerd://2.2.0
```

Three nodes, each with an address in `172.19.0.0/16`. Note that **the control-plane is a node like any other** — in this lab it will host a MetalLB speaker too (that matters in Lesson 4, when we kill nodes).

## Step 4 — Find the network the nodes live on

This one command decides the address range we can use as VIPs in Lesson 3:

```bash
docker network inspect kind --format '{{range .IPAM.Config}}subnet {{.Subnet}} gw {{.Gateway}}{{"\n"}}{{end}}'
```

```console
subnet fc00:f853:ccd:e793::/64 gw fc00:f853:ccd:e793::1
subnet 172.19.0.0/16 gw 172.19.0.1
```

The nodes are containers on the **`kind`** Docker bridge, so "the physical network" is `172.19.0.0/16`, and the host itself is `172.19.0.1` on it.

> 🧪 **Lab Hack:** in production you discover this with `ip route` / your network team: "which subnet do my nodes sit in, and which addresses in it are free?" The *question* is the same; only the tools differ.

## Step 5 — Deploy the app

```bash
kubectl apply -f whoami.yaml
kubectl rollout status deploy/whoami
kubectl get pods -o wide
```

```console
deployment.apps/whoami created
service/whoami created
deployment "whoami" successfully rolled out
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE
whoami-8644bfc655-84rkr   1/1     Running   0          15s   10.244.1.2   metallb-lab-worker2
whoami-8644bfc655-hxlxx   1/1     Running   0          15s   10.244.2.2   metallb-lab-worker
whoami-8644bfc655-tx66b   1/1     Running   0          15s   10.244.2.3   metallb-lab-worker
```

Three pods, two nodes, `10.244.x.x` pod IPs — the app is healthy and spread out.

## Step 6 — The problem

```bash
kubectl get svc whoami
```

```console
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
whoami   LoadBalancer   10.96.233.4   <pending>     80:31559/TCP   16s
```

`EXTERNAL-IP` is `<pending>`. Now confirm that this is *not* an error condition — Kubernetes has nothing to report, because nothing failed:

```bash
kubectl get svc whoami -o jsonpath='{.status.loadBalancer}{"\n"}'
kubectl describe svc whoami | sed -n '/Events/,$p'
```

```console
{}
Events:                   <none>
```

The `status` is an empty object and there are no events. The Service is simply **waiting for a component that does not exist in this cluster**.

## Step 7 — Prove only the *address* is missing

The app works perfectly — over its ClusterIP, from inside the cluster:

```bash
kubectl run curl-proof --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
  --command -- curl -s http://whoami
```

```console
Hostname: whoami-8644bfc655-hxlxx
IP: 127.0.0.1
IP: 10.244.2.2
RemoteAddr: 10.244.2.4:57792
GET / HTTP/1.1
Host: whoami
User-Agent: curl/8.10.1
pod "curl-proof" deleted from default namespace
```

But from the host, that ClusterIP is not reachable — it is a virtual IP that only exists inside `kube-proxy`'s rules on the nodes:

```bash
curl --max-time 5 http://10.96.233.4 ; echo "exit: $?"
```

```console
exit: 124          # timed out: nothing routes to a ClusterIP from outside
```

So we have: a working app, a healthy cluster, and **no way for anything outside the cluster to reach it**.

## Expected outcome

| What | State |
|------|-------|
| 3 nodes | `Ready` |
| 3 `whoami` pods | `Running`, spread over 2 workers |
| `whoami` Service | `type: LoadBalancer`, `EXTERNAL-IP: <pending>`, **no events** |
| App reachable in-cluster | Yes (ClusterIP) |
| App reachable from the host | No |

> ⚠️ **Your IPs will differ.** Docker assigns the node subnet and `ClusterIP`s dynamically; `172.19.x.x` / `10.96.x.x` are from the lab machine. Wherever this course uses `172.19.255.200`, substitute an address from *your* node subnet as discovered in Step 4.

## Production note

On a cloud provider, the **cloud-controller-manager** does this job: it sees `type: LoadBalancer`, calls the cloud API, and writes the resulting IP into `status`. There is no such component on bare metal — nothing to call, nobody to ask. Your options are:

| Option | What it is |
|--------|------------|
| **MetalLB** | The de-facto standard. Speaks ARP/NDP (L2) or BGP. What this course teaches. |
| kube-vip | Similar goals, also does control-plane VIPs. |
| PureLB | LB IP allocation with a different announcement model. |
| Cilium LB IPAM + BGP | If you already run Cilium, it can do both halves itself. |
| A public cloud CCM | If your "bare metal" is OpenStack/vSphere, you may want the cloud's LB instead. |

## Next
Continue to [Lesson 2 — Install MetalLB](../lesson-02-install/README.md).

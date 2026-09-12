# Lesson 2 — Install MetalLB

## Glossary
| Term | What it means |
|------|---------------|
| **Helm chart** | A packaged set of Kubernetes manifests with configurable values |
| **CRD** | Custom Resource Definition — a new API type added to the cluster (`IPAddressPool`, `BGPPeer`, …) |
| **webhook** | An HTTPS callback the API server calls to validate/reject objects; MetalLB ships two |
| **controller** | The MetalLB Deployment that *allocates* IPs (1 replica, leader-elected) |
| **speaker** | The MetalLB DaemonSet that *announces* IPs (1 pod per node, `hostNetwork`) |
| **frr-k8s** | A Kubernetes wrapper around the FRR routing suite — the default BGP backend since v0.16 |
| **hostNetwork** | Pod setting: the pod shares the node's network namespace (needed to answer ARP / open BGP sessions) |
| **NET_RAW / NET_ADMIN** | Linux capabilities: craft raw packets (ARP) / change routing and interfaces (BGP) |

Install MetalLB, then tour what it *actually* puts in your cluster — because knowing which piece is responsible for what is what makes debugging it easy later.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- none — this lesson is an install plus an inspection tour.

## Step 1 — Add the chart and install

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update metallb
helm install metallb metallb/metallb \
  --namespace metallb-system --create-namespace \
  --version 0.16.1 --wait --timeout 5m
```

```console
NAME: metallb
LAST DEPLOYED: Sat Sep 12 21:18:48 2026
NAMESPACE: metallb-system
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
MetalLB is now running in the cluster.

Now you can configure it via its CRs. Please refer to the metallb official docs
on how to use the CRs.
```

> 💡 **Why pin `--version`?** MetalLB's behaviour changes between minor versions (v0.16 changed the *default BGP backend*, for example). Pin it in the lab so the outputs in this course match yours; `helm search repo metallb/metallb --versions` lists what is available.

> 🏭 **Production alternatives:** the same chart via GitOps (Argo CD/Flux) or the manifest bundle from `metallb/metallb` releases (`kubectl apply -f metallb-native.yaml`) if you want no Helm in the loop. Nothing else changes.

## Step 2 — What appeared

```bash
kubectl -n metallb-system get deploy,ds,svc
```

```console
NAME                                            READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/metallb-controller              1/1     1            1           60s
deployment.apps/metallb-frr-k8s-statuscleaner   1/1     1            1           60s

NAME                             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
daemonset.apps/metallb-frr-k8s   3         3         3       3            3           kubernetes.io/os=linux
daemonset.apps/metallb-speaker   3         3         3       3            3           kubernetes.io/os=linux

NAME                              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/frr-k8s-webhook-service   ClusterIP   10.96.146.162   <none>        443/TCP   60s
service/metallb-webhook-service   ClusterIP   10.96.119.94    <none>        443/TCP   60s
```

Four things to notice:

1. **`metallb-controller` is a Deployment with 1 replica.** Allocation must be a single decision, so MetalLB runs one (leader-elected) brain.
2. **`metallb-speaker` is a DaemonSet, 3/3 on 3 nodes.** Announcement must happen on *every* node, because an ARP reply or a BGP session comes out of a specific machine.
3. **`metallb-frr-k8s` is a separate DaemonSet** — this is the v0.16 default BGP backend, FRR running on each node. If you only ever use L2 mode, this is extra weight you can remove later (Lesson 6).
4. **Two webhook services.** MetalLB validates your CRs (`IPAddressPool`, `L2Advertisement`, …) through an HTTPS admission webhook, so a typo is rejected at `kubectl apply` time instead of half-working at runtime.

```bash
kubectl -n metallb-system get pods -o wide
```

```console
NAME                                            READY   STATUS    RESTARTS   AGE   IP           NODE
metallb-controller-55846b4849-gkn2m             1/1     Running   0          54s   10.244.1.3   metallb-lab-worker2
metallb-frr-k8s-9nskd                           5/5     Running   0          54s   172.19.0.3   metallb-lab-worker
metallb-frr-k8s-k8wft                           5/5     Running   0          54s   172.19.0.4   metallb-lab-control-plane
metallb-frr-k8s-kk4vt                           5/5     Running   0          54s   172.19.0.2   metallb-lab-worker2
metallb-frr-k8s-statuscleaner-8bf664555-v4dsj   1/1     Running   0          54s   172.19.0.2   metallb-lab-worker2
metallb-speaker-krjq6                           1/1     Running   0          54s   172.19.0.3   metallb-lab-worker
metallb-speaker-qm5wr                           1/1     Running   0          54s   172.19.0.2   metallb-lab-worker2
metallb-speaker-rvfmd                           1/1     Running   0          54s   172.19.0.4   metallb-lab-control-plane
```

Look at the IP column: the controller has a **pod IP** (`10.244.x.x`), while every speaker and frr-k8s pod has a **node IP** (`172.19.0.x`). That is `hostNetwork: true` — those pods are on the node's own network namespace, which is the only way they can answer ARP for the node and peer with a real router.

## Step 3 — The new API surface

```bash
kubectl get crds -o name | grep metallb | sort
```

```console
customresourcedefinition.apiextensions.k8s.io/bfdprofiles.metallb.io
customresourcedefinition.apiextensions.k8s.io/bgpadvertisements.metallb.io
customresourcedefinition.apiextensions.k8s.io/bgppeers.metallb.io
customresourcedefinition.apiextensions.k8s.io/bgpsessionstates.frrk8s.metallb.io
customresourcedefinition.apiextensions.k8s.io/communities.metallb.io
customresourcedefinition.apiextensions.k8s.io/configurationstates.metallb.io
customresourcedefinition.apiextensions.k8s.io/frrconfigurations.frrk8s.metallb.io
customresourcedefinition.apiextensions.k8s.io/frrk8sconfigurations.frrk8s.metallb.io
customresourcedefinition.apiextensions.k8s.io/frrnodestates.frrk8s.metallb.io
customresourcedefinition.apiextensions.k8s.io/ipaddresspools.metallb.io
customresourcedefinition.apiextensions.k8s.io/l2advertisements.metallb.io
customresourcedefinition.apiextensions.k8s.io/servicebgpstatuses.metallb.io
customresourcedefinition.apiextensions.k8s.io/servicel2statuses.metallb.io
```

There is no ConfigMap to edit: **since v0.13, MetalLB is configured entirely through CRs.** The `*.frrk8s.metallb.io` ones belong to the FRR backend; the rest are the MetalLB API you will use:

| CRD | Answers the question |
|-----|----------------------|
| `IPAddressPool` | *Which* IPs may be handed out, and to which Services? |
| `L2Advertisement` | *Who* announces them with ARP/NDP, on which interfaces/nodes? |
| `BGPPeer` | *Which router* do we peer with, and as which AS? |
| `BGPAdvertisement` | *What* do we advertise over BGP, with which communities/local-pref? |
| `ServiceL2Status` / `ServiceBGPStatus` | *Which node* is announcing a given Service right now? (debugging gold) |
| `ConfigurationState` | *Did my CRs actually get accepted* by the components? |

## Step 4 — Look inside the speaker

```bash
kubectl -n metallb-system get ds metallb-speaker -o jsonpath='{.spec.template.spec.hostNetwork}{"\n"}'
kubectl -n metallb-system get ds metallb-speaker -o jsonpath='{.spec.template.spec.containers[0].securityContext}{"\n"}'
kubectl -n metallb-system get ds metallb-speaker -o jsonpath='{.spec.template.spec.tolerations}{"\n"}'
kubectl -n metallb-system get ds metallb-speaker -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
```

```console
true
{"allowPrivilegeEscalation":false,"capabilities":{"add":["NET_RAW"],"drop":["ALL"]},"readOnlyRootFilesystem":true}
[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master","operator":"Exists"},{"effect":"NoSchedule","key":"node-role.kubernetes.io/control-plane","operator":"Exists"}]
["--port=9120","--log-level=info"]
```

Read that as a security story:

- `NET_RAW` only, everything else dropped — enough to craft ARP replies, not enough to reconfigure the node. (In BGP mode the **frr-k8s** pods hold the `NET_ADMIN` privilege, because FRR genuinely needs to program routes.)
- `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`.
- The tolerations mean the speaker runs on control-plane nodes too — 3 speakers for 3 nodes here.
- Metrics are served on port `9120` (Lesson 8).

## Step 5 — What MetalLB does *not* do

MetalLB is **inert until you give it addresses**. Check:

```bash
kubectl -n metallb-system get ipaddresspools
kubectl get svc whoami
```

```console
No resources found in metallb-system namespace.
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
whoami   LoadBalancer   10.96.233.4   <pending>     80:31559/TCP   2m18s
```

Still `<pending>`. Installing the machinery is not the same as giving it a pool of IPs — that is Lesson 3, and it is two small YAML objects.

> 💡 **This is the #1 real-world "MetalLB is broken" report**, and it is not a bug: no `IPAddressPool` (or a pool that selects nothing) means no addresses, forever. Keep this step in mind for Lesson 8.

## Expected outcome

| What | State |
|------|-------|
| Helm release `metallb` | `deployed`, chart `0.16.1` |
| `metallb-controller` | 1/1, pod IP |
| `metallb-speaker` | 3/3, node IPs, `hostNetwork`, `NET_RAW` |
| `metallb-frr-k8s` | 3/3 (5 containers each), node IPs |
| New CRDs | 13 |
| `whoami` EXTERNAL-IP | **still `<pending>`** |

## Production note

- **Pin the version and read the release notes before upgrading.** v0.16 flipped the default BGP backend to frr-k8s; v0.15 changed how L2 handles memberlist-disabled setups; v0.14 removed the legacy `AddressPool` API. Upgrade deliberately (Lesson 8).
- **The speakers are the only privileged-ish part.** On hardened clusters, review the pod security context; MetalLB v0.15+ already ships `readOnlyRootFilesystem`, dropped capabilities and no privilege escalation.
- **L2 exclusions:** the chart installs a `metallb-excludel2` ConfigMap listing interface patterns the L2 responder must ignore (`^veth.*`, `^cali.*`, `^lxc.*`, …) so it does not answer ARP on container/overlay interfaces. If you add a CNI with a new interface pattern, this is the knob to touch.
- **Webhooks need certificates.** The chart wires up self-signed certs for the two webhook services; if you run a cluster-wide cert manager with strict policies, plan how those certs are issued.

## Next
Continue to [Lesson 3 — Layer 2 mode: your first VIP](../lesson-03-l2/README.md).

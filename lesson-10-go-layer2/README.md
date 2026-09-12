# Lesson 10 — Inside `internal/layer2`

## Glossary
| Term | What it means |
|------|---------------|
| **AF_PACKET socket** | A raw socket that sees Ethernet frames — needed to answer ARP yourself |
| **candidate set** | The nodes eligible to announce a given VIP (alive, not excluded, and with a local endpoint under `Local` policy) |
| **sha256 election** | `sort by sha256(node + "#" + VIP)`, announce if first — stateless and deterministic |
| **gratuitous ARP spam** | Repeating the announcement for a few seconds, because broadcast packets get lost |
| **`spamLoop`** | The goroutine that repeats announcements: every 1100 ms for 5 s per VIP |
| **memberlist / SWIM** | The gossip protocol speakers use to detect dead peers |
| **NDP** | IPv6 neighbour discovery — the same job as ARP, for v6 |
| **drop reason** | Why the responder ignored a frame (`dropReasonARPReply`, `dropReasonEthernetDestination`, …) |

This lesson is the payoff of Part I: every packet and every log line you observed now has a source line, and you will run the election algorithm yourself and match it against what the cluster actually did.

> 🧪 **Lab Hack** = a step that exists only because of the kind simulation — production does it differently or not at all (each tagged step explains why).

## Files
- `election/main.go` — a 50-line reimplementation of MetalLB's L2 election (no dependencies, runs offline).

Work in `.src/metallb` (cloned in Lesson 9).

## Step 1 — The files

```console
internal/layer2/
├── announcer.go        9.5 KB   interface scanning, the spam loop, SetBalancer/DeleteBalancer
├── arp.go              3.4 KB   the ARP responder (raw socket)
├── arp_test.go         4.0 KB   what a valid request looks like, and what gets dropped
├── ndp.go              4.6 KB   the IPv6 equivalent
├── ip_advertisement.go 1.4 KB   "which IP, on which interfaces" value type
├── announcer_test.go   1.4 KB
└── stats.go                     packet counters
```

Two responders (`arp` for v4, `ndp` for v6), one `Announce` coordinator, one small value type describing *what* to announce and *where*. The protocol-specific code is genuinely small; the interesting logic is the decision-making, which lives in the speaker.

## Step 2 — Who is allowed to announce (the candidate set)

`speaker/layer2_controller.go`, `ShouldAnnounce` — the function that decides your VIP's fate:

```go
if !activeEndpointExists(eps) {          // no healthy pods, no announcement
    return "notOwner"
}
adsForService := l2AdsForService(pool.L2Advertisements, svc)
if !adsMatchNodeL2(adsForService, c.myNode) {
    return "noMatchingAdvertisement"      // your L2Advertisement doesn't cover this node
}
speakerMap := c.speakersForAds(l, name, adsForService, nodes)
availableNodes := nodesWithActiveSpeakers(speakerMap)
if svc.Spec.ExternalTrafficPolicy == v1.ServiceExternalTrafficPolicyTypeLocal {
    availableNodes = nodesWithEndpoint(eps, speakerMap)   // ← Lesson 4's ETP experiment
}
```

Three gates, in order: **are there healthy endpoints**, **does an advertisement cover my node**, and **am I in the candidate set**. Every symptom you debugged in Lessons 4–7 is one of these three returning early — and each returns a *reason string* that ends up verbatim in the speaker log.

Then the election itself:

```go
// Sort the slice by the hash of node + load balancer ips. This
// produces an ordering of ready nodes that is unique to all the services
// with the same ip.
sort.Slice(availableNodes, func(i, j int) bool {
    hi := sha256.Sum256([]byte(availableNodes[i] + "#" + ipString))
    hj := sha256.Sum256([]byte(availableNodes[j] + "#" + ipString))
    return bytes.Compare(hi[:], hj[:]) < 0
})

// Are we first in the list? If so, we win and should announce.
if len(availableNodes) > 0 && availableNodes[0] == c.myNode {
    return ""
}
return "notOwner"
```

That is the whole leader election mechanism — the one Lesson 4 described as "stateless". Notice what is *not* there: no lock, no lease, no `etcd` write, no consensus round. Every speaker runs this function on its own copy of the cluster state and must reach the same conclusion. It is `sha256`, not a fancy consistent-hashing ring, and it is sorted lexicographically.

## Step 3 — Predict the election yourself

Our lab recorded these announcements in Lesson 4 (with the control-plane excluded by its node label, so two candidates):

```
whoami   172.19.255.200 → metallb-lab-worker
whoami-b 172.19.255.201 → metallb-lab-worker2
whoami-c 172.19.255.202 → metallb-lab-worker
whoami-d 172.19.255.203 → metallb-lab-worker2
```

The program in this lesson's folder reimplements the function above:

```bash
cd lesson-10-go-layer2/election
go run .
```

```console
candidates: [metallb-lab-worker metallb-lab-worker2]

VIP                ANNOUNCED BY       SORTED CANDIDATE ORDER
172.19.255.200     metallb-lab-worker [metallb-lab-worker metallb-lab-worker2]
172.19.255.201     metallb-lab-worker2 [metallb-lab-worker2 metallb-lab-worker]
172.19.255.202     metallb-lab-worker [metallb-lab-worker metallb-lab-worker2]
172.19.255.203     metallb-lab-worker2 [metallb-lab-worker2 metallb-lab-worker]
```

**It matches the live cluster exactly** — two VIPs each. That is the value of a stateless algorithm: you can reproduce production behaviour on a laptop with the node *names* alone (the IPs on the wire never enter the hash).

Now add the control-plane to the candidate set, as Lesson 7's `ignoreExcludeLB=true` did:

```bash
go run . -nodes metallb-lab-worker,metallb-lab-worker2,metallb-lab-control-plane
```

```console
172.19.255.200     metallb-lab-worker       [metallb-lab-worker metallb-lab-control-plane metallb-lab-worker2]
172.19.255.201     metallb-lab-control-plane [metallb-lab-control-plane metallb-lab-worker2 metallb-lab-worker]
172.19.255.202     metallb-lab-worker       [metallb-lab-worker metallb-lab-control-plane metallb-lab-worker2]
172.19.255.203     metallb-lab-worker2      [metallb-lab-worker2 metallb-lab-worker metallb-lab-control-plane]
```

`172.19.255.201` moves to the control-plane. **Adding a node reshuffles ownership of VIPs** — while *removing* one only affects the VIPs that node owned (Lesson 4's observation). The asymmetry is entirely a property of "sorted by hash, first wins": the list is re-sorted from scratch, and the set of elements determines each element's position.

## Step 4 — The ARP responder

`internal/layer2/arp.go` — the code behind Lesson 3's capture:

```go
func (a *arpResponder) processRequest() dropReason {
	pkt, eth, err := a.conn.Read()
	…
	// Ignore ARP replies.
	if pkt.Operation != arp.OperationRequest {
		return dropReasonARPReply
	}
	// Ignore ARP requests which are not broadcast or bound directly for this machine.
	if !bytes.Equal(eth.Destination, ethernet.Broadcast) && !bytes.Equal(eth.Destination, a.hardwareAddr) {
		return dropReasonEthernetDestination
	}
	// Ignore ARP requests that the announcer tells us to ignore.
	reason := a.announce(pkt.TargetIP, a.intf)
	if reason != dropReasonNone {
		return reason
	}
	…
```

and the reply itself:

```console
level=debug interface=eth0 ip=172.19.255.200 senderIP=172.19.0.5 senderMAC=… responseMAC=1e:63:c1:b5:6f:e9 msg="got ARP request for service IP, sending response"
```

`responseMAC` is `a.hardwareAddr` — **the node's own MAC**. That is why Lesson 3's `ip neigh` showed the VIP pointing at the worker's MAC, and why the reply is a *lie* the node is willing to tell: the address is not configured on that interface anywhere.

The responder is just as strict about what it ignores, which is what makes it safe: replies (someone else's answer), frames addressed elsewhere, and interfaces the announcer excluded.

Where do the exclusions come from? The `metallb-excludel2` ConfigMap from Lesson 2, parsed at startup:

```go
excludeL2ConfigPath = "/etc/metallb/excludel2.yaml"
…
interfacesToExclude, err = parseAnnouncedInterfacesToExclude()
…
InterfaceExcludeRegexp: interfacesToExclude,
```

`^veth.*`, `^cali.*`, `^lxc.*` … — the responder never answers ARP on the CNI's own interfaces. On a cluster with an unusual CNI, this is the list you may need to extend.

## Step 5 — Why the GARP burst looked the way it did

Lesson 4 measured **5 gratuitous ARPs per VIP, ~1.1 s apart, for about 5 seconds**. That is not a coincidence — it is two constants in `internal/layer2/announcer.go`:

```go
func (a *Announce) spamLoop() {
	…
	case s := <-a.spamCh:
		if len(m) == 0 {
			// See https://github.com/metallb/metallb/issues/172 for the 1100 choice.
			ticker.Reset(1100 * time.Millisecond)
		}
		…
		// Set spam stop time to 5 seconds from now.
		m[ipStr] = timedSpam{time.Now().Add(5 * time.Second), s}
```

**1100 ms and 5 s ⇒ 4–5 announcements per VIP.** Millions of hours of production traffic disagreeing with a broadcast packet's reliability is why the repetition exists at all: a single lost GARP frame would leave some clients pointing at a dead node.

```go
case now := <-ticker.C:
	for ipStr, tSpam := range m {
		if now.After(tSpam.until) {
			delete(m, ipStr)     // "We have spammed enough - remove the IP from the map."
		} else {
			a.gratuitous(tSpam.IPAdvertisement)
		}
	}
```

And the burst you captured carried *all four VIPs* because the leadership change enqueued four addresses on the same channel — each one spammed independently, interleaved on the wire.

> 💡 This is the single most valuable habit in this lesson: **measure on the wire, then find the constant.** "MetalLB is spamming ARP" becomes "MetalLB re-announces for 5 s at 1.1 s intervals", which is a fact you can reason about (and change, if you fork it).

## Step 6 — Liveness: memberlist

`internal/speakerlist/speakerlist.go` wraps HashiCorp's memberlist:

```go
memberListConfig := memberlist.DefaultLANConfig()
…
sl.mlEventCh = make(chan memberlist.NodeEvent, 1024)
memberListConfig.Events = &memberlist.ChannelEventDelegate{Ch: sl.mlEventCh}
ml, err := memberlist.Create(memberListConfig)
```

The speaker turns those node events into the `SpeakerList` used by the candidate set (`nodesWithActiveSpeakers`). This is the difference between "the cluster says the node is `NotReady`" (kubelet heartbeats, tens of seconds) and "the other speakers stopped hearing it gossip" (seconds) — which is why Lesson 4's failover began in the *same second* we killed the node.

> ⚠️ **Production gotcha:** memberlist needs **TCP and UDP 7946** reachable *between your nodes*. On a cluster with a strict node firewall, speakers cannot see each other, the candidate set never shrinks, and L2 failover silently stops working while everything still looks green. (In v0.15+ there is also a supported mode with memberlist disabled, where all speakers are assumed alive.)

## Step 7 — Run the tests that pin this behaviour

```bash
go test ./internal/layer2/... -v
```

```console
=== RUN   Test_SetBalancer_AddsToAnnouncedServices
--- PASS: Test_SetBalancer_AddsToAnnouncedServices (0.00s)
=== RUN   TestARPResponder
=== RUN   TestARPResponder/ARP_reply
=== RUN   TestARPResponder/bad_Ethernet_destination
=== RUN   TestARPResponder/OK_(unicast)
=== RUN   TestARPResponder/OK_(broadcast)
=== RUN   TestARPResponder/shouldAnnounce_denies_request
=== RUN   TestARPResponder/shouldAnnounce_allows_request
--- PASS: TestARPResponder (0.00s)
```

Look at the subtest names and compare them with `processRequest`: `ARP reply` is the frame it drops, `bad Ethernet destination` is the frame it ignores, `OK (broadcast)` and `OK (unicast)` are the two cases it answers, and the two `shouldAnnounce` cases are the announcer-level veto. **The test file is a readable specification of the state machine** — 40 lines instead of a protocol RFC.

## Exercises

1. Change the spam window in `announcer.go` (`5 * time.Second` → `1 * time.Second`), rebuild the speaker image (`docker build -t metallb-speaker-lab:v1 speaker/`), load it into kind (`kind load docker-image metallb-speaker-lab:v1`), point the DaemonSet at it, and re-run Lesson 4's GARP experiment. You can now measure your own code on the wire.
2. Add a third node name to the election program and predict which VIPs move *before* you run it. Then check your prediction.
3. `grep -rn 'dropReason' internal/layer2/arp.go` — list all the ways an ARP request is ignored, and think of a real network condition that produces each one.
4. Find `nodesWithEndpoint` and explain, from the code, why `externalTrafficPolicy: Local` shrinks the candidate set (and why Lesson 4's "no endpoints" case killed the VIP).

## Production note

- **`NET_RAW` is the whole privilege requirement for L2 mode.** The responder uses a raw socket; it never changes the node's interfaces, routes or firewall. That is why the speaker's security context in Lesson 2 is so small — and why BGP's FRR-backed modes need more.
- **L2 does not scale with nodes.** The code makes this explicit: exactly one winner is chosen. Adding nodes adds failover options, never bandwidth.
- **Understand the spam window when you tune clients.** If your monitoring flags "ARP storms" on VIP changes, 4–5 frames per VIP per failover is normal.
- **IPv6 uses the same logic via NDP**, so everything here transfers — with the added detail that NDP has no broadcast, and the code joins the solicited-node multicast group per VIP.

## Next
Continue to [Lesson 11 — Write your own Go controller](../lesson-11-go-controller/README.md).

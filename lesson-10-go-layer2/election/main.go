// Lesson 10 — the layer 2 election, reimplemented in 30 lines.
//
// This is the election from speaker/layer2_controller.go, with nothing else
// attached: build the candidate set, sort it by sha256(node + "#" + VIP), and
// announce only if you are first. There is no leader database, no lease and no
// consensus — every speaker computes the same answer from the same inputs.
//
// Run it against this course's lab:
//
//	go run . -nodes metallb-lab-worker,metallb-lab-worker2 \
//	         -ips 172.19.255.200,172.19.255.201,172.19.255.202,172.19.255.203
//
// The output should match what lesson-04 recorded:
//
//	whoami    (.200) -> metallb-lab-worker
//	whoami-b  (.201) -> metallb-lab-worker2
//	whoami-c  (.202) -> metallb-lab-worker
//	whoami-d  (.203) -> metallb-lab-worker2
package main

import (
	"bytes"
	"crypto/sha256"
	"flag"
	"fmt"
	"sort"
	"strings"
)

// elect answers "which node announces this VIP?" — the same computation every
// speaker performs independently.
func elect(candidates []string, vip string) string {
	// Copy: we must not reorder the caller's slice, and the node order in the
	// input must not influence the result.
	sorted := append([]string(nil), candidates...)

	sort.Slice(sorted, func(i, j int) bool {
		hi := sha256.Sum256([]byte(sorted[i] + "#" + vip))
		hj := sha256.Sum256([]byte(sorted[j] + "#" + vip))
		return bytes.Compare(hi[:], hj[:]) < 0
	})
	return sorted[0]
}

func main() {
	nodesFlag := flag.String("nodes", "metallb-lab-worker,metallb-lab-worker2",
		"comma-separated candidate nodes (the ones that may announce)")
	ipsFlag := flag.String("ips", "172.19.255.200,172.19.255.201,172.19.255.202,172.19.255.203",
		"comma-separated VIPs")
	flag.Parse()

	nodes := strings.Split(*nodesFlag, ",")
	ips := strings.Split(*ipsFlag, ",")

	fmt.Printf("candidates: %v\n\n", nodes)
	fmt.Printf("%-18s %-18s %s\n", "VIP", "ANNOUNCED BY", "SORTED CANDIDATE ORDER")
	for _, ip := range ips {
		// Recompute the full order so we can show *why* the winner won.
		order := append([]string(nil), nodes...)
		sort.Slice(order, func(i, j int) bool {
			hi := sha256.Sum256([]byte(order[i] + "#" + ip))
			hj := sha256.Sum256([]byte(order[j] + "#" + ip))
			return bytes.Compare(hi[:], hj[:]) < 0
		})
		fmt.Printf("%-18s %-18s %v\n", ip, elect(nodes, ip), order)
	}

	fmt.Println("\nnote: adding or removing a candidate can change every winner at once —")
	fmt.Println("      that is why lesson-04's failover left the VIPs on the surviving node.")
}

// SPDX-License-Identifier:Apache-2.0

package tests

import (
	"errors"
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/openperouter/openperouter/api/v1alpha1"
	"github.com/openperouter/openperouter/e2etests/pkg/executor"
	"github.com/openperouter/openperouter/e2etests/pkg/frr"
	"github.com/openperouter/openperouter/e2etests/pkg/k8s"
	"github.com/openperouter/openperouter/e2etests/pkg/openperouter"
	corev1 "k8s.io/api/core/v1"
	clientset "k8s.io/client-go/kubernetes"
	"k8s.io/utils/ptr"
)

const Established = true

func validateFRRK8sSessionForHostSession(name string, hostsession v1alpha1.HostSession, established bool, frrk8sPods ...*corev1.Pod) {
	var cidrs []string

	if ipv4CIDR := ptr.Deref(hostsession.LocalCIDR.IPv4, ""); ipv4CIDR != "" {
		cidrs = append(cidrs, ipv4CIDR)
	}
	if ipv6CIDR := ptr.Deref(hostsession.LocalCIDR.IPv6, ""); ipv6CIDR != "" {
		cidrs = append(cidrs, ipv6CIDR)
	}

	Expect(cidrs).NotTo(BeEmpty(), "either IPv4 or IPv6 CIDR must be provided")

	for _, cidr := range cidrs {
		neighborIP, err := openperouter.RouterIPFromCIDR(cidr)
		Expect(err).NotTo(HaveOccurred())

		for _, p := range frrk8sPods {
			By(fmt.Sprintf("checking the session between %s and session %s for CIDR %s", p.Name, name, cidr))
			exec := executor.ForPod(p.Namespace, p.Name, "frr")
			validateSessionWithNeighbor(p.Name, name, exec, neighborIP, established)
		}
	}
}

func validateSessionWithNeighbor(fromName, toName string, exec executor.Executor, neighborIP string, established bool) {
	Eventually(func() error {
		neigh, err := frr.NeighborInfo(neighborIP, exec)
		if err != nil {
			return err
		}
		if !established && neigh.BgpState == "Established" {
			return fmt.Errorf("neighbor from %s to %s - %s is established", fromName, toName, neighborIP)
		}
		if established && neigh.BgpState != "Established" {
			return fmt.Errorf("neighbor %s to %s - %s is not established", fromName, toName, neighborIP)
		}
		return nil
	}, 5*time.Minute, time.Second).ShouldNot(HaveOccurred())
}

func waitForType5Route(exec executor.Executor, prefix string) {
	Eventually(func() error {
		evpn, err := frr.EVPNInfo(exec)
		if err != nil {
			return err
		}
		if !evpn.ContainsType5Prefix(prefix) {
			return fmt.Errorf("Type-5 route for %s not yet present", prefix)
		}
		return nil
	}, 2*time.Minute, time.Second).ShouldNot(HaveOccurred())
}

// waitForNICRecovery waits until the underlay NICs are back in the host
// network namespace on all cluster nodes. After CleanAll deletes the
// underlay, the recovery monitor moves NICs from perouter to host. This
// takes time (especially on non-kind platforms). Calling this before
// creating a new underlay ensures the controller can properly move NICs
// and preserve their IPs.
func waitForNICRecovery(cs clientset.Interface) {
	GinkgoHelper()
	nodes, err := k8s.GetNodes(cs)
	Expect(err).NotTo(HaveOccurred())

	Eventually(func() error {
		for _, node := range nodes {
			exec, err := executor.ForNode(node.Name)
			if err != nil {
				return fmt.Errorf("node %s: %w", node.Name, err)
			}
			for _, nic := range []string{"toswitch1", "toswitch2"} {
				_, err = exec.Exec("ip", "link", "show", nic)
				if err != nil {
					return fmt.Errorf("node %s: %s not in host netns yet", node.Name, nic)
				}
			}
		}
		return nil
	}).WithTimeout(2 * time.Minute).WithPolling(2 * time.Second).Should(Succeed())
}

// validateSessionDownForNeigh validates that the neighbor is down
// or if the session does not exist.
func validateSessionDownForNeigh(exec executor.Executor, neighborIP string) {
	Eventually(func() error {
		neigh, err := frr.NeighborInfo(neighborIP, exec)
		if errors.As(err, &frr.NoNeighborError{}) {
			return nil
		}
		if err != nil {
			return err
		}

		if neigh.BgpState == "Established" {
			return fmt.Errorf("neighbor %s is established: %v", neighborIP, neigh)
		}
		return nil
	}, 2*time.Minute, time.Second).ShouldNot(HaveOccurred())
}

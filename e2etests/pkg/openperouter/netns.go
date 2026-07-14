// SPDX-License-Identifier:Apache-2.0

package openperouter

import (
	"fmt"
	"log"
	"strings"

	"github.com/openperouter/openperouter/e2etests/pkg/executor"
)

const namedNetns = "perouter"

// NamedNetnsExists checks whether /var/run/netns/perouter is present on nodeName.
func NamedNetnsExists(nodeName string) (bool, error) {
	exec, err := executor.ForNode(nodeName)
	if err != nil {
		return false, err
	}
	out, err := exec.Exec("ip", "netns", "list")
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == namedNetns {
			return true, nil
		}
	}
	return false, nil
}

// NamedNetnsHasInterfaceType checks whether the named netns contains at least one
// interface of the given link type (e.g. "vrf", "bridge", "vxlan").
func NamedNetnsHasInterfaceType(nodeName, linkType string) (bool, error) {
	exec, err := executor.ForNode(nodeName)
	if err != nil {
		return false, err
	}
	out, err := exec.Exec("ip", "netns", "exec", namedNetns, "ip", "link", "show", "type", linkType)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(out) != "", nil
}

// DeleteNamedNetns pre-deletes all non-loopback devices inside the perouter
// netns, then runs "ip netns delete perouter" on nodeName.
func DeleteNamedNetns(nodeName string) error {
	e, err := executor.ForNode(nodeName)
	if err != nil {
		return err
	}

	if err := deleteNetnsDevices(e); err != nil {
		log.Printf("pre-deletion of devices failed for %q, proceeding with netns delete: %v", nodeName, err)
	}

	_, err = e.Exec("ip", "netns", "delete", namedNetns)
	return err
}

// UnderlayConfigured checks whether the underlay is configured inside
// the perouter netns on nodeName by looking for the VTEP loopback (lound).
func UnderlayConfigured(nodeName string) bool {
	exec, err := executor.ForNode(nodeName)
	if err != nil {
		return false
	}
	_, err = exec.Exec("ip", "netns", "exec", namedNetns, "ip", "link", "show", "lound")
	return err == nil
}

// UnderlayVethExists checks whether the toswitch interfaces exist on nodeName,
// either in the default netns or inside the perouter netns.
func UnderlayVethsExists(nodeName string) bool {
	exec, err := executor.ForNode(nodeName)
	if err != nil {
		return false
	}
	for _, iface := range []string{"toswitch1", "toswitch2"} {
		if _, err := exec.Exec("ip", "link", "show", iface); err == nil {
			return true
		}
		if _, err := exec.Exec("ip", "netns", "exec", namedNetns, "ip", "link", "show", iface); err == nil {
			return true
		}
	}
	return false
}

// deleteNetnsDevices lists all devices inside the perouter netns and deletes
// them one by one, skipping loopback.
func deleteNetnsDevices(e executor.Executor) error {
	out, err := e.Exec("ip", "netns", "exec", namedNetns, "ip", "-o", "link", "show")
	if err != nil {
		return err
	}

	for _, line := range strings.Split(out, "\n") {
		name, err := ifaceName(line)
		if err != nil {
			log.Printf("could not get interface name from line %v", err)
			continue
		}
		if name == "lo" {
			continue
		}
		if out, err := e.Exec("ip", "netns", "exec", namedNetns, "ip", "link", "delete", name); err != nil {
			if strings.Contains(out, "Cannot find device") {
				continue
			}
			return fmt.Errorf("failed to delete link %q; output %q; error: %v", name, out, err)
		}
	}
	return nil
}

func ifaceName(line string) (string, error) {
	parts := strings.SplitN(line, ": ", 3)
	if len(parts) < 2 {
		return "", fmt.Errorf("unexpected line from 'ip -o link show': %q", line)
	}
	return strings.SplitN(parts[1], "@", 2)[0], nil
}

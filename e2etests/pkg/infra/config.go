// SPDX-License-Identifier:Apache-2.0

package infra

import (
	"encoding/json"
	"fmt"
	"os"
)

const (
	kindLeafIP  = "192.168.11.2"
	kindLeaf2IP = "192.168.12.2"
)

type nodeLinksConfig struct {
	Nodes map[string]nodeConfig `json:"nodes"`
}

type nodeConfig struct {
	IPForKindLeaf  string `json:"ipForKindLeaf"`
	IPForKindLeaf2 string `json:"ipForKindLeaf2"`
}

func RegisterLinks(path string) error {
	registerFabricLinks()

	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading node links config %s: %w", path, err)
	}
	var cfg nodeLinksConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("parsing node links config %s: %w", path, err)
	}

	nodeLeaf1IPs := make(map[string]string, len(cfg.Nodes))
	nodeLeaf2IPs := make(map[string]string, len(cfg.Nodes))
	for name, nc := range cfg.Nodes {
		nodeLeaf1IPs[name] = nc.IPForKindLeaf
		nodeLeaf2IPs[name] = nc.IPForKindLeaf2
	}
	registerNodeLinks(kindLeafIP, kindLeaf2IP, nodeLeaf1IPs, nodeLeaf2IPs)
	return nil
}

// SPDX-License-Identifier:Apache-2.0

package infra

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/openperouter/openperouter/api/v1alpha1"
	"github.com/openperouter/openperouter/e2etests/pkg/openperouter"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type TopologyConfig struct {
	ClabPrefix        string                `json:"clabPrefix,omitempty"`
	Nodes             map[string]NodeConfig `json:"nodes"`
	PeerLeaf1IP       string                `json:"peerLeaf1IP"`
	PeerLeaf2IP       string                `json:"peerLeaf2IP"`
	UnderlayNics      []string              `json:"underlayNics"`
	UnderlayNeighbors []NeighborConfig      `json:"underlayNeighbors"`
}

type NodeConfig struct {
	PeerLeafIP  string `json:"peerLeafIP"`
	PeerLeaf2IP string `json:"peerLeaf2IP,omitempty"`
}

type NeighborConfig struct {
	ASN     int64  `json:"asn"`
	Address string `json:"address"`
}

func LoadTopologyConfig(path string) (*TopologyConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading topology config %s: %w", path, err)
	}
	var cfg TopologyConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing topology config %s: %w", path, err)
	}
	return &cfg, nil
}

func ApplyTopologyConfig(cfg *TopologyConfig) {
	if cfg.ClabPrefix != "" {
		ClabPrefix = cfg.ClabPrefix
		PeerLeaf1 = ClabPrefix + "leafkind1"
		PeerLeaf2 = ClabPrefix + "leafkind2"
		LeafA = ClabPrefix + "leafA"
		LeafB = ClabPrefix + "leafB"
		PeerLeaf1Container.Name = PeerLeaf1
		PeerLeaf2Container.Name = PeerLeaf2
		LeafAContainer.Name = LeafA
		LeafBContainer.Name = LeafB
		reinitFabricLinks()
	}

	nodeLeaf1IPs := make(map[string]string, len(cfg.Nodes))
	nodeLeaf2IPs := make(map[string]string, len(cfg.Nodes))
	for name, nc := range cfg.Nodes {
		nodeLeaf1IPs[name] = nc.PeerLeafIP
		if nc.PeerLeaf2IP != "" {
			nodeLeaf2IPs[name] = nc.PeerLeaf2IP
		} else {
			nodeLeaf2IPs[name] = nc.PeerLeafIP
		}
	}
	RegisterNodeLinks(cfg.PeerLeaf1IP, cfg.PeerLeaf2IP, nodeLeaf1IPs, nodeLeaf2IPs)

	applyUnderlayConfig(cfg)
}

func applyUnderlayConfig(cfg *TopologyConfig) {
	if len(cfg.UnderlayNics) > 0 {
		Underlay.Spec.Nics = cfg.UnderlayNics
	}

	if len(cfg.UnderlayNeighbors) > 0 {
		neighbors := make([]v1alpha1.Neighbor, len(cfg.UnderlayNeighbors))
		for i, n := range cfg.UnderlayNeighbors {
			asn := n.ASN
			addr := n.Address
			neighbors[i] = v1alpha1.Neighbor{
				ASN:     &asn,
				Address: &addr,
			}
		}
		Underlay.Spec.Neighbors = neighbors
	}

	rebuildSingleSessionUnderlay(cfg)
}

func rebuildSingleSessionUnderlay(cfg *TopologyConfig) {
	if len(cfg.UnderlayNics) > 0 {
		SingleSessionUnderlayNic = cfg.UnderlayNics[0]
	}
	if len(cfg.UnderlayNeighbors) > 0 {
		SingleSessionNeighborIP = cfg.UnderlayNeighbors[0].Address
		SingleSessionNeighborASN = cfg.UnderlayNeighbors[0].ASN
	}
}

var (
	SingleSessionUnderlayNic = "toswitch1"
	SingleSessionNeighborIP  = "192.168.11.2"
	SingleSessionNeighborASN = int64(64512)
)

var Underlay = v1alpha1.Underlay{
	ObjectMeta: metav1.ObjectMeta{
		Name:      "underlay",
		Namespace: openperouter.Namespace,
	},
	Spec: v1alpha1.UnderlaySpec{
		ASN:  64514,
		Nics: []string{"toswitch1", "toswitch2"},
		Neighbors: []v1alpha1.Neighbor{
			{
				ASN:     new(int64(64512)),
				Address: new("192.168.11.2"),
			},
			{
				ASN:     new(int64(64513)),
				Address: new("192.168.12.2"),
			},
		},
		EVPN: &v1alpha1.EVPNConfig{
			VTEPCIDR: new("100.65.0.0/24"),
		},
	},
}

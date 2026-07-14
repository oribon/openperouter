# E2E Test Network Topology

## Overview

The E2E tests simulate a data center fabric with spine-leaf routing, EVPN/VXLAN overlays, and cluster nodes running OpenPerOuter as a PE router.

IP source annotations:
- **ip_map** — assigned by `assign_ips` during clab setup (constant across platforms)
- **topology.json** — provided per-platform via `--infra-config` flag

## Network Diagram

```mermaid
graph TB
    subgraph Spine
        spine["spine<br/>ASN 64612"]
    end

    subgraph Fabric Leaves
        leafA["leafA<br/>ASN 64520<br/>VTEP 100.64.0.1"]
        leafB["leafB<br/>ASN 64520<br/>VTEP 100.64.0.2"]
    end

    subgraph Peer Leaves
        peerLeaf1["peerLeaf1<br/>ASN 64512"]
        peerLeaf2["peerLeaf2<br/>ASN 64513"]
    end

    subgraph "Cluster Nodes (OpenPerOuter, ASN 64514)"
        node0["node-0<br/>toswitch1, toswitch2"]
        node1["node-1<br/>toswitch1, toswitch2"]
    end

    subgraph Test Hosts
        hostA_red["hostA_red<br/>192.168.20.2<br/>VRF red"]
        hostA_blue["hostA_blue<br/>192.168.21.2<br/>VRF blue"]
        hostA_default["hostA_default<br/>192.168.22.2"]
        hostB_red["hostB_red<br/>192.169.20.2<br/>VRF red"]
        hostB_blue["hostB_blue<br/>192.169.21.2<br/>VRF blue"]
    end

    spine ---|"192.168.1.0/1<br/>(ip_map)"| leafA
    spine ---|"192.168.1.2/3<br/>(ip_map)"| leafB
    spine ---|"192.168.1.4/5<br/>(ip_map)"| peerLeaf1
    spine ---|"192.168.1.6/7<br/>(ip_map)"| peerLeaf2

    leafA ---|"192.168.20.x<br/>(ip_map)"| hostA_red
    leafA ---|"192.168.21.x<br/>(ip_map)"| hostA_blue
    leafA ---|"192.168.22.x<br/>(ip_map)"| hostA_default
    leafB ---|"192.169.20.x<br/>(ip_map)"| hostB_red
    leafB ---|"192.169.21.x<br/>(ip_map)"| hostB_blue

    peerLeaf1 ---|"toswitch1<br/>(topology.json)"| node0
    peerLeaf1 ---|"toswitch1<br/>(topology.json)"| node1
    peerLeaf2 ---|"toswitch2<br/>(topology.json)"| node0
    peerLeaf2 ---|"toswitch2<br/>(topology.json)"| node1

    style spine fill:#f9f,stroke:#333
    style leafA fill:#bbf,stroke:#333
    style leafB fill:#bbf,stroke:#333
    style peerLeaf1 fill:#bfb,stroke:#333
    style peerLeaf2 fill:#bfb,stroke:#333
    style node0 fill:#fbb,stroke:#333
    style node1 fill:#fbb,stroke:#333
```

## Data flow

1. **ip_map.txt** configures the constant clab fabric (spine, leafA/B, hosts)
2. **topology.json** describes the cluster↔fabric connectivity (varies per platform)
3. The test suite reads `topology.json` to configure BGP peering and neighbor lookups
4. OpenPerOuter on each node peers with the peer leaves via the underlay NICs

## Address sources by component

| Component | IP Source | Example |
|-----------|----------|---------|
| spine ↔ leafA | ip_map.txt | 192.168.1.0/1 |
| spine ↔ leafB | ip_map.txt | 192.168.1.2/3 |
| spine ↔ peerLeaf1 | ip_map.txt | 192.168.1.4/5 |
| spine ↔ peerLeaf2 | ip_map.txt | 192.168.1.6/7 |
| leafA ↔ hostA_red | ip_map.txt | 192.168.20.1/2 |
| leafB ↔ hostB_red | ip_map.txt | 192.169.20.1/2 |
| peerLeaf1 ↔ nodes | topology.json | varies by platform |
| peerLeaf2 ↔ nodes | topology.json | varies by platform |
| Underlay CR neighbors | topology.json | `underlayNeighbors` |
| Underlay CR NICs | topology.json | `underlayNics` |

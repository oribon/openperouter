# E2E Test Infrastructure Topology

This directory contains the topology configuration files used by the E2E test suite.

## Files

### `topology-default.json`

Describes how the cluster nodes connect to the containerlab fabric. This is the **contract** between the infrastructure setup step and the test suite.

Used by the test suite via the `--infra-config` flag. Defaults to `topology-default.json` (kind cluster topology).

**Contents:**
- `nodes` — cluster node names and their IPs on the leaf-facing network
- `peerLeaf1IP` / `peerLeaf2IP` — the peer leaf router IPs that cluster nodes peer with
- `underlayNics` — interface names on cluster nodes used by OpenPerOuter
- `underlayNeighbors` — BGP neighbor config (ASN + address) for the Underlay CR

### `ip_map.txt`

IP assignments for containerlab containers. Used by the `assign_ips` tool during clab setup. Contains spine-to-leaf and leaf-to-host addresses that are **constant across all platforms**.

This file has **no overlap** with `topology.json` — it covers only clab-internal addressing, while `topology.json` covers cluster-to-fabric connectivity.

## Creating a topology for a new platform

1. Set up the containerlab fabric using `ip_map.txt` (same for all platforms)
2. Wire the peer leaf routers to the cluster's network
3. Create the dedicated NICs on cluster nodes (`toswitch1`, `toswitch2`)
4. Discover the actual IPs and write a `topology.json`:

```json
{
  "nodes": {
    "<node-name-1>": {"peerLeafIP": "<node1-IP-on-leaf-network>"},
    "<node-name-2>": {"peerLeafIP": "<node2-IP-on-leaf-network>"}
  },
  "peerLeaf1IP": "<peer-leaf-1-IP>",
  "peerLeaf2IP": "<peer-leaf-2-IP>",
  "underlayNics": ["toswitch1", "toswitch2"],
  "underlayNeighbors": [
    {"asn": 64512, "address": "<peer-leaf-1-IP>"},
    {"asn": 64513, "address": "<peer-leaf-2-IP>"}
  ]
}
```

5. Run tests: `make e2etest INFRA_CONFIG=path/to/topology.json`

See [topology.md](topology.md) for a diagram of the full E2E network setup.

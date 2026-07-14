# E2E Test Infrastructure — Node Links

This directory contains the node links configuration used by the E2E test suite.

## Files

### `nodelink-default.json`

Maps cluster node names to their IPs on the leaf-facing networks. This is the **contract** between the infrastructure setup step and the test suite.

Used by the test suite via the `--nodelink-config` flag. Defaults to `nodelink-default.json` (kind cluster).

## Creating a config for a new platform

1. Set up the containerlab fabric (same for all platforms)
2. Wire the leaf routers to the cluster's network
3. Create the dedicated NICs on cluster nodes (`toswitch1`, `toswitch2`)
4. Assign IPs and write a config JSON:

```json
{
  "nodes": {
    "<node-name-1>": {"ipForKindLeaf": "<node1-IP>", "ipForKindLeaf2": "<node1-IP-leaf2>"},
    "<node-name-2>": {"ipForKindLeaf": "<node2-IP>", "ipForKindLeaf2": "<node2-IP-leaf2>"}
  }
}
```

5. Run tests: `make e2etest NODELINK_CONFIG=path/to/config.json`

See [topology.md](topology.md) for a diagram of the full E2E network setup.

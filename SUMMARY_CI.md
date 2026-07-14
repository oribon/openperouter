# OpenPerOuter E2E CI — Summary of Changes

## Problem

The E2E test suite only runs on kind clusters. Tests hardcode kind container names,
node names, IPs, and use `docker exec` to run commands on nodes. None of this works
on OCP where nodes are VMs, not containers.

## Goal

Make E2E tests run on any platform (kind, OCP, future) without knowing which
platform they're on. External setup provides a topology config file describing
the environment. Tests consume it generically.

---

## Old Flow (kind only)

```
make deploy
  └── clab/setup.sh (11 steps)
       ├── Creates kind cluster
       ├── Deploys clab topology (kind.clab.yml)
       │     kind nodes are ext-container — clab wires them natively
       ├── Assigns IPs to all containers + kind nodes (ip_map.txt + ip_map_nodes.txt)
       └── Deploys OpenPerOuter controller via kustomize

make e2etests
  └── ginkgo runs tests
       ├── executor.ForContainer(nodeName) — docker exec into kind nodes
       ├── Hardcoded node names: KindControlPlane, KindWorker
       ├── Hardcoded leaf IPs in init() — 192.168.11.x, 192.168.12.x
       └── Hardcoded underlay NICs and neighbor IPs
```

## New Flow

### Kind (mostly unchanged)

```
make deploy                    # same as before
make e2etest                   # passes --infra-config=e2etests/infra/topology-default.json
  └── ginkgo runs tests
       ├── BeforeSuite: reads topology config, deploys node-exec-helper DaemonSet
       ├── executor.ForNode(nodeName) — kubectl exec helper pod + nsenter
       ├── Node names, IPs from topology config
       └── Underlay NICs/neighbors from topology config
```

### OCP (new)

```
# Prerequisite: OCP + OpenPerOuter operator deployed (see SETUP_PEROUTER.md)
# dev-scripts config must include EXTRA_NETWORK_NAMES="toswitch1 toswitch2"

openshift/e2e/setup-clab.sh
  ├── Discovers extra network bridges (toswitch1, toswitch2)
  ├── Generates leafkind FRR configs (listen on 192.168.11.0/24, 192.168.12.0/24)
  ├── Deploys clab topology (ocp.clab.yml)
  │     Same fabric as kind, leafkind containers wire to extra bridges via clab
  ├── Assigns IPs to clab containers + leafkind bridge interfaces
  ├── Renames extra NICs inside worker nodes (enp3s0→toswitch1, enp4s0→toswitch2)
  ├── Discovers node IPs on toswitch network (DHCP-assigned by dev-scripts)
  ├── Cleans stale state + restarts router DaemonSet
  │     (matches kind ordering: interfaces exist → FRR starts fresh)
  └── Generates topology.json

make e2etest INFRA_CONFIG=openshift/e2e/topology.json \
  -- --frrk8s-namespace=openshift-frr-k8s
```

---

## What Changed in the Code

### 1. Node command execution: ForContainer → ForNode

**Before:** `executor.ForContainer(nodeName)` — `docker exec <container>`.
Only works when nodes are docker containers (kind).

**After:** `executor.ForNode(nodeName)` — dynamically finds a node-exec-helper
pod on that node, runs `kubectl exec <pod> -- nsenter -t 1 -m -u -i -n <cmd>`.
Works on any platform. The DaemonSet is deployed/torn down by BeforeSuite/AfterSuite.

**Files:** `executor.go`, `netns.go`, `dump_podman.go`, `podman_routers.go`,
`evpn_l2.go`, `resiliency.go`

### 2. Topology config file

**Before:** Node names, IPs, NICs, ASNs hardcoded in Go `init()` and env vars.

**After:** Single JSON file passed via `--infra-config` flag. Contains:
- `clabPrefix` — container name prefix (optional, default `"clab-kind-"`)
- `nodes` — node names and their IPs on the leaf-facing network
- `peerLeaf1IP`/`peerLeaf2IP` — leaf router IPs
- `underlayNics` — interface names for the Underlay CR
- `underlayNeighbors` — BGP neighbor config (ASN + address)

**Files:** `config.go` (new), `topology-default.json` (new), `routers.go`, `underlay.go`,
`suite_test.go`

### 3. Kind-ism removal from test code

**Renamed:**
- `KindLeaf` → `PeerLeaf1`, `KindLeaf2` → `PeerLeaf2`
- `LeafKind1Config` → `PeerLeaf1Config`, etc.
- `LeafKindConfiguration` → `PeerLeafConfiguration`
- `LeafKind` (struct) → `PeerLeaf`

**Removed:**
- `KindControlPlane`, `KindWorker` — tests use k8s API for node names
- `nodes.go` — deleted
- All `OPR_*` env vars

**Files:** `leaf.go`, `nodes.go` (deleted), all test files

### 4. ip_map split

**Before:** Single `ip_map.txt` with clab container IPs AND kind node IPs.

**After:**
- `ip_map.txt` — clab container IPs only (used by both kind and OCP)
- `ip_map_nodes.txt` — kind node IPs (used by kind only)

`08-ip-assignment.sh` runs both files.

### 5. FRRConfiguration namespace fix

**Problem:** The `Updater` overrides ALL CR namespaces to `openperouter-system`.
On OCP, FRR-K8s only watches `openshift-frr-k8s`. FRRConfiguration CRs created
in the wrong namespace are invisible to FRR-K8s.

**Fix:** The Updater skips namespace override for FRRConfiguration objects — they
keep their original namespace from `frrk8s.Namespace`. CleanAll deletes from
`frrk8s.Namespace`.

**File:** `update.go`

### 6. Container runtime fix

**Problem:** `frr/container.go` hardcoded `"docker"` for `docker cp` commands.

**Fix:** Uses `executor.ContainerRuntime` (reads `CONTAINER_RUNTIME` env var).

**File:** `frr/container.go`

### 7. OCP clab topology

`clab/singlecluster/ocp.clab.yml` — Same fabric as `kind.clab.yml` but:
- No kind nodes, no bridge switches
- `toswitch1`/`toswitch2` declared as `kind: bridge` — clab natively wires
  leafkind to the libvirt bridges created by `EXTRA_NETWORK_NAMES`

### 8. OCP setup scripts

- `openshift/e2e/setup-clab.sh` — 11-step setup script
- `openshift/e2e/recover-toswitch.sh` — background NIC recovery monitor
  (equivalent of kind's `check_veths`)
- `openshift/e2e/teardown-clab.sh` — cleanup
- `openshift/e2e/README.md` — usage instructions

### 9. Documentation

- `e2etests/infra/README.md` — topology file documentation
- `e2etests/infra/topology.md` — mermaid diagram of E2E network setup

---

## Key Discoveries During POC

### EXTRA_NETWORK_NAMES — the right approach
dev-scripts supports `EXTRA_NETWORK_NAMES` which provisions extra NICs on every VM
at cluster creation time. Each named network gets its own libvirt bridge. This:
- Eliminates PCI slot issues (NICs provisioned at VM creation, not hot-plugged)
- Eliminates `virsh attach-interface` workaround
- Uses separate bridges per leaf switch (matches kind's bridge-switch model)
- DHCP works naturally (dev-scripts manages the network)

### How OCP setup mirrors kind
With `EXTRA_NETWORK_NAMES`, the OCP topology closely matches kind:

| Component | Kind | OCP |
|-----------|------|-----|
| toswitch1 bridge | clab `leafkind1-sw` (bridge kind) | libvirt `toswitch1` (bridge kind) |
| toswitch2 bridge | clab `leafkind2-sw` (bridge kind) | libvirt `toswitch2` (bridge kind) |
| leafkind wiring | clab creates veth to bridge | clab creates veth to bridge |
| Node NIC | clab creates veth to bridge | dev-scripts provisions NIC on bridge |
| NIC naming | clab names it `toswitch1` | kernel names by PCI slot, setup renames + udev persists |
| IP assignment | `check_veths` assigns static IPs | `setup-clab.sh` assigns static IPs (192.168.11.100+) |
| NIC recovery | `check_veths` recreates veths + assigns IPs | `recover-toswitch.sh` moves NICs + re-assigns IPs |

The key insight: both use **per-leaf-switch bridges** with clab natively attaching
leafkind containers to them. The OCP-specific steps are: renaming kernel-assigned
NIC names to `toswitch1`/`toswitch2` (persisted via udev rules), and running a
NIC recovery monitor (equivalent of kind's `check_veths`).

### Static IPs — critical for NIC lifecycle
On kind, `check_veths` assigns static IPs when creating veths. On OCP, NICs originally
get DHCP IPs from the libvirt network, but NetworkManager is disabled for them (to
prevent interference during netns transitions). Without static IPs, NICs lose their
addresses after a cleanup/recovery cycle:

1. Test cleanup calls `RemoveUnderlay` → NIC stays in perouter with group 0
2. `recover-toswitch.sh` detects group 0 → moves NIC to host netns
3. NIC returns to host **without an IP** (NM is disabled, DHCP doesn't renew)
4. Next test creates Underlay → controller moves NIC to perouter — still no IP
5. FRR can't establish BGP → test timeout

Fix: `setup-clab.sh` assigns deterministic static IPs (192.168.11.100+index) and
`recover-toswitch.sh` re-assigns the static IP from `topology.json` after recovery.

### NIC recovery: why and how
When OpenPerOuter deletes an Underlay, it removes the perouter netns contents but
does NOT return NICs to the default netns. On kind, `check_veths` recreates the
disposable veths. On OCP, the real virtio NICs get stuck in perouter.

`recover-toswitch.sh` runs in the background (started by `setup-clab.sh` step 10),
polls every 5 seconds, and moves stuck NICs back to the default netns. Udev rules
(installed by step 7) auto-rename them back to `toswitch1`/`toswitch2`.

### Router pod ordering
The FRR process starts with `nsenter --net=/var/run/netns/perouter`. If the perouter
netns doesn't exist, the container waits. When the Underlay CR is created, the
controller moves the NIC into a new perouter netns, and FRR starts with the interface
visible. The setup script restarts router pods after NICs are in place to ensure this
ordering — same as kind where OpenPerOuter deploys after interfaces exist.

### FRR-K8s namespace
On kind: `frr-k8s-system`. On OCP (deployed by CNO): `openshift-frr-k8s`.
Configurable via `--frrk8s-namespace` test flag.

### FRRConfiguration namespace
The test Updater creates FRRConfigurations in `frrk8s.Namespace` (not the
openperouter namespace). On kind, FRR-K8s watches all namespaces. On OCP, it only
watches its own namespace. The Updater was fixed to not override the namespace for
FRRConfiguration objects.

---

## POC Test Results

### EVPN L2 Traffic — all IPv4 variants pass

After fixing static IP assignment and `CONTAINER_RUNTIME=podman`:

| Test | Result |
|------|--------|
| EVPN L2: for single stack ipv4 | PASS |
| EVPN L2: OVS bridge autocreate for single stack ipv4 | PASS |
| EVPN L2: OVS bridge existing for single stack ipv4 | PASS |

All 7 reachability checks pass per test (pod↔pod, pod→hostA/B, hostA→pod).

### Earlier multi-test results

| Test | Result |
|------|--------|
| Node Router Status | PASS |
| RawFRRConfig: append raw config | PASS |
| RawFRRConfig: node selector | FAIL (timeout — OCP-specific timing, not infra) |
| RawFRRConfig: remove raw config | PASS |
| Single Session IPv4 | PASS |
| FRR restart (north/south recovery) | PASS |

### Running E2E tests on OCP

```bash
# Prerequisites: setup-clab.sh completed, topology.json generated
cd /root/openperouter/e2etests
KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig \
  CONTAINER_RUNTIME=podman \
  go test -count 1 -v ./suite/ \
    --infra-config=/root/openperouter/openshift/e2e/topology.json \
    --frrk8s-namespace=openshift-frr-k8s \
    -ginkgo.v -ginkgo.focus="for single stack ipv4"
```

`CONTAINER_RUNTIME=podman` is required — OCP servers have podman, not docker.
The executor uses this for `podman exec` / `podman cp` on clab containers.

---

## File Summary

| File | Action | Purpose |
|------|--------|---------|
| `e2etests/pkg/executor/executor.go` | Modified | `ForNode()` + `InitForNode()` |
| `e2etests/pkg/infra/config.go` | New | Topology config struct, loader, `ApplyTopologyConfig` |
| `e2etests/pkg/infra/routers.go` | Modified | `ClabPrefix` as var, `reinitFabricLinks()` |
| `e2etests/pkg/infra/underlay.go` | Modified | Stripped env vars |
| `e2etests/pkg/infra/leaf.go` | Modified | `LeafKind` → `PeerLeaf` renames |
| `e2etests/pkg/infra/nodes.go` | Deleted | Node names from config/k8s API |
| `e2etests/pkg/config/update.go` | Modified | FRRConfig namespace fix |
| `e2etests/pkg/frr/container.go` | Modified | `ContainerRuntime` for `cp` |
| `e2etests/pkg/openperouter/netns.go` | Modified | `ForContainer` → `executor.ForNode` |
| `e2etests/pkg/openperouter/dump_podman.go` | Modified | Same |
| `e2etests/pkg/openperouter/podman_routers.go` | Modified | Same |
| `e2etests/suite/suite_test.go` | Modified | Topology config, helper DaemonSet |
| `e2etests/tests/*.go` | Modified | `PeerLeaf1`, `ForNode`, k8s API nodes |
| `e2etests/infra/topology-default.json` | New | Kind topology defaults |
| `e2etests/infra/README.md` | New | Documentation |
| `e2etests/infra/topology.md` | New | Mermaid diagram |
| `clab/singlecluster/ip_map.txt` | Modified | Node entries removed |
| `clab/singlecluster/ip_map_nodes.txt` | New | Kind node IPs |
| `clab/singlecluster/ocp.clab.yml` | New | OCP clab topology |
| `clab/scripts/08-ip-assignment.sh` | Modified | Runs both ip_map files |
| `openshift/e2e/setup-clab.sh` | New | OCP setup (11 steps + udev + recovery monitor) |
| `openshift/e2e/recover-toswitch.sh` | New | NIC recovery monitor (equivalent of check_veths) |
| `openshift/e2e/teardown-clab.sh` | New | OCP teardown |
| `openshift/e2e/README.md` | New | Usage instructions |

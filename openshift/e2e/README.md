# OpenPerOuter E2E on OpenShift

Run the OpenPerOuter E2E test suite against an OCP cluster deployed via dev-scripts.

## Prerequisites

- RHEL 10 server with OCP installed via dev-scripts (see `SETUP_PEROUTER.md`)
- dev-scripts config must include:
  ```bash
  export EXTRA_NETWORK_NAMES="toswitch1 toswitch2"
  export TOSWITCH1_NETWORK_SUBNET_V4='192.168.11.0/24'
  export TOSWITCH2_NETWORK_SUBNET_V4='192.168.12.0/24'
  ```
- OpenPerOuter operator deployed on the cluster
- FRR-K8s enabled via CNO
- containerlab installed (`bash -c "$(curl -sL https://get.containerlab.dev)"`)
- Go installed (for building leaf config generators and `assign_ips` tool)

## Usage

```bash
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

# 1. Set up the clab fabric and wire it to the OCP cluster
./openshift/e2e/setup-clab.sh

# 2. Run the E2E tests
make e2etest NODELINK_CONFIG=openshift/e2e/nodelink.json \
  -- --frrk8s-namespace=openshift-frr-k8s

# 3. Tear down
./openshift/e2e/teardown-clab.sh
```

## What setup-clab.sh does

1. Discovers extra network bridges (toswitch1, toswitch2) created by dev-scripts
2. Generates peerLeaf FRR configs with matching listen ranges
3. Deploys the containerlab topology (ocp.clab.yml) wired to the bridges
4. Assigns IPs to clab containers
5. Runs setup scripts inside leaf and host containers
6. Renames extra NICs inside worker nodes to `toswitch1`/`toswitch2`
7. Discovers node IPs on the toswitch network
8. Generates `nodelink.json`
9. Cleans stale state and restarts router pods (ensures correct FRR startup order)
10. Verifies connectivity between nodes and peerLeaf routers

## How it works

dev-scripts' `EXTRA_NETWORK_NAMES` provisions extra NICs on every VM at creation
time. Each named network gets its own libvirt bridge. The clab topology references
these bridges via the `kind: bridge` node type, creating a native connection
between leafkind containers and the OCP VMs — same architecture as the kind setup,
just with libvirt bridges instead of clab bridge switches.

## Customization

| Variable | Default | Description |
|----------|---------|-------------|
| `PEERLEAF1_IP` | `192.168.11.2` | IP for peerLeaf1 on toswitch1 network |
| `PEERLEAF2_IP` | `192.168.12.2` | IP for peerLeaf2 on toswitch2 network |

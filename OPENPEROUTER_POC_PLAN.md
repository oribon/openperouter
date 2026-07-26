# OpenPerOuter E2E CI POC — Agent Instructions

## What This Is About

### The Project: OpenPerOuter
OpenPerOuter (https://github.com/openshift-kni/openperouter, docs at https://openperouter.github.io/) is an open-source Provider Edge (PE) router for Kubernetes. It enables K8s nodes to terminate VPN protocols (L3 EVPN, L2 EVPN via VXLAN) and expose a BGP interface to the host network — effectively placing a virtual PE router inside each node. It complements MetalLB and FRR-K8s by providing the EVPN/VXLAN termination layer they peer with.

### The Goal
We need to run OpenPerOuter's E2E test suite against a real OpenShift cluster in CI. Currently the tests only run on kind clusters. The end state is an automated CI job in the `openshift/release` repository (Prow) that provisions a bare metal OCP cluster and runs these tests on every PR to the openperouter repo.

### Why Bare Metal
OpenPerOuter's E2E tests simulate a data center network fabric: spine routers, leaf switches, VXLAN tunnels, BGP EVPN peering. This requires L2 adjacency between the network routers and the K8s nodes — something cloud providers (AWS, GCP) cannot provide because they abstract away L2 networking. Bare metal with libvirt gives us real L2 bridges.

### The CI Model We're Replicating
OpenShift CI already has a pattern for this: **MetalLB E2E**. MetalLB tests run on Equinix bare metal servers where:
1. `dev-scripts` ((https://github.com/openshift-metal3/dev-scripts)) provisions an OCP cluster as libvirt VMs connected to the `ostestbm` bridge (192.168.111.0/24)
2. An external FRR container is attached to the same bridge for BGP peering
3. Tests run against the real cluster

We're doing the same thing, but instead of one FRR container, we deploy a full **containerlab** (clab) spine-leaf topology and wire its leaf routers to the ostestbm bridge.

### How Upstream Tests Work
OpenPerOuter's E2E tests use containerlab to simulate the network fabric:

```
spine (FRR, ASN 64612)
├── leafA (ASN 64520) → hostA_red, hostA_blue, hostA_default (test traffic)
├── leafB (ASN 64520) → hostB_red, hostB_blue (test traffic)
├── leafkind1 (ASN 64512) → kind-control-plane, kind-worker
└── leafkind2 (ASN 64513) → kind-control-plane, kind-worker
```

In the upstream setup, the kind cluster nodes are docker containers managed by clab. Tests interact with:
- **Clab containers** (leaves, spine, hosts) via `docker exec` → `executor.ForContainer()`
- **In-cluster pods** (FRR-K8s, OpenPerOuter) via `kubectl exec` → `executor.ForPod()` / `executor.ForPodInNamedNetns()`
- **Kind nodes** (to check host-level state) via `docker exec` → `executor.ForContainer(nodeName)`

The third category is the problem: on OCP, nodes are VMs, not docker containers. We can't `docker exec` into them.

### The Executor Problem and Solution
The test code has an executor abstraction (`e2etests/pkg/executor/executor.go`) with multiple implementations. Most test operations already work on OCP — `ForContainer()` works for clab containers (they're still containers), `ForPod()` works for cluster pods.

The gap is ~10 call sites where tests exec into kind nodes for host-level operations:
- Check if the `perouter` network namespace exists (`ip netns list`)
- Delete the `perouter` netns (resiliency testing)
- Create/delete OVS bridges (test setup)
- Inspect host-side veth interfaces

**Solution**: Deploy a privileged DaemonSet (`hostPID: true`, `privileged: true`) with one pod per node. Commands run via `kubectl exec <helper-pod> -- nsenter -t 1 -m -u -i -n <cmd>`, which enters the host's PID 1 namespaces (mount, UTS, IPC, network) — equivalent to SSH. This is a well-established K8s pattern.

### Your Role (This POC)
You are proving this works on a real server before we automate it in CI. A second agent will take your documented results and create the Prow CI configuration. Your documentation is the bridge between POC and production CI.

---

## Server Requirements

The server must have:
- **RAM**: 96GB+ minimum (dev-scripts creates 3 masters + 2 workers at 16GB each = 80GB, plus clab containers and host overhead)
- **Disk**: 200GB+ free (for VM images, container images, registry)
- **CPU**: 16+ cores recommended
- **OS**: RHEL10 (fresh install)
- **Network**: Internet access for pulling images and packages

If the server has less than 96GB RAM, reduce VM memory in the dev-scripts config (e.g., `MASTER_MEMORY=12288`, `WORKER_MEMORY=12288`) but this may cause stability issues.

---

## SSH Access to the Server

You have root access to a RHEL10 server. All remote commands run via SSH:

```bash
# Single command
ssh root@<SERVER_IP> "hostname"

# Multi-line script
ssh root@<SERVER_IP> bash -s << 'EOF'
cd /root/dev-scripts
make
EOF

# Copy files to server
scp localfile root@<SERVER_IP>:/root/

# Copy files from server
scp root@<SERVER_IP>:/root/file ./
```

The server IP and root password will be provided to you. Use `sshpass` if password auth is needed:
```bash
export SSHPASS='<password>'
sshpass -e ssh -o StrictHostKeyChecking=no root@<SERVER_IP> "command"
```

Or set up `.ssh/config` for convenience:
```bash
cat >> ~/.ssh/config << EOF
Host poc-server
    HostName <SERVER_IP>
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
```

**Infrastructure work happens on the remote server** (installing OCP, deploying clab, running tests). **Code changes happen locally** (editing openperouter source), then get synced to the server for building and testing. This way code survives if the server goes away.

Workflow:
1. Clone openperouter locally: `git clone https://github.com/openshift-kni/openperouter.git`
2. Edit files locally
3. Sync to server: `rsync -avz /path/to/openperouter/ root@<SERVER_IP>:/root/openperouter/`
4. Build and test on server via SSH
5. Iterate

---

## Your Tasks

1. Install an OpenShift cluster on this server using dev-scripts (virtual mode)
2. Install containerlab and deploy a spine-leaf network topology
3. Wire the containerlab topology to the OCP cluster's libvirt bridge
4. Install OpenPerOuter on the cluster using the operator
5. Implement test code changes to make E2E tests work on OCP (instead of kind)
6. Run a focused E2E test subset and iterate until it passes
7. Document every step so the work can be reproduced in CI

**IMPORTANT**: Document everything. Every command, every config change, every workaround. The output of this POC will be used by a second agent to create the actual CI configuration in the openshift/release repository.

---

## Phase 1: Install OCP Using dev-scripts

dev-scripts (https://github.com/openshift-metal3/dev-scripts) is the tool OpenShift CI uses to provision clusters on bare metal hosts. In `virt` mode, it creates libvirt VMs on the provisioning host itself — no external bare metal nodes needed.

**RHEL10 WARNING**: dev-scripts is tested on RHEL9/CentOS Stream 9. RHEL10 may have compatibility issues (different package names, systemd changes, libvirt version differences). If dev-scripts fails on RHEL10, document the exact error and try these fallbacks in order:
1. Fix the specific incompatibility (preferred)
2. Check if dev-scripts has a RHEL10 branch or recent PRs addressing it
3. As last resort, consider running dev-scripts inside a CentOS Stream 9 container or VM

### 1.1 Disable firewalld and ensure no packet filtering

Before anything else — eliminate firewall as a source of debugging pain:

```bash
systemctl stop firewalld
systemctl disable firewalld
systemctl mask firewalld

# Flush all iptables/nftables rules
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
nft flush ruleset 2>/dev/null || true

# Set default ACCEPT policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Disable SELinux enforcement (can re-enable after POC works)
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Verify
iptables -L -n   # should show all ACCEPT, no rules
firewall-cmd --state 2>&1  # should say "not running"
```

Do this BEFORE installing OCP. dev-scripts manages its own iptables rules for libvirt networking — extra rules from firewalld will interfere. After the POC is working end-to-end, you can document which ports/rules are actually needed.

### 1.2 Install prerequisites

```bash
dnf install -y git sysstat sos make podman python39 jq net-tools gcc
systemctl start sysstat
```

Note: Do NOT install golang from dnf — the version will be too old. See Phase 5 for Go installation.

### 1.3 Configure disk (if server has a second disk)

If the server has a second disk (NVMe or otherwise) larger than 200GB:
```bash
# Find the largest non-root disk
DISK=$(lsblk -dnb -o NAME,SIZE | sort -k2 -n | tail -1 | awk '{print $1}')
mkfs.xfs -f /dev/$DISK
mkdir -p /opt/dev-scripts
mount /dev/$DISK /opt/dev-scripts
```

If no second disk, dev-scripts will use the root filesystem (needs ~100GB free).

### 1.4 Clone dev-scripts

```bash
cd /root
git clone https://github.com/openshift-metal3/dev-scripts.git
cd dev-scripts
```

### 1.5 Create pull secret

You need an OpenShift pull secret. It will be provided to you, or it may already be on the server. Save it as:
```bash
# The pull secret must be at /root/dev-scripts/pull_secret.json
# If not provided, ask the user for it — you cannot proceed without it.
cat > /root/dev-scripts/pull_secret.json << 'EOF'
<PULL_SECRET_CONTENT>
EOF
```

**If no pull secret is provided, STOP and ask for one.** You cannot install OCP without it.

### 1.6 Configure dev-scripts

Create `/root/dev-scripts/config_$USER.sh`:

```bash
cat > /root/dev-scripts/config_$USER.sh << 'EOF'
export IP_STACK=v4
export NETWORK_TYPE=OVNKubernetes
export NUM_WORKERS=2
export WORKER_MEMORY=16384
export WORKER_DISK=50
export MASTER_MEMORY=16384
export MASTER_DISK=50
export ENABLE_LOCAL_REGISTRY=true
EOF
```

Key variables:
- `IP_STACK=v4` — IPv4 only (matching CI metallb config)
- `NETWORK_TYPE=OVNKubernetes` — required for FRR-K8s
- `NUM_WORKERS=2` — OpenPerOuter needs at least 2 worker nodes
- `ENABLE_LOCAL_REGISTRY=true` — local mirror for faster image pulls

Adjust memory values down if the server has less than 96GB RAM.

### 1.7 Run dev-scripts

```bash
cd /root/dev-scripts
make
```

This will take 60-120 minutes. It:
- Installs libvirt, creates VMs
- Creates the `ostestbm` bridge (192.168.111.0/24)
- Deploys OpenShift via IPI installer
- VMs connect to the ostestbm bridge

### 1.8 Set up oc/kubectl access

After dev-scripts completes:

```bash
# Set KUBECONFIG
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
echo 'export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig' >> ~/.bashrc

# oc binary is at:
ls /root/dev-scripts/ocp/ostest/oc
# Add to PATH if not already there
export PATH=/root/dev-scripts/ocp/ostest:$PATH
echo 'export PATH=/root/dev-scripts/ocp/ostest:$PATH' >> ~/.bashrc

# Verify
oc get nodes
oc get co
```

All nodes should be Ready, all cluster operators Available.

### 1.9 Document

Record:
- Exact OCP version installed (`oc version`)
- Number of nodes and their IPs (`oc get nodes -o wide`)
- The ostestbm bridge configuration (`ip addr show ostestbm`)
- Any RHEL10-specific workarounds needed
- Time taken for installation
- Content of your final `config_$USER.sh`
- Full path to `oc` binary and `KUBECONFIG`

---

## Phase 2: Install Containerlab and Deploy Topology

### 2.1 Install containerlab

```bash
bash -c "$(curl -sL https://get.containerlab.dev)"
containerlab version
```

Verify which container runtime is available:
```bash
which podman && echo "podman available"
which docker && echo "docker available"
```

dev-scripts installs podman. Containerlab supports podman via `--runtime podman`. If you encounter issues with podman, you can install docker as a fallback, but try podman first since that's what CI uses.

### 2.2 Clone openperouter

```bash
cd /root
git clone https://github.com/openshift-kni/openperouter.git
cd openperouter
```

### 2.3 Understand the upstream clab topology and setup scripts

Read these files to understand the upstream setup:

1. **`clab/singlecluster/kind.clab.yml`** — the topology file. Contains all nodes, links, and startup configs.

2. **`clab/scripts/`** — 11 sequential setup scripts. For the CI adaptation:
   - **Skip**: `00-environment.sh` (bridge creation — ostestbm exists), `01-registry.sh` (kind registry), `03-kind-configs.sh` (kind cluster), `05-load-images.sh` (kind image loading), `06-kubeconfig-setup.sh` (kind kubeconfig)
   - **Use/adapt**: `02-leaf-configs.sh` (generates FRR configs via Go tools — **run this**, but adapt output IPs), `04-containerlab-deploy.sh` (deploy clab — use CI topology), `09-container-setup.sh` (run setup scripts inside clab containers)
   - **Adapt**: `07-frr-k8s-setup.sh` (use CNO instead), `08-ip-assignment.sh` (use ostestbm subnet), `10-veth-monitoring.sh` (optional)

3. **`clab/scripts/02-leaf-configs.sh`** in particular — it builds Go binaries (`generate_leaf`, `generate_leafkind`) that produce FRR configs. You need to run these generators but adjust the output to use 192.168.111.x IPs instead of 192.168.11.x. Read the Go source for the generators to understand what parameters they accept.

### 2.4 Create CI-adapted topology

Create `clab/singlecluster/kind-ci.clab.yml` based on the upstream topology with these changes:

1. **Remove** all `ext-container` nodes (pe-kind-control-plane, pe-kind-worker)
2. **Remove** leafkind1-sw, leafkind2-sw bridge switches
3. **Remove** all links that reference removed nodes
4. **Keep** spine, leafA, leafB, leafkind1, leafkind2, all agnhost containers
5. **Keep** all spine↔leaf and leaf↔host links

The OCP VMs replace the kind nodes — connectivity is established via veth pairs to the ostestbm bridge (done in step 2.6).

### 2.5 Generate FRR configs for leaves

Run the leaf config generators (from `clab/scripts/02-leaf-configs.sh`), but adapt the leafkind configs to peer with OCP node IPs on 192.168.111.0/24 instead of 192.168.11.0/24.

```bash
# Get OCP node IPs first
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
```

The generated configs go into `clab/leafkind1/frr.conf` and `clab/leafkind2/frr.conf` (or wherever the topology file mounts them as startup configs).

### 2.6 Deploy the topology

```bash
cd /root/openperouter

# Determine runtime
CLI="podman"
command -v docker &>/dev/null && CLI="docker"

# Deploy
containerlab deploy --runtime $CLI --topo clab/singlecluster/kind-ci.clab.yml --reconfigure
```

Verify containers are running:
```bash
containerlab inspect --runtime $CLI --topo clab/singlecluster/kind-ci.clab.yml
```

### 2.7 Run container setup scripts

The upstream `clab/scripts/09-container-setup.sh` runs setup scripts inside each clab container (e.g., `clab/leafA/setup.sh`, `clab/leafB/setup.sh`). These set up VTEP loopbacks, VRFs, VXLAN bridges. Run the applicable ones:

```bash
# Example — adapt based on what 09-container-setup.sh does
$CLI exec clab-kind-leafA /setup.sh
$CLI exec clab-kind-leafB /setup.sh
# hostA, hostB setup scripts too
```

Skip any setup scripts for removed nodes (kind control-plane, worker).

### 2.8 Wire leafkind routers to ostestbm bridge

This is the critical step — connecting the clab leaf routers to the same bridge the OCP VMs are on.

```bash
# --- leafkind1 → ostestbm ---
ip link add veth-lk1-bm type veth peer name veth-lk1-clab
ip link set veth-lk1-bm master ostestbm
ip link set veth-lk1-bm up
LEAFKIND1_PID=$($CLI inspect -f '{{.State.Pid}}' clab-kind-leafkind1)
ip link set veth-lk1-clab netns $LEAFKIND1_PID
nsenter -t $LEAFKIND1_PID -n ip link set veth-lk1-clab up
nsenter -t $LEAFKIND1_PID -n ip addr add 192.168.111.200/24 dev veth-lk1-clab

# --- leafkind2 → ostestbm ---
ip link add veth-lk2-bm type veth peer name veth-lk2-clab
ip link set veth-lk2-bm master ostestbm
ip link set veth-lk2-bm up
LEAFKIND2_PID=$($CLI inspect -f '{{.State.Pid}}' clab-kind-leafkind2)
ip link set veth-lk2-clab netns $LEAFKIND2_PID
nsenter -t $LEAFKIND2_PID -n ip link set veth-lk2-clab up
nsenter -t $LEAFKIND2_PID -n ip addr add 192.168.111.201/24 dev veth-lk2-clab
```

### 2.9 Verify connectivity

```bash
# From leafkind1, ping an OCP node
$CLI exec clab-kind-leafkind1 ping -c 3 192.168.111.10

# From an OCP node, ping leafkind1 (use node-exec-helper once it exists, or oc debug for now)
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') -- chroot /host ping -c 3 192.168.111.200
```

If pings fail, check:
- `ip link show` on the host — are veth interfaces up?
- `bridge link show` — are veths attached to ostestbm?
- `iptables -L FORWARD -n` — any DROP rules? (should be all ACCEPT from step 1.1)

### 2.10 Document

Record:
- Final `kind-ci.clab.yml` content
- Exact veth wiring commands that worked
- FRR config content for leafkind1/2
- Which `clab/scripts/` steps were run and any adaptations
- Connectivity test results
- Container runtime used and version

---

## Phase 3: Install OpenPerOuter on OCP

### 3.1 Enable FRR-K8s via CNO

OpenPerOuter requires FRR-K8s. Deploy it through the Cluster Network Operator:

```bash
oc patch Network.operator.openshift.io cluster --type=merge \
  -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}}}'

# Wait for FRR-K8s daemonset to be ready
until oc rollout status daemonset -n openshift-frr-k8s frr-k8s --timeout 2m 2>/dev/null; do
  echo "Waiting for FRR-K8s..."
  sleep 10
done
```

### 3.2 Build and deploy OpenPerOuter operator

Option A — From source (for development):
```bash
cd /root/openperouter
# Build images
make docker-build
# Load into cluster registry or deploy via manifests
make deploy
```

Option B — Via OLM bundle (closer to CI):
```bash
cd /root/openperouter
make operator-sdk
make bundle-build bundle-push
./_cache/operator-sdk run bundle <bundle-image> -n openperouter-system
```

Choose whichever works on your setup. The goal is to have the openperouter-operator running and CRDs installed.

### 3.3 Verify installation

```bash
oc get pods -n openperouter-system
oc get crd | grep openperouter
oc get pods -n openshift-frr-k8s
```

### 3.4 Document

Record:
- Deployment method used (source vs OLM)
- Exact commands that worked
- Pod status output
- Any image pull or build issues

---

## Phase 4: Implement Test Code Changes

All code changes happen **locally** in your openperouter clone. After each change, sync to the server with `rsync -avz ./openperouter/ root@<SERVER_IP>:/root/openperouter/`, then build and test on the server via SSH. The upstream E2E tests assume kind cluster nodes are docker containers accessible via `docker exec`. On OCP, the nodes are libvirt VMs. Most test code works as-is, but a few functions need adaptation.

### 4.1 Understand the executor abstraction

Read `e2etests/pkg/executor/executor.go`. There are 5 executor types:
- `ForContainer(name)` → `docker exec <name> <cmd>` — for clab containers (stays as-is)
- `ForPod(ns, name, container)` → `kubectl exec <name> -n <ns> -c <container> -- <cmd>` — for in-cluster pods (stays as-is)
- `ForPodInNamedNetns(ns, name, container, path)` → `kubectl exec ... -- nsenter --net=<path> <cmd>` — for pods in named netns (stays as-is)
- `ForPodmanInContainer(outer, inner)` → `docker exec <outer> podman exec <inner> <cmd>` — host mode only (not used in pod mode)
- `Host` → direct host command

Note: The `ContainerRuntime` variable in executor.go defaults to `"docker"`. On the server, you may need to set `CONTAINER_RUNTIME=podman` environment variable so `ForContainer()` uses podman instead of docker.

### 4.2 Add ForNode() executor

Add a new executor type for host-level operations on OCP nodes. This uses a privileged DaemonSet with `nsenter -t 1 -m -u -i -n` to enter the host's namespaces.

Add to `e2etests/pkg/executor/executor.go`:

```go
type nodeExecutor struct {
	namespace string
	podName   string
}

func ForNode(namespace, podName string) Executor {
	return &nodeExecutor{namespace: namespace, podName: podName}
}

func (e *nodeExecutor) Exec(cmd string, args ...string) (string, error) {
	if Kubectl == "" {
		return "", errors.New("the kubectl parameter is not set")
	}
	nsenterArgs := []string{"exec", e.podName, "-n", e.namespace, "-c", "nsenter", "--",
		"nsenter", "-t", "1", "-m", "-u", "-i", "-n", cmd}
	fullargs := append(nsenterArgs, args...)
	out, err := exec.Command(Kubectl, fullargs...).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("exec on node via pod %s/%s failed: %w. Output: %s",
			e.namespace, e.podName, err, string(out))
	}
	return string(out), nil
}
```

### 4.3 Create node-exec-helper DaemonSet

Create `e2etests/manifests/node-exec-helper.yaml`:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exec-helper
  namespace: openperouter-system
spec:
  selector:
    matchLabels:
      app: node-exec-helper
  template:
    metadata:
      labels:
        app: node-exec-helper
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: nsenter
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["sleep", "infinity"]
        securityContext:
          privileged: true
```

Deploy it:
```bash
oc apply -f e2etests/manifests/node-exec-helper.yaml
oc rollout status daemonset -n openperouter-system node-exec-helper
```

Verify it works:
```bash
# Get a helper pod name
HELPER_POD=$(oc get pods -n openperouter-system -l app=node-exec-helper -o jsonpath='{.items[0].metadata.name}')

# Test: list network namespaces on the node
oc exec -n openperouter-system $HELPER_POD -c nsenter -- nsenter -t 1 -m -u -i -n ip netns list
```

### 4.4 Build node-to-pod mapping

You need a way to map K8s node names to their corresponding `node-exec-helper` pods. Add a helper function or do it in test setup:

```go
func nodeExecHelperPods(cs clientset.Interface) (map[string]string, error) {
	pods, err := k8s.PodsForLabel(cs, "openperouter-system", "app=node-exec-helper")
	if err != nil {
		return nil, err
	}
	m := make(map[string]string)
	for _, p := range pods {
		m[p.Spec.NodeName] = p.Name
	}
	return m, nil
}
```

### 4.5 Reroute netns.go functions

File: `e2etests/pkg/openperouter/netns.go`

All 6 functions currently use `executor.ForContainer(nodeName)`. Change them based on what they actually need:

**Can use ForPodInNamedNetns (openperouter pod has access to perouter netns):**
- `NamedNetnsHasInterfaceType()` — runs `ip link show type <type>` in perouter netns
- `UnderlayConfigured()` — runs `ip link show lound` in perouter netns

**Must use ForNode (needs host-level access):**
- `NamedNetnsExists()` — runs `ip netns list` on host
- `DeleteNamedNetns()` — runs `ip netns delete perouter` on host
- `UnderlayVethsExists()` — checks interfaces in both host netns and perouter netns
- `deleteNetnsDevices()` — deletes devices in perouter netns (part of delete flow)

**Suggested approach**: Add a `NodeExecutorFunc` that can be set at test setup time:

```go
// Package-level variable, set during test init
var NodeExec func(nodeName string) executor.Executor

func init() {
	// Default: docker exec into container (upstream kind mode)
	NodeExec = executor.ForContainer
}
```

Then in test setup for CI mode:
```go
// Set up ForNode executors using the DaemonSet pods
helperPods, _ := nodeExecHelperPods(cs)
openperouter.NodeExec = func(nodeName string) executor.Executor {
	podName := helperPods[nodeName]
	return executor.ForNode("openperouter-system", podName)
}
```

And change `netns.go` functions from `executor.ForContainer(nodeName)` to `NodeExec(nodeName)`.

### 4.6 Reroute OVS bridge operations

Files: `e2etests/tests/singlesession.go`, `e2etests/tests/evpn_l2.go`

These create/delete OVS bridges on nodes using `executor.ForContainer(nodeName)`. Change to use `NodeExec(nodeName)` (or `ForNode()` directly).

### 4.7 Handle infra/nodes.go constants

File: `e2etests/pkg/infra/nodes.go`

Currently:
```go
const (
    KindControlPlane = "pe-kind-control-plane"
    KindWorker       = "pe-kind-worker"
)
```

These are kind container names. On OCP, node names come from `oc get nodes` (e.g., `ostest-master-0`, `ostest-worker-0-abcde`). The test code needs to discover node names dynamically instead of using hardcoded constants. Check where `infra.KindControlPlane` and `infra.KindWorker` are used and make them configurable (e.g., via environment variables or test flags).

### 4.8 Handle infra/routers.go link topology

File: `e2etests/pkg/infra/routers.go`

The `init()` function hardcodes link IPs between leafkind routers and kind nodes (192.168.11.x, 192.168.12.x). For OCP on ostestbm, these need to be 192.168.111.x. Make these configurable or add CI-mode overrides.

### 4.9 Document

For EVERY file you change, record:
- Original code
- New code
- Why the change was needed
- Whether it's a CI-only change or improves the code generally
- Save a unified diff: `cd /root/openperouter && git diff > /root/openperouter-changes.patch`

---

## Phase 5: Run Focused E2E Tests

### 5.1 Install Go

The openperouter project requires Go 1.26+. Do NOT use `dnf install golang` — the version will be too old.

```bash
# Check required version
grep '^go ' /root/openperouter/go.mod

# Install the required version (adjust version as needed)
GO_VERSION=1.26.3
curl -LO https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
export PATH=/usr/local/go/bin:$PATH
echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc
go version
```

### 5.2 Install ginkgo

```bash
cd /root/openperouter
go install github.com/onsi/ginkgo/v2/ginkgo@latest
export PATH=$PATH:$(go env GOPATH)/bin
echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.bashrc
```

### 5.3 Set CONTAINER_RUNTIME

If the server uses podman (likely), set the environment variable so the executor uses podman for `ForContainer()` calls:

```bash
export CONTAINER_RUNTIME=podman
```

### 5.4 Run a minimal test first

Start with the simplest possible test to validate the plumbing works. Look for a test that:
- Creates a basic OpenPerOuter configuration (single session, single VNI)
- Validates BGP peering establishes between leafkind and OCP nodes
- Checks route advertisement

```bash
cd /root/openperouter

# Find available test names
grep -r 'Describe\|It(' e2etests/tests/ | head -30

# Run a focused test
OC_PATH=$(which oc)
ginkgo -v --timeout=1h --focus="<test name pattern>" ./e2etests/suite -- \
  --kubectl=$OC_PATH
```

If no specific test can be isolated, try running the full suite and see what passes:
```bash
ginkgo -v --timeout=3h ./e2etests/suite -- --kubectl=$OC_PATH
```

### 5.5 Iterate on failures

For each failure:
1. Read the error message
2. Identify which executor call failed
3. Determine if it's a ForContainer/ForNode/ForPod routing issue
4. Fix and re-run

Common failure patterns to expect:
- `ForContainer(nodeName)` failing because the node isn't a docker/podman container → needs ForNode() rerouting
- FRR config mismatches (wrong peer IPs, wrong ASN) → update leafkind FRR configs
- Network unreachable between clab containers and OCP pods → check ostestbm wiring
- Timeout waiting for BGP sessions → check FRR logs on both sides
- `CONTAINER_RUNTIME` not set → ForContainer uses docker but only podman exists

### 5.6 Debug tools

```bash
# Check FRR state on a clab leaf
$CLI exec clab-kind-leafkind1 vtysh -c "show bgp summary"
$CLI exec clab-kind-leafkind1 vtysh -c "show bgp l2vpn evpn"

# Check FRR-K8s state on OCP
FRRPOD=$(oc get pods -n openshift-frr-k8s -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-frr-k8s $FRRPOD -c frr -- vtysh -c "show bgp summary"

# Check OpenPerOuter pods
oc logs -n openperouter-system -l app=router --all-containers

# Check node-exec-helper works
HELPER=$(oc get pods -n openperouter-system -l app=node-exec-helper -o jsonpath='{.items[0].metadata.name}')
oc exec -n openperouter-system $HELPER -c nsenter -- nsenter -t 1 -m -u -i -n ip netns list

# Check ostestbm bridge state
ip addr show ostestbm
bridge link show
bridge fdb show br ostestbm
```

### 5.7 Document

Record:
- Which tests pass and which fail
- Root cause of each failure
- Fix applied for each failure
- Final test command that produces passing results
- Total test runtime

---

## Phase 6: Final Documentation

Create a file `/root/POC_RESULTS.md` with:

### Section A: OCP Installation
- Exact commands used to install OCP via dev-scripts
- Final `config_$USER.sh` content
- Any RHEL10-specific workarounds
- OCP version and node details (names, IPs)
- Path to `oc` binary and `KUBECONFIG`

### Section B: Containerlab Topology
- Final `kind-ci.clab.yml` content
- Which `clab/scripts/` steps were run and how they were adapted
- FRR config content for leafkind1 and leafkind2
- Veth wiring commands
- Container runtime used and version

### Section C: OpenPerOuter Installation
- Deployment method and commands
- FRR-K8s enablement via CNO
- How the node-exec-helper DaemonSet was deployed

### Section D: Code Changes
- Complete diff: `cd /root/openperouter && git diff`
- For each changed file: what changed and why
- Categorize changes as:
  - **Must have for OCP CI** — required for tests to run on OCP instead of kind
  - **Nice to have** — improvements discovered during POC
  - **Temporary workaround** — hacks that should be done properly later

### Section E: Test Results
- Which tests pass
- Which tests still fail and why
- Recommended test subset for initial CI (specific test names or label filter)
- Final test execution command

### Section F: CI Reproduction Steps
- Step-by-step instructions to reproduce the entire setup from scratch
- Estimated time for each phase
- Known issues and workarounds
- Environment variables needed (`KUBECONFIG`, `CONTAINER_RUNTIME`, `PATH`)

---

## Key Reference Files

In the openshift/release repository (for understanding CI patterns):
- `ci-operator/step-registry/baremetalds/devscripts/setup/baremetalds-devscripts-setup-commands.sh` — how CI installs OCP
- `ci-operator/step-registry/baremetalds/metallb-e2e/test/baremetalds-metallb-e2e-test-commands.sh` — how MetalLB E2E runs in CI
- `ci-operator/step-registry/baremetalds/e2e/ovn/bgp/pre/baremetalds-e2e-ovn-bgp-pre-commands.sh` — how CI wires external containers to ostestbm bridge

In the openperouter repository:
- `clab/singlecluster/kind.clab.yml` — upstream clab topology (base for CI adaptation)
- `clab/scripts/` — 11-step setup scripts (reference for what needs adapting)
- `clab/scripts/02-leaf-configs.sh` — FRR config generators (Go tools, must run and adapt)
- `e2etests/pkg/executor/executor.go` — executor abstraction (add ForNode here)
- `e2etests/pkg/openperouter/netns.go` — 6 functions to reroute
- `e2etests/pkg/infra/nodes.go` — hardcoded kind node names (make configurable)
- `e2etests/pkg/infra/routers.go` — hardcoded link topology IPs (adapt for 192.168.111.x)
- `e2etests/tests/singlesession.go` — OVS bridge ops on nodes
- `e2etests/tests/evpn_l2.go` — OVS bridge ops on nodes

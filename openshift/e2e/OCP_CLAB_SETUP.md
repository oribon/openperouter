# OCP Clab Setup — Step-by-Step Justification

Every step in `setup-clab.sh` mapped against its upstream kind equivalent, with an explanation of why OCP needs it or why OCP does it differently.

## Upstream Kind Pipeline

The kind CI runs `clab/setup.sh` which orchestrates scripts `00` through `10`:

| Script | What | OCP Equivalent |
|--------|------|----------------|
| `00-environment.sh` | Creates bridges (`leafkind1-sw`, `leafkind2-sw`), checks for kind binary | **Step 1**: Discovers pre-existing libvirt bridges |
| `01-registry.sh` | Starts local Docker registry for kind | **Not needed**: OCP uses real registries |
| `02-leaf-configs.sh` | Generates FRR configs for leafA, leafB, leafkind1, leafkind2 | **Step 2**: Same — generates identical FRR configs |
| `03-kind-configs.sh` | Generates kind cluster YAML | **Not needed**: OCP provisioned by dev-scripts |
| `04-containerlab-deploy.sh` | Deploys clab topology | **Step 4**: Same — deploys `ocp.clab.yml` instead of `kind.clab.yml` |
| `05-load-images.sh` | Loads images into kind nodes | **Not needed**: OCP pulls from registries |
| `06-kubeconfig-setup.sh` | Extracts kubeconfig from kind | **Not needed**: kubeconfig from dev-scripts |
| `07-frr-k8s-setup.sh` | Deploys frr-k8s + Multus + copies CNI binaries | **Not needed**: OCP enables frr-k8s via CNO, Multus built-in |
| `08-ip-assignment.sh` | Assigns IPs to clab containers + kind nodes | **Steps 5+9**: Assigns IPs to clab containers AND OCP node NICs separately |
| `09-container-setup.sh` | Runs `/setup.sh` in clab containers | **Step 6**: Same |
| `10-veth-monitoring.sh` | Starts `check_veths` daemon | **Not needed**: OCP uses real NICs, no veths to monitor |

## setup-clab.sh Steps — Justified

### Step 1: Discover extra network bridges
```bash
TOSWITCH1_BRIDGE=$(virsh net-info toswitch1 | grep Bridge | awk '{print $2}')
```
**Kind equivalent:** `00-environment.sh` creates bridges `leafkind1-sw`/`leafkind2-sw` with `ip link add type bridge`.

**Why OCP is different:** On kind, clab creates the bridges. On OCP, dev-scripts creates libvirt networks via `EXTRA_NETWORK_NAMES="toswitch1 toswitch2"`. Each libvirt network has a bridge (e.g., `virbr3`). We discover the bridge name because clab's `kind: bridge` node type needs the exact Linux bridge name. Kind's `00-environment.sh` hardcodes the bridge names because it creates them.

**Necessary:** Yes.

### Step 1b: Disable DHCP on extra networks
```bash
kill $(cat /var/run/libvirt/network/${net}.pid)
```
**Kind equivalent:** None — kind bridges don't run DHCP.

**Why OCP needs this:** dev-scripts enables dnsmasq DHCP on each libvirt network by default. DHCP assigns IPs that compete with our static assignments and expire after 60 minutes, silently breaking routing mid-test. We kill dnsmasq but don't `virsh net-destroy` (which would disconnect VMs from the bridge).

**Necessary:** Yes. Without this, tests break after ~60 minutes when DHCP leases expire.

### Step 2: Generate FRR configs
```bash
./generate_leaf_config/generate_leafkind -leaf singlecluster/leafkind1 -asn 64512 ...
```
**Kind equivalent:** `02-leaf-configs.sh` — identical commands, identical parameters.

**Why same:** The fabric topology (leafA, leafB, spine, leafkind1, leafkind2) is the same on both platforms. The leafkind FRR configs use `interface toswitch1` for IS-IS and `bgp listen range 192.168.11.0/24` for dynamic peers — both work identically because the clab endpoint naming matches (`leafkind1:toswitch1`).

**Necessary:** Yes.

### Step 3: Enable podman socket
```bash
systemctl enable --now podman.socket
```
**Kind equivalent:** None — kind uses Docker, socket is always running.

**Why OCP needs this:** containerlab with `--runtime podman` requires the podman socket. RHEL/RHCOS doesn't enable it by default.

**Necessary:** Yes (one-liner, harmless).

### Step 4: Deploy clab topology
```bash
containerlab deploy --runtime podman --topo ocp.clab.yml --reconfigure
```
**Kind equivalent:** `04-containerlab-deploy.sh` — same command, different topology file and runtime.

**Why OCP is different:** Uses `ocp.clab.yml` (libvirt bridge references, no kind nodes) instead of `kind.clab.yml`. Uses `--runtime podman` instead of Docker.

**Necessary:** Yes.

### Step 5: Assign IPs to clab containers + MTU fix
```bash
go run tools/assign_ips/assign_ips.go -file ip_map_ocp.txt -engine "sudo podman"
ip link set dev toswitch1 mtu 1500   # on leafkind1/2
ip addr add 192.168.11.2/24 dev toswitch1  # on leafkind1
```
**Kind equivalent:** `08-ip-assignment.sh` — same `assign_ips` tool, different ip_map file (`ip_map.txt` vs `ip_map_ocp.txt`).

**Why OCP is different:**
- **ip_map_ocp.txt** — same as kind's `ip_map.txt` for spine/leaf/host IPs, but excludes kind node IPs (those are assigned in step 9 via nsenter, not via clab exec).
- **MTU fix** — kind bridges are at MTU 9500 (clab default). Libvirt bridges are MTU 1500. Clab creates leafkind's `toswitch1` veth at MTU 9500. IS-IS PDUs from leafkind1 get dropped by the 1500-MTU libvirt bridge. Must match MTU.
- **Leafkind bridge IPs** — on kind, the `ip_map.txt` assigns leafkind IPs on the bridge-facing interfaces because those interfaces are in the same ip_map. On OCP, leafkind's bridge-facing interface (`toswitch1`) is created by a clab link to a `kind: bridge` node — it's not in the upstream ip_map. We assign manually.

**Necessary:** Yes. MTU fix is critical (IS-IS breaks without it). Manual leafkind IP assignment is needed because the upstream ip_map doesn't cover bridge-facing interfaces.

### Step 5b: rp_filter on clab containers + IPv6 forwarding
```bash
for c in spine leafA leafB leafkind1 leafkind2 leafSRV6; do
    podman exec $c sh -c 'for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f; done'
done
podman exec clab-kind-spine sysctl -qw net.ipv6.conf.all.forwarding=1
```
**Kind equivalent:** None explicit — on kind, rp_filter defaults to 0 in container network namespaces.

**Why OCP needs this:** RHCOS defaults `rp_filter=1`. Clab containers on RHCOS inherit this from the host. VXLAN traffic is asymmetric (forward via leafkind1, return via leafkind2). Strict rp_filter drops the return. IPv6 forwarding on spine is needed for IS-IS transit between leafkind and leafSRV6.

**Necessary:** Yes. Both rp_filter and IPv6 forwarding. Verified by packet tracing — without these, EVPN and SRV6 data plane break.

### Step 6: Run container setup scripts
```bash
for c in leafA leafB leafSRV6 hostA_red ...; do
    podman exec clab-kind-${c} /setup.sh
done
```
**Kind equivalent:** `09-container-setup.sh` — identical logic, iterates over same containers.

**Why same:** The clab containers (leafA, leafB, hosts, leafSRV6) are the same on both platforms. Their setup scripts configure loopback IPs, VRFs, routes, SRV6 locators — all fabric-internal, unrelated to the K8s platform.

**Necessary:** Yes.

### Step 7: Clean stale CRs
```bash
oc delete underlay --all -n openshift-openperouter-system
oc delete l3vni --all -n openshift-openperouter-system
...
```
**Kind equivalent:** None — kind creates a fresh cluster each time. No stale CRs possible.

**Why OCP needs this:** OCP cluster persists across test runs. Previous test debris (old underlays, VNIs, FRRConfigurations) can conflict. Must clean before creating bootstrap underlay.

**Necessary:** Yes. Should also clean `l3vpn`, `l3passthrough`, `rawfrrconfig` (currently missing).

### Step 8: Rename NICs + udev rules
```bash
virsh domiflist "${vm_name}" | grep "toswitch${i}" | awk '{print $5}'  # get MAC
echo 'SUBSYSTEM=="net", ATTR{address}=="$MAC", NAME="toswitch${i}"' > /etc/udev/rules.d/70-toswitch${i}.rules
ip link set $IFACE name toswitch${i}
```
**Kind equivalent:** None — kind nodes are containers. Clab names their veths directly in the topology YAML (`pe-kind-worker:toswitch1`).

**Why OCP needs this:** Libvirt assigns virtio NICs with kernel-generated names (enp3s0, enp4s0). The names are unpredictable and change across reboots. Tests and the underlay CR reference `toswitch1`/`toswitch2` by name. Udev rules persist the rename across reboots. `nmcli device set managed no` prevents NetworkManager from reconfiguring the NICs.

**Necessary:** Yes. Without this, the underlay CR can't find the interfaces.

### Step 9: Assign static IPs + generate nodelink.json
```bash
ip addr replace ${TS1_V4}/24 dev toswitch1   # on OCP nodes
ip -6 addr add ${TS1_V6}/64 dev toswitch1
```
**Kind equivalent:** `08-ip-assignment.sh` assigns IPs to kind nodes via `docker exec pe-kind-worker ip addr add ...`. The IP map file contains the kind node entries.

**Why OCP is different:** OCP nodes are VMs, not containers. We can't `docker exec` into them. We use `nsenter` via controller pods to run commands in the node's host netns. The nodelink.json is also generated here (kind's `nodelink-default.json` is static/checked-in because kind always has the same 2 nodes with the same IPs).

**Necessary:** Yes. Both IP assignment and nodelink generation are required.

### ~~Step 10: Restart router pods~~ (REMOVED)
```bash
oc rollout restart daemonset router -n openshift-openperouter-system
```
**Status:** Removed from setup-clab.sh.

**Why removed:** Causes FRR crashloop — the old FRR writes PID lockfiles to `/var/run/frr/` inside perouter netns (host filesystem). When the new pod starts, FRR finds the stale lock and exits with `Could not lock pid_file`. The controller's reloader handles FRR config when the test suite creates underlays — no restart needed.

### ~~Step 11: Create bootstrap underlay~~ (REMOVED)
```bash
oc apply -f - <<EOF
kind: Underlay
spec:
  interfaces: [toswitch1, toswitch2]
  neighbors: [leafkind1, leafkind2]
  tunnelEndpoint: {cidrs: ["100.65.0.0/24"]}
EOF
```
**Status:** Removed from setup-clab.sh.

**Why removed:** Kind doesn't create a bootstrap underlay either — the test suite's `BeforeAll` creates underlays as needed. The bootstrap was added to support step 13 (verify connectivity) and to prevent router pod unhealthiness, but: (a) step 13 is also removed, (b) router pods are fine without an underlay — they wait for perouter, and the first test triggers its creation.

### Step 12: rp_filter in perouter
```bash
ip netns exec perouter sysctl -qw net.ipv4.conf.default.rp_filter=0 net.ipv4.conf.all.rp_filter=0
```
**Kind equivalent:** None — kind nodes default to rp_filter=0.

**Why OCP needs this:** RHCOS defaults `rp_filter=1` on ALL new interfaces, including those created by the controller inside perouter (vni100, br-pe-100, etc.). Must set `default=0` and `all=0` so new interfaces inherit rp_filter=0 automatically. The step 5b rp_filter only covers clab containers, not the perouter netns inside OCP nodes.

**Necessary:** Yes. Without this, VXLAN return traffic is dropped on newly-created VNI interfaces.

### ~~Step 13: Verify connectivity~~ (REMOVED)
```bash
ping -c 1 -W 2 "${PEERLEAF1_IP}"
```
**Status:** Removed from setup-clab.sh.

**Why removed:** Required the bootstrap underlay (step 11) to have NICs in perouter and BGP up. With step 11 removed, this ping would always fail. Kind doesn't do a connectivity check either — it relies on the test suite to catch issues.

## Files

| File | Status | Purpose |
|------|--------|---------|
| `setup-clab.sh` | **Keep** | Main setup script — all steps justified above |
| `ocp.clab.yml` | **Keep** | Clab topology — same fabric as kind but with libvirt bridge references |
| `ip_map_ocp.txt` | **Keep** | IP assignments for clab containers (spine, leafA/B, hosts, leafSRV6) |
| `recover-toswitch.sh` | **Deleted** | Leftover from iteration where we thought NICs needed active recovery. Controller handles this natively. |
| `teardown-clab.sh` | **Deleted** | Wrong topology path, stale veth cleanup from old approach. Teardown is just `containerlab destroy --runtime podman --topo openshift/e2e/ocp.clab.yml`. |
| `README.md` | **Needs update** | Outdated test command. Should match OCP_CI_STATUS.md Phase 4. |

## Stale file in wrong location

`clab/singlecluster/ocp.clab.yml` exists but is outdated — missing SRV6 containers, uses old `leafkind1:eth2` naming (broken for IS-IS). Our working copy is `openshift/e2e/ocp.clab.yml`. The stale file should be removed or updated, but it's in upstream territory.

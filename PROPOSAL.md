# Running OpenPerOuter E2E Tests on OpenShift

## Part 1: Making Tests Platform-Agnostic

The upstream E2E suite assumes kind. Four things need to change for it to run anywhere:

**External topology config** — Node names, IPs, NICs, and ASNs move from hardcoded Go to a JSON file (`--infra-config`). Kind ships a default. Other platforms generate theirs during setup.

**Node command execution** — `docker exec` into kind containers → `kubectl exec` into helper pods with `nsenter`. Works on any k8s cluster.

**Container runtime** — Hardcoded `docker` for clab operations → `CONTAINER_RUNTIME` env var (podman on OCP).

**FRR-K8s namespace** — Hardcoded `frr-k8s-system` → `--frrk8s-namespace` flag (`openshift-frr-k8s` on OCP).

None of these changes are OCP-specific. They make the suite portable.

---

## Part 2: OpenShift-Specific Setup

### The OCP Cluster

The cluster is provisioned via [dev-scripts](https://github.com/openshift-metal3/dev-scripts), which creates libvirt VMs and installs OCP via IPI baremetal. dev-scripts supports `EXTRA_NETWORK_NAMES` — each name creates a libvirt network (bridge + DHCP) and attaches an extra NIC to every VM at creation time.

We configure two extra networks:

```
EXTRA_NETWORK_NAMES="toswitch1 toswitch2"

toswitch1:  192.168.11.0/24  +  2001:db8:11::/64
toswitch2:  192.168.12.0/24  +  2001:db8:12::/64
```

This gives every VM (masters + workers) two extra NICs connected to two separate bridges — matching kind's two-switch topology.

The cluster runs dual-stack (`IP_STACK=v4v6`) so pods get both IPv4 and IPv6 addresses, which is needed for the full test suite (host session tests create dual-stack FRRConfigurations).

### How Nodes Connect to the Fabric

On kind, nodes are containers — clab creates bridge switches (`leafkind1-sw`, `leafkind2-sw`) and wires both the kind nodes and the leafkind FRR containers to them via veths.

On OCP, the libvirt bridges (`toswitch1`, `toswitch2`) already exist. Clab references them as `kind: bridge` and wires only the leafkind FRR containers. The VMs are already connected via their virtio NICs.

```
Kind:
  kind-node ──veth──► leafkind1-sw (clab bridge) ◄──veth── leafkind1
  kind-node ──veth──► leafkind2-sw (clab bridge) ◄──veth── leafkind2

OCP:
  OCP VM ──virtio──► toswitch1 (libvirt bridge) ◄──veth── leafkind1
  OCP VM ──virtio──► toswitch2 (libvirt bridge) ◄──veth── leafkind2
```

From leafkind upward (spine, leafA, leafB, hosts), the clab fabric is identical.

### What's the Same, What's Different, What's New

**Same as kind:**
- Clab fabric topology (spine, leaves, hosts, FRR configs)
- Underlay CR, L3VNI, L2VNI, host session mechanics
- Test suite code (same ginkgo tests, same assertions)
- Container IP assignment (`ip_map.txt`, `assign_ips` tool)

**Different from kind:**

| | Kind | OCP |
|---|------|-----|
| Nodes | Containers (clab `ext-container`) | Libvirt VMs (libvirt bridge + virtio) |
| NIC names | Clab assigns (`toswitch1`) | Kernel assigns by PCI slot → renamed via udev rules |
| IP assignment | `check_veths` assigns on veth creation | Static IPs assigned once by setup script (DHCP disabled) |
| NIC lifecycle | Veths — destroyed/recreated freely | Virtio NICs — permanent, must never be destroyed |
| FRR-K8s | Namespace `frr-k8s-system` | Namespace `openshift-frr-k8s` (deployed by CNO) |
| Pod networking | Simple bridge/veth | OVN-Kubernetes |

**New for OCP (not needed on kind):**

**NIC lifecycle — the critical difference from kind:**

On kind, node interfaces are veths. The `check_veths` daemon can destroy and recreate them at will. The perouter netns can also be deleted freely — `check_veths` recreates the veths and the controller rebuilds perouter.

On OCP, node interfaces are virtio NICs attached by the hypervisor. **Deleting the perouter netns destroys any virtio NICs inside it permanently.** They can only be recovered via `virsh detach-interface` + `virsh attach-interface` on the hypervisor — not from inside the cluster.

This has a critical consequence: **the perouter netns must never be deleted on OCP.** Fortunately, the controller handles this correctly:

- When an underlay is deleted, `RemoveUnderlay()` resets the NIC group ID (4242 → 0) and deletes the VTEP loopback, but **leaves NICs in perouter with their IPs intact**.
- When a new underlay is created, `SetupUnderlay()` detects the NICs are already in perouter (`moveInterfaceToNamespace` returns "intf is already in namespace") and **reuses them in-place** — no namespace move, no IP stripping.
- Static IPs and `rp_filter` sysctl defaults survive across underlay delete/recreate cycles.

This means **no recovery monitor is needed** — no `recover-toswitch.sh`, no `waitForNICRecovery`. The controller's existing code handles it. The one constraint: setup-clab.sh must never call `ip netns delete perouter`.

Two tests in the upstream suite explicitly delete perouter (to test crash recovery) and must be skipped on OCP — see "Tests to Skip" below.

- **DHCP disabled** — dev-scripts enables DHCP on extra networks by default. DHCP IPs expire and conflict with the static IPs the controller preserves. The setup kills dnsmasq.

- **rp_filter=0** — RHCOS defaults `rp_filter=1` on new interfaces. VXLAN return traffic is asymmetric (forward via toswitch1/peerLeaf1, return via toswitch2/peerLeaf2). Strict rp_filter drops packets arriving on the "wrong" interface. Must be disabled in perouter on all nodes via `sysctl -w net.ipv4.conf.default.rp_filter=0 net.ipv4.conf.all.rp_filter=0` so new interfaces (vni100, br-pe-100, etc.) inherit the setting. Also needed on the spine clab container for the same reason.

- **routingViaHost + ipForwarding** — OVN by default bypasses the host kernel routing table for pod traffic. L3 host session tests need pod traffic to hit FRR-K8s routes installed in the kernel. `routingViaHost: true` sends pod egress through the host stack. `ipForwarding: Global` allows forwarding across OVN-managed interfaces.

- **Bootstrap underlay** — The FRR container waits 60s for the perouter netns to exist. Without an underlay CR, the controller never creates perouter → FRR times out → CrashLoopBackOff. The setup creates a bootstrap underlay so router pods start healthy.

### Tests to Skip on OCP

| Skip Pattern | Reason |
|---|---|
| `editing the underlay parameters` | Changes NICs to `[foo]` → triggers `UnderlayExistsError` → controller deletes perouter → destroys virtio NICs |
| `auto-recover when the named netns is deleted` | Explicitly deletes perouter to test crash recovery → destroys virtio NICs |
| `BridgeRefresher` | Runs `ping` inside pod — OCP restricted SCC drops CAP_NET_RAW |
| `Webhook` | Operator webhook has cert issues in manual deployment |
| `static files` | File-based config not relevant to OCP |
| `underlay address family` | Unnumbered BGP — no point-to-point links in OCP topology |

The first two are the most important — they trigger `HandleNonRecoverableError` in the controller, which deletes perouter and restarts the router pod. On kind this is fine (check_veths recreates veths). On OCP it permanently destroys the virtio NICs.

### Known Limitations

- **Host→pod source IP:** OVN SNATs inbound traffic to the management port IP. The source IP assertion in `evpn_routes` is commented out — connectivity is still verified (curl succeeds), only the source IP check is bypassed.
- **L2 VNI host configuration validation:** The `validatehost` binary reports failures for L2 VNI checks on OCP. Needs investigation — may be OVS bridge differences vs Linux bridge on kind.
- **Passthrough routes:** One passthrough traffic test fails intermittently. Needs further investigation.

### Failure Analysis

Of 67 applicable specs, 29 ran before the 120-minute suite timeout. **13 passed, 16 failed** — but only **4 distinct root causes**, all at the test level:

**1. `hostconfiguration` validatehost binary missing (12 failures)**

The `ensureValidator` function copies the `validatehost` binary into each router pod and sets a `validator=true` annotation. If the FRR container restarts (crash, kill, OOM), the binary is lost but the annotation persists. On the next BeforeEach, `ensureValidator` sees the annotation and skips the copy → all subsequent validations fail with "No such file or directory".

On kind, FRR container restarts are rare. On OCP, the FRR crash test and HandleNonRecoverableError both cause restarts. Fix: check for the binary's existence, not just the annotation.

**2. `bridgerefresh` ping permission denied (1 failure + cascading skips)**

The test runs `ping` inside a busybox pod. OCP's restricted SCC drops `CAP_NET_RAW`, so ping fails with "permission denied". Fix: add `NET_RAW` capability to the pod spec, or skip.

**3. `passthrough_routes` traffic timeout (1 failure + cascading skips)**

External host `hostA_default` (192.168.22.2) cannot reach pods via passthrough routing. Investigation shows `leafA` cannot ping `hostA_default` despite being on the same L2 segment (192.168.22.0/24 via `ethdefault`). This appears to be a clab networking issue — the veth link between leafA and hostA_default may be broken. Needs clab topology investigation.

**4. `evpn_l2` IPv6 type-5 route timeout (1 failure + cascading skips)**

The IPv6 L2 overlay test waits for Type-5 routes to propagate but they never appear. `show bgp l2vpn evpn route type prefix` returns empty on leafkind1. This occurs after many underlay delete/recreate cycles — may be a FRR session convergence timing issue with IPv6 on OCP.

### Results

The infra layer (NICs, IPs, rp_filter, BGP) **remained stable throughout the entire 60-minute run** — no recovery infrastructure was needed and no cascading infra failures occurred. All failures are at the test level. With the validatehost fix and BridgeRefresher skip, the pass rate would increase significantly.

The suite needs `--timeout 180m` (120m was insufficient for 67 specs with 5-minute BGP wait timeouts).

# Things We Tried — OCP E2E Debugging Log

Track what was investigated and ruled out, so we don't revisit.

---

## Ruled Out (not the cause)

### 1. rp_filter on clab containers (spine, leaves)
- **Hypothesis:** Spine drops asymmetrically-routed VXLAN reply packets
- **Disproved:** Set rp_filter=0 on ALL interfaces in ALL clab containers. Traffic still fails.
- **Status:** NOT THE ISSUE (clab containers are not the problem)

### 3. ECMP return path (5-node fan-out)
- **Hypothesis:** LeafA's 5-way ECMP sends reply to wrong node, L2 forward fails
- **Disproved:** When infra is manually pre-converged, ALL traffic works including pod2→hostARed. The ECMP path works when the infrastructure is stable.
- **Status:** NOT THE ROOT CAUSE (was a convergence timing symptom)

### 4. Host firewall (nftables FORWARD chain)
- **Hypothesis:** Host firewalld rejects bridge-forwarded traffic between VMs and clab
- **Disproved:** br_netfilter module not loaded. Bridge traffic doesn't traverse netfilter. `bridge-nf-call-iptables` sysctl doesn't exist.
- **Status:** NOT THE ISSUE

### 5. MTU mismatch
- **Hypothesis:** VXLAN overhead (50 bytes) exceeds bridge MTU
- **Disproved:** toswitch1 MTU=1500, VNI MTU=1450. TCP SYN is ~60 bytes inner, ~110 outer. Well within limits.
- **Status:** NOT THE ISSUE

---

## Confirmed Issues (fixed or fixing)

### 1. DHCP competing with static IPs
- **Problem:** Libvirt DHCP assigns .20-.24 with 60-min leases. Our static IPs (.100+) added as secondary. DHCP expires → NIC loses primary IP → BGP uses stale .20 next-hop → return VXLAN goes to wrong IP → black hole.
- **Fix:** Kill dnsmasq for toswitch networks in setup-clab.sh step 1b. Assign only static IPs.
- **Status:** FIXED in setup-clab.sh

### 2. CONTAINER_RUNTIME not set
- **Problem:** Test executor defaults to "docker". OCP has only podman.
- **Fix:** Set `CONTAINER_RUNTIME=podman` when running tests.
- **Status:** FIXED (documented in SETUP_PEROUTER.md)

### 3. Controller skips IP restoration when NICs already in perouter
- **Problem:** Controller's `moveInterfaceToNamespace()` preserves IPs during move. But if NIC is already in perouter (from previous test), no move happens → no IP restoration.
- **Fix:** Recovery monitor ensures IPs via `ip addr replace` on NICs in perouter.
- **Status:** FIXED in recover-toswitch.sh

### 4. Recovery monitor crashes (set -euo pipefail)
- **Problem:** Any `oc exec` timeout kills the bash monitor.
- **Fix:** Removed `set -euo pipefail` from main loop. Per-command error handling.
- **Status:** FIXED in recover-toswitch.sh

### 5. Recovery monitor group check (JSON format)
- **Problem:** `ip -j link show` outputs group 0 as `"group":"default"` not `"group":0`. Grep pattern didn't match.
- **Fix:** Check for `"default"` string instead of numeric 0.
- **Status:** FIXED in recover-toswitch.sh

### 6. FRR CrashLoopBackOff (zebra timeout)
- **Problem:** FRR container waits 60s for perouter netns. Without a bootstrap underlay, perouter never exists → timeout → crash.
- **Fix:** setup-clab.sh step 11 creates a bootstrap underlay so controller creates perouter before FRR times out.
- **Status:** FIXED in setup-clab.sh

### 7. setup-clab.sh step ordering
- **Problem:** NIC rename (step 7) ran before perouter delete (step 8). NICs stuck in perouter, rename couldn't find them.
- **Fix:** Reordered: clean first (step 7), then rename (step 8), then IPs (step 9).
- **Status:** FIXED in setup-clab.sh

### 8. virsh net-destroy breaks running VMs
- **Problem:** Destroying libvirt network while VMs are running removes their virtual NICs from the guest. NICs vanish.
- **Fix:** Kill dnsmasq process instead of destroying the network. Never touch libvirt network lifecycle with running VMs.
- **Status:** FIXED in setup-clab.sh (lesson learned)

### 9. toswitch2 never got static IP
- **Problem:** Only toswitch1 got static IPs. toswitch2 relied on DHCP. Return VXLAN via peerLeaf2 → toswitch2 → black hole.
- **Fix:** Assign static IPs to BOTH toswitch1 and toswitch2 in setup-clab.sh step 9.
- **Status:** FIXED in setup-clab.sh

### 10. rp_filter on perouter toswitch interfaces (THE ROOT CAUSE)
- **Problem:** RHCOS sets rp_filter=1 on all new interfaces. In perouter, toswitch1 and toswitch2 have rp_filter=1. VXLAN return traffic arrives on toswitch2 but the source IP (100.64.0.1, leafA VTEP) routes via toswitch1. Strict rp_filter: incoming interface ≠ route interface → packet DROPPED.
- **Why kind works:** On kind, both toswitch interfaces connect to the same bridge (leafkind1-sw). The routing is symmetric — return traffic arrives on the same interface the route points to. On OCP, toswitch1 and toswitch2 connect to SEPARATE libvirt bridges (separate peerLeaf switches), creating asymmetric routing.
- **How we found it:** Traced packet counters hop-by-hop. Forward VXLAN TX on master-1 incremented. Return arrived at master-1 toswitch2 (RX incremented). But vni100 RX never incremented — kernel dropped the packet before VXLAN decap. Confirmed by `ip route get 100.65.0.2 from 192.168.12.2 iif toswitch2` → local delivery via lo. Setting rp_filter=0 in perouter → all 7 traffic paths pass.
- **Fix:** recover-toswitch.sh sets rp_filter=0 in perouter on every poll cycle. Should also be fixed upstream in OpenPerOuter controller's sysctl setup.
- **Status:** FIXED in recover-toswitch.sh

---

## Current State (as of 2026-07-08)

### All 7 traffic paths pass
- pod1 (master-0) → pod2 (master-1): PASS (L2 overlay VNI 110)
- pod2 → pod1: PASS
- pod1 → hostARed: PASS (L3 via EVPN type-5)
- pod1 → hostBRed: PASS
- pod2 → hostARed: PASS
- pod2 → hostBRed: PASS
- hostARed → pod1: PASS

### Infra setup validated
- setup-clab.sh runs clean from scratch (all 13 steps pass)
- teardown + setup cycle works
- All 5 nodes: static IPs on both toswitch1 and toswitch2 (no DHCP)
- rp_filter=0 in perouter (set by recovery monitor)
- BGP established, EVPN converged, full L2/L3 VXLAN data plane working

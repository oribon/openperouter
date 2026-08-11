# rp_filter on OCP — Findings

## Question 1: Is rp_filter=1 (strict) enough, or do we need to loosen it?

**Answer: rp_filter=1 drops packets. rp_filter=2 (loose) is sufficient.**

### Proof (tested on cnfdc15.t5g-dev.eng.rdu2.dc.redhat.com, RHCOS)

Simulated the asymmetric VXLAN return path: packet with source `100.64.0.1`
(remote VTEP) arriving on `veth-ts2`, while the route to `100.64.0.1` points
to `veth-ts1`.

| rp_filter | Packets received | Replies generated | Result |
|-----------|-----------------|-------------------|--------|
| 1 (strict) | 3 | **0** | **DROPPED** — kernel silently discards, no reply |
| 2 (loose) | 3 | **3** | **ACCEPTED** — kernel generates reply |
| 0 (disabled) | 3 | **2** | **ACCEPTED** — same as loose |

Strict mode checks: "is the source reachable via the interface the packet
arrived on?" Route to `100.64.0.1` goes via `veth-ts1`, but packet arrived
on `veth-ts2` → drop.

Loose mode checks: "does ANY route to the source exist?" Route exists
(via `veth-ts1`) → accept.

**`rp_filter=2` is enough. We don't need `rp_filter=0`.**

## Question 2: Is this an artifact of our setup (libvirt/clab) or a general OCP issue?

**Answer: General OCP issue. Not specific to our setup.**

RHCOS ships `/usr/lib/sysctl.d/50-redhat.conf` which sets:
```
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.*.rp_filter = 1
```

This overrides the systemd default (`50-default.conf` sets `rp_filter=2`).
Every new network namespace on RHCOS — whether created by libvirt, podman,
CRI-O, or `ip netns add` — inherits `rp_filter=1`.

Any openperouter deployment on OCP with multi-homed underlay (toswitch1 +
toswitch2) will have this issue, regardless of whether the nodes are
libvirt VMs, bare metal, or cloud instances. The asymmetric VXLAN return
path is inherent to the topology — BGP at the spine can select a different
leafkind for the return than the one used for the forward.

Kind CI runs on Ubuntu, which defaults to `rp_filter=2` (loose). That's
why kind doesn't need any rp_filter tuning.

The controller already handles VRF interfaces (`vrf.go:47` calls
`DisableRPFilter`) but does NOT handle underlay interfaces (toswitch1/2),
VXLAN interfaces (vni100, br-pe-100), or the `default`/`all` sysctls.
This is arguably a product bug — the controller should set rp_filter on
all interfaces it manages in perouter.

## Question 3: Is there an OCP-native way to set rp_filter?

**Not investigated yet.** Potential options:
- MachineConfig to set sysctl on nodes (affects host, not perouter netns)
- NMState for NIC-level sysctl (may not cover netns)
- TuningCNI for pod-level sysctl (openperouter pods are privileged, might work)
- The controller itself should handle this (product fix)

For clab containers: no OCP-native mechanism — they're podman containers
on the hypervisor, outside OCP's control.

## Question 4: What is must-have vs what can be removed?

### Must-have: Step 9 (rp_filter in perouter)

The perouter netns gets `rp_filter=1` on RHCOS. The controller only sets
`rp_filter=0` on VRF interfaces. It does NOT set it on toswitch1/2 or
VXLAN interfaces. Without step 9, asymmetric VXLAN return traffic on
toswitch2 is silently dropped.

**Should be `rp_filter=2` (loose), not `rp_filter=0`.** Matches the
Ubuntu/kind default and still provides basic source validation.

**Long-term fix:** The controller should handle this — set rp_filter=2
on all interfaces in perouter, or at least on underlay interfaces.

### Likely needed: Step 5b (rp_filter on clab containers)

Clab containers on RHCOS inherit `rp_filter=1`. The spine routes between
leafkind1 and leafkind2 — asymmetric paths are possible. On kind CI
(Ubuntu), clab containers get `rp_filter=2` implicitly.

**Not proven to cause actual test failures** — we only proved the perouter
case above. But the theoretical risk exists and it's a cheap one-liner.

**Should be `rp_filter=2` (loose), not `rp_filter=0`.**

**Long-term:** Not needed if openperouter is deployed on real hardware
(no clab). Only needed for the E2E test fabric.

## Verified Defaults

| Platform | rp_filter default | Source |
|----------|-------------------|--------|
| RHCOS | 1 (strict) | `/usr/lib/sysctl.d/50-redhat.conf` |
| Ubuntu (kind CI) | 2 (loose) | `/usr/lib/sysctl.d/50-default.conf` |
| New container on RHCOS | 1 (strict) | Inherits from host |
| New netns on RHCOS | 1 (strict) | Inherits from host |

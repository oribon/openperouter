#!/bin/bash
# Monitors for toswitch NICs stuck in the perouter netns and recovers them
# to the default netns. This is the OCP equivalent of kind's check_veths.
#
# Why this exists:
# When a test deletes an Underlay CR, the OpenPerOuter controller calls
# RemoveUnderlay() which resets the group ID on NICs to 0 but does NOT
# move them back to the default netns. On kind, check_veths detects the
# veth LEFT-side deletion and recreates fresh veths. On OCP, real NICs
# can't be recreated — we move them back instead.
#
# Race-free design using group IDs:
# The controller sets group 4242 on NICs when actively managing them
# (SetupUnderlay). RemoveUnderlay resets group to 0 during cleanup.
# This monitor ONLY recovers NICs with group 0 — meaning the controller
# has already finished with them. NICs with group 4242 are never touched,
# eliminating any race between this monitor and the controller.
#
# Static IP assignment:
# On kind, check_veths assigns static IPs when creating veths. On OCP,
# the NICs originally get DHCP IPs from libvirt, but NetworkManager is
# disabled for them (to prevent interference during netns transitions).
#
# The controller preserves IPs when moving NICs between namespaces
# (captures before move, re-assigns after). But when a NIC is already
# in perouter (e.g., from a previous test that didn't clean up), the
# controller skips the move and doesn't restore IPs.
#
# Additionally, if a NIC has a DHCP-assigned IP, `ip addr add` with the
# same address fails (EEXIST). When the DHCP lease expires, the NIC
# loses its only IP. This monitor uses `ip addr replace` which converts
# a dynamic DHCP address to a permanent static one, surviving expiry.
#
# No perouter deletion or router restart needed:
# Perouter netns persists between tests. FRR stays running inside it.
# When the controller moves recovered NICs back into perouter for the
# next test, FRR detects them via netlink — same as kind where
# check_veths creates fresh veths in the host netns and the controller
# moves them into the existing perouter.

KUBECONFIG="${KUBECONFIG:-/root/dev-scripts/ocp/ostest/auth/kubeconfig}"
export KUBECONFIG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPOLOGY_FILE="${SCRIPT_DIR}/topology.json"

node_exec() {
    local node=$1; shift
    local pod
    pod=$(oc get pods -n openperouter-system -l app=controller \
        --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [ -z "$pod" ] && return 1
    oc exec -n openperouter-system "${pod}" -- nsenter -t 1 -m -u -i -n "$@" 2>/dev/null
}

get_node_ip() {
    local node=$1 field=$2
    python3 -c "
import json
cfg = json.load(open('${TOPOLOGY_FILE}'))
n = cfg.get('nodes', {}).get('${node}', {})
print(n.get('${field}', ''))
" 2>/dev/null
}

ensure_nic_ip() {
    local node=$1 nic=$2 netns=$3
    local node_ip=""
    if [ "${nic}" = "toswitch1" ]; then
        node_ip=$(get_node_ip "${node}" "peerLeafIP")
    elif [ "${nic}" = "toswitch2" ]; then
        node_ip=$(get_node_ip "${node}" "peerLeaf2IP")
    fi
    [ -z "${node_ip}" ] && return 0

    if [ "${netns}" = "host" ]; then
        node_exec "${node}" ip addr replace "${node_ip}/24" dev "${nic}" 2>/dev/null || true
    else
        node_exec "${node}" ip netns exec perouter ip addr replace "${node_ip}/24" dev "${nic}" 2>/dev/null || true
    fi
}

echo "recover-toswitch: watching for stuck NICs..."
echo "recover-toswitch: topology file: ${TOPOLOGY_FILE}"

while true; do
    # Check if an Underlay CR exists — controls whether we recover NICs.
    UNDERLAY_EXISTS=$(oc get underlay -n openperouter-system --no-headers 2>/dev/null | grep -c .) || true

    NODES=$(oc get nodes -l kubernetes.io/os=linux \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || { sleep 5; continue; }

    for node in ${NODES}; do
        # Disable rp_filter in perouter netns.
        #
        # Why: VXLAN return traffic is asymmetric. The forward path goes
        # node → toswitch1 → peerLeaf1 → spine → leafA. The return goes
        # leafA → spine → peerLeaf2 → toswitch2 → node (spine picks
        # peerLeaf2 as BGP best path for the VTEP). The packet arrives on
        # toswitch2 but the source IP (leafA VTEP 100.64.0.1) routes via
        # toswitch1. Strict rp_filter (RHCOS default=1) drops it.
        #
        # Why kind doesn't need this: on kind, nodes are containers with
        # rp_filter=0 by default in their network namespace. On OCP, RHCOS
        # sets rp_filter=1 on all new interfaces. The asymmetric routing
        # exists on both platforms, but only OCP enforces the filter.
        node_exec "${node}" ip netns exec perouter \
            sh -c 'for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f 2>/dev/null; done' \
            2>/dev/null || true

        for nic in toswitch1 toswitch2; do
            # Check if NIC is in perouter
            GROUP_JSON=$(node_exec "${node}" ip netns exec perouter ip -j link show "${nic}" 2>/dev/null) || continue

            # ip -j outputs group 0 as "default" (string), group 4242 as "4242".
            IS_DEFAULT=$(echo "${GROUP_JSON}" | grep -c '"group".*"default"') || true

            if [ "${IS_DEFAULT}" -gt 0 ] && [ "${UNDERLAY_EXISTS}" -eq 0 ]; then
                # Group 0/"default" AND no underlay = controller released it.
                # Move back to host. Skip if underlay exists — the controller
                # might be in the process of setting group 4242.
                echo "$(date +%T) recover-toswitch: ${node}/${nic} group 0, recovering to host..."
                node_exec "${node}" ip netns exec perouter ip link set "${nic}" netns 1 || continue
                node_exec "${node}" ip link set "${nic}" up 2>/dev/null || true
                ensure_nic_ip "${node}" "${nic}" "host"
                echo "$(date +%T) recover-toswitch: ${node}/${nic} recovered"
            else
                # NIC in perouter — either controller manages it (4242) or
                # underlay exists and controller is setting it up. Always
                # ensure it has an IP.
                ensure_nic_ip "${node}" "${nic}" "perouter"
            fi
        done
    done
    sleep 2
done

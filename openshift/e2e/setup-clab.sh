#!/bin/bash
# Sets up the containerlab fabric and wires it to an OCP cluster deployed via dev-scripts.
#
# Prerequisites:
#   - OCP cluster running via dev-scripts with EXTRA_NETWORK_NAMES="toswitch1 toswitch2"
#   - OpenPerOuter operator deployed on the cluster
#   - containerlab installed
#   - podman available
#
# Produces:
#   - Running clab topology wired to extra network bridges
#   - topology.json for the test suite
#
# Usage:
#   export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
#   ./openshift/e2e/setup-clab.sh
#   make e2etest INFRA_CONFIG=openshift/e2e/topology.json \
#     -- --frrk8s-namespace=openshift-frr-k8s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOPOLOGY_OUT="${SCRIPT_DIR}/topology.json"

PEERLEAF1_IP="${PEERLEAF1_IP:-192.168.11.2}"
PEERLEAF2_IP="${PEERLEAF2_IP:-192.168.12.2}"

CLI="sudo podman"

echo "=== Step 1: Discover extra network bridges ==="
# dev-scripts creates libvirt networks named toswitch1 / toswitch2
TOSWITCH1_BRIDGE=$(virsh net-info toswitch1 2>/dev/null | grep Bridge | awk '{print $2}') || true
TOSWITCH2_BRIDGE=$(virsh net-info toswitch2 2>/dev/null | grep Bridge | awk '{print $2}') || true

if [ -z "${TOSWITCH1_BRIDGE}" ] || [ -z "${TOSWITCH2_BRIDGE}" ]; then
    echo "ERROR: Could not find extra network bridges."
    echo "  Make sure dev-scripts config has: EXTRA_NETWORK_NAMES=\"toswitch1 toswitch2\""
    echo "  Found toswitch1 bridge: ${TOSWITCH1_BRIDGE:-not found}"
    echo "  Found toswitch2 bridge: ${TOSWITCH2_BRIDGE:-not found}"
    echo ""
    echo "Available libvirt networks:"
    virsh net-list --all
    exit 1
fi

echo "  toswitch1 bridge: ${TOSWITCH1_BRIDGE}"
echo "  toswitch2 bridge: ${TOSWITCH2_BRIDGE}"

echo "=== Step 2: Generate peerLeaf FRR configs ==="
cd "${REPO_ROOT}/clab/tools"
go build -o generate_leaf_config/generate_leaf generate_leaf_config/common.go generate_leaf_config/generate_leaf.go
go build -o generate_leaf_config/generate_leafkind generate_leaf_config/common.go generate_leaf_config/generate_leafkind.go

rm -f ../leafA/frr.conf
./generate_leaf_config/generate_leaf \
    -leaf leafA -neighbor 192.168.1.0 -network 100.64.0.1/32 \
    -template generate_leaf_config/frr_template/frr.conf.template

rm -f ../leafB/frr.conf
./generate_leaf_config/generate_leaf \
    -leaf leafB -neighbor 192.168.1.2 -network 100.64.0.2/32 \
    -template generate_leaf_config/frr_template/frr.conf.template

rm -f ../singlecluster/leafkind1/frr.conf
./generate_leaf_config/generate_leafkind \
    -leaf singlecluster/leafkind1 -asn 64512 -spine-ip 192.168.1.4 \
    -ipv4-listen-range 192.168.11.0/24 -ipv6-listen-range 2001:db8:11::/64 \
    -template generate_leaf_config/frr_template/leafkind.conf.template

rm -f ../singlecluster/leafkind2/frr.conf
./generate_leaf_config/generate_leafkind \
    -leaf singlecluster/leafkind2 -asn 64513 -spine-ip 192.168.1.6 \
    -ipv4-listen-range 192.168.12.0/24 -ipv6-listen-range 2001:db8:12::/64 \
    -template generate_leaf_config/frr_template/leafkind.conf.template

echo "=== Step 3: Enable podman socket ==="
systemctl enable --now podman.socket 2>/dev/null || true

echo "=== Step 4: Deploy clab topology ==="
cd "${REPO_ROOT}"

containerlab deploy --runtime podman \
    --topo clab/singlecluster/ocp.clab.yml --reconfigure

echo "=== Step 5: Assign IPs to clab containers ==="
cd "${REPO_ROOT}/clab"
go run tools/assign_ips/assign_ips.go \
    -file singlecluster/ip_map.txt -engine "${CLI}"

# Assign leafkind IPs on the bridge-facing interfaces (eth2)
${CLI} exec clab-kind-leafkind1 ip addr add "${PEERLEAF1_IP}/24" dev eth2
${CLI} exec clab-kind-leafkind2 ip addr add "${PEERLEAF2_IP}/24" dev eth2

echo "=== Step 6: Run container setup scripts ==="
for c in leafA leafB hostA_red hostA_blue hostA_default hostB_red hostB_blue; do
    if ${CLI} exec clab-kind-${c} test -f /setup.sh 2>/dev/null; then
        ${CLI} exec clab-kind-${c} /setup.sh
    fi
done

WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Use controller pods for fast node access (no debug pods)
node_exec() {
    local node=$1; shift
    local pod=$(oc get pods -n openperouter-system -l app=controller \
        --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')
    oc exec -n openperouter-system "${pod}" -- nsenter -t 1 -m -u -i -n "$@"
}

echo "=== Step 7: Rename extra NICs to toswitch1/toswitch2 on nodes ==="
# dev-scripts creates extra NICs but names them by PCI slot (enp3s0, enp4s0).
# We rename them to toswitch1/toswitch2 so OpenPerOuter can find them.
for worker in ${WORKERS}; do
    echo "Renaming NICs on ${worker}..."
    # Match MACs: virsh domiflist shows which MAC is on which bridge
    vm_name="ostest_${worker//-/_}"
    for i in 1 2; do
        BRIDGE_MAC=$(virsh domiflist "${vm_name}" 2>/dev/null | grep "toswitch${i}" | awk '{print $5}')
        if [ -n "${BRIDGE_MAC}" ]; then
            node_exec "${worker}" bash -c "
                IFACE=\$(ip -br link show | grep '${BRIDGE_MAC}' | awk '{print \$1}')
                if [ -n \"\$IFACE\" ] && [ \"\$IFACE\" != \"toswitch${i}\" ]; then
                    nmcli device set \$IFACE managed no 2>/dev/null
                    ip link set \$IFACE down
                    ip link set \$IFACE name toswitch${i}
                    ip link set toswitch${i} up
                    echo \"  \$IFACE -> toswitch${i}\"
                elif [ \"\$IFACE\" = \"toswitch${i}\" ]; then
                    echo \"  toswitch${i} already named correctly\"
                fi
            " 2>&1
        fi
    done
done

echo "=== Step 8: Discover node IPs and generate topology.json ==="
NODES_JSON=""
for worker in ${WORKERS}; do
    # toswitch1 gets an IP from dev-scripts DHCP on the extra network
    TOSWITCH_IP=$(node_exec "${worker}" bash -c \
        "ip -4 addr show toswitch1 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" 2>&1)

    if [ -z "${TOSWITCH_IP}" ]; then
        echo "WARN: No IP found on toswitch1 for ${worker}, trying interface name from dev-scripts..."
        # dev-scripts might name the interface differently
        ALL_IFS=$(node_exec "${worker}" ip -br link show 2>&1)
        echo "  Interfaces on ${worker}: ${ALL_IFS}"
        continue
    fi

    echo "  ${worker}: toswitch1 IP = ${TOSWITCH_IP}"

    if [ -n "${NODES_JSON}" ]; then
        NODES_JSON="${NODES_JSON},"
    fi
    NODES_JSON="${NODES_JSON}
    \"${worker}\": {\"peerLeafIP\": \"${TOSWITCH_IP}\"}"
done

cat > "${TOPOLOGY_OUT}" << TOPOEOF
{
  "nodes": {${NODES_JSON}
  },
  "peerLeaf1IP": "${PEERLEAF1_IP}",
  "peerLeaf2IP": "${PEERLEAF2_IP}",
  "underlayNics": ["toswitch1", "toswitch2"],
  "underlayNeighbors": [
    {"asn": 64512, "address": "${PEERLEAF1_IP}"},
    {"asn": 64513, "address": "${PEERLEAF2_IP}"}
  ]
}
TOPOEOF

echo "=== Step 9: Clean stale state and restart router pods ==="
oc delete underlay --all -n openperouter-system 2>/dev/null || true
oc delete l3vni --all -n openperouter-system 2>/dev/null || true
oc delete l2vni --all -n openperouter-system 2>/dev/null || true
oc delete frrconfigurations --all -n openshift-frr-k8s 2>/dev/null || true
sleep 5

for worker in ${WORKERS}; do
    node_exec "${worker}" ip netns delete perouter 2>/dev/null || true
done

oc rollout restart daemonset router -n openperouter-system
oc rollout status daemonset router -n openperouter-system --timeout=120s

echo "=== Step 10: Verify connectivity ==="
for worker in ${WORKERS}; do
    echo "Checking ${worker} → peerLeaf1 (${PEERLEAF1_IP})..."
    node_exec "${worker}" ping -c 1 -W 2 "${PEERLEAF1_IP}" -I toswitch1 || echo "WARN: ping failed"
done

echo ""
echo "=== Setup complete ==="
echo "Topology config: ${TOPOLOGY_OUT}"
echo ""
echo "Run tests with:"
echo "  make e2etest INFRA_CONFIG=${TOPOLOGY_OUT} -- --frrk8s-namespace=openshift-frr-k8s"
echo ""
cat "${TOPOLOGY_OUT}"

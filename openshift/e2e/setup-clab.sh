#!/bin/bash
# Sets up the containerlab fabric and wires it to an OCP cluster deployed via dev-scripts.
#
# Prerequisites:
#   - OCP cluster running via dev-scripts with EXTRA_NETWORK_NAMES="toswitch1 toswitch2"
#     and both _V4 and _V6 subnets configured for dual-stack
#   - OpenPerOuter operator deployed on the cluster
#   - containerlab installed
#   - podman available
#
# Produces:
#   - Running clab topology wired to extra network bridges
#   - nodelink.json for the test suite
#   - Bootstrap underlay so router pods are healthy (FRR running in perouter)
#   - rp_filter=0 in perouter (required for asymmetric VXLAN routing)
#
# Usage:
#   export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
#   ./openshift/e2e/setup-clab.sh
#   cd e2etests && CONTAINER_RUNTIME=podman go test -v ./suite/ \
#     --nodelink-config=../openshift/e2e/nodelink.json --frrk8s-namespace=openshift-frr-k8s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODELINK_OUT="${SCRIPT_DIR}/nodelink.json"

PEERLEAF1_IP="${PEERLEAF1_IP:-192.168.11.2}"
PEERLEAF2_IP="${PEERLEAF2_IP:-192.168.12.2}"
PEERLEAF1_IPV6="${PEERLEAF1_IPV6:-2001:db8:11::2}"
PEERLEAF2_IPV6="${PEERLEAF2_IPV6:-2001:db8:12::2}"

CLI="sudo podman"

echo "=== Step 1: Discover extra network bridges ==="
TOSWITCH1_BRIDGE=$(virsh net-info toswitch1 2>/dev/null | grep Bridge | awk '{print $2}') || true
TOSWITCH2_BRIDGE=$(virsh net-info toswitch2 2>/dev/null | grep Bridge | awk '{print $2}') || true

if [ -z "${TOSWITCH1_BRIDGE}" ] || [ -z "${TOSWITCH2_BRIDGE}" ]; then
    echo "ERROR: Could not find extra network bridges."
    echo "  Make sure dev-scripts config has: EXTRA_NETWORK_NAMES=\"toswitch1 toswitch2\""
    exit 1
fi
echo "  toswitch1 bridge: ${TOSWITCH1_BRIDGE}"
echo "  toswitch2 bridge: ${TOSWITCH2_BRIDGE}"

echo "=== Step 1b: Disable DHCP on extra networks ==="
# dev-scripts enables DHCP by default. DHCP IPs compete with our static IPs
# and expire after 60 minutes, breaking VXLAN routing. We assign all IPs
# statically, so DHCP is not needed. Kill dnsmasq (don't virsh net-destroy
# which disconnects running VMs from the bridge).
for net in toswitch1 toswitch2; do
    DNSMASQ_PID=$(cat /var/run/libvirt/network/${net}.pid 2>/dev/null) || true
    if [ -n "${DNSMASQ_PID}" ] && kill -0 "${DNSMASQ_PID}" 2>/dev/null; then
        kill "${DNSMASQ_PID}"
        echo "  ${net}: killed dnsmasq (PID ${DNSMASQ_PID})"
    else
        echo "  ${net}: dnsmasq not running"
    fi
done

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
    -isis-net 49.0001.0000.0000.0004.00 \
    -toswitch-interface toswitch1 \
    -template generate_leaf_config/frr_template/leafkind.conf.template

rm -f ../singlecluster/leafkind2/frr.conf
./generate_leaf_config/generate_leafkind \
    -leaf singlecluster/leafkind2 -asn 64513 -spine-ip 192.168.1.6 \
    -ipv4-listen-range 192.168.12.0/24 -ipv6-listen-range 2001:db8:12::/64 \
    -isis-net 49.0001.0000.0000.0005.00 \
    -toswitch-interface toswitch2 \
    -template generate_leaf_config/frr_template/leafkind.conf.template

echo "=== Step 3: Enable podman socket ==="
systemctl enable --now podman.socket 2>/dev/null || true

echo "=== Step 4: Deploy clab topology ==="
cd "${REPO_ROOT}"
containerlab deploy --runtime podman \
    --topo "${SCRIPT_DIR}/ocp.clab.yml" --reconfigure

echo "=== Step 5: Assign IPs to clab containers ==="
cd "${REPO_ROOT}/clab"
go run tools/assign_ips/assign_ips.go \
    -file "${SCRIPT_DIR}/ip_map_ocp.txt" -engine "${CLI}"

# Match leafkind bridge-facing MTU to the libvirt bridge (1500)
${CLI} exec clab-kind-leafkind1 ip link set dev toswitch1 mtu 1500
${CLI} exec clab-kind-leafkind2 ip link set dev toswitch2 mtu 1500

# Assign leafkind IPs on the bridge-facing interfaces — IPv4 + IPv6
${CLI} exec clab-kind-leafkind1 ip addr add "${PEERLEAF1_IP}/24" dev toswitch1
${CLI} exec clab-kind-leafkind1 ip -6 addr add "${PEERLEAF1_IPV6}/64" dev toswitch1
${CLI} exec clab-kind-leafkind2 ip addr add "${PEERLEAF2_IP}/24" dev toswitch2
${CLI} exec clab-kind-leafkind2 ip -6 addr add "${PEERLEAF2_IPV6}/64" dev toswitch2

echo "=== Step 5b: Disable rp_filter on clab FRR containers ==="
# The spine routes VXLAN asymmetrically (forward via peerLeaf1/eth3,
# return via peerLeaf2/eth4). Strict rp_filter (default=1) drops packets
# arriving on the "wrong" interface. Must be disabled on all FRR containers.
for c in spine leafA leafB leafkind1 leafkind2 leafSRV6; do
    ${CLI} exec clab-kind-${c} sh -c 'for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f; done' 2>/dev/null
done
# Enable IPv6 forwarding on spine for SRV6 IS-IS transit
${CLI} exec clab-kind-spine sysctl -qw net.ipv6.conf.all.forwarding=1
echo "  rp_filter disabled + IPv6 forwarding enabled on FRR containers"

echo "=== Step 6: Run container setup scripts ==="
for c in leafA leafB leafSRV6 hostA_red hostA_blue hostA_default hostB_red hostB_blue hostSRV6_red hostSRV6_blue; do
    if ${CLI} exec clab-kind-${c} test -f /setup.sh 2>/dev/null; then
        ${CLI} exec clab-kind-${c} /setup.sh
    fi
done

NODES=$(oc get nodes -l kubernetes.io/os=linux -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

node_exec() {
    local node=$1; shift
    local pod=$(oc get pods -n openperouter-system -l app=controller \
        --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')
    oc exec -n openperouter-system "${pod}" -- nsenter -t 1 -m -u -i -n "$@"
}

echo "=== Step 7: Clean stale CRs ==="
# Clean CRs but do NOT delete perouter netns. The controller reuses NICs
# already in perouter (with their IPs intact) when a new underlay is created.
# Deleting perouter destroys virtio NICs on libvirt VMs (they cannot be
# recovered without virsh detach/reattach).
oc delete underlay --all -n openperouter-system 2>/dev/null || true
oc delete l3vni --all -n openperouter-system 2>/dev/null || true
oc delete l2vni --all -n openperouter-system 2>/dev/null || true
oc delete l3vpn --all -n openperouter-system 2>/dev/null || true
oc delete l3passthrough --all -n openperouter-system 2>/dev/null || true
oc delete rawfrrconfig --all -n openperouter-system 2>/dev/null || true
oc delete frrconfigurations --all -n openshift-frr-k8s 2>/dev/null || true
sleep 5

echo "=== Step 8: Rename NICs + install udev rules ==="
for node in ${NODES}; do
    short_name="${node%%.*}"
    vm_name="ostest_${short_name//-/_}"
    for i in 1 2; do
        BRIDGE_MAC=$(virsh domiflist "${vm_name}" 2>/dev/null | grep "toswitch${i}" | awk '{print $5}')
        if [ -n "${BRIDGE_MAC}" ]; then
            node_exec "${node}" bash -c "
                echo 'SUBSYSTEM==\"net\", ATTR{address}==\"${BRIDGE_MAC}\", NAME=\"toswitch${i}\"' \
                    > /etc/udev/rules.d/70-toswitch${i}.rules
                udevadm control --reload-rules
                IFACE=\$(ip -br link show | grep '${BRIDGE_MAC}' | awk '{print \$1}')
                if [ -n \"\$IFACE\" ] && [ \"\$IFACE\" != \"toswitch${i}\" ]; then
                    nmcli device set \$IFACE managed no 2>/dev/null || true
                    ip link set \$IFACE down
                    ip link set \$IFACE name toswitch${i}
                    ip link set toswitch${i} up
                    echo \"  ${node}: \$IFACE -> toswitch${i}\"
                elif [ \"\$IFACE\" = \"toswitch${i}\" ]; then
                    nmcli device set toswitch${i} managed no 2>/dev/null || true
                    echo \"  ${node}: toswitch${i} already named\"
                else
                    echo \"  ${node}: toswitch${i} not found (MAC ${BRIDGE_MAC})\"
                fi
            " 2>&1
        fi
    done
done

echo "=== Step 9: Assign static IPs (IPv4 + IPv6) ==="
NODE_INDEX=0
NODES_JSON=""
for node in ${NODES}; do
    TS1_V4="192.168.11.$((100 + NODE_INDEX))"
    TS2_V4="192.168.12.$((100 + NODE_INDEX))"
    TS1_V6="2001:db8:11::$((100 + NODE_INDEX))"
    TS2_V6="2001:db8:12::$((100 + NODE_INDEX))"
    NODE_INDEX=$((NODE_INDEX + 1))

    node_exec "${node}" bash -c "
        ip -4 addr flush dev toswitch1 2>/dev/null || true
        ip addr replace ${TS1_V4}/24 dev toswitch1
        ip -6 addr add ${TS1_V6}/64 dev toswitch1 2>/dev/null || true
        ip link set toswitch1 up

        ip -4 addr flush dev toswitch2 2>/dev/null || true
        ip addr replace ${TS2_V4}/24 dev toswitch2
        ip -6 addr add ${TS2_V6}/64 dev toswitch2 2>/dev/null || true
        ip link set toswitch2 up
    " 2>&1
    echo "  ${node}: ts1=${TS1_V4}+${TS1_V6}  ts2=${TS2_V4}+${TS2_V6}"

    if [ -n "${NODES_JSON}" ]; then
        NODES_JSON="${NODES_JSON},"
    fi
    NODES_JSON="${NODES_JSON}
    \"${node}\": {
      \"ipForKindLeaf\": \"${TS1_V4}\",
      \"ipForKindLeaf2\": \"${TS2_V4}\",
      \"ipv6ForKindLeaf\": \"${TS1_V6}\",
      \"ipv6ForKindLeaf2\": \"${TS2_V6}\",
      \"ifaceForKindLeaf\": \"toswitch1\",
      \"ifaceForKindLeaf2\": \"toswitch2\",
      \"leafIfaceForKindLeaf\": \"toswitch1\",
      \"leafIfaceForKindLeaf2\": \"toswitch2\"
    }"
done

cat > "${NODELINK_OUT}" << TOPOEOF
{
  "nodes": {${NODES_JSON}
  }
}
TOPOEOF

echo "=== Step 10: Restart router pods ==="
oc rollout restart daemonset router -n openperouter-system
oc rollout status daemonset router -n openperouter-system --timeout=120s

echo "=== Step 11: Create bootstrap underlay ==="
cat <<EOF | oc apply -f -
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: Underlay
metadata:
  name: underlay
  namespace: openperouter-system
spec:
  asn: 64514
  interfaces:
  - type: NetworkDevice
    networkDevice:
      interfaceName: toswitch1
  - type: NetworkDevice
    networkDevice:
      interfaceName: toswitch2
  neighbors:
  - asn: 64512
    address: ${PEERLEAF1_IP}
  - asn: 64513
    address: ${PEERLEAF2_IP}
  tunnelEndpoint:
    cidrs:
    - "100.65.0.0/24"
EOF
echo "  Waiting for BGP sessions..."
sleep 30

echo "=== Step 12: Ensure rp_filter=0 defaults in perouter ==="
# RHCOS defaults rp_filter=1 on all new interfaces. VXLAN return traffic
# arrives on toswitch2 but source routes via toswitch1 — rp_filter drops it.
# Set 'default' and 'all' so new interfaces (vni100, br-pe-100, etc.)
# created by the controller inherit rp_filter=0 automatically.
for node in ${NODES}; do
    node_exec "${node}" ip netns exec perouter \
        sh -c 'sysctl -qw net.ipv4.conf.default.rp_filter=0 net.ipv4.conf.all.rp_filter=0; for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f 2>/dev/null; done' \
        2>/dev/null || true
done
echo "  rp_filter disabled in perouter on all nodes (default + all + existing)"

echo "=== Step 13: Verify connectivity ==="
for node in ${NODES}; do
    echo -n "  ${node} → peerLeaf1: "
    node_exec "${node}" ip netns exec perouter ping -c 1 -W 2 "${PEERLEAF1_IP}" 2>&1 | grep -o "1 received" || echo "FAILED"
done

echo ""
echo "=== Setup complete ==="
echo "Node links config: ${NODELINK_OUT}"
echo ""
cat "${NODELINK_OUT}"

#!/bin/bash
# Tears down the containerlab topology and cleans up veth wiring.
#
# Usage:
#   ./openshift/e2e/teardown-clab.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=== Destroying clab topology ==="
containerlab destroy --runtime podman \
    --topo "${REPO_ROOT}/clab/singlecluster/ocp.clab.yml" 2>/dev/null || true

echo "=== Removing veth pairs ==="
ip link del veth-pl1-bm 2>/dev/null || true
ip link del veth-pl2-bm 2>/dev/null || true

echo "=== Done ==="

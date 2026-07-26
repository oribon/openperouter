# OpenPerOuter on OCP — Server Setup (RHEL 10)

Self-contained reproduction steps. Starting point: a fresh RHEL 10 server with
root SSH access, 252 GB RAM, 128 cores, two 447 GB disks.

**End state:** OCP 4.22.1 cluster (3 masters + 2 workers) with OpenPerOuter
operator running on all nodes, FRR-K8s enabled via CNO.

---

## 1. SSH Access

All commands run as root on the server.

```bash
# From your local machine — set up passwordless convenience alias
cat >> ~/.ssh/config << EOF
Host poc-server
    HostName 10.1.98.74
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
```

Password: `password` (use `sshpass -e` with `SSHPASS=password` if scripting).

---

## 2. SELinux — Set Permissive

```bash
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

Do **not** mask firewalld — dev-scripts manages it and needs to enable it.

---

## 3. Install Prerequisites

```bash
dnf install -y git sysstat sos make podman python3 jq net-tools gcc
```

Notes:
- `python39` does not exist on RHEL 10 — use `python3` (3.12).
- Do **not** install golang from dnf (version too old).

---

## 4. Generate SSH Key

dev-scripts reads `/root/.ssh/id_rsa.pub` during setup.

```bash
ssh-keygen -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa -q
```

---

## 5. Mount Second Disk

The server has two 447 GB disks. `/dev/sdb` holds the OS (root 70 GB, home
342 GB, swap 32 GB). `/dev/sda4` is a 446 GB XFS partition — unmounted, ideal
for dev-scripts working directory.

```bash
mount /dev/sda4 /opt/dev-scripts
echo "/dev/sda4 /opt/dev-scripts xfs defaults 0 0" >> /etc/fstab
```

If your server layout differs, ensure `/opt/dev-scripts` has ≥200 GB free.
dev-scripts stores VM images, registry data, and ironic images here.

---

## 6. Clone dev-scripts

```bash
cd /root
git clone https://github.com/openshift-metal3/dev-scripts.git
cd dev-scripts
```

---

## 7. Patch dev-scripts for RHEL 10

dev-scripts only supports CentOS 9 / RHEL 9. Two files need patching.

### 7a. `01_install_requirements.sh` — Add `rhel10` to the distro case

Find the case statement (around line 100):

```bash
case $DISTRO in
  "centos9"|"rhel9"|"almalinux9"|"rocky9")
```

Change to:

```bash
case $DISTRO in
  "centos9"|"rhel9"|"almalinux9"|"rocky9" | "rhel10")
```

Then find the `elif` for `rhel9` inside that case block and add a separate
`rhel10` branch after it:

```bash
    elif [[ $DISTRO == "rhel10" ]]; then
      if sudo subscription-manager identity > /dev/null 2>&1; then
	sudo subscription-manager repos --enable "codeready-builder-for-rhel-10-$(arch)-rpms" || true
      fi
      sudo dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm || true
```

The `|| true` on both lines is intentional — EPEL 10 or CRB may not be
available on all RHEL 10 variants, and the install proceeds fine without them.

### 7b. `02_configure_host.sh` — Add `rhel10` to the libvirtd case

Find (around line 23):

```bash
      centos9|rhel9|almalinux9|rocky9)
```

Change to:

```bash
      centos9|rhel9|almalinux9|rocky9|rhel10)
```

This ensures RHEL 10 uses the modular libvirt socket activation (same as
RHEL 9) instead of the legacy `systemctl restart libvirtd.service`.

---

## 8. Pull Secret

Get a pull secret from <https://console.redhat.com/openshift/install/pull-secret>
and save it:

```bash
cat > /root/dev-scripts/pull_secret.json << 'EOF'
<PASTE_PULL_SECRET_JSON_HERE>
EOF
```

---

## 9. Configure dev-scripts

```bash
cat > /root/dev-scripts/config_root.sh << 'EOF'
export IP_STACK=v4
export NETWORK_TYPE=OVNKubernetes
export NUM_WORKERS=2
export WORKER_MEMORY=16384
export WORKER_DISK=50
export MASTER_MEMORY=16384
export MASTER_DISK=50
export ENABLE_LOCAL_REGISTRY=true
export OPENSHIFT_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release@sha256:a15674d407c156561629987807f6b3e827772c6d2ef51dd226a6114871f23844
export OPENSHIFT_CI=true
export EXTRA_NETWORK_NAMES="toswitch1 toswitch2"
export TOSWITCH1_NETWORK_SUBNET_V4='192.168.11.0/24'
export TOSWITCH2_NETWORK_SUBNET_V4='192.168.12.0/24'
EOF
```

Key points:
- **`OPENSHIFT_RELEASE_IMAGE`** — Pinned OCP 4.22.1 GA image from quay.io.
  This avoids needing a CI_TOKEN (nightly images require one).
  To find the latest stable 4.22 image:
  ```bash
  curl -sL "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.22/release.txt" | grep "Pull From:"
  ```
- **`OPENSHIFT_CI=true`** — Bypasses the CI_TOKEN validation check in
  `validation.sh`. Without this, dev-scripts refuses to proceed even with an
  explicit release image.
- **`ENABLE_LOCAL_REGISTRY=true`** — Creates a local container registry at
  `virthost.ostest.test.metalkube.org:5000` (user: `ocp-user`, pass: `ocp-pass`).
  We push the OpenPerOuter image here so OCP nodes can pull it.
- **`EXTRA_NETWORK_NAMES`** — Provisions extra NICs on every VM at creation time.
  Each named network gets its own libvirt bridge. The E2E tests use `toswitch1`
  and `toswitch2` to connect OpenPerOuter to the containerlab fabric.

---

## 10. Install OCP

```bash
cd /root/dev-scripts
make
```

Takes ~60 minutes. Creates:
- libvirt VMs for 3 masters + 2 workers
- `ostestbm` bridge at 192.168.111.0/24 (all nodes connected)
- OpenShift 4.22.1 cluster via IPI baremetal installer

### Verify

```bash
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
echo 'export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig' >> ~/.bashrc

oc get nodes -o wide
# Should show 3 masters + 2 workers, all Ready
# IPs: 192.168.111.20–24

oc get co | grep -v True
# Should show only the header line (all COs available)
```

---

## 11. Enable FRR-K8s via CNO

OpenPerOuter requires FRR-K8s. Deploy it through the Cluster Network Operator:

```bash
oc patch Network.operator.openshift.io cluster --type=merge \
  -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}}}'
```

Wait for rollout:

```bash
until oc rollout status daemonset -n openshift-frr-k8s frr-k8s --timeout 2m 2>/dev/null; do
  echo "Waiting for FRR-K8s..."
  sleep 10
done
```

Verify:

```bash
oc get pods -n openshift-frr-k8s
# 5 frr-k8s pods (7/7 Running) + 1 statuscleaner
```

---

## 12. Build OpenPerOuter Image

```bash
cd /root/openperouter
make docker-build CONTAINER_ENGINE=podman
```

This builds `quay.io/openperouter/router:main` locally in podman.

---

## 13. Push Image to Local Registry

OCP nodes need to pull the image. Push to the dev-scripts local registry:

```bash
REGISTRY="virthost.ostest.test.metalkube.org:5000"
LOCAL_IMG="${REGISTRY}/openperouter/router:main"

sudo podman login --tls-verify=false -u ocp-user -p ocp-pass ${REGISTRY}
sudo podman tag quay.io/openperouter/router:main ${LOCAL_IMG}
sudo podman push --tls-verify=false ${LOCAL_IMG}
```

Verify the image is in the registry:

```bash
curl -sk -u ocp-user:ocp-pass \
  https://virthost.ostest.test.metalkube.org:5000/v2/openperouter/router/tags/list
# {"name":"openperouter/router","tags":["main"]}
```

---

## 14. Deploy OpenPerOuter via the Operator

The operator detects OpenShift automatically (`config.openshift.io` API group)
and sets the container runtime to CRI-O — no manual volume patching needed.

### 14a. Point operator image env vars to local registry

The operator deployment reads `CONTROLLER_IMAGE` and `FRR_IMAGE` env vars to
know which image to use when creating the controller/router DaemonSets.
Edit `operator/config/pods/env.yaml` to point at the local registry:

```bash
cd /root/openperouter
REGISTRY="virthost.ostest.test.metalkube.org:5000"
LOCAL_IMG="${REGISTRY}/openperouter/router:main"

cat > operator/config/pods/env.yaml << ENVEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: operator
  namespace: system
spec:
  template:
    spec:
      containers:
        - name: operator
          env:
          - name: OPERATOR_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: CONTROLLER_IMAGE
            value: "${LOCAL_IMG}"
          - name: FRR_IMAGE
            value: "${LOCAL_IMG}"
          - name: KUBE_RBAC_PROXY_IMAGE
            value: "quay.io/brancz/kube-rbac-proxy:v0.11.0"
          - name: DEPLOY_KUBE_RBAC_PROXIES
            value: "false"
ENVEOF
```

### 14b. Set the operator pod image to local registry

```bash
cd operator/config/pods
../../bin/kustomize edit set image controller=${LOCAL_IMG}
cd /root/openperouter
```

### 14c. Install CRDs + deploy operator

```bash
# Install all CRDs (including the OpenPERouter operator CRD)
bin/kustomize build operator/config/crd | oc apply -f -

# Deploy operator, RBAC, webhook, and namespace
bin/kustomize build operator/config/default | oc apply -f -
```

Wait for the operator pod:

```bash
oc rollout status deployment operator -n openperouter-system --timeout 60s
```

### 14d. Create the OpenPERouter CR

This triggers the operator to reconcile and create controller, router, and
nodemarker workloads:

```bash
cat <<CR | oc apply -f -
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: OpenPERouter
metadata:
  name: openperouter
  namespace: openperouter-system
spec:
  logLevel: debug
CR
```

Wait for all pods:

```bash
sleep 30
oc get pods -n openperouter-system
```

The operator auto-detects OpenShift and configures:
- Container runtime volume: `/var/run/crio` (not `/run/containerd`)
- SCC role bindings for privileged pods

---

## 15. Verify Final State

```bash
oc get pods -n openperouter-system
# All pods Running:
#   operator-xxxxx    1/1  Running  (×1)
#   webhook-xxxxx     1/1  Running  (×1)
#   controller-xxxxx  1/1  Running  (×5, created by operator)
#   nodemarker-xxxxx  1/1  Running  (×1, created by operator)
#   router-xxxxx      2/2  Running  (×5, created by operator)

oc get openperouter -n openperouter-system
# NAME           AGE
# openperouter   ...

oc get pods -n openshift-frr-k8s
# frr-k8s-xxxxx  7/7  Running  (×5)
# frr-k8s-statuscleaner-xxxxx  1/1  Running  (×1)

oc get nodes -o wide
# NAME       STATUS   ROLES                  INTERNAL-IP
# master-0   Ready    control-plane,master   192.168.111.20
# master-1   Ready    control-plane,master   192.168.111.21
# master-2   Ready    control-plane,master   192.168.111.22
# worker-0   Ready    worker                 192.168.111.23
# worker-1   Ready    worker                 192.168.111.24

# Verify operator auto-detected OpenShift and set CRI-O volume
oc get ds controller -n openperouter-system \
  -o jsonpath='{.spec.template.spec.volumes[1].hostPath.path}'
# /var/run/crio
```

---

## Environment Summary

| Item | Value |
|------|-------|
| Host OS | RHEL 10.2, kernel 6.12.0-211.28.1.el10_2.x86_64 |
| OCP | 4.22.1 (Kubernetes v1.35.5) |
| Node OS | RHCOS 9.8 (Plow), kernel 5.14.0-687.13.1.el9_8 |
| Container runtime (host) | podman 5.8.2 |
| Container runtime (nodes) | CRI-O 1.35.4 |
| Network plugin | OVNKubernetes |
| Baremetal bridge | `ostestbm` — 192.168.111.0/24, host at .1 |
| Extra networks | `toswitch1` — 192.168.11.0/24, `toswitch2` — 192.168.12.0/24 |
| Working dir | `/opt/dev-scripts` on `/dev/sda4` (XFS, 405 GB) |
| KUBECONFIG | `/root/dev-scripts/ocp/ostest/auth/kubeconfig` |
| Local registry | `virthost.ostest.test.metalkube.org:5000` (ocp-user/ocp-pass) |
| SELinux | Permissive |
| Firewall | Running (managed by dev-scripts/libvirt) |

---

## 16. Run E2E Tests

After the cluster and OpenPerOuter are deployed, set up the clab fabric and run tests:

```bash
# Set up clab fabric, wire to cluster, generate topology
./openshift/e2e/setup-clab.sh

# Run E2E tests (IPv4)
cd e2etests
KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig \
  CONTAINER_RUNTIME=podman \
  go test -count 1 -v ./suite/ \
    --infra-config=/root/openperouter/openshift/e2e/topology.json \
    --frrk8s-namespace=openshift-frr-k8s \
    -ginkgo.v -ginkgo.focus="for single stack ipv4"
cd ..

# Tear down
./openshift/e2e/teardown-clab.sh
```

**`CONTAINER_RUNTIME=podman`** is required — OCP servers have podman, not docker.
The test executor uses this for `podman exec` / `podman cp` on clab containers.

See `openshift/e2e/README.md` for details on what `setup-clab.sh` does.

---

## RHEL 10 Workarounds Summary

| Issue | Fix |
|-------|-----|
| dev-scripts rejects RHEL 10 in `01_install_requirements.sh` | Add `"rhel10"` to case, add RHEL 10 EPEL/CRB branch |
| dev-scripts rejects RHEL 10 in `02_configure_host.sh` | Add `rhel10` to libvirt case |
| `python39` package missing | Use `python3` (3.12, preinstalled) |
| `CI_TOKEN` required for nightly releases | Use explicit `OPENSHIFT_RELEASE_IMAGE` + `OPENSHIFT_CI=true` |

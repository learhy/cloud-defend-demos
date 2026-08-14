#!/bin/bash
# Set up the complete Cloud Defend demo on a Hetzner KVM VM.
# This is the ONE script the user runs after cloning the repo.
#
# It:
#   1. Creates the VM (k3s + BPF-LSM)
#   2. Waits for it to boot
#   3. Installs the eventdumper binary + demo policy
#   4. Creates k8s Deployments (debian + nginx)
#   5. Generates k8s-resources.yaml and starts eventdumper
#   6. Prints everything the user needs to demo: SSH command, policy file
#      path, kubectl exec commands, and the log-watching command
#
# Usage: export HCLOUD_TOKEN=*** && ./scripts/setup-demo.sh
#
set -e

VM_DIR="${VM_DIR:-./vm}"
SCRIPTS_DIR="$(dirname "$0")"
VM_NAME="${VM_NAME:-cloud-defend-kvm}"
SERVER_TYPE="${SERVER_TYPE:-cpx31}"

# ──────────────────────────────────────────────────────
# Step 1: Create the VM
# ──────────────────────────────────────────────────────
echo "============================================"
echo "  Cloud Defend Demo Setup"
echo "============================================"
echo ""

# Install hcloud if missing
if ! command -v hcloud &>/dev/null; then
    echo ">>> Installing hcloud CLI..."
    curl -sL https://github.com/hetznercloud/cli/releases/download/v1.51.0/hcloud-linux-amd64.tar.gz | tar xz -C /tmp
    mkdir -p ~/.local/bin && cp /tmp/hcloud ~/.local/bin/
fi

export HCLOUD_TOKEN="${HCLOUD_TOKEN:?HCLOUD_TOKEN environment variable is required}"

# Find or register SSH key
SSH_KEY_ID=$(hcloud ssh-key list 2>&1 | grep cloud-defend-demo | awk '{print $1}')
if [ -z "$SSH_KEY_ID" ]; then
    if [ ! -f "${VM_DIR}/ssh-keys/demo_key" ]; then
        mkdir -p "${VM_DIR}/ssh-keys"
        ssh-keygen -t ed25519 -f "${VM_DIR}/ssh-keys/demo_key" -N "" -C "cloud-defend-demo"
    fi
    PUBKEY=$(cat "${VM_DIR}/ssh-keys/demo_key.pub")
    hcloud ssh-key create --name cloud-defend-demo --public-key-from-file "${VM_DIR}/ssh-keys/demo_key.pub" 2>/dev/null || true
    SSH_KEY_ID=$(hcloud ssh-key list 2>&1 | grep cloud-defend-demo | awk '{print $1}')
fi
echo ">>> Using SSH key ID: $SSH_KEY_ID"

# Delete old VM if exists
hcloud server delete "$VM_NAME" 2>/dev/null || true
sleep 3

# Create VM
echo ">>> Creating Hetzner KVM VM ($SERVER_TYPE)..."
hcloud server create \
  --name "$VM_NAME" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --ssh-key "$SSH_KEY_ID" \
  --location ash \
  --user-data-from-file /dev/stdin << 'CLOUDINIT'
#cloud-config
hostname: cloud-defend-kvm
manage_etc_hosts: true

users:
  - name: demo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBry8f9JvIS9z6DqZrGetxzU9Xp7dVNNNh9Y+5OdvvJb cloud-defend-demo

packages:
  - jq curl wget clang-16 libbpf-dev linux-headers-generic build-essential linux-tools-generic bpftool

write_files:
  - path: /etc/default/grub.d/99-bpf-lsm.cfg
    content: |
      GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT lsm=lockdown,capability,yama,apparmor,bpf"

runcmd:
  - update-grub
  - |
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
    until kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 2; done
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
  - reboot
CLOUDINIT

VM_IP=$(hcloud server list 2>&1 | grep "$VM_NAME" | awk '{print $4}')
echo "$VM_IP" > "${VM_DIR}/kvm-vm-ip.txt"
echo ">>> VM created at IP: $VM_IP"

# ──────────────────────────────────────────────────────
# Step 2: Wait for VM to be ready
# ──────────────────────────────────────────────────────
echo ""
echo ">>> Waiting for VM to boot and install k3s (5 min)..."
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${VM_DIR}/ssh-keys/demo_key"
REMOTE="demo@${VM_IP}"

for i in $(seq 1 150); do
    if ssh -T $SSH_OPTS $REMOTE "cat /sys/kernel/security/lsm 2>/dev/null | grep -q bpf && sudo k3s kubectl get nodes 2>/dev/null | grep -q Ready" 2>/dev/null; then
        echo ">>> VM is ready! BPF-LSM enabled, k3s running."
        break
    fi
    if [ $((i % 30)) -eq 0 ]; then
        echo "    Still waiting... ($((i*2)) seconds)"
    fi
    sleep 2
done

# Verify
LSM=$(ssh -T $SSH_OPTS $REMOTE "cat /sys/kernel/security/lsm" 2>/dev/null)
if ! echo "$LSM" | grep -q bpf; then
    echo "ERROR: BPF-LSM not enabled. LSM list: $LSM"
    exit 1
fi
echo "    BPF-LSM: $LSM"

# ──────────────────────────────────────────────────────
# Step 3: Install eventdumper + demo policy
# ──────────────────────────────────────────────────────
echo ""
echo ">>> Installing eventdumper and demo policy..."
ssh -T $SSH_OPTS $REMOTE "sudo mkdir -p /opt/cloud-defend/policies && sudo chown -R demo:demo /opt/cloud-defend"
scp $SSH_OPTS "bin/eventdumper" $REMOTE:/opt/cloud-defend/eventdumper
scp $SSH_OPTS "policies/demo-policy.yaml" $REMOTE:/opt/cloud-defend/policies/
scp $SSH_OPTS "vm/k8s-resources.yaml" $REMOTE:/opt/cloud-defend/
ssh -T $SSH_OPTS $REMOTE "sudo chmod +x /opt/cloud-defend/eventdumper && sudo chmod -x /etc/update-motd.d/* 2>/dev/null; true"

# ──────────────────────────────────────────────────────
# Step 4: Create k8s Deployments
# ──────────────────────────────────────────────────────
echo ">>> Creating k8s Deployments..."
ssh -T $SSH_OPTS $REMOTE 'set -e
sudo k3s kubectl create namespace demo 2>/dev/null || true

cat << "EOF" | sudo k3s kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: debian-demo
  namespace: demo
  labels:
    app: debian
spec:
  replicas: 1
  selector:
    matchLabels:
      app: debian
  template:
    metadata:
      labels:
        app: debian
    spec:
      containers:
      - name: debian
        image: debian:bookworm
        command: ["sleep", "3600"]
        imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: demo
  labels:
    app: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        command: ["nginx", "-g", "daemon off;"]
        imagePullPolicy: IfNotPresent
EOF

sudo k3s kubectl -n demo wait --for=condition=Ready deployment/debian-demo --timeout=120s
sudo k3s kubectl -n demo wait --for=condition=Ready deployment/nginx-demo --timeout=120s

# Install procps and gzip in the debian pod
sudo k3s kubectl -n demo exec deployment/debian-demo -- apt-get update -qq
sudo k3s kubectl -n demo exec deployment/debian-demo -- apt-get install -y -qq procps gzip
echo "Pods ready."
'

# ──────────────────────────────────────────────────────
# Step 5: Generate k8s-resources.yaml and start eventdumper
# ──────────────────────────────────────────────────────
echo ">>> Generating k8s-resources.yaml and starting eventdumper..."
ssh -T $SSH_OPTS $REMOTE 'set -e
POD_INFO=$(sudo k3s kubectl -n demo get pods -o json)
echo "$POD_INFO" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pods_yaml = \"k8s_resources:\n  pods:\n\"
for pod in data[\"items\"]:
    name = pod[\"metadata\"][\"name\"]
    uid = pod[\"metadata\"][\"uid\"]
    ns = pod[\"metadata\"][\"namespace\"]
    labels = pod[\"metadata\"].get(\"labels\", {})
    host_ip = pod[\"status\"].get(\"hostIP\", \"\")
    pod_ip = pod[\"status\"].get(\"podIP\", \"\")
    node = pod[\"spec\"].get(\"nodeName\", \"\")
    for cs in pod[\"status\"][\"containerStatuses\"]:
        cid = cs[\"containerID\"].replace(\"containerd://\", \"\")
        cname = cs[\"name\"]
        img = cs[\"image\"]
        img_short = img.split(\"/\")[-1].split(\":\")[0]
        img_tag = img.split(\":\")[-1] if \":\" in img else \"\"
        img_long = img.split(\":\")[0] if \":\" in img else img
        labels_str = \"\\n\".join([f\"        {k}: {v}\" for k, v in labels.items()])
        pods_yaml += f\"\"\"    - uid: \"{uid}\"
      labels:
{labels_str}
      spec:
        name: {name}
        namespace: {ns}
        node_name: {node}
        containers:
          {cname}:
            name: {cname}
            image_name_long: {img_long}
            image_name_short: {img_short}
            image_tag: {img_tag}
      status:
        host_ip: {host_ip}
        pod_ips:
          - {pod_ip}
        container_statuses:
          {cname}:
            name: {cname}
            id: {cid}
            image_hash: \"\"
\"\"\"
with open(\"/opt/cloud-defend/k8s-resources.yaml\", \"w\") as f:
    f.write(pods_yaml)
print(\"k8s-resources.yaml generated\")
"

# Install the demo policy as the active config
sudo cp /opt/cloud-defend/policies/demo-policy.yaml /tmp/cloud-defend.yaml
sudo chown demo:demo /tmp/cloud-defend.yaml

# Start eventdumper
sudo systemctl stop eventdumper 2>/dev/null; sudo systemctl reset-failed eventdumper 2>/dev/null; sudo killall eventdumper 2>/dev/null; sleep 1
sudo systemd-run --unit=eventdumper /bin/bash -c "ulimit -l unlimited; cd /opt/cloud-defend && exec ./eventdumper --config /tmp/cloud-defend.yaml --k8s-resources /opt/cloud-defend/k8s-resources.yaml > /tmp/events.log 2>/tmp/stderr.log"
sleep 2

# Wait for probes
for i in $(seq 1 30); do
    COUNT=$(wc -l < /tmp/events.log 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ]; then
        echo "BPF probes loaded! $COUNT events"
        break
    fi
    sleep 2
done

# Send SIGUSR1 to load k8s pod info
ED_PID=$(pgrep eventdumper | tail -1)
sudo kill -USR1 $ED_PID
sleep 3
echo "Eventdumper running with demo policy and k8s pod tracking."
'

# ──────────────────────────────────────────────────────
# Step 6: Print the demo guide
# ──────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  DEMO IS READY"
echo "============================================"
echo ""
echo "SSH into the VM:"
echo "  ssh -i ${VM_DIR}/ssh-keys/demo_key demo@${VM_IP}"
echo ""
echo "Policy file (edit this live, then reload with SIGHUP):"
echo "  /tmp/cloud-defend.yaml"
echo ""
echo "Source policy with commented-out sections to uncomment:"
echo "  /opt/cloud-defend/policies/demo-policy.yaml"
echo ""
echo "Watch the live event stream (open a 2nd terminal):"
echo "  ssh -i ${VM_DIR}/ssh-keys/demo_key demo@${VM_IP} \"tail -f /tmp/events.log\""
echo ""
echo "Exec into the debian container (bash):"
echo "  sudo k3s kubectl -n demo exec -it deployment/debian-demo -- /bin/bash"
echo ""
echo "Exec into the nginx container (sh, no bash in alpine):"
echo "  sudo k3s kubectl -n demo exec -it deployment/nginx-demo -- /bin/sh"
echo ""
echo "Reload policy after editing (hot-swap, no restart):"
echo "  sudo kill -HUP \$(pgrep eventdumper)"
echo ""
echo "Delete a pod to test Deployment auto-restart:"
echo "  sudo k3s kubectl -n demo delete pods -l app=debian"
echo ""
echo "Destroy the VM when done:"
echo "  export HCLOUD_TOKEN=\$HCLOUD_TOKEN && ${SCRIPTS_DIR}/destroy-kvm-vm.sh"
echo ""
echo "============================================"
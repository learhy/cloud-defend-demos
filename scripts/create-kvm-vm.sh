#!/bin/bash
# Create a Hetzner Cloud VM with BPF-LSM enabled kernel + k3s installed.
# k3s runs pods directly on the host (no Docker nesting), so BPF-LSM hooks
# can see container cgroup paths and blocking works.
#
# Requirements:
#   - hcloud CLI (installed by this script if missing)
#   - HCLOUD_TOKEN environment variable
#   - An SSH key registered in Hetzner Cloud
#
set -e

VM_DIR="${VM_DIR:-./vm}"
SSH_PORT="${SSH_PORT:-22}"
VM_NAME="${VM_NAME:-cloud-defend-kvm}"
SERVER_TYPE="${SERVER_TYPE:-cpx31}"  # 4 vCPU, 8GB RAM, 160GB disk

# Install hcloud if missing
if ! command -v hcloud &>/dev/null; then
    echo ">>> Installing hcloud CLI..."
    curl -sL https://github.com/hetznercloud/cli/releases/download/v1.51.0/hcloud-linux-amd64.tar.gz | tar xz -C /tmp
    mkdir -p ~/.local/bin && cp /tmp/hcloud ~/.local/bin/
fi

export HCLOUD_TOKEN="${HCLOUD_TOKEN:?HCLOUD_TOKEN environment variable is required}"

# Find an SSH key
SSH_KEY_ID=$(hcloud ssh-key list 2>&1 | head -3 | tail -1 | awk '{print $1}')
if [ -z "$SSH_KEY_ID" ]; then
    echo "ERROR: No SSH key found in Hetzner Cloud. Add one first with:"
    echo "  hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_ed25519.pub"
    exit 1
fi
echo ">>> Using SSH key ID: $SSH_KEY_ID"

# Generate SSH key pair locally if not present
if [ ! -f "${VM_DIR}/ssh-keys/demo_key" ]; then
    echo ">>> Generating local SSH key pair..."
    mkdir -p "${VM_DIR}/ssh-keys"
    ssh-keygen -t ed25519 -f "${VM_DIR}/ssh-keys/demo_key" -N "" -C "cloud-defend-demo"
fi

# Read the actual public key
PUBKEY=$(cat "${VM_DIR}/ssh-keys/demo_key.pub")
echo ">>> Using SSH public key: ${PUBKEY}"

# Create cloud-init config (k3s installed directly on host, no Docker nesting)
cat > /tmp/cd-user-data.yaml << CLOUDINIT
#cloud-config
hostname: cloud-defend-kvm
manage_etc_hosts: true

users:
  - name: demo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUBKEY}

packages:
  - jq curl wget clang-16 libbpf-dev linux-headers-generic build-essential linux-tools-generic bpftool

write_files:
  - path: /etc/default/grub.d/99-bpf-lsm.cfg
    content: |
      GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT lsm=lockdown,capability,yama,apparmor,bpf"

runcmd:
  - update-grub
  - |
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
    until kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 2; done
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
  - reboot
CLOUDINIT

# Create the server
echo ">>> Creating Hetzner Cloud VM ($SERVER_TYPE)..."
hcloud server create \
  --name "$VM_NAME" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --ssh-key "$SSH_KEY_ID" \
  --location ash \
  --user-data-from-file /tmp/cd-user-data.yaml

# Get the IP
VM_IP=$(hcloud server list 2>&1 | grep "$VM_NAME" | awk '{print $4}')
echo "$VM_IP" > "${VM_DIR}/kvm-vm-ip.txt"

echo ""
echo ">>> VM created at IP: $VM_IP"
echo ">>> IP saved to ${VM_DIR}/kvm-vm-ip.txt"
echo ""
echo ">>> The VM will automatically:"
echo "    1. Install packages (clang-16, libbpf-dev, etc.)"
echo "    2. Install k3s (lightweight Kubernetes, runs directly on host)"
echo "    3. Configure grub with lsm=...bpf..."
echo "    4. Reboot to enable BPF-LSM"
echo ""
echo ">>> Wait ~5 minutes for cloud-init + k3s + reboot, then:"
echo "    ./scripts/install-eventdumper-on-kvm.sh $VM_IP"
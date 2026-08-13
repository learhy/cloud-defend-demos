#!/bin/bash
# Create a Hetzner Cloud VM with BPF-LSM enabled kernel.
# Hetzner Cloud VMs use real KVM, so the BPF verifier completes in seconds.
#
# Requirements:
#   - hcloud CLI (installed by this script if missing)
#   - HCLOUD_TOKEN environment variable
#   - An SSH key registered in Hetzner Cloud
#
set -e

SSH_PORT="${SSH_PORT:-22}"
VM_NAME="${VM_NAME:-cloud-defend-kvm}"
SERVER_TYPE="${SERVER_TYPE:-cpx22}"  # 2 vCPU, 4GB RAM, 80GB disk ~€4/mo

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

# Create cloud-init config
cat > /tmp/cd-user-data.yaml << 'EOF'
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
  - jq
  - curl
  - wget
  - clang-16
  - libbpf-dev
  - linux-headers-generic
  - build-essential
  - linux-tools-generic
  - bpftool

write_files:
  - path: /etc/default/grub.d/99-bpf-lsm.cfg
    content: |
      GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT lsm=lockdown,capability,yama,apparmor,bpf"

runcmd:
  - update-grub
  - reboot
EOF

# Create the server
echo ">>> Creating Hetzner Cloud VM ($SERVER_TYPE)..."
hcloud server create \
  --name "$VM_NAME" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --ssh-key "$SSH_KEY_ID" \
  --location fsn1 \
  --user-data-from-file /tmp/cd-user-data.yaml

# Get the IP
VM_IP=$(hcloud server list 2>&1 | grep "$VM_NAME" | awk '{print $4}')
echo ""
echo ">>> VM created at IP: $VM_IP"
echo ">>> The VM will automatically:"
echo "    1. Install packages (clang-16, libbpf-dev, etc.)"
echo "    2. Configure grub with lsm=...bpf..."
echo "    3. Reboot to enable BPF-LSM"
echo ""
echo ">>> Wait ~3 minutes for cloud-init + reboot, then:"
echo "    ssh -i vm/ssh-keys/demo_key demo@$VM_IP"
echo "    cat /sys/kernel/security/lsm  # should show 'bpf'"
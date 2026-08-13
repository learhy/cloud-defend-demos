#!/bin/bash
# Create a QEMU VM with BPF-LSM enabled kernel for the Cloud Defend demo.
#
# Requirements:
#   - qemu-system-x86_64
#   - cloud-localds (or genisoimage)
#   - wget
#   - ~20GB free disk space
#
set -e

VM_DIR="${VM_DIR:-./vm}"
VM_NAME="cloud-defend-demo"
VM_DISK="${VM_DIR}/${VM_NAME}.qcow2"
VM_SEED="${VM_DIR}/seed.img"
VM_PIDFILE="${VM_DIR}/vm.pid"
VM_CONSOLE="${VM_DIR}/vm-console.log"
SSH_PORT="${SSH_PORT:-2222}"
SSH_KEY_DIR="${VM_DIR}/ssh-keys"

# Generate SSH key if it doesn't exist
if [ ! -f "${SSH_KEY_DIR}/demo_key" ]; then
    echo ">>> Generating SSH key pair..."
    mkdir -p "${SSH_KEY_DIR}"
    ssh-keygen -t ed25519 -f "${SSH_KEY_DIR}/demo_key" -N "" -C "cloud-defend-demo"
fi

PUBKEY=$(cat "${SSH_KEY_DIR}/demo_key.pub")

# Update user-data.yaml with the actual SSH public key
cat > "${VM_DIR}/user-data.yaml" << EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: demo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUBKEY}

packages:
  - jq
  - curl
  - wget
  - openssh-server
  - clang-16
  - libbpf-dev
  - linux-headers-generic
  - build-essential
  - bpftool

write_files:
  - path: /etc/default/grub.d/99-bpf-lsm.cfg
    content: |
      GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT lsm=lockdown,capability,yama,apparmor,bpf"

runcmd:
  - update-grub
  - echo "VM ready" > /tmp/vm-ready
EOF

# Download Ubuntu cloud image if not present
CLOUD_IMG="${VM_DIR}/ubuntu-24.04-cloud.qcow2"
if [ ! -f "${CLOUD_IMG}" ]; then
    echo ">>> Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress \
        https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
        -O "${CLOUD_IMG}"
fi

# Create VM disk (copy from base image)
echo ">>> Creating VM disk..."
cp "${CLOUD_IMG}" "${VM_DISK}"
qemu-img resize "${VM_DISK}" 20G

# Create cloud-init seed
echo ">>> Creating cloud-init seed..."
cloud-localds "${VM_SEED}" "${VM_DIR}/user-data.yaml" "${VM_DIR}/meta-data.yaml"

# Check for KVM
ACCEL="tcg"
if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL="kvm"
    echo ">>> KVM available — using hardware acceleration"
else
    echo ">>> KVM not available — using TCG software emulation (slower)"
fi

# Start the VM
echo ">>> Starting VM..."
qemu-system-x86_64 \
    -name "${VM_NAME}" \
    -machine pc,accel=${ACCEL} \
    -cpu max \
    -smp 4 \
    -m 4096 \
    -drive file="${VM_DISK}",if=virtio,format=qcow2 \
    -drive file="${VM_SEED}",if=virtio,format=raw \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -serial file:"${VM_CONSOLE}" \
    -display none \
    -pidfile "${VM_PIDFILE}" &

echo ""
echo ">>> VM is starting."
echo ">>> Console log: ${VM_CONSOLE}"
echo ">>> SSH: ssh -i ${SSH_KEY_DIR}/demo_key -p ${SSH_PORT} demo@localhost"
echo ""
echo ">>> Wait for SSH: ./scripts/wait-for-vm.sh"
echo ">>> After first boot, the VM needs a reboot to enable BPF-LSM."
echo ">>> Run: ./scripts/install-on-vm.sh (handles reboot automatically)"
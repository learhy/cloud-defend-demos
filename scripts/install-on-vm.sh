#!/bin/bash
# Install the BPF-LSM demo on the VM.
# This script:
#   1. Copies the BPF demo source to the VM
#   2. Generates vmlinux.h from the VM's kernel BTF
#   3. Compiles the BPF program and userspace binary
#   4. Reboots the VM if BPF-LSM is not yet enabled
#
# Usage: ./scripts/install-on-vm.sh
#
set -e

VM_DIR="${VM_DIR:-./vm}"
SSH_KEY="${VM_DIR}/ssh-keys/demo_key"
SSH_PORT="${SSH_PORT:-2222}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@localhost -p ${SSH_PORT}"

echo ">>> Checking if BPF-LSM is enabled..."
LSM_OUTPUT=$(ssh ${SSH_OPTS} ${REMOTE} "cat /sys/kernel/security/lsm 2>/dev/null" 2>/dev/null || echo "")

if echo "${LSM_OUTPUT}" | grep -q "bpf"; then
    echo ">>> BPF-LSM is already enabled!"
else
    echo ">>> BPF-LSM is not enabled. Rebooting VM to apply grub config..."
    ssh ${SSH_OPTS} ${REMOTE} "sudo reboot" 2>/dev/null || true
    echo ">>> Waiting for VM to come back up..."
    sleep 60
    for i in $(seq 1 60); do
        if ssh ${SSH_OPTS} ${REMOTE} "echo alive" 2>/dev/null | grep -q alive; then
            break
        fi
        sleep 5
    done
    echo ">>> Checking BPF-LSM after reboot..."
    LSM_OUTPUT=$(ssh ${SSH_OPTS} ${REMOTE} "cat /sys/kernel/security/lsm 2>/dev/null" 2>/dev/null || echo "")
    if echo "${LSM_OUTPUT}" | grep -q "bpf"; then
        echo ">>> BPF-LSM is now enabled!"
    else
        echo "ERROR: BPF-LSM is still not enabled after reboot."
        echo "LSM list: ${LSM_OUTPUT}"
        exit 1
    fi
fi

echo ">>> Creating demo directory on VM..."
ssh ${SSH_OPTS} ${REMOTE} "mkdir -p ~/bpf-demo && echo ok"

echo ">>> Copying BPF demo source to VM..."
scp ${SSH_OPTS} -P ${SSH_PORT} \
    bpf-demo/lsm_demo.bpf.c \
    bpf-demo/lsm_demo_user.c \
    bpf-demo/Makefile \
    bpf-demo/policy-1-log-all.txt \
    bpf-demo/policy-2-block-and-protect.txt \
    ${REMOTE/\-p/}:~/bpf-demo/ 2>&1 || \
scp ${SSH_OPTS} -P ${SSH_PORT} \
    bpf-demo/lsm_demo.bpf.c \
    bpf-demo/lsm_demo_user.c \
    bpf-demo/Makefile \
    bpf-demo/policy-1-log-all.txt \
    bpf-demo/policy-2-block-and-protect.txt \
    demo@localhost:~/bpf-demo/ 2>&1

echo ">>> Generating vmlinux.h from kernel BTF..."
ssh ${SSH_OPTS} ${REMOTE} "cd ~/bpf-demo && mkdir -p headers && bpftool btf dump file /sys/kernel/btf/vmlinux format c > headers/vmlinux.h && echo 'vmlinux.h generated'"

echo ">>> Compiling BPF demo..."
ssh ${SSH_OPTS} ${REMOTE} "cd ~/bpf-demo && make clean && make 2>&1"

echo ">>> Installation complete!"
echo ">>> Test Policy 1: ./scripts/test-policy-1.sh"
echo ">>> Test Policy 2: ./scripts/test-policy-2.sh"
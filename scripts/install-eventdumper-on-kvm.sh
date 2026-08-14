#!/bin/bash
# Install the real Elastic Cloud Defend eventdumper on a KVM VM.
# SCPs the pre-built binary from ./bin/ and copies the YAML policies.
#
# Usage: ./scripts/install-eventdumper-on-kvm.sh <VM_IP>
#   (or set VM_IP env var)
#
# Prerequisites:
#   - VM created with ./scripts/create-kvm-vm.sh
#   - VM has rebooted and BPF-LSM is enabled
#
set -e

VM_IP="${1:-${VM_IP:?Usage: $0 <VM_IP>}}"
SSH_KEY="${SSH_KEY:-vm/ssh-keys/demo_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@${VM_IP}"
SSH_PORT="${SSH_PORT:-22}"
BIN_DIR="${BIN_DIR:-./bin}"

echo "============================================"
echo "  Installing Cloud Defend eventdumper on KVM VM"
echo "  VM IP: ${VM_IP}"
echo "============================================"
echo ""

# Step 0: Verify the binary exists locally
if [ ! -f "${BIN_DIR}/eventdumper" ]; then
    echo "ERROR: eventdumper binary not found at ${BIN_DIR}/eventdumper"
    echo "The binary is included in this repo via Git LFS."
    echo "Run: git lfs pull"
    exit 1
fi

# Step 1: Wait for VM SSH, then verify BPF-LSM
echo ">>> Step 1: Waiting for VM SSH and verifying BPF-LSM..."
MAX_WAIT=180
for i in $(seq 1 $MAX_WAIT); do
    LSM_OUTPUT=$(ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "cat /sys/kernel/security/lsm 2>/dev/null" 2>/dev/null || echo "")
    if echo "${LSM_OUTPUT}" | grep -q "bpf"; then
        echo "    BPF-LSM is enabled: ${LSM_OUTPUT}"
        break
    fi
    if [ $i -eq 1 ]; then
        echo "    VM not ready yet (may still be rebooting), waiting..."
    fi
    if [ $((i % 30)) -eq 0 ]; then
        echo "    Still waiting... ($i seconds elapsed)"
    fi
    sleep 2
done

if ! echo "${LSM_OUTPUT}" | grep -q "bpf"; then
    echo "ERROR: BPF-LSM is not enabled after ${MAX_WAIT} seconds."
    echo "LSM list: ${LSM_OUTPUT}"
    exit 1
fi
echo ""

# Step 2: Create directories and disable MOTD (speeds up SSH for test scripts)
echo ">>> Step 2: Creating directories..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo mkdir -p /opt/cloud-defend/policies && sudo chown -R demo:demo /opt/cloud-defend && sudo chmod -x /etc/update-motd.d/* 2>/dev/null; true"

# Step 3: SCP the eventdumper binary
echo ">>> Step 3: Copying eventdumper binary (${BIN_DIR}/eventdumper, ~80MB)..."
scp ${SSH_OPTS} -P ${SSH_PORT} "${BIN_DIR}/eventdumper" ${REMOTE}:/opt/cloud-defend/eventdumper
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo chmod +x /opt/cloud-defend/eventdumper && /opt/cloud-defend/eventdumper --help 2>&1 | head -3"
echo ""

# Step 4: Copy policies and k8s-resources config
echo ">>> Step 4: Copying policies..."
scp ${SSH_OPTS} -P ${SSH_PORT} \
    policies/policy-1-log-all-processes.yaml \
    policies/policy-2-block-commands-protect-passwd.yaml \
    ${REMOTE}:/opt/cloud-defend/policies/

scp ${SSH_OPTS} -P ${SSH_PORT} \
    vm/k8s-resources.yaml \
    ${REMOTE}:/opt/cloud-defend/

ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    sudo cp /opt/cloud-defend/policies/policy-1-log-all-processes.yaml /tmp/cloud-defend.yaml
    sudo cp /opt/cloud-defend/k8s-resources.yaml /tmp/k8s-resources.yaml
    sudo chown demo:demo /tmp/cloud-defend.yaml /tmp/k8s-resources.yaml
    echo "    Policies installed:"
    ls -la /opt/cloud-defend/policies/
EOF
echo ""

echo "============================================"
echo "  Installation complete!"
echo "============================================"
echo ""
echo "  Test Policy 1:  ./scripts/test-eventdumper-policy-1.sh ${VM_IP}"
echo "  Test Policy 2:  ./scripts/test-eventdumper-policy-2.sh ${VM_IP}"
echo "  Destroy VM:      ./scripts/destroy-kvm-vm.sh"
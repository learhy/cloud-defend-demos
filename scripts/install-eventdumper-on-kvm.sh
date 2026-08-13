#!/bin/bash
# Install the real Elastic Cloud Defend eventdumper on a KVM VM.
# This script:
#   1. Downloads the eventdumper binary from the cloud-defend-demo GitHub repo
#   2. Copies the real Cloud Defend YAML policies and fake-k8s config
#   3. Verifies BPF-LSM is enabled
#   4. Does NOT compile anything — the binary is pre-built and statically linked
#
# Usage: ./scripts/install-eventdumper-on-kvm.sh <VM_IP>
#   (or set VM_IP env var)
#
# Prerequisites:
#   - VM created with ./scripts/create-kvm-vm.sh
#   - SSH key at vm/ssh-keys/demo_key
#   - VM has rebooted and BPF-LSM is enabled (cat /sys/kernel/security/lsm shows bpf)
#
set -e

VM_IP="${1:-${VM_IP:?Usage: $0 <VM_IP>}}"
SSH_KEY="${SSH_KEY:-vm/ssh-keys/demo_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@${VM_IP}"
SSH_PORT="${SSH_PORT:-22}"

echo "============================================"
echo "  Installing Cloud Defend eventdumper on KVM VM"
echo "  VM IP: ${VM_IP}"
echo "============================================"
echo ""

# Step 1: Verify BPF-LSM is enabled
echo ">>> Step 1: Verifying BPF-LSM is enabled..."
LSM_OUTPUT=$(ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "cat /sys/kernel/security/lsm 2>/dev/null" 2>/dev/null || echo "")
if echo "${LSM_OUTPUT}" | grep -q "bpf"; then
    echo "    BPF-LSM is enabled: ${LSM_OUTPUT}"
else
    echo "ERROR: BPF-LSM is not enabled on the VM."
    echo "LSM list: ${LSM_OUTPUT}"
    echo "The VM may still be rebooting. Wait 2-3 minutes and retry."
    exit 1
fi
echo ""

# Step 2: Create directories on the VM
echo ">>> Step 2: Creating directories..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo mkdir -p /opt/cloud-defend/policies && sudo chown -R demo:demo /opt/cloud-defend"
echo ""

# Step 3: Download eventdumper from GitHub
echo ">>> Step 3: Downloading eventdumper binary..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    set -e
    cd /opt/cloud-defend
    # Download from the cloud-defend-demo repo (private, but binary is LFS)
    # If gh is not available, we'll SCP it from the host instead
    if command -v gh &>/dev/null; then
        gh repo clone learhy/cloud-defend-demo /tmp/cd-demo 2>/dev/null || true
        if [ -f /tmp/cd-demo/bin/eventdumper ]; then
            cp /tmp/cd-demo/bin/eventdumper /opt/cloud-defend/
            cp /tmp/cd-demo/policies/*.yaml /opt/cloud-defend/policies/
            echo "Downloaded from GitHub"
        fi
    fi
EOF

# If download didn't work, SCP from local host
if ! ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "test -f /opt/cloud-defend/eventdumper" 2>/dev/null; then
    echo "    GitHub download unavailable, SCPing from local host..."
    # Try to find the binary locally
    LOCAL_BIN=""
    for path in \
        /home/dan.rohan/cloud-defend-demo/bin/eventdumper \
        /home/dan.rohan/software/cloud-defend/artifacts/amd64/eventdumper \
        ../cloud-defend-demo/bin/eventdumper; do
        if [ -f "$path" ]; then
            LOCAL_BIN="$path"
            break
        fi
    done
    if [ -z "$LOCAL_BIN" ]; then
        echo "ERROR: Cannot find eventdumper binary locally."
        echo "Clone the cloud-defend-demo repo first:"
        echo "  git clone git@github.com:learhy/cloud-defend-demo.git"
        exit 1
    fi
    scp ${SSH_OPTS} -P ${SSH_PORT} "$LOCAL_BIN" ${REMOTE}:/opt/cloud-defend/eventdumper
    echo "    Copied eventdumper to VM"
fi

ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo chmod +x /opt/cloud-defend/eventdumper && /opt/cloud-defend/eventdumper --help 2>&1 | head -5"
echo ""

# Step 4: Copy policies and fake-k8s config
echo ">>> Step 4: Copying policies..."
scp ${SSH_OPTS} -P ${SSH_PORT} \
    policies/policy-1-log-all-processes.yaml \
    policies/policy-2-block-commands-protect-passwd.yaml \
    ${REMOTE}:/opt/cloud-defend/policies/ 2>&1 || true

scp ${SSH_OPTS} -P ${SSH_PORT} \
    vm/fake-k8s.yaml \
    ${REMOTE}:/opt/cloud-defend/ 2>&1 || true

# Also place config files at the default paths eventdumper expects
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    sudo cp /opt/cloud-defend/policies/policy-1-log-all-processes.yaml /tmp/cloud-defend.yaml
    sudo cp /opt/cloud-defend/fake-k8s.yaml /tmp/fake-k8s.yaml
    sudo chown demo:demo /tmp/cloud-defend.yaml /tmp/fake-k8s.yaml
    echo "    Policies installed:"
    ls -la /opt/cloud-defend/policies/
    echo "    Config at /tmp/cloud-defend.yaml and /tmp/fake-k8s.yaml"
EOF
echo ""

echo "============================================"
echo "  Installation complete!"
echo "============================================"
echo ""
echo "  Test Policy 1:  ./scripts/test-eventdumper-policy-1.sh ${VM_IP}"
echo "  Test Policy 2:  ./scripts/test-eventdumper-policy-2.sh ${VM_IP}"
echo ""

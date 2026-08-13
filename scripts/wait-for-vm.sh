#!/bin/bash
# Wait for the VM to be reachable via SSH.
# Usage: ./scripts/wait-for-vm.sh
#
set -e

VM_DIR="${VM_DIR:-./vm}"
SSH_KEY="${VM_DIR}/ssh-keys/demo_key"
SSH_PORT="${SSH_PORT:-2222}"
MAX_WAIT="${MAX_WAIT:-300}"  # 5 minutes

echo "Waiting for VM SSH on port ${SSH_PORT}..."

for i in $(seq 1 ${MAX_WAIT}); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
         -i "${SSH_KEY}" demo@localhost -p ${SSH_PORT} \
         "echo ok" 2>/dev/null | grep -q ok; then
        echo "VM is reachable via SSH!"
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
            -i "${SSH_KEY}" demo@localhost -p ${SSH_PORT} \
            "uname -r; cat /sys/kernel/security/lsm 2>/dev/null || echo 'lsm file not found'"
        exit 0
    fi
    sleep 2
done

echo "ERROR: VM did not become reachable within ${MAX_WAIT} seconds"
echo "Check the console log: ${VM_DIR}/vm-console.log"
exit 1
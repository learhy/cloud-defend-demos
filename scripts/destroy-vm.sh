#!/bin/bash
# Destroy the QEMU VM and clean up.
#
# Usage: ./scripts/destroy-vm.sh
#
set -e

VM_DIR="${VM_DIR:-./vm}"
VM_PIDFILE="${VM_DIR}/vm.pid"

if [ -f "${VM_PIDFILE}" ]; then
    PID=$(cat "${VM_PIDFILE}")
    echo ">>> Stopping VM (PID ${PID})..."
    kill "${PID}" 2>/dev/null || true
    sleep 3
    kill -9 "${PID}" 2>/dev/null || true
    rm -f "${VM_PIDFILE}"
fi

echo ">>> VM stopped."
echo ">>> Disk image preserved at: ${VM_DIR}/cloud-defend-demo.qcow2"
echo ">>> To fully clean up: rm -rf ${VM_DIR}"
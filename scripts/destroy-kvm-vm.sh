#!/bin/bash
# Destroy a Hetzner Cloud KVM VM created by create-kvm-vm.sh.
#
# Usage: ./scripts/destroy-kvm-vm.sh
#
set -e

VM_NAME="${VM_NAME:-cloud-defend-kvm}"
VM_DIR="${VM_DIR:-./vm}"

export HCLOUD_TOKEN="${HCLOUD_TOKEN:?HCLOUD_TOKEN environment variable is required}"

echo ">>> Deleting VM '${VM_NAME}'..."

# Power off and delete
hcloud server delete "${VM_NAME}" 2>&1 || echo "    (server may already be deleted)"

# Clean up local state
rm -f "${VM_DIR}/kvm-vm-ip.txt"

echo ">>> VM deleted."
echo ">>> Note: Hetzner bills by the hour. Cost for this VM was ~€0.01-0.05."

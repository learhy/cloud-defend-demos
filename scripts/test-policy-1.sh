#!/bin/bash
# Test Policy 1: Log all process activity.
# Starts the BPF-LSM demo with --log-all, generates some process activity,
# and shows the accumulated JSON event log.
#
# Usage: ./scripts/test-policy-1.sh
#
set -e

VM_DIR="${VM_DIR:-./vm}"
SSH_KEY="${VM_DIR}/ssh-keys/demo_key"
SSH_PORT="${SSH_PORT:-2222}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@localhost -p ${SSH_PORT}"

echo "============================================"
echo "  Policy 1: Log All Process Activity"
echo "============================================"
echo ""

# Kill any existing demo
ssh ${SSH_OPTS} ${REMOTE} "sudo killall demo 2>/dev/null; sleep 1; echo 'Previous demo stopped'"

# Start demo with log-all
echo ">>> Starting BPF-LSM demo (Policy 1: log all execs)..."
ssh ${SSH_OPTS} ${REMOTE} "sudo bash -c 'ulimit -l unlimited; cd ~/bpf-demo && ./demo --log-all > /tmp/policy1.log 2>/tmp/policy1-err.log & echo PID=\$!'"

# Wait for BPF to load
echo ">>> Waiting for BPF programs to load..."
sleep 5

# Show startup logs
echo ">>> Startup log:"
ssh ${SSH_OPTS} ${REMOTE} "cat /tmp/policy1-err.log"

# Generate some process activity
echo ""
echo ">>> Generating process activity (ls, cat, echo)..."
ssh ${SSH_OPTS} ${REMOTE} "ls /tmp > /dev/null 2>&1; cat /etc/hostname > /dev/null 2>&1; echo 'hello from VM'; sleep 2"

# Show results
echo ""
echo ">>> Event count:"
ssh ${SSH_OPTS} ${REMOTE} "wc -l /tmp/policy1.log"

echo ""
echo ">>> Sample events (last 10):"
ssh ${SSH_OPTS} ${REMOTE} "tail -10 /tmp/policy1.log"

echo ""
echo ">>> Unique process names seen:"
ssh ${SSH_OPTS} ${REMOTE} "cat /tmp/policy1.log | python3 -c 'import sys,json; comms=set(); [comms.add(json.loads(l)[\"comm\"]) for l in sys.stdin]; print(sorted(comms))' 2>/dev/null || echo '(python3 not available)'"

# Cleanup
ssh ${SSH_OPTS} ${REMOTE} "sudo killall demo 2>/dev/null"

echo ""
echo "============================================"
echo "  Policy 1 test complete!"
echo "============================================"
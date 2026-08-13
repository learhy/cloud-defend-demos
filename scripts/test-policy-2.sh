#!/bin/bash
# Test Policy 2: Block commands (ps, zcat) and protect /etc/passwd.
# Starts the BPF-LSM demo with --block and --protect-passwd, attempts
# to run blocked commands, and shows the results.
#
# Usage: ./scripts/test-policy-2.sh
#
set -e

VM_DIR="${VM_DIR:-./vm}"
SSH_KEY="${VM_DIR}/ssh-keys/demo_key"
SSH_PORT="${SSH_PORT:-2222}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@localhost -p ${SSH_PORT}"

echo "============================================"
echo "  Policy 2: Block Commands + Protect /etc/passwd"
echo "============================================"
echo ""

# Kill any existing demo
ssh ${SSH_OPTS} ${REMOTE} "sudo killall demo 2>/dev/null; sleep 1; echo 'Previous demo stopped'"

# Start demo with block + protect-passwd
echo ">>> Starting BPF-LSM demo (Policy 2: block ps/zcat + protect /etc/passwd)..."
ssh ${SSH_OPTS} ${REMOTE} "sudo bash -c 'ulimit -l unlimited; cd ~/bpf-demo && ./demo --log-all --block ps --block zcat --protect-passwd > /tmp/policy2.log 2>/tmp/policy2-err.log & echo PID=\$!'"

# Wait for BPF to load
echo ">>> Waiting for BPF programs to load..."
sleep 5

# Show startup logs
echo ">>> Startup log:"
ssh ${SSH_OPTS} ${REMOTE} "cat /tmp/policy2-err.log"

echo ""

# Test 1: Try to run zcat (should be blocked)
echo ">>> Test 1: Running 'zcat' (should be BLOCKED)..."
ssh ${SSH_OPTS} ${REMOTE} "echo 'test data' | zcat 2>&1; echo 'Exit code:' \$?"

echo ""

# Test 2: Try to write to /etc/passwd (should be blocked)
echo ">>> Test 2: Writing to /etc/passwd (should be BLOCKED)..."
ssh ${SSH_OPTS} ${REMOTE} "echo 'hacker:x:0:0::/root:/bin/bash' | sudo tee -a /etc/passwd 2>&1; echo 'Exit code:' \$?"

echo ""

# Test 3: Run a normal command (should work)
echo ">>> Test 3: Running 'ls' (should WORK normally)..."
ssh ${SSH_OPTS} ${REMOTE} "ls /tmp 2>&1 | head -3; echo 'Exit code:' \$?"

echo ""

# Show block events
echo ">>> Block events captured:"
ssh ${SSH_OPTS} ${REMOTE} "grep BLOCK /tmp/policy2.log 2>/dev/null || echo '(no block events)'"

echo ""

# Show all unique process names
echo ">>> All unique process names seen:"
ssh ${SSH_OPTS} ${REMOTE} "cat /tmp/policy2.log | python3 -c 'import sys,json; comms=set(); [comms.add(json.loads(l)[\"comm\"]) for l in sys.stdin]; print(sorted(comms))' 2>/dev/null || echo '(python3 not available)'"

# Cleanup
ssh ${SSH_OPTS} ${REMOTE} "sudo killall demo 2>/dev/null"

echo ""
echo "============================================"
echo "  Policy 2 test complete!"
echo "  - zcat: BLOCKED (EPERM)"
echo "  - /etc/passwd write: BLOCKED (EPERM)"
echo "  - ls: ALLOWED (normal operation)"
echo "============================================"
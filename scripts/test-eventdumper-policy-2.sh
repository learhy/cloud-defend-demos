#!/bin/bash
# Test Policy 2 with the REAL Cloud Defend eventdumper: Block commands + protect /etc/passwd.
# Starts eventdumper with the YAML policy, waits for BPF probes to load,
# attempts blocked operations, and shows the results.
#
# Usage: ./scripts/test-eventdumper-policy-2.sh <VM_IP>
#   (or set VM_IP env var)
#
set -e

VM_IP="${1:-${VM_IP:?Usage: $0 <VM_IP>}}"
SSH_KEY="${SSH_KEY:-vm/ssh-keys/demo_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@${VM_IP}"
SSH_PORT="${SSH_PORT:-22}"

echo "============================================"
echo "  Policy 2: Block Commands + Protect /etc/passwd"
echo "  (Real Cloud Defend eventdumper)"
echo "============================================"
echo ""

# Kill any existing eventdumper
echo ">>> Stopping any existing eventdumper..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo killall eventdumper 2>/dev/null; sleep 1; echo stopped"

# Copy Policy 2 config to /tmp/cloud-defend.yaml
echo ">>> Installing Policy 2 config..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo cp /opt/cloud-defend/policies/policy-2-block-commands-protect-passwd.yaml /tmp/cloud-defend.yaml && sudo chown demo:demo /tmp/cloud-defend.yaml"

# Start eventdumper in background
echo ">>> Starting eventdumper..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    sudo bash -c 'ulimit -l unlimited; cd /opt/cloud-defend && nohup ./eventdumper \
        --config /tmp/cloud-defend.yaml \
        --k8s-resources /opt/cloud-defend/fake-k8s.yaml \
        > /tmp/policy2-events.log 2>/tmp/policy2-stderr.log & echo PID=$!'
EOF

# Wait for BPF probes to load
echo ">>> Waiting for BPF probes to load (this can take 10-60 seconds on KVM)..."
for i in $(seq 1 60); do
    if ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "grep -q 'probes initialized' /tmp/policy2-stderr.log 2>/dev/null" 2>/dev/null; then
        echo "    BPF probes loaded after ${i} seconds!"
        break
    fi
    if ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "grep -qi 'error\|fail' /tmp/policy2-stderr.log 2>/dev/null" 2>/dev/null; then
        echo "    WARNING: error detected in startup log, checking..."
        ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "tail -10 /tmp/policy2-stderr.log"
        break
    fi
    sleep 2
done

# Show startup log
echo ""
echo ">>> Startup log (last 10 lines):"
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "tail -10 /tmp/policy2-stderr.log"
echo ""

# Test 1: Try to run zcat (should be blocked)
echo ">>> Test 1: Running 'zcat /etc/hostname' (should be BLOCKED)..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "zcat /etc/hostname 2>&1; echo 'Exit code:' \$?"
echo ""

# Test 2: Try to run ps (should be blocked)
echo ">>> Test 2: Running 'ps' (should be BLOCKED)..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "ps 2>&1; echo 'Exit code:' \$?"
echo ""

# Test 3: Try to write to /etc/passwd (should be blocked)
echo ">>> Test 3: Writing to /etc/passwd (should be BLOCKED)..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "echo 'hacker:x:0:0::/root:/bin/bash' | sudo tee -a /etc/passwd 2>&1; echo 'Exit code:' \$?"
echo ""

# Test 4: Run a normal command (should work)
echo ">>> Test 4: Running 'ls /tmp' (should WORK normally)..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "ls /tmp 2>&1 | head -5; echo 'Exit code:' \$?"
echo ""

# Wait for events to flush
sleep 3

# Show block events
echo ">>> Block events captured:"
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    if [ -s /tmp/policy2-events.log ]; then
        # Look for events with block=true
        grep -i '"block"' /tmp/policy2-events.log 2>/dev/null | tail -10 || echo '(no block events found in JSON)'
        echo ""
        echo "Total events:"
        wc -l /tmp/policy2-events.log
    else
        echo '(no events captured)'
    fi
EOF
echo ""

# Show unique process names from events
echo ">>> All unique process executables seen:"
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    if [ -s /tmp/policy2-events.log ]; then
        cat /tmp/policy2-events.log | python3 -c "
import sys, json
exes = set()
for line in sys.stdin:
    try:
        e = json.loads(line)
        # eventdumper outputs proto.Event JSON with body fields
        body = e.get('body', e)
        # Try various field paths for executable name
        exe = body.get('filename', body.get('execPath', body.get('comm', '')))
        if exe:
            exes.add(exe)
    except: pass
for x in sorted(exes):
    print(f'  {x}')
" 2>/dev/null || echo '(parse error)'
    else
        echo '(no events)'
    fi
EOF

# Cleanup
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo killall eventdumper 2>/dev/null"

echo ""
echo "============================================"
echo "  Policy 2 test complete!"
echo "============================================"
echo ""
echo "  Expected results:"
echo "    - zcat: BLOCKED (EPERM, exit code 126)"
echo "    - ps:    BLOCKED (EPERM)"
echo "    - /etc/passwd write: BLOCKED (EPERM)"
echo "    - ls:    ALLOWED (normal operation)"
echo ""
echo "  If blocking did not trigger, check:"
echo "    1. BPF-LSM is enabled (cat /sys/kernel/security/lsm | grep bpf)"
echo "    2. Policy 2 uses processExecutable (not processName) for ps/zcat"
echo "    3. The eventdumper binary matches the VM's architecture (amd64)"

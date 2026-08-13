#!/bin/bash
# Test Policy 1 with the REAL Cloud Defend eventdumper: Log all process activity.
# Starts eventdumper with the YAML policy, waits for BPF probes to load,
# generates process activity, and shows the accumulated JSON event stream.
#
# Usage: ./scripts/test-eventdumper-policy-1.sh <VM_IP>
#   (or set VM_IP env var)
#
set -e

VM_IP="${1:-${VM_IP:?Usage: $0 <VM_IP>}}"
SSH_KEY="${SSH_KEY:-vm/ssh-keys/demo_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@${VM_IP}"
SSH_PORT="${SSH_PORT:-22}"

echo "============================================"
echo "  Policy 1: Log All Process Activity"
echo "  (Real Cloud Defend eventdumper)"
echo "============================================"
echo ""

# Kill any existing eventdumper
echo ">>> Stopping any existing eventdumper..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo killall eventdumper 2>/dev/null; sleep 1; echo stopped"

# Copy Policy 1 config to /tmp/cloud-defend.yaml
echo ">>> Installing Policy 1 config..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo cp /opt/cloud-defend/policies/policy-1-log-all-processes.yaml /tmp/cloud-defend.yaml && sudo chown demo:demo /tmp/cloud-defend.yaml"

# Start eventdumper in background
echo ">>> Starting eventdumper..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    sudo bash -c 'ulimit -l unlimited; cd /opt/cloud-defend && nohup ./eventdumper \
        --config /tmp/cloud-defend.yaml \
        --k8s-resources /opt/cloud-defend/fake-k8s.yaml \
        > /tmp/policy1-events.log 2>/tmp/policy1-stderr.log & echo PID=$!'
EOF

# Wait for BPF probes to load (can take 10-60 seconds on KVM)
echo ">>> Waiting for BPF probes to load (this can take 10-60 seconds on KVM)..."
for i in $(seq 1 60); do
    if ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "grep -q 'probes initialized' /tmp/policy1-stderr.log 2>/dev/null" 2>/dev/null; then
        echo "    BPF probes loaded after ${i} seconds!"
        break
    fi
    if ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "grep -qi 'error\|fail' /tmp/policy1-stderr.log 2>/dev/null" 2>/dev/null; then
        echo "    WARNING: error detected in startup log, checking..."
        ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "tail -10 /tmp/policy1-stderr.log"
        break
    fi
    sleep 2
done

# Show startup log
echo ""
echo ">>> Startup log (last 10 lines):"
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "tail -10 /tmp/policy1-stderr.log"
echo ""

# Generate process activity
echo ">>> Generating process activity..."
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "ls /tmp > /dev/null; cat /etc/hostname; echo 'hello'; sleep 2"

# Wait for events to flush
sleep 3

# Show event count
echo ""
echo ">>> Event count:"
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "wc -l /tmp/policy1-events.log 2>/dev/null || echo '0 events'"
echo ""

# Show sample events
echo ">>> Sample events (last 10):"
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "tail -10 /tmp/policy1-events.log 2>/dev/null || echo '(no events yet)'"
echo ""

# Show unique event types
echo ">>> Unique event types:"
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} << 'EOF'
    if [ -s /tmp/policy1-events.log ]; then
        cat /tmp/policy1-events.log | python3 -c "
import sys, json
types = {}
for line in sys.stdin:
    try:
        e = json.loads(line)
        t = e.get('body', {}).get('type', e.get('type', 'unknown'))
        types[t] = types.get(t, 0) + 1
    except: pass
for t, c in sorted(types.items()):
    print(f'  {t}: {c}')
" 2>/dev/null || echo '(parse error)'
    else
        echo '(no events)'
    fi
EOF

# Cleanup
ssh ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo killall eventdumper 2>/dev/null"

echo ""
echo "============================================"
echo "  Policy 1 test complete!"
echo "============================================"

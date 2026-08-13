#!/bin/bash
# Test Policy 2 with the REAL Cloud Defend eventdumper: Block commands + protect /etc/passwd.
# Starts eventdumper via systemd-run, waits for BPF probes, attempts blocked
# operations, and shows the results.
#
# Usage: ./scripts/test-eventdumper-policy-2.sh <VM_IP>
#
set -e

VM_IP="${1:-${VM_IP:?Usage: $0 <VM_IP>}}"
SSH_KEY="${SSH_KEY:-vm/ssh-keys/demo_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@${VM_IP}"
SSH_PORT="${SSH_PORT:-22}"
EVT_LOG="/tmp/policy2-events.log"
ERR_LOG="/tmp/policy2-stderr.log"

echo "============================================"
echo "  Policy 2: Block Commands + Protect /etc/passwd"
echo "  (Real Cloud Defend eventdumper)"
echo "============================================"
echo ""

# Kill any existing eventdumper
echo ">>> Stopping any existing eventdumper..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo systemctl stop eventdumper 2>/dev/null; sudo systemctl reset-failed eventdumper 2>/dev/null; sudo killall eventdumper 2>/dev/null; echo stopped"

# Install Policy 2 config and create launcher script
echo ">>> Installing Policy 2 config..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "
sudo cp /opt/cloud-defend/policies/policy-2-block-commands-protect-passwd.yaml /tmp/cloud-defend.yaml
sudo chown demo:demo /tmp/cloud-defend.yaml
sudo tee /opt/cloud-defend/start-eventdumper.sh > /dev/null << 'LAUNCHER'
#!/bin/bash
ulimit -l unlimited
cd /opt/cloud-defend
exec ./eventdumper --config /tmp/cloud-defend.yaml --k8s-resources /opt/cloud-defend/fake-k8s.yaml > ${EVT_LOG} 2>${ERR_LOG}
LAUNCHER
sudo chmod +x /opt/cloud-defend/start-eventdumper.sh
echo done"

# Start eventdumper via systemd-run
echo ">>> Starting eventdumper..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo systemd-run --unit=eventdumper /opt/cloud-defend/start-eventdumper.sh 2>&1; sleep 1; systemctl is-active eventdumper"

# Wait for BPF probes to load
echo ">>> Waiting for BPF probes to load (can take 10-60 seconds on KVM)..."
PROBES_READY=0
for i in $(seq 1 30); do
    EVENT_COUNT=$(ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "wc -l < ${EVT_LOG} 2>/dev/null" 2>/dev/null | tr -d '\r\n ')
    if [ "${EVENT_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        echo "    BPF probes loaded! ${EVENT_COUNT} events captured after $((i*2)) seconds"
        PROBES_READY=1
        break
    fi
    sleep 2
done

if [ "${PROBES_READY}" -eq 0 ]; then
    echo "    WARNING: No events detected after 60 seconds, continuing anyway..."
    ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "tail -5 ${ERR_LOG} 2>/dev/null"
fi

echo ""

# Test 1: Try to run zcat (should be blocked)
echo ">>> Test 1: Running 'zcat /etc/hostname' (should be BLOCKED)..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "zcat /etc/hostname 2>&1; echo 'Exit code:' \$?"
echo ""

# Test 2: Try to run ps (should be blocked)
echo ">>> Test 2: Running 'ps' (should be BLOCKED)..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "ps 2>&1; echo 'Exit code:' \$?"
echo ""

# Test 3: Try to write to /etc/passwd (should be blocked)
echo ">>> Test 3: Writing to /etc/passwd (should be BLOCKED)..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "echo 'hacker:x:0:0::/root:/bin/bash' | sudo tee -a /etc/passwd 2>&1; echo 'Exit code:' \$?"
echo ""

# Test 4: Run a normal command (should work)
echo ">>> Test 4: Running 'ls /tmp' (should WORK normally)..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "ls /tmp 2>&1 | head -5; echo 'Exit code:' \$?"
echo ""

# Wait for events to flush
sleep 3

# Show event count and block events
echo ">>> Total events captured:"
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "wc -l ${EVT_LOG} 2>/dev/null || echo '0 events'"
echo ""

echo ">>> Events with block=true (should show blocked operations):"
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "grep '\"block\":true' ${EVT_LOG} 2>/dev/null | tail -10 || echo '(no block events found)'"
echo ""

echo ">>> Event type breakdown:"
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "python3 -c '
import json
types = {}
for line in open(\"${EVT_LOG}\"):
    try:
        e = json.loads(line)
        t = e.get(\"meta\", {}).get(\"type\", -1)
        names = {0: \"ProcessFork\", 1: \"ProcessExec\", 3: \"ProcessExit\", 4: \"ProcessSetsid\"}
        name = names.get(t, f\"type_{t}\")
        blocked = e.get(\"meta\", {}).get(\"block\", False)
        if blocked:
            name += \" [BLOCKED]\"
        types[name] = types.get(name, 0) + 1
    except: pass
for t, c in sorted(types.items()):
    print(f\"  {t}: {c}\")
' 2>/dev/null || echo '(parse error)'"

# Cleanup
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo systemctl stop eventdumper 2>/dev/null; sudo killall eventdumper 2>/dev/null"

echo ""
echo "============================================"
echo "  Policy 2 test complete!"
echo "============================================"
echo ""
echo "  Expected results:"
echo "    zcat: BLOCKED (EPERM, exit code 126)"
echo "    ps:    BLOCKED (EPERM)"
echo "    /etc/passwd write: BLOCKED (EPERM)"
echo "    ls:    ALLOWED (normal operation)"
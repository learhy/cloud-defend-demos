#!/bin/bash
# Test Policy 1 with the REAL Cloud Defend eventdumper: Log all process activity.
# Starts eventdumper via systemd-run (properly daemonized), waits for events,
# generates process activity, and shows the accumulated JSON event stream.
#
# Usage: ./scripts/test-eventdumper-policy-1.sh <VM_IP>
#
set -e

VM_IP="${1:-${VM_IP:?Usage: $0 <VM_IP>}}"
SSH_KEY="${SSH_KEY:-vm/ssh-keys/demo_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@${VM_IP}"
SSH_PORT="${SSH_PORT:-22}"
EVT_LOG="/tmp/policy1-events.log"
ERR_LOG="/tmp/policy1-stderr.log"

echo "============================================"
echo "  Policy 1: Log All Process Activity"
echo "  (Real Cloud Defend eventdumper)"
echo "============================================"
echo ""

# Kill any existing eventdumper
echo ">>> Stopping any existing eventdumper..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo systemctl stop eventdumper 2>/dev/null; sudo systemctl reset-failed eventdumper 2>/dev/null; sudo killall eventdumper 2>/dev/null; echo stopped"

# Install Policy 1 config and create launcher script
echo ">>> Installing Policy 1 config..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "
sudo cp /opt/cloud-defend/policies/policy-1-log-all-processes.yaml /tmp/cloud-defend.yaml
sudo chown demo:demo /tmp/cloud-defend.yaml
sudo tee /opt/cloud-defend/start-eventdumper.sh > /dev/null << 'LAUNCHER'
#!/bin/bash
ulimit -l unlimited
cd /opt/cloud-defend
exec ./eventdumper --config /tmp/cloud-defend.yaml --k8s-resources /opt/cloud-defend/k8s-resources.yaml > ${EVT_LOG} 2>${ERR_LOG}
LAUNCHER
sudo chmod +x /opt/cloud-defend/start-eventdumper.sh
echo done"

# Start eventdumper via systemd-run (properly daemonized, SSH returns immediately)
echo ">>> Starting eventdumper..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo systemd-run --unit=eventdumper /opt/cloud-defend/start-eventdumper.sh 2>&1; sleep 1; systemctl is-active eventdumper"

# Wait for BPF probes to load by checking for events in the output file
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

# Generate process activity
echo ">>> Generating process activity (ls, cat, echo)..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "ls /tmp > /dev/null; cat /etc/hostname; echo hello; sleep 2"

# Wait for events to flush
sleep 3

# Show results
echo ""
echo ">>> Event count:"
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "wc -l ${EVT_LOG}"

echo ""
echo ">>> Sample events (first 5):"
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "head -5 ${EVT_LOG}"

echo ""
echo ">>> Sample events (last 5):"
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "tail -5 ${EVT_LOG}"

echo ""
echo ">>> Event type breakdown:"
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "python3 -c '
import json, sys
types = {}
for line in open(\"${EVT_LOG}\"):
    try:
        e = json.loads(line)
        t = e.get(\"meta\", {}).get(\"type\", -1)
        names = {0: \"ProcessFork\", 1: \"ProcessExec\", 3: \"ProcessExit\", 4: \"ProcessSetsid\"}
        name = names.get(t, f\"type_{t}\")
        types[name] = types.get(name, 0) + 1
    except: pass
for t, c in sorted(types.items()):
    print(f\"  {t}: {c}\")
' 2>/dev/null || echo '(parse error)'"

# Cleanup
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} "sudo systemctl stop eventdumper 2>/dev/null; sudo killall eventdumper 2>/dev/null"

echo ""
echo "============================================"
echo "  Policy 1 test complete!"
echo "============================================"
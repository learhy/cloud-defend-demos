#!/bin/bash
# Set up k3s test pods and k8s-resources.yaml for container scenarios.
# Creates two pods (debian with procps+gzip, nginx), extracts container IDs,
# and writes the k8s-resources.yaml that eventdumper needs to track containers.
#
# Usage: ./scripts/setup-k3s-pods.sh <VM_IP>
#
set -e

VM_IP="${1:-${VM_IP:?Usage: $0 <VM_IP>}}"
SSH_KEY="${SSH_KEY:-vm/ssh-keys/demo_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${SSH_KEY}"
REMOTE="demo@${VM_IP}"
SSH_PORT="${SSH_PORT:-22}"

echo "============================================"
echo "  Setting up k3s test pods"
echo "  VM IP: ${VM_IP}"
echo "============================================"
echo ""

# Create namespace and pods
echo ">>> Creating test pods..."
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} 'set -e
sudo k3s kubectl create namespace demo 2>/dev/null || true

cat << "EOF" | sudo k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: debian-demo
  namespace: demo
  labels:
    app: debian
spec:
  containers:
  - name: debian
    image: debian:bookworm
    command: ["sleep", "3600"]
EOF

cat << "EOF" | sudo k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-demo
  namespace: demo
  labels:
    app: nginx
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["nginx", "-g", "daemon off;"]
EOF

sudo k3s kubectl -n demo wait --for=condition=Ready pod/debian-demo --timeout=120s
sudo k3s kubectl -n demo wait --for=condition=Ready pod/nginx-demo --timeout=120s

echo ">>> Installing procps and gzip in debian pod..."
sudo k3s kubectl -n demo exec debian-demo -- apt-get update -qq
sudo k3s kubectl -n demo exec debian-demo -- apt-get install -y -qq procps gzip

echo ">>> Verifying paths..."
sudo k3s kubectl -n demo exec debian-demo -- which ps
sudo k3s kubectl -n demo exec debian-demo -- which zcat
echo "Pods ready."
'

echo ""
echo ">>> Extracting container IDs and creating k8s-resources.yaml..."

# Extract container IDs and create k8s-resources.yaml
ssh -T ${SSH_OPTS} -p ${SSH_PORT} ${REMOTE} 'set -e
POD_INFO=$(sudo k3s kubectl -n demo get pods -o json)

# Extract pod info using python
echo "$POD_INFO" | python3 -c "
import json, sys
data = json.load(sys.stdin)

pods_yaml = \"k8s_resources:\n  pods:\n\"

for pod in data[\"items\"]:
    name = pod[\"metadata\"][\"name\"]
    uid = pod[\"metadata\"][\"uid\"]
    ns = pod[\"metadata\"][\"namespace\"]
    labels = pod[\"metadata\"].get(\"labels\", {})
    host_ip = pod[\"status\"].get(\"hostIP\", \"\")
    pod_ip = pod[\"status\"].get(\"podIP\", \"\")
    node = pod[\"spec\"].get(\"nodeName\", \"\")

    for cs in pod[\"status\"][\"containerStatuses\"]:
        cid = cs[\"containerID\"].replace(\"containerd://\", \"\")
        cname = cs[\"name\"]
        img = cs[\"image\"]
        img_short = img.split(\"/\")[-1].split(\":\")[0]
        img_tag = img.split(\":\")[-1] if \":\" in img else \"\"
        img_long = img.split(\":\")[0] if \":\" in img else img

        labels_str = \"\\n\".join([f\"        {k}: {v}\" for k, v in labels.items()])

        pods_yaml += f\"\"\"    - uid: \"{uid}\"
      labels:
{labels_str}
      spec:
        name: {name}
        namespace: {ns}
        node_name: {node}
        containers:
          {cname}:
            name: {cname}
            image_name_long: {img_long}
            image_name_short: {img_short}
            image_tag: {img_tag}
      status:
        host_ip: {host_ip}
        pod_ips:
          - {pod_ip}
        container_statuses:
          {cname}:
            name: {cname}
            id: {cid}
            image_hash: \"\"
\"\"\"

with open(\"/tmp/k8s-resources.yaml\", \"w\") as f:
    f.write(pods_yaml)
print(pods_yaml)
" > /tmp/k8s-resources-content.txt 2>&1

cat /tmp/k8s-resources-content.txt
sudo cp /tmp/k8s-resources.yaml /opt/cloud-defend/k8s-resources.yaml
echo ""
echo ">>> k8s-resources.yaml created and copied to /opt/cloud-defend/"
'

echo ""
echo "============================================"
echo "  Pod setup complete!"
echo "============================================"
echo ""
echo "  Now run the test scripts:"
echo "    ./scripts/test-eventdumper-policy-1.sh ${VM_IP}  # Scenario 1+2: logging"
echo "    ./scripts/test-eventdumper-policy-2.sh ${VM_IP}  # Scenario 3: blocking"
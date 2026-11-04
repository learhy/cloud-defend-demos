# Cloud Defend Demos

A complete, reproducible demo kit for **Elastic Cloud Defend** — a BPF-LSM based
runtime security tool for Linux. One script provisions everything. You SSH in,
run commands, edit a policy live, and watch the kernel enforce it in real time.

## Quick Start

```bash
git clone git@github.com:learhy/cloud-defend-demos.git
cd cloud-defend-demos
git lfs pull
export HCLOUD_TOKEN=your_hetzner_api_token
./scripts/setup-demo.sh
```

The script takes ~7 minutes. When it finishes, it prints:
- The SSH command to log in
- Where the live policy file is (`/tmp/cloud-defend.yaml`)
- The kubectl exec commands for the pods
- The command to watch the live event stream

## The Demo Flow

### 1. SSH in and watch events

```bash
# Terminal 1 — SSH in
ssh -i vm/ssh-keys/demo_key demo@<VM_IP>

# Terminal 2 — watch live events (from your laptop)
ssh -i vm/ssh-keys/demo_key demo@<VM_IP> "tail -f /tmp/events.log"
```

### 2. Exec into the container — ps and zcat are blocked, but files are unprotected

```bash
sudo k3s kubectl -n demo exec -it deployment/debian-demo -- /bin/bash
# Inside the container:
ps                           # Blocked: operation not permitted
zcat /etc/hostname            # Blocked: operation not permitted
rm /etc/passwd                # WORKS — no file protection yet
exit
```

### 3. Edit the policy live — enable FIM protection for /etc/passwd

```bash
nano /tmp/cloud-defend.yaml
# Uncomment the passwdModify, passwdDelete, passwdCreate selectors and responses
# Save and exit

# Hot-swap the policy (no restart needed)
sudo kill -HUP $(pgrep eventdumper)
```

### 4. Delete the pod — Deployment recreates it with a clean /etc/passwd

```bash
sudo k3s kubectl -n demo delete pods -l app=debian
sudo k3s kubectl -n demo wait --for=condition=Ready deployment/debian-demo --timeout=120s
```

### 5. Exec back in — now /etc/passwd is protected

```bash
sudo k3s kubectl -n demo exec -it deployment/debian-demo -- /bin/bash
# Inside:
zcat /etc/hostname            # Still blocked
rm /etc/passwd                 # Now BLOCKED: Operation not permitted
ls /tmp                        # Works normally
exit
```

### 6. Take questions, modify the policy live

Uncomment more lines in `/tmp/cloud-defend.yaml` to block `cat`, protect
`/etc/shadow`, change actions from `block` to `log`, etc. Each change: edit,
save, `sudo kill -HUP $(pgrep eventdumper)`, test.

### 7. Destroy the VM

```bash
./scripts/destroy-kvm-vm.sh
```

## How It Works

- **k3s** runs pods directly on the VM host (no Docker nesting)
- **BPF-LSM** hooks intercept syscalls before they complete
- **eventdumper** loads the BPF probes and reads the YAML policy
- **SIGHUP** reloads the policy file and pushes it to BPF maps in real time
- **Deployments** auto-restart deleted pods with fresh container filesystems

## Policy File

The demo uses a single policy file (`policies/demo-policy.yaml`) with
commented-out sections. Uncomment lines to enable FIM protection, block
additional commands, or change blocking to logging. The active copy on the VM
is at `/tmp/cloud-defend.yaml`.

## Repository Structure

```
cloud-defend-demos/
├── README.md                       ← This file
├── talk-track.md                   ← Presentation script
├── bin/                            ← Pre-built binaries (Git LFS)
│   └── eventdumper
├── policies/
│   └── demo-policy.yaml             ← Single policy with commented sections
├── k8s/
│   └── deployments.yaml             ← Debian + nginx Deployments
├── vm/
│   ├── ssh-keys/                    ← Demo SSH key (generated locally, gitignored)
│   └── k8s-resources.yaml
└── scripts/
    ├── setup-demo.sh                ← ONE script to provision everything
    ├── destroy-kvm-vm.sh            ← Destroy the VM
    ├── create-kvm-vm.sh             ← Create VM only (without pods/policy)
    ├── install-eventdumper-on-kvm.sh ← Install eventdumper only
    ├── setup-k3s-pods.sh            ← Create pods + k8s-resources.yaml only
    └── ...                          ← Fallback QEMU scripts
```

## Requirements

- Hetzner Cloud account (~€0.05 per run)
- `HCLOUD_TOKEN` environment variable
- `git lfs`

## License

BPF demo code: GPL-2.0. Cloud Defend: licensed by Elastic.
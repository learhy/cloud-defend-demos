# Cloud Defend Demos

A complete, reproducible demo kit for **Elastic Cloud Defend** — a BPF-LSM based
runtime security tool for Linux. One repo, one flow: spin up a VM with k3s,
install the agent, load policies, and watch real BPF-LSM security enforcement
in action across three scenarios.

## What Is Cloud Defend?

Cloud Defend is Elastic's "Defend for Containers." It uses Linux **BPF-LSM**
hooks to monitor and block process execution and file modifications at the
kernel level — *before* the operation completes. This is preemptive blocking,
not reactive logging.

## Three Scenarios

| # | Scenario | What happens |
|---|----------|-------------|
| 1 | **Logging on a bare VM** | Every fork and exec generates a JSON event — works on any host with BPF-LSM |
| 2 | **Logging in containers** | Same logging, but events show container cgroup paths and container IDs |
| 3 | **Blocking in containers** | `ps` and `zcat` are blocked with EPERM inside k8s pods; `/etc/passwd` writes are blocked |

**Why k3s?** Cloud Defend's BPF blocking code calls `calc_cnt_uuid()` which
extracts a container UUID from the process's cgroup path. On a bare VM (no
containers), this returns -1 and blocking is skipped. k3s runs pods directly
on the host — no Docker nesting — so the BPF-LSM hooks can see the container
cgroup paths and blocking works.

## Quick Start (~15 min, ~€0.05)

```bash
# 1. Clone this repo (includes the pre-built binary via Git LFS)
git clone git@github.com:learhy/cloud-defend-demos.git
cd cloud-defend-demos
git lfs pull

# 2. Set your Hetzner Cloud token (stored in ~/.hermes/.env as HETZNER_API_KEY)
export HCLOUD_TOKEN=your_hetzner_api_token

# 3. Create a KVM VM with k3s + BPF-LSM (cpx31: 4 vCPU, 8GB RAM, ~€0.05/hr)
./scripts/create-kvm-vm.sh

# 4. Wait ~5 min for cloud-init + k3s + reboot
#    Check: ssh -i vm/ssh-keys/demo_key demo@$(cat vm/kvm-vm-ip.txt) \
#            "cat /sys/kernel/security/lsm; sudo k3s kubectl get nodes"

# 5. Install eventdumper + policies on the VM
./scripts/install-eventdumper-on-kvm.sh $(cat vm/kvm-vm-ip.txt)

# 6. Create k3s test pods (debian + nginx) and fake-k8s.yaml
./scripts/setup-k3s-pods.sh $(cat vm/kvm-vm-ip.txt)

# 7. Test Scenario 1+2: Log all process activity (VM + containers)
./scripts/test-eventdumper-policy-1.sh $(cat vm/kvm-vm-ip.txt)

# 8. Test Scenario 3: Block commands + protect /etc/passwd in containers
./scripts/test-eventdumper-policy-2.sh $(cat vm/kvm-vm-ip.txt)

# 9. Destroy the VM when done
./scripts/destroy-kvm-vm.sh
```

## What You'll See

### Scenario 1+2: Logging (Policy 1)

The eventdumper outputs JSON events. On a KVM VM, BPF probes load in ~14
seconds and capture 200+ events:

```
BPF probes loaded! 77 events captured after 14 seconds

Event type breakdown:
  ProcessExec: 42
  ProcessExit: 12
  ProcessFork: 44
  ProcessSetsid: 40
```

After SIGUSR1 reload (loads k8s pod info), container events appear with
`"log":true` and containerd cgroup paths:

```json
{"meta":{"type":1,"log":true,"block":false},
 "body":{"pids":{"tgid":5320},
  "cwd":"/run/k3s/containerd/.../db2f5b573995154f.../rootfs",
  "filename":"/"}}
```

### Scenario 3: Blocking (Policy 2)

Blocked commands return EPERM:

```
$ kubectl exec debian-demo -- ps
exec /usr/bin/ps: operation not permitted        # exit 255

$ kubectl exec debian-demo -- zcat /etc/hostname
exec /usr/bin/zcat: operation not permitted       # exit 255

$ kubectl exec debian-demo -- sh -c "echo x >> /etc/passwd"
sh: 1: cannot create /etc/passwd: Operation not permitted  # exit 2

$ kubectl exec debian-demo -- ls /tmp             # works normally
$ ps aux                                          # works on host (not a container)
```

Block events in the JSON stream:

```json
{"meta":{"type":1,"block":true},"body":{"filename":"/usr/bin/ps"}}
{"meta":{"type":1,"block":true},"body":{"filename":"/usr/bin/zcat"}}
{"meta":{"type":7,"block":true},"body":{"filename":"/etc/passwd"}}
```

## Repository Structure

```
cloud-defend-demos/
├── README.md
├── talk-track.md                  ← Presentation script (~15 min demo)
├── bin/                           ← Pre-built binaries (Git LFS)
│   ├── eventdumper                ← Real Elastic eventdumper (80MB)
│   └── cloud-defend-debug-local   ← Debug-local build (137MB)
├── policies/                      ← Real Cloud Defend YAML policies
│   ├── policy-1-log-all-processes.yaml
│   └── policy-2-block-commands-protect-passwd.yaml
├── vm/                            ← VM provisioning config
│   ├── ssh-keys/                  ← Demo SSH key (in repo for reproducibility)
│   ├── fake-k8s.yaml
│   ├── user-data.yaml
│   └── meta-data.yaml
├── scripts/
│   ├── create-kvm-vm.sh           ← Create Hetzner KVM VM with k3s + BPF-LSM
│   ├── install-eventdumper-on-kvm.sh  ← Install eventdumper + policies
│   ├── setup-k3s-pods.sh          ← Create k3s pods + fake-k8s.yaml
│   ├── test-eventdumper-policy-1.sh   ← Scenarios 1+2: logging
│   ├── test-eventdumper-policy-2.sh   ← Scenario 3: blocking
│   ├── destroy-kvm-vm.sh          ← Destroy Hetzner VM
│   ├── create-vm.sh               ← Create local QEMU VM (fallback)
│   ├── wait-for-vm.sh
│   ├── install-on-vm.sh           ← Install minimal BPF demo (fallback)
│   ├── test-policy-1.sh
│   ├── test-policy-2.sh
│   └── destroy-vm.sh
└── bpf-demo/                      ← Minimal BPF-LSM demo (fallback for QEMU/TCG)
```

## Requirements

- [Hetzner Cloud](https://www.hetzner.com/cloud) account (~€0.05 per run)
- `hcloud` CLI (auto-installed by `create-kvm-vm.sh`)
- `HCLOUD_TOKEN` environment variable
- An SSH key registered in Hetzner Cloud (or let the script generate one)
- `git lfs` (to pull the pre-built binary)

## Key Design Notes

1. **k3s, not minikube**: minikube with `--driver=docker` nests k8s inside a
   Docker container. The BPF-LSM hooks can't see the nested container cgroup
   paths, so blocking doesn't work. k3s runs pods directly on the host, so
   the BPF hooks see the real cgroup paths and blocking works.

2. **`ps` blocking uses `processExecutable`**: `processName` matches
   `task->comm` (the calling process, e.g. `bash`), not the binary being
   exec'd. `processExecutable` matches `bprm->file->f_path` (the actual
   binary path, e.g. `/usr/bin/ps`).

3. **`/etc/passwd` protection blocks writes, not reads**: The `file_open`
   hook only fires for `FMODE_WRITE`. This prevents tampering — it does not
   prevent reading.

4. **BPF verifier needs KVM**: The real Cloud Defend BPF programs are
   extremely complex. The verifier completes in ~15 seconds on KVM but
   stalls indefinitely under QEMU TCG (software emulation).

5. **Debian, not Alpine**: Alpine uses BusyBox symlinks, so `ps` resolves to
   `/bin/busybox` inside the container. Debian has real binaries at
   `/usr/bin/ps` and `/usr/bin/zcat`, matching the policy paths.

## License

BPF demo code: GPL-2.0. Cloud Defend source: licensed by Elastic under various
licenses — see the source repo.
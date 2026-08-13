# Cloud Defend Demos

A complete, reproducible demo kit for **Elastic Cloud Defend** — a BPF-LSM based
runtime security tool for Linux. One repo, one flow: spin up a VM, install the
agent, load policies, watch real BPF-LSM enforcement in action.

## What Is Cloud Defend?

Cloud Defend is Elastic's "Defend for Containers." It uses Linux **BPF-LSM**
hooks to monitor and block process execution and file modifications at the
kernel level — *before* the operation completes. This is preemptive blocking,
not reactive logging.

This repo includes:
- Pre-built `eventdumper` binary (the real Elastic tool, 80MB, statically linked)
- Two security policies in the real Cloud Defend YAML format
- VM provisioning scripts (Hetzner KVM or local QEMU)
- Automated install and test scripts for both policies

## Policies

1. **Log all process activity** — every `fork` and `exec` generates a JSON event
2. **Block dangerous commands + protect `/etc/passwd`** — blocks `ps` and `zcat`
   execution, blocks writes to `/etc/passwd` (blocking requires a container —
   see [Limitations](#limitations) below)

## Quick Start (KVM, ~10 min, ~€0.01)

```bash
# 1. Clone this repo (includes the pre-built binary via Git LFS)
git clone git@github.com:learhy/cloud-defend-demos.git
cd cloud-defend-demos
git lfs pull

# 2. Set your Hetzner Cloud token
export HCLOUD_TOKEN=your_hetzner_api_token

# 3. Create a KVM VM (2 vCPU, 4GB RAM, Ubuntu 24.04, ~€4/mo billed by the hour)
./scripts/create-kvm-vm.sh

# 4. Wait ~3 min for cloud-init + reboot, then install the eventdumper + policies
./scripts/install-eventdumper-on-kvm.sh $(cat vm/kvm-vm-ip.txt)

# 5. Test Policy 1: log all process activity
./scripts/test-eventdumper-policy-1.sh $(cat vm/kvm-vm-ip.txt)

# 6. Test Policy 2: block commands + protect /etc/passwd
./scripts/test-eventdumper-policy-2.sh $(cat vm/kvm-vm-ip.txt)

# 7. Destroy the VM when done
./scripts/destroy-kvm-vm.sh
```

## What You'll See

### Policy 1: Log All Process Activity ✅

The eventdumper outputs JSON events to stdout. On a KVM VM, the BPF probes load
in ~15 seconds and you'll see 100+ events within seconds:

```
BPF probes loaded! 65 events captured after 14 seconds

Event type breakdown:
  ProcessFork: 40
  ProcessExec: 38
  ProcessExit: 12
  ProcessSetsid: 36
```

Sample events:
```json
{"meta":{"type":1,"hook_point":1,"log":false,"alert":false,"block":false},
 "body":{"pids":{"tgid":2579},"filename":"/usr/bin/bash","cwd":"/home/demo"}}
{"meta":{"type":1,"hook_point":1,"log":false,"alert":false,"block":false},
 "body":{"pids":{"tgid":2579},"filename":"/usr/bin/tail","cwd":"/home/demo"}}
```

### Policy 2: Block Commands + Protect /etc/passwd ⚠️

**Policy 2 loads and the BPF probes attach, but blocking does not trigger on a
bare VM.** This is by design — see [Limitations](#limitations) below.

The eventdumper will capture all process events (same as Policy 1), and the
policy maps are populated with the blocked executable paths, but the LSM
blocking hooks require a tracked container UUID. On a bare VM (no containers),
`calc_cnt_uuid()` returns -1 and the blocking code is skipped.

To see actual blocking, run the eventdumper inside a Kubernetes pod or a
container that cloud-defend recognizes.

## Limitations

Cloud Defend is designed for **Kubernetes containers**, not bare VMs. The BPF
blocking code calls `calc_cnt_uuid()` which extracts a container UUID from the
process's cgroup path. On a bare VM (no containers), this returns -1 and the
blocking logic is skipped. The result:

- **Policy 1 (logging)**: Works fully. The tracepoint probes that generate log
  events do not require a tracked container UUID — they emit events for all
  processes regardless of container membership.

- **Policy 2 (blocking)**: The BPF probes load and the policy maps are
  populated with the blocked executable paths (`/usr/bin/ps`, `/usr/bin/zcat`),
  but the LSM blocking hooks (`bprm_check_security`, `file_open`) check
  `calc_cnt_uuid()` before evaluating the policy and return 0 (allow) if the
  process is not in a tracked container.

To see Policy 2 blocking in action, the eventdumper must run inside a
Kubernetes pod or a container with a cgroup path that cloud-defend recognizes
as a `kubepods` cgroup.

## Quick Start (Local QEMU, no Hetzner needed)

A minimal BPF-LSM demo that demonstrates the same security concepts but with
simple BPF code that loads fast even under QEMU TCG emulation. This minimal
demo **does** block commands on a bare VM because it doesn't check for
container UUIDs.

```bash
git clone git@github.com:learhy/cloud-defend-demos.git
cd cloud-defend-demos

./scripts/create-vm.sh          # QEMU VM (auto-detects KVM or TCG)
./scripts/wait-for-vm.sh        # waits for SSH
./scripts/install-on-vm.sh     # compiles minimal BPF demo on VM
./scripts/test-policy-1.sh     # logs execs as JSON events
./scripts/test-policy-2.sh     # blocks zcat + /etc/passwd writes (works on bare VM!)
./scripts/destroy-vm.sh
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
│   ├── user-data.yaml
│   ├── meta-data.yaml
│   ├── fake-k8s.yaml
│   └── ssh-keys/                  ← Demo SSH key (in repo for reproducibility)
├── scripts/
│   ├── create-kvm-vm.sh           ← Create Hetzner KVM VM
│   ├── install-eventdumper-on-kvm.sh  ← Install eventdumper + policies
│   ├── test-eventdumper-policy-1.sh   ← Test Policy 1 (log all processes)
│   ├── test-eventdumper-policy-2.sh   ← Test Policy 2 (block + protect)
│   ├── destroy-kvm-vm.sh          ← Destroy Hetzner VM
│   ├── create-vm.sh               ← Create local QEMU VM (fallback)
│   ├── wait-for-vm.sh
│   ├── install-on-vm.sh           ← Install minimal BPF demo (fallback)
│   ├── test-policy-1.sh
│   ├── test-policy-2.sh
│   └── destroy-vm.sh
└── bpf-demo/                      ← Minimal BPF-LSM demo (fallback for QEMU/TCG)
    ├── lsm_demo.bpf.c
    ├── lsm_demo_user.c
    └── Makefile
```

## Requirements

### KVM path (real eventdumper)

- [Hetzner Cloud](https://www.hetzner.com/cloud) account (€0.01-0.05 per run)
- `hcloud` CLI (auto-installed by `create-kvm-vm.sh`)
- `HCLOUD_TOKEN` environment variable
- An SSH key registered in Hetzner Cloud (or let the script generate one)
- `git lfs` (to pull the pre-built binary)

### Local QEMU path (minimal demo, blocking works on bare VM)

- `qemu-system-x86_64`, `cloud-localds`, `ssh`, `scp`
- ~20GB disk, 4GB RAM
- KVM optional (falls back to TCG automatically)

## Key Design Notes

1. **`ps` blocking uses `processExecutable`**: `processName` matches `task->comm`
   (the calling process, e.g. `bash`), not the binary being exec'd.
   `processExecutable` matches `bprm->file->f_path` (the actual binary path).

2. **`/etc/passwd` protection blocks writes, not reads**: The `file_open` hook
   only fires for `FMODE_WRITE`. This prevents tampering — it does not prevent
   reading.

3. **BPF verifier needs KVM**: The real Cloud Defend BPF programs are extremely
   complex. The verifier completes in ~15 seconds on KVM but stalls
   indefinitely under QEMU TCG (software emulation). The minimal BPF demo is
   provided as a fallback for non-KVM environments.

4. **Blocking requires containers**: The BPF blocking code checks for a tracked
   container UUID via `calc_cnt_uuid()`. On a bare VM, this returns -1 and
   blocking is skipped. The minimal BPF demo doesn't have this check and blocks
   on bare VMs.

## License

BPF demo code: GPL-2.0. Cloud Defend source: licensed by Elastic under various
licenses — see the source repo.
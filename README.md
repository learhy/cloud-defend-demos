# Cloud Defend Demos

A complete, reproducible demo kit for **Elastic Cloud Defend** — a BPF-LSM based
runtime security tool for Linux. Spin up a VM, install the security agent, load
policies, and watch real BPF-LSM enforcement in action.

## What Is Cloud Defend?

Cloud Defend is Elastic's "Defend for Containers." It uses Linux **BPF-LSM**
(Berkeley Packet Filter — Linux Security Module) hooks to monitor and block
process execution and file modifications at the kernel level — *before* the
operation completes. This is preemptive blocking, not reactive logging.

This demo includes two policies:

1. **Log all process activity** — every `fork` and `exec` generates a JSON event
2. **Block dangerous commands + protect `/etc/passwd`** — blocks `ps` and `zcat`
   execution, blocks writes to `/etc/passwd`

## Two Ways To Run

### Path A: Real Cloud Defend eventdumper (recommended)

Uses the pre-built `eventdumper` binary from the
[cloud-defend-demo](https://github.com/learhy/cloud-defend-demo) repo. This is
the actual Elastic tool, loading the real BPF probes and processing the real
YAML policy language. Requires a **KVM VM** (the BPF verifier is too complex
for QEMU TCG emulation).

**Time:** ~10 minutes · **Cost:** ~€0.01 on Hetzner Cloud

```bash
# 1. Clone this repo
git clone git@github.com:learhy/cloud-defend-demos.git
cd cloud-defend-demos

# 2. Clone the binaries repo (private — needs GitHub access)
git clone git@github.com:learhy/cloud-defend-demo.git

# 3. Create a KVM VM on Hetzner Cloud
export HCLOUD_TOKEN=your_hetzner_token
./scripts/create-kvm-vm.sh

# 4. Wait ~3 min for cloud-init + reboot
#    Check: VM_IP=$(cat vm/kvm-vm-ip.txt)
#    ssh -i vm/ssh-keys/demo_key demo@$VM_IP cat /sys/kernel/security/lsm
#    Should show: lockdown,capability,yama,apparmor,bpf

# 5. Install eventdumper + policies on the VM
./scripts/install-eventdumper-on-kvm.sh $(cat vm/kvm-vm-ip.txt)

# 6. Test Policy 1: log all process activity
./scripts/test-eventdumper-policy-1.sh $(cat vm/kvm-vm-ip.txt)

# 7. Test Policy 2: block commands + protect /etc/passwd
./scripts/test-eventdumper-policy-2.sh $(cat vm/kvm-vm-ip.txt)

# 8. Destroy the VM when done
./scripts/destroy-kvm-vm.sh
```

### Path B: Minimal BPF-LSM demo (no KVM required)

Uses a minimal BPF-LSM program that demonstrates the same security concepts but
with simple BPF code that loads fast even under QEMU TCG emulation. Works on any
Linux host with QEMU. The policies are simple text files, not the real Cloud
Defend YAML format.

**Time:** ~5 minutes · **Cost:** free

```bash
# 1. Clone this repo
git clone git@github.com:learhy/cloud-defend-demos.git
cd cloud-defend-demos

# 2. Create a local QEMU VM (auto-detects KVM, falls back to TCG)
./scripts/create-vm.sh

# 3. Wait for SSH (2-3 min under TCG)
./scripts/wait-for-vm.sh

# 4. Install and compile the minimal BPF demo on the VM
./scripts/install-on-vm.sh

# 5. Test Policy 1: log all process activity
./scripts/test-policy-1.sh

# 6. Test Policy 2: block commands + protect /etc/passwd
./scripts/test-policy-2.sh

# 7. Destroy the VM when done
./scripts/destroy-vm.sh
```

## What You'll See

### Policy 1: Log All Process Activity

The eventdumper outputs JSON events to stdout. With the real eventdumper you'll
see events like:

```json
{"type":"process_fork_event","body":{"parent_pids":{"tgid":1,"pgid":1},"child_pids":{"tgid":2345,"pgid":2345},...}}
{"type":"process_exec_event","body":{"pids":{"tgid":2345},"filename":"/usr/bin/ls",...}}
```

With the minimal BPF demo you'll see simpler JSON:

```json
{"timestamp":1786608175,"pid":1176,"uid":0,"action":"LOG","op_type":"exec","comm":"sshd","filename":"/usr/sbin/sshd"}
{"timestamp":1786608176,"pid":1179,"uid":0,"action":"LOG","op_type":"exec","comm":"sh","filename":"/bin/sh"}
```

### Policy 2: Block Commands + Protect /etc/passwd

Blocked commands return `EPERM` (Operation not permitted):

```
$ zcat /etc/hostname
/usr/bin/zcat: 51: exec: gzip: Operation not permitted    # exit 126

$ echo hacker | sudo tee -a /etc/passwd
tee: /etc/passwd: Operation not permitted                 # exit 1

$ ls /tmp                                                 # works normally
```

## Repository Structure

```
cloud-defend-demos/
├── README.md                     ← This file
├── talk-track.md                  ← Presentation script for a ~15 min demo
│
├── policies/                      ← Real Cloud Defend YAML policies
│   ├── policy-1-log-all-processes.yaml
│   └── policy-2-block-commands-protect-passwd.yaml
│
├── vm/                            ← VM provisioning config
│   ├── user-data.yaml             ← Cloud-init (SSH keys, grub BPF-LSM)
│   ├── meta-data.yaml
│   └── fake-k8s.yaml              ← Empty k8s resources (eventdumper needs this)
│
├── scripts/                       ← Automation scripts
│   ├── create-kvm-vm.sh           ← Create Hetzner KVM VM (Path A)
│   ├── install-eventdumper-on-kvm.sh  ← Install eventdumper on KVM VM (Path A)
│   ├── test-eventdumper-policy-1.sh   ← Test Policy 1 with eventdumper (Path A)
│   ├── test-eventdumper-policy-2.sh   ← Test Policy 2 with eventdumper (Path A)
│   ├── destroy-kvm-vm.sh          ← Destroy Hetzner VM (Path A)
│   ├── create-vm.sh               ← Create local QEMU VM (Path B)
│   ├── wait-for-vm.sh             ← Wait for QEMU VM SSH (Path B)
│   ├── install-on-vm.sh           ← Install minimal BPF demo (Path B)
│   ├── test-policy-1.sh           ← Test Policy 1 with minimal demo (Path B)
│   ├── test-policy-2.sh           ← Test Policy 2 with minimal demo (Path B)
│   └── destroy-vm.sh              ← Destroy QEMU VM (Path B)
│
└── bpf-demo/                      ← Minimal BPF-LSM demo (Path B)
    ├── lsm_demo.bpf.c             ← BPF kernel program (exec + file_open hooks)
    ├── lsm_demo_user.c            ← Userspace event reader and policy loader
    ├── Makefile
    ├── policy-1-log-all.txt       ← Simple policy for minimal demo
    └── policy-2-block-and-protect.txt
```

## Requirements

### Path A (real eventdumper)

- A [Hetzner Cloud](https://www.hetzner.com/cloud) account (€0.01-0.05 per demo run)
- `hcloud` CLI (auto-installed by the script)
- `HCLOUD_TOKEN` environment variable
- An SSH key registered in Hetzner Cloud
- `git clone` access to the private `learhy/cloud-defend-demo` repo
- The VM gets: Ubuntu 24.04, kernel 6.8 with BPF-LSM, clang-16, libbpf-dev

### Path B (minimal BPF demo)

- Linux host with QEMU installed (`qemu-system-x86_64`)
- `cloud-localds` for cloud-init seed images
- `ssh` and `scp`
- ~20GB free disk, 4GB+ RAM
- KVM optional (falls back to TCG automatically)

## How It Works

### BPF-LSM Architecture

The demo uses two Linux Security Module hooks:

1. **`bprm_check_security`** — fires before every `execve()`. The BPF program
   checks the executable path against blocked paths and either logs the event
   or returns `-EPERM` to block execution.

2. **`file_open`** — fires on every file open. If the file is `/etc/passwd`
   opened for writing (`FMODE_WRITE`), the BPF program returns `-EPERM`.

### Event Delivery

Events flow from the BPF program to userspace via a **BPF ring buffer**. The
userspace process polls the ring buffer and prints each event as JSON to stdout.

### Policy Format

**Real Cloud Defend policies** (Path A) use the YAML format documented in the
[Cloud Defend policy guide](https://www.elastic.co/guide/en/security/current/d4c-policy-guide.html).
Policies consist of **selectors** (what to match) and **responses** (what to do
when matched). See the policy files in `policies/` for examples.

**Minimal demo policies** (Path B) use a simple text format:
```
log_all: true
block: ps
block: zcat
protect_passwd: true
```

## Key Design Notes

1. **`ps` blocking uses `processExecutable`, not `processName`**: The
   `processName` selector matches `task->comm` (the *calling* process name, e.g.
   `bash`), not the binary being exec'd. `processExecutable` matches
   `bprm->file->f_path` (the actual binary path, e.g. `/usr/bin/ps`).

2. **`/etc/passwd` protection blocks writes, not reads**: Cloud Defend's
   `file_open` hook only fires for files opened with `FMODE_WRITE`. Reads are
   not intercepted. This prevents tampering with the user database — it does
   not prevent reading it.

3. **BPF verifier complexity**: The real Cloud Defend BPF programs are among the
   most complex BPF programs ever written. They push the BPF verifier to its
   limits. Under QEMU TCG (software emulation), the verifier can take 10+
   minutes or never complete. On a real KVM VM, it completes in ~15 seconds.

4. **`zcat` blocking**: `zcat` is a shell script wrapper that calls `exec gzip`.
   The BPF program sees the `comm` field change to `zcat` at the wrapper level.
   The `processExecutable` path `/usr/bin/zcat` or `/bin/zcat` matches the
   binary path at `bprm_check_security` time.

## License

The BPF demo code is GPL-2.0 (required for BPF programs).
Cloud Defend source is licensed by Elastic under various licenses — see the
[cloud-defend-demo](https://github.com/learhy/cloud-defend-demo) repo.
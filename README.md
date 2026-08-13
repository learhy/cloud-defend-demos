# Cloud Defend Demos

A complete, reproducible demo kit for **Elastic Cloud Defend** — a BPF-LSM based
runtime security tool for Linux. This repo contains everything you need to spin
up a virtual machine, install the security agent, configure policies, and see
real BPF-LSM security enforcement in action.

## What is Cloud Defend?

Cloud Defend is Elastic's "Defend for Containers" — a tool that uses Linux
BPF-LSM (Berkeley Packet Filter - Linux Security Module) hooks to monitor and
block process execution and file modifications at the kernel level. It provides
a flexible policy language for defining security rules.

This demo includes:
1. A **minimal BPF-LSM security agent** that demonstrates the same concepts as
   the full Cloud Defend tool, but with simple BPF programs that load quickly
   even under QEMU TCG emulation.
2. **Two security policies** matching the Cloud Defend policy format.
3. **VM provisioning scripts** to create a QEMU VM with BPF-LSM enabled.
4. **Test scripts** to verify both policies work correctly.

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/learhy/cloud-defend-demos.git
cd cloud-defend-demos

# 2. Create the VM (requires QEMU, ~20GB disk, 4GB RAM)
./scripts/create-vm.sh

# 3. Wait for VM to boot and SSH to be available (~2-3 min under TCG)
./scripts/wait-for-vm.sh

# 4. Install the demo on the VM
./scripts/install-on-vm.sh

# 5. Test Policy 1: Log all process activity
./scripts/test-policy-1.sh

# 6. Test Policy 2: Block commands and protect /etc/passwd
./scripts/test-policy-2.sh

# 7. When done, destroy the VM
./scripts/destroy-vm.sh
```

## What You'll See

### Policy 1: Log All Process Activity

Every `execve()` system call generates a JSON event printed to stdout:

```json
{"timestamp":1786608175,"pid":1176,"uid":0,"action":"LOG","op_type":"exec","comm":"sshd","filename":"/usr/sbin/sshd"}
{"timestamp":1786608176,"pid":1179,"uid":0,"action":"LOG","op_type":"exec","comm":"sh","filename":"/bin/sh"}
{"timestamp":1786608176,"pid":1180,"uid":0,"action":"LOG","op_type":"exec","comm":"env","filename":"/usr/bin/env"}
```

### Policy 2: Block Commands + Protect /etc/passwd

Blocked commands return `EPERM` (Operation not permitted):

```
$ zcat /etc/hostname
/usr/bin/zcat: 51: exec: gzip: Operation not permitted

$ echo test | sudo tee -a /etc/passwd
tee: /etc/passwd: Operation not permitted
```

Block events are logged as JSON:

```json
{"timestamp":1786608411,"pid":2314,"uid":1000,"action":"BLOCK","op_type":"exec","comm":"zcat","filename":"/usr/bin/gzip"}
{"timestamp":1786608411,"pid":2318,"uid":0,"action":"BLOCK","op_type":"file_write","comm":"tee","filename":"/etc/passwd"}
```

## Repository Structure

```
cloud-defend-demos/
├── README.md                  ← This file
├── vm/
│   ├── user-data.yaml         ← Cloud-init config (SSH keys, grub BPF-LSM)
│   ├── meta-data.yaml         ← Cloud-init metadata
│   └── create-vm.sh           ← QEMU VM creation script
├── bpf-demo/
│   ├── lsm_demo.bpf.c         ← BPF-LSM kernel program (exec + file_open hooks)
│   ├── lsm_demo_user.c        ← Userspace event reader and policy loader
│   ├── Makefile               ← Build system for BPF demo
│   ├── policy-1-log-all.txt   ← Simple policy: log all process activity
│   └── policy-2-block.txt     ← Simple policy: block ps/zcat + protect passwd
├── policies/
│   ├── policy-1-log-all-processes.yaml       ← Cloud Defend format policy
│   └── policy-2-block-commands-protect-passwd.yaml ← Cloud Defend format policy
└── scripts/
    ├── create-vm.sh           ← Create the QEMU VM
    ├── wait-for-vm.sh         ← Wait for SSH to be available
    ├── install-on-vm.sh       ← Install BPF demo on the VM
    ├── test-policy-1.sh       ← Test logging policy
    ├── test-policy-2.sh       ← Test blocking policy
    └── destroy-vm.sh          ← Destroy the VM
```

## Requirements

### Host Machine (where you run the scripts)
- Linux with QEMU installed (`qemu-system-x86_64`)
- `cloud-localds` (for cloud-init seed image)
- `ssh` and `scp`
- ~20GB free disk space
- 4GB+ RAM for the VM

### VM (created by the scripts)
- Ubuntu 24.04 LTS cloud image
- Kernel 5.10+ with `CONFIG_BPF_LSM=y`
- Boot parameter `lsm=...bpf...` (configured automatically via grub)
- `clang-16`, `libbpf-dev`, `linux-headers`, `build-essential` (installed automatically)

## How It Works

### BPF-LSM Architecture

The demo uses two Linux Security Module (LSM) hooks:

1. **`bprm_check_security`** — Fires before every `execve()` call. The BPF
   program checks the process name against a hash map of blocked commands and
   either logs the event or returns `-EPERM` to block execution.

2. **`file_open`** — Fires on every file open. The BPF program checks if the
   file is `/etc/passwd` and opened for writing (`FMODE_WRITE`), and if so,
   returns `-EPERM` to block the write.

### Communication Between Kernel and Userspace

Events flow from the BPF program to userspace via a **BPF ring buffer**:
- The BPF program reserves space in the ring buffer with `bpf_ringbuf_reserve()`
- Fills in an event struct (pid, uid, comm, filename, blocked flag)
- Submits with `bpf_ringbuf_submit()`
- The userspace program polls the ring buffer with `ring_buffer__poll()` and
  prints each event as JSON to stdout

### Policy Configuration

The userspace program reads policy from command-line flags or a simple YAML-like
file. Blocked commands are written to a BPF hash map (`blocked_commands`) that
the BPF program queries on every exec.

## Limitations and Notes

1. **`ps` blocking**: The BPF program uses `bpf_get_current_comm()` to get the
   process name, which at `bprm_check_security` time returns the *calling*
   process name (usually `bash`), not the binary being exec'd. The full Cloud
   Defend tool handles this with complex BPF code that reads `bprm->filename`,
   but that code is too complex for the BPF verifier under QEMU TCG emulation.
   `zcat` is blocked because it's a shell script wrapper that calls `gzip` via
   `exec`, and at that point `comm` is `zcat`.

2. **No KVM**: If your host supports KVM (hardware virtualization), the VM will
   be much faster and the full Cloud Defend `eventdumper` binary (included in
   the `cloud-defend-demo` repo) may also work. Without KVM (nested virt), we
   use QEMU TCG which is slower.

3. **File read blocking**: Cloud Defend's `file_open` hook only fires for files
   opened for **writing** (`FMODE_WRITE`). Reads are not intercepted. This is a
   design decision in the BPF-LSM hooks — the tool prevents tampering with
   `/etc/passwd`, not reading it.

4. **Full Cloud Defend**: The pre-built `cloud-defend` and `eventdumper` binaries
   are in the [cloud-defend-demo](https://github.com/learhy/cloud-defend-demo)
   repo. These work on real KVM machines with BPF-LSM but their BPF programs are
   too complex for the QEMU TCG verifier to complete in reasonable time.

## License

The BPF demo code is licensed under GPL-2.0 (required for BPF programs).
The Cloud Defend source is licensed by Elastic under various licenses — see
the [cloud-defend-demo](https://github.com/learhy/cloud-defend-demo) repo.
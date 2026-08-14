# Cloud Defend Demo — Talk Track

**Audience:** Staff engineers, security architects, product leaders
**Duration:** ~15 minutes live demo + Q&A
**Setup:** VM provisioned by `./scripts/setup-demo.sh`, eventdumper running, two
k8s Deployments (debian + nginx), demo policy active with FIM lines commented out.
**Presenter:** Dan Rohan — PM, not a kernel engineer. Frame: "I learned this from
the team."

---

## Part 1: Opening (2 min)

I'm not a BPF programmer. I'm a product manager who's spent enough time around
kernel-adjacent infrastructure to know what's interesting and what's not. And
this is interesting.

The problem we're solving: how do you enforce security policy on a running
system — not after the fact, not by reading logs tomorrow, but *before* the
operation completes? Traditional tools like auditd, fanotify, even ptrace-based
approaches — they all either fire after the damage is done, or they're
race-prone, or they're too slow for production.

BPF-LSM is different. It attaches eBPF programs to Linux Security Module hooks
that fire *before* a syscall completes. The kernel calls your BPF program, your
program checks a policy, and either allows or denies. No TOCTOU gap, no race
condition, no userspace round-trip.

Cloud Defend takes that kernel mechanism and wraps it in a YAML policy language
so someone like me — who writes YAML, not C — can define what's allowed and
what's blocked on a k8s cluster.

Let me show you.

---

## Part 2: The Environment (1 min)

This is a real Hetzner KVM VM running Ubuntu 24.04 with kernel 6.8. BPF-LSM is
enabled — you can see `bpf` in the LSM list:

```bash
cat /sys/kernel/security/lsm
# lockdown,capability,yama,apparmor,bpf
```

On this VM, k3s is running two Deployments — a Debian pod and an Nginx pod.
The eventdumper binary — the real Elastic Cloud Defend tool — is running as a
systemd service with BPF probes attached.

I have two terminals open. In this one, I'll run commands. In the other, I have
the live event stream running:

```bash
tail -f /tmp/events.log
```

Every fork, exec, file open — all streaming as JSON in real time.

---

## Part 3: Policy 1 — Block Commands, No FIM (4 min)

The active policy is at `/tmp/cloud-defend.yaml`. Right now it does two things:

1. Blocks `ps` and `zcat` execution — returns EPERM
2. Logs all other exec events silently

Everything else is allowed. File operations are completely unprotected.

Let me demonstrate. I'll exec into the Debian container:

```bash
sudo k3s kubectl -n demo exec -it deployment/debian-demo -- /bin/bash
```

I'm now root inside a container in a k8s pod. Let me try `ps`:

```bash
ps
# exec /usr/bin/ps: operation not permitted
```

Blocked. EPERM. The BPF-LSM hook intercepted the execve syscall and returned
-EACCES before the binary ever ran. If you look at the event stream, you can see
the block event:

```json
{"meta":{"type":1,"block":true},"body":{"filename":"/usr/bin/ps"}}
```

Now let me try something that's NOT blocked — deleting `/etc/passwd`:

```bash
rm /etc/passwd
# It works. No error. File is gone.
```

That's the point. The policy blocks specific commands, but file operations are
completely unprotected right now. I just deleted the user database and the
kernel let me do it.

Let me exit the container.

```bash
exit
```

---

## Part 4: Hot-Swap — Enable FIM Protection (3 min)

Now watch this. I'm going to edit the policy *while it's running* — no restart,
no re-attach, no downtime. The eventdumper reads the config on SIGHUP and pushes
the new policy to the BPF maps in real time.

```bash
nano /tmp/cloud-defend.yaml
```

I'm uncommenting the FIM protection lines for `/etc/passwd`. These lines add file
selectors for `modifyFile`, `deleteFile`, and `createFile` targeting
`/etc/passwd`, with `block, alert` actions.

I save the file, then reload:

```bash
sudo kill -HUP $(pgrep eventdumper)
```

That's it. The new policy is live. Let me prove it by deleting the pod and
letting the Deployment restart it — fresh container, clean `/etc/passwd`:

```bash
sudo k3s kubectl -n demo delete pods -l app=debian
# pod deleted
# wait ~30 seconds for the Deployment to recreate it
sudo k3s kubectl -n demo wait --for=condition=Ready deployment/debian-demo --timeout=120s
```

Pod is back. Let me exec in again:

```bash
sudo k3s kubectl -n demo exec -it deployment/debian-demo -- /bin/bash
```

Now try `zcat` — still blocked:

```bash
zcat /etc/hostname
# exec /usr/bin/zcat: operation not permitted
```

Now try deleting `/etc/passwd`:

```bash
rm /etc/passwd
# rm: cannot remove '/etc/passwd': Operation not permitted
```

**Blocked.** Same kernel, same container, same root user — but the policy
changed, and now the BPF-LSM hook intercepts the file operation.

And in the event stream, you can see the block event:

```json
{"meta":{"type":7,"block":true},"body":{"filename":"/etc/passwd"}}
```

This is the key demo moment: I changed a YAML file, sent one signal, and the
kernel's security policy changed in real time. No reboot, no recompile, no
container restart.

---

## Part 5: Live Policy Tweaks — Q&A (5 min)

Now I'll take questions and modify the policy live based on what people ask.

Common requests:
- "Can you also block `cat`?" → Uncomment the `blockCat` selector and response, SIGHUP
- "What about `/etc/shadow`?" → Uncomment the `shadowModify`/`shadowDelete` selectors and responses, SIGHUP
- "Can you log instead of block?" → Change `actions: [block, alert]` to `actions: [log]`, SIGHUP
- "Can you block all writes to `/etc/**`?" → Add a selector with `targetFilePath: [/etc/**]` and `operation: [modifyFile, deleteFile, createFile]`

Every change is the same: edit YAML, SIGHUP, test. The BPF programs stay loaded,
the probes stay attached, the policy maps get updated.

---

## Part 6: Closing — Why This Matters (2 min)

The thing I want you to take away: this is kernel-level enforcement that's
controlled by YAML. Not a bash wrapper, not an audit log you read tomorrow, not
a fanotify daemon that races with the attacker. The kernel calls your BPF
program before the syscall completes, your program checks a policy map, and
the operation is allowed or denied before it happens.

That's the preemptive blocking story. No TOCTOU, no race, no bypass through
symlinks or interpreters — because the kernel itself is making the decision.

The policy language — selectors, responses, wildcards, excludes — that's the
product surface. The BPF verifier, the hash map lookups, the tail call chains,
the dentry walks — that's the engineering. The demo you just saw is the bridge:
YAML in, kernel enforcement out, hot-swap in real time.

---

## Appendix: Quick Reference

### Files on the VM
| File | Purpose |
|------|---------|
| `/tmp/cloud-defend.yaml` | Active policy (edit this, then SIGHUP) |
| `/opt/cloud-defend/policies/demo-policy.yaml` | Source policy with commented sections |
| `/tmp/events.log` | Live JSON event stream |
| `/tmp/stderr.log` | Eventdumper startup/debug logs |

### Commands
| Action | Command |
|--------|---------|
| SSH in | `ssh -i vm/ssh-keys/demo_key demo@<VM_IP>` |
| Watch events | `tail -f /tmp/events.log` |
| Exec into debian | `sudo k3s kubectl -n demo exec -it deployment/debian-demo -- /bin/bash` |
| Exec into nginx | `sudo k3s kubectl -n demo exec -it deployment/nginx-demo -- /bin/sh` |
| Reload policy | `sudo kill -HUP $(pgrep eventdumper)` |
| Delete debian pod | `sudo k3s kubectl -n demo delete pods -l app=debian` |
| Destroy VM | `./scripts/destroy-kvm-vm.sh` |

### One-Liner Setup
```bash
export HCLOUD_TOKEN=***
./scripts/setup-demo.sh
```
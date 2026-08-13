# Cloud Defend Demo — Talk Track

*A speaking script for demonstrating the software to staff-level engineers.
Intended to be delivered by a technical product manager who understands the
concepts but isn't a programmer. Demo cues are marked with ▶.*

---

## Opening: How I Got Here

Before I jump into the software, let me give you some context for why I'm
the one presenting this, and where my understanding of the technology comes
from — because I want to be honest about the limits of that understanding.

Back in 2017, I was at a startup called Kentik. We did network observability,
and I was looking at a project for IBM — they ran IBM Cloud on what's now
called MCS Plus, but at the time it was just called IKS, IBM Kubernetes
Service. The goal was to give network engineers visibility into what was
happening *inside* the Kubernetes network — not just the overlay, but the
actual flows between pods, between namespaces, between containers.

We had an engineer on the team — brilliant guy, really into Rust and Linux
kernel programming — and he started talking to me about BPF. Not BPF-LSM,
not security BPF — just the packet filtering and tracing side of it. He was
using it to capture network flows at the kernel level without the overhead of
traditional monitoring agents. And I remember thinking, okay, this is
interesting, but it's a tool for engineers who speak kernel. How does this
become a product?

That question — how do you take something that lives in the kernel and make
it accessible to someone who writes YAML, not C — that's the question that
ended up defining the next few years of my career.

Fast forward a few years. I was getting ready to leave Kentik. I'd spent a
lot of time with BPF-adjacent technology, enough to appreciate what it could
do, and a headhunter from Elastic called. They told me Elastic had just
acqui-hired a startup out of Vancouver that specialized in BPF — and they
were looking for a product manager who could help translate the unique
differentiations the technology offered into customer benefits. I jumped at
the chance.

So that's how I came to know the engineers who built this. The team came
from a startup called CMD — they did Linux PAM solutions, authentication
modules. At Elastic, this same team added BPF reporting support to Elastic
Defend, which was their endpoint product. And then they built a standalone
thing called Cloud Defend — which is what we're going to see today.

I want to be upfront about something: I understand the architecture, I
understand the trade-offs, and I can tell you why the team made the
decisions they made. But I'm not a programmer. When the engineers showed me
the BPF verifier logs and explained why nested loops would "never verify,"
I understood the *shape* of the problem — the constraint, the workaround —
but I couldn't write the code that solves it. What I *can* do is show you
what the software does, explain why it's harder to build than it looks, and
walk you through the decisions that I think are genuinely interesting —
even from a product perspective.

Let me start the demo.

---

## Part 1: The Environment

▶ *Show the VM booting or already booted. Point out the kernel parameter.*

Before we run anything, I need to show you the environment, because the
environment *is* the story here. This is a Linux VM — Ubuntu 24.04, kernel
6.8 — and I've configured it with a specific boot parameter:

▶ `cat /sys/kernel/security/lsm`

See that? The LSM list ends with `bpf`. That means the BPF Linux Security
Module is active in the kernel. Without this, nothing I'm about to show you
works. The kernel needs to be built with `CONFIG_BPF_LSM=y` — most modern
kernels are — and the `lsm=` boot parameter has to explicitly include `bpf`.

This is worth pausing on, because it's the first trade-off the team had to
navigate. There are a few ways to do runtime security monitoring on Linux:

You could use **ptrace** — attach to processes and intercept syscalls. But
that's slow, it's racey, and it requires per-process attachment.

You could use **auditd** or **fanotify** — these are the traditional approaches.
They work, but they're observation-only. They tell you something happened
*after* it happened. You can't block — you can only alert and then maybe kill
the process. By the time you kill it, the damage might be done.

Or you could use **BPF-LSM** — which is what Cloud Defend does. The BPF-LSM
framework lets you attach eBPF programs to security hooks in the kernel. These
hooks fire *before* the operation completes. When your BPF program returns
`-EPERM`, the operation never happens. The file is never written. The process
is never exec'd. It's preemptive, not reactive.

That's a fundamentally different security posture. You're not detecting
intrusions — you're preventing them. And you're doing it at the kernel level,
which means it works regardless of what userspace code does. You can't bypass
it by modifying the binary, by using a different shell, by exploiting a library.
The hook is in the kernel.

There's another advantage to the in-kernel approach that my team kept
emphasizing, and once I understood it, it changed how I thought about the
entire product category. It's something called **TOCTOU** — Time of Check to
Time of Use. The classic security problem with userspace monitoring is that
you check whether an operation is allowed, and then you let it proceed. But
between the check and the actual operation, the state of the system can
change. The file you approved could be swapped. The process you vetted could
have been replaced. The path you validated could be a symlink by the time the
write happens.

With auditd or fanotify, you get an event in userspace, you evaluate it, and
if it looks bad, you try to kill the process. But the kill is asynchronous —
there's a window between "I decided this is bad" and "the process is actually
stopped" where the process can still do damage. And even if you kill it
instantly, the operation may have already completed. You're closing the barn
door after the horse has left.

BPF-LSM doesn't have this problem because the check and the use happen in the
same atomic kernel context. The LSM hook fires, the BPF program evaluates the
policy, and the return value — allow or deny — is enforced *before the kernel
proceeds with the operation*. There's no window. There's no race. The
decision and the enforcement are the same event. My engineers were very proud
of this — they'd say "we don't detect attacks, we prevent the syscall from
completing." That's the difference between a security camera and a locked
door.

The trade-off — and my team explained this to me in detail — is that BPF-LSM
requires kernel support. Not every kernel has it. Not every cloud provider
enables it. And the BPF programs themselves have to pass the kernel's verifier,
which I'll talk about more in a minute. But the preemptive blocking capability
— and the TOCTOU guarantee that comes with it — is worth those constraints.

---

## Part 2: Policy 1 — Logging All Process Activity

▶ *Start the event dumper with Policy 1. Show JSON events streaming to stdout.*

Okay, so what you're seeing here is the `eventdumper` tool — that's a thin
wrapper that Elastic ships for testing. It loads the same BPF probes that the
production Cloud Defend agent uses, but instead of sending events to
Elasticsearch, it prints them as JSON to stdout.

▶ *Point to the event stream. Run a few commands (ls, cat, echo) to generate activity.*

Every line you see is a real kernel event. A process forked. A process exec'd.
A process exited. These are coming from BPF programs attached to kernel
tracepoints and LSM hooks — `sched_process_fork`, `sched_process_exec`,
`bprm_check_security`, `taskstats_exit`. The BPF programs are running in kernel
context, observing every process on the system, and shipping events to
userspace through a ring buffer.

▶ `wc -l /tmp/policy1.log`

We've got — what, 170, 200 events in a few seconds? And look at the richness
of the data. Each event has the PID, the UID, the credentials, the current
working directory, the full path of the executable being run. This is not
`ps` output. This is the kernel telling you, in real time, every single
process that's starting on this machine.

Now, here's what I find interesting from a product perspective. The policy
that's driving this is about ten lines of YAML:

▶ `cat policies/policy-1-log-all-processes.yaml`

Two selectors — one for fork, one for exec. Two responses — log each one.
That's it. The user doesn't need to know anything about BPF, about LSM hooks,
about tracepoints, about ring buffers. They write a policy in a declarative
language, and the system translates that into BPF programs that run in the
kernel.

But under the hood — and this is where it gets sophisticated — the policy
engine is doing something really clever. But first, let me walk you through
the policy language itself, because the design of this language is actually
one of the things I was most involved with as a PM.

---

## Part 2b: The Policy Language

The policy language is built around two concepts: **selectors** and
**responses**. If you've ever written a firewall rule or an IAM policy, the
shape of this will feel familiar — but the details are specific to the
runtime security domain.

**Selectors** describe what you're looking for. Each selector has a name and
a set of conditions. A condition is a field and a list of values. The
conditions within a selector are ANDed — all of them must match. So if you
say `operation: [exec]` and `processExecutable: [/usr/bin/ps]`, both must be
true for the selector to match.

There are two namespaces of selectors: **process selectors** and **file
selectors**. Process selectors can match on:

- `operation` — `fork` or `exec`
- `processName` — the kernel task name (the 16-byte `comm` field)
- `processExecutable` — the full path to the binary, with wildcard support
- `sessionLeaderInteractive` — whether the process is attached to an
  interactive session (a TTY)
- `containerImageName`, `containerImageTag`, `containerImageFullName` —
  identify the container
- `kubernetesNamespace`, `kubernetesPodName`, `kubernetesPodLabel`,
  `kubernetesClusterId`, `kubernetesClusterName` — identify the Kubernetes
  context

File selectors can match on:

- `operation` — `createExecutable`, `modifyExecutable`, `createFile`,
  `modifyFile`, `deleteFile`
- `targetFilePath` — the file path, with wildcard support
- The same container and Kubernetes fields as process selectors
- `ignoreVolumeMounts` and `ignoreVolumeFiles` — these are interesting
  safeguards that I'll explain in a moment

The wildcard system supports three patterns. A fixed path like
`/usr/bin/foo` matches exactly that file. A single-level wildcard like
`/usr/bin/*` matches anything one level deep — `/usr/bin/ps` matches, but
`/usr/bin/local/ps` does not. And a recursive wildcard like `/usr/bin/**`
matches at any depth — `/usr/bin/ps`, `/usr/bin/local/ps`,
`/usr/bin/local/bin/ps`, all match.

**Responses** describe what to do when a selector matches. Each response has
a `match` list — the selectors that trigger it — an optional `exclude` list
— selectors that exempt the operation — and an `actions` list. The actions
are `log`, `alert`, and `block`.

The `exclude` mechanism is where the policy language gets genuinely
expressive. You can write a policy that says "block all executable creation
in `/usr/bin`" and then carve out an exception: "except in
`/usr/bin/internal`." The match selectors and the exclude selectors are
evaluated together — if any match selector fires and *none* of the exclude
selectors fire, the action is taken. This lets you write layered policies
that are broad by default with specific carve-outs, which is how most
security teams actually want to operate.

The `ignoreVolumeMounts` and `ignoreVolumeFiles` fields in file selectors are
a safeguard that the engineering team added after we saw some dangerous
policies in testing. If you write a policy that blocks all file modifications
globally, you can accidentally block writes to mounted volumes — configMaps,
secrets, empty dirs — which will break the container. These fields let you
say "match file operations, but ignore anything that's on a volume mount."
There's also a validation rule in the policy schema: if you write a blocking
response that references a file operation selector, you *must* either specify
a `targetFilePath` in every matching selector or include at least one
excluding selector with a `targetFilePath`. The system literally refuses to
load a policy that could block all file writes without a path constraint.
That's a product decision enforced in code — the team pushed back when I
asked if we could make it a warning instead of an error. They were right.

▶ *Optional: show the policy schema JSON*

There's a JSON schema that validates every policy before it's loaded. It
enforces things like unique selector names, valid selector references in
responses, the length limits I mentioned earlier, and the FIM safeguard rule.
If a policy fails validation, the agent refuses to apply it and stays on the
previous policy — it never goes into an unconfigured state. That's important
for a security tool: a bad policy shouldn't leave you less protected than
you were before.

Now, let me show you something that I think really makes this tangible.

▶ *Live: modify the policy on the fly*

One of the things I love about this system — and I'll be honest, I didn't
appreciate this until I saw the engineers demoing it — is that you can
change the policy while the agent is running. The config manager watches for
a signal — SIGHUP — and when it receives one, it re-reads the config file,
validates the new policy, and hot-swaps it into the BPF maps without
restarting the agent and without dropping events.

So let me do something you probably weren't expecting. Let me take the
policy we're running right now — the log-all-processes policy — and modify
it live to add a blocking rule.

▶ *Edit the config file on the VM: add a process selector blocking "zcat"
with a block action. Save the file.*

▶ `sudo kill -HUP $(pidof eventdumper)`

▶ *Show the log confirming "reloaded config due to SIGHUP"*

And now, without restarting anything, without recompiling any BPF code, the
policy has changed. The BPF maps have been updated. Let me prove it:

▶ `echo test | zcat`
```
/usr/bin/zcat: 51: exec: gzip: Operation not permitted
```

That was a log-only policy thirty seconds ago. I added one selector and one
response — six lines of YAML — sent a signal, and now `zcat` is blocked at
the kernel level. The BPF programs didn't change. The verifier didn't need
to re-run. What changed was the contents of the hash maps that the BPF
programs query. The programs are fixed; the policy is data.

This is the abstraction I was talking about at the beginning. How do you
take something that lives in the kernel and make it accessible to someone
who writes YAML, not C? This is how. The BPF programs are compiled once,
verified once, loaded once. The policy is just data in maps, and it can
change at any time.

Now, let me explain what the BPF code is actually doing when it evaluates
that policy — because this is where it gets really sophisticated.

---

## Part 3: The Verifier and Why This Software Is Hard to Write

This is the part where I have to be honest about the limits of my understanding.
My team spent a lot of time explaining this to me, and I think I get the shape
of it, but I would not pretend to be able to write this code.

The thing about eBPF programs is that they don't just run. Before the kernel
will load a BPF program, it runs it through something called the **verifier**.
The verifier is essentially a static analysis tool that proves the program is
safe — it can't access memory out of bounds, it can't infinite loop, it can't
crash the kernel. It does this by exploring every possible execution path
through the program.

Now, for a simple BPF program — like a packet counter — the verifier is fast.
It's milliseconds. But Cloud Defend's BPF programs are not simple. They
implement a full policy evaluation engine *inside BPF*. They have to match
process names, file paths with wildcards, container image names, Kubernetes
namespaces, pod labels — all inside a BPF program that the verifier has to
prove safe.

The naive approach would be nested loops — for each response, for each
selector, for each field, do a string comparison. But the verifier tracks
state through loops, and each nested loop multiplicatively increases the
number of states the verifier has to explore. The Cloud Defend team's own
comments in the code say it plainly: "if we take this approach, our probes
will never verify."

So what they did instead — and I think this is genuinely elegant — is they
inverted the whole thing. Instead of looping over selectors inside the BPF
program, they precompute the selector matching in userspace and store the
results in BPF hash maps. Each selector field gets its own map. When a process
exec's, the BPF program does a hash map lookup for the process name, another
for the executable path, another for the container image — each lookup is an
implicit string comparison that happens *outside* the verifier's analysis.
Then it ANDs the resulting bitsets together. No nested loops. The verifier
sees a fixed sequence of map lookups and bitwise operations.

The path matching is even more sophisticated. They support three types of
wildcards — recursive (`/usr/bin/**`), single-level (`/usr/bin/*`), and exact
paths. For each type, there's a separate BPF map. When a file operation
happens, the BPF program walks the dentry chain — that's the kernel's
directory entry tree — building the path string component by component,
looking up each partial path in the recursive wildcard map at every step.
That's a loop, but it's a single loop, not nested, and the body is just a
hash lookup.

They also use **tail calls** — BPF subprograms that replace the current stack
frame instead of nesting. This keeps the verifier's stack depth bounded. The
policy evaluation is split into a chain of tail calls, each handling one
selector field.

I hit this verifier problem firsthand when I was building the demo. I wrote
a simple BPF program to extract the basename from a file path — find the last
slash, copy everything after it. Totally straightforward in C. The verifier
rejected it because the loop bounds were variable and the stack access
couldn't be proven safe. I had to simplify the approach. And that was a
*trivial* program. Cloud Defend's programs are orders of magnitude more
complex.

▶ *Optional: mention the TCG vs KVM finding*

Actually, I'll share something that drove this home for me. When I first tried
to load Cloud Defend's BPF programs on a QEMU VM using software emulation —
no hardware virtualization — the verifier never completed. I gave it ten
minutes. It was still going. The verifier's state space exploration is
CPU-bound, and under software emulation it's dramatically slower. When I
provisioned a real KVM VM on Hetzner Cloud, the same programs verified in
about fourteen seconds. Same code, same kernel, same policy — the only
difference was hardware vs software CPU virtualization. That's how
computationally intensive the verifier is for these programs.

---

## Part 4: The Length Limits and Selector Constraints

There's another set of constraints that I think product people usually don't
think about, but they shape what the tool can actually do.

The `processName` selector matches against the kernel's `task->comm` field.
That field is 16 bytes. So you can match "ps" or "zcat" — short names — but
you can't match a full path. For full paths, there's a separate selector
called `processExecutable` that matches against the binary's file path using
the same wildcard system as file paths.

But here's the subtle thing I learned: at the `bprm_check_security` hook —
which is where blocking happens — `bpf_get_current_comm()` returns the name
of the *calling* process, not the binary being exec'd. So if bash forks and
execs `ps`, the comm field at that moment is "bash", not "ps". The new
process name isn't set until after execve completes — but by then it's too
late to block.

Cloud Defend handles this by using `processExecutable`, which reads the path
from `binprm->file->f_path` — that's the file being exec'd, available at
hook time. But reading and matching that path in BPF requires the full dentry
walk and wildcard matching machinery I described earlier. It's a lot of
verifier complexity just to get the right process identity.

There are also length limits enforced in the policy validation: process names
are capped at 15 entries, file paths at 255 characters, container image names
at 511. These aren't arbitrary product decisions — they're constraints imposed
by the BPF map key sizes and the verifier's complexity limits. The engineering
team had to push back against product requirements that would have exceeded
these limits.

---

## Part 5: Policy 2 — Blocking Commands and Protecting Files

▶ *Kill the Policy 1 process. Start Policy 2. Show the startup log.*

Now let's switch to the second policy. This one blocks execution of `zcat`
and protects `/etc/passwd` from modification.

▶ `cat policies/policy-2-block-commands-protect-passwd.yaml`

Same declarative format. Process selectors with `block, alert` actions. File
selectors targeting `/etc/passwd` with `block, alert` on modify, delete,
create executable, and modify executable operations.

▶ *Run zcat — show it's blocked*

```
$ echo test | zcat
/usr/bin/zcat: 51: exec: gzip: Operation not permitted
```

There it is. `Operation not permitted`. That's `EPERM` — coming directly from
the BPF-LSM hook in the kernel. The `bprm_check_security` hook fired, the BPF
program looked up the process name in the blocked commands map, found a match,
and returned `-EPERM`. The exec never completed. `gzip` never ran. There's no
process to kill — it was never born.

This is the difference I was talking about earlier. With auditd or fanotify,
you'd get an alert that `zcat` ran, and then you'd have to kill the process.
With BPF-LSM, the process doesn't run. The attack surface is different.

▶ *Run ls — show it works normally*

```
$ ls /tmp
cloud-defend.yaml  eventdumper  policies
```

`ls` works fine. The BPF program evaluated it, didn't find a match in the
blocked commands map, and returned 0 — allow. The overhead is a hash map
lookup, which is nanoseconds.

▶ *Try to write to /etc/passwd — show it's blocked*

```
$ echo hacker | sudo tee -a /etc/passwd
tee: /etc/passwd: Operation not permitted
```

And here's the file protection. The `file_open` LSM hook fires on every file
open. The BPF program checks if the file is opened for writing — the
`FMODE_WRITE` flag — and if the path matches `/etc/passwd`, it returns
`-EPERM`. The write never happens.

Now, I should be transparent about a limitation here. The `file_open` hook
only fires for files opened for *writing*. Reads are not intercepted. So this
policy prevents someone from *modifying* `/etc/passwd` — adding a user,
changing a shell, deleting entries — but it doesn't prevent someone from
*reading* it. That's a design decision in the BPF hook, not a bug. The team
chose to hook the write path because that's where the security-relevant
operation is. Reading `/etc/passwd` is normal — every login reads it. Blocking
reads would break the system. Blocking writes is the surgical intervention.

---

## Part 6: The Container Context

I want to mention one more thing that I think is easy to miss when you're
looking at this from the outside.

Cloud Defend was built for Kubernetes containers. The production agent runs
as a daemonset — one instance per node — and it monitors *all* containers on
that node. The policy language has selectors for Kubernetes namespace, pod
name, pod labels, container image name, container image tag. You can write
a policy that says "block executable creation in `/usr/bin` inside Redis
containers in the `production` namespace" and the BPF programs will enforce
that.

The way this works is that the BPF programs identify containers by their
cgroup path — the kernel's control group hierarchy has a specific structure
for Kubernetes pods, and the BPF code parses that to extract the container
ID. Then a userspace process database maintains a mapping from container ID
to pod metadata (namespace, labels, image name) by querying the Kubernetes
API. The BPF programs query this mapping via BPF maps.

But here's the subtle part: the events module has a filter — `inK8sContainer`
— that checks whether an event's cgroup path matches the Kubernetes container
regex. If it doesn't match, the event is silently dropped from the logging
pipeline. This means that when you run Cloud Defend outside of Kubernetes —
like we're doing in this demo — the process logging events are dropped. The
events you see from the `eventdumper` are raw BPF events from the ring buffer,
not the filtered, enriched events that the production agent would send to
Elasticsearch.

This is the kind of architectural decision that makes sense in production —
you don't want to flood Elasticsearch with events from the host's own system
processes — but it makes standalone testing tricky. The `eventdumper` tool
exists specifically to bypass this filtering for testing purposes.

---

## Closing

So, to wrap up — what I hope you take away from this:

First, BPF-LSM is a genuinely different approach to runtime security. It's
preemptive, it's kernel-level, and it can't be bypassed from userspace. The
trade-off is kernel version requirements and verifier complexity.

Second, the engineering challenge of writing policy evaluation logic inside
BPF is significant. The verifier imposes hard constraints on program
complexity, and the Cloud Defend team had to restructure their entire
architecture — hash map-based selector matching, tail calls, bitset
operations — to stay within those constraints. This is not "write a BPF
program and load it." This is "design a policy engine that the verifier can
prove safe."

Third, the product interface — the YAML policy language — hides all of this
complexity. A user writes ten lines of YAML and gets kernel-level preemptive
blocking. That abstraction is the product. The BPF programs, the verifier
constraints, the cgroup parsing, the container metadata mapping — that's the
implementation. And the gap between those two is where the engineering
sophistication lives.

I'm happy to go deeper on any of these areas. I may need to defer some
questions to the codebase itself — like I said, I understand the architecture
but I'm not going to pretend I can read BPF bytecode. But I can show you the
policy schema, the event format, and the test results, and we can talk about
what a production deployment would look like.

▶ *Open floor for questions.*
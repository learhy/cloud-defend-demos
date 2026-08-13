// SPDX-License-Identifier: GPL-2.0
// Minimal BPF-LSM demo for cloud-defend concepts.
// Logs process exec events and blocks execution of "ps" and "zcat".
// Also blocks writes to /etc/passwd.

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

#define EPERM 1
#define COMM_LEN 16
#define PATH_LEN 128
#define MAX_BLOCKED 8
#define FMODE_WRITE 0x2

struct event {
    u32 pid;
    u32 uid;
    int blocked;
    int op_type;    // 0=exec, 1=file_write
    char comm[COMM_LEN];
    char filename[PATH_LEN];
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_BLOCKED);
    __type(key, char[COMM_LEN]);
    __type(value, u32);
} blocked_commands SEC(".maps");

// LSM hook: bprm_check_security - called before exec
// Uses bpf_get_current_comm() to get the process name.
// Note: At bprm_check_security time, comm is the name of the process
// calling execve(). For most cases this is the parent shell, but for
// scripts and wrappers (like zcat->gzip), comm may be the wrapper.
// The filename from bprm->filename gives the actual binary path.
SEC("lsm/bprm_check_security")
int BPF_PROG(lsm_bprm_check, struct linux_binprm *bprm) {
    char comm[COMM_LEN] = {};
    bpf_get_current_comm(&comm, sizeof(comm));

    // Read the filename being exec'd for logging
    char filename[PATH_LEN] = {};
    bpf_probe_read_kernel_str(filename, sizeof(filename), &bprm->filename);

    // Check if this command is blocked
    u32 *blocked = bpf_map_lookup_elem(&blocked_commands, &comm);
    if (blocked) {
        struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {
            e->pid = bpf_get_current_pid_tgid() >> 32;
            e->uid = bpf_get_current_uid_gid();
            e->blocked = 1;
            e->op_type = 0;
            __builtin_memcpy(e->comm, comm, COMM_LEN);
            __builtin_memcpy(e->filename, filename, PATH_LEN);
            bpf_ringbuf_submit(e, 0);
        }
        return -EPERM;
    }

    // Emit log event for all execs
    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (e) {
        e->pid = bpf_get_current_pid_tgid() >> 32;
        e->uid = bpf_get_current_uid_gid();
        e->blocked = 0;
        e->op_type = 0;
        __builtin_memcpy(e->comm, comm, COMM_LEN);
        __builtin_memcpy(e->filename, filename, PATH_LEN);
        bpf_ringbuf_submit(e, 0);
    }

    return 0;
}

// LSM hook: file_open - blocks writes to /etc/passwd
SEC("lsm/file_open")
int BPF_PROG(lsm_file_open, struct file *file) {
    fmode_t f_mode = BPF_CORE_READ(file, f_mode);

    if (!(f_mode & FMODE_WRITE))
        return 0;

    char path[PATH_LEN] = {};
    int ret = bpf_d_path(&file->f_path, path, sizeof(path));
    if (ret < 0)
        return 0;

    // Check if this is /etc/passwd
    char passwd[] = "/etc/passwd";
    int match = 1;
    for (int i = 0; i < 12; i++) {
        if (path[i] != passwd[i]) {
            match = 0;
            break;
        }
    }

    if (match) {
        struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {
            e->pid = bpf_get_current_pid_tgid() >> 32;
            e->uid = bpf_get_current_uid_gid();
            e->blocked = 1;
            e->op_type = 1;
            bpf_get_current_comm(&e->comm, sizeof(e->comm));
            __builtin_memcpy(e->filename, "/etc/passwd", 12);
            bpf_ringbuf_submit(e, 0);
        }
        return -EPERM;
    }

    return 0;
}
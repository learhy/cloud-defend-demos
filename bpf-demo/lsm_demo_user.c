// SPDX-License-Identifier: GPL-2.0
// Userspace companion for the BPF-LSM demo.
// Reads events from the BPF ringbuf and prints them as JSON.
// Also manages the blocked_commands BPF map based on policy.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <sys/resource.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#define COMM_LEN 16
#define PATH_LEN 128
#define MAX_BLOCKED 8

struct event {
    unsigned int pid;
    unsigned int uid;
    int blocked;
    int op_type;
    char comm[COMM_LEN];
    char filename[PATH_LEN];
};

static volatile sig_atomic_t running = 1;

static void sig_handler(int sig) {
    (void)sig;
    running = 0;
}

// ring_buffer_sample_fn signature: int (void *ctx, void *data, size_t sz)
static int print_event(void *ctx, void *data, size_t data_sz) {
    (void)ctx;
    (void)data_sz;
    struct event *e = (struct event *)data;
    time_t now = time(NULL);
    const char *op_name = e->op_type == 0 ? "exec" : "file_write";
    const char *action = e->blocked ? "BLOCK" : "LOG";

    printf("{\"timestamp\":%ld,\"pid\":%u,\"uid\":%u,\"action\":\"%s\","
           "\"op_type\":\"%s\",\"comm\":\"%s\"",
           now, e->pid, e->uid, action, op_name, e->comm);

    if (e->filename[0] != 0) {
        printf(",\"filename\":\"%s\"", e->filename);
    }
    printf("}\n");
    fflush(stdout);
    return 0;
}

static int add_blocked_command(int map_fd, const char *name) {
    char key[COMM_LEN];
    unsigned int value = 1;
    memset(key, 0, sizeof(key));
    strncpy(key, name, COMM_LEN - 1);
    return bpf_map_update_elem(map_fd, key, &value, BPF_ANY);
}

static void usage(const char *prog) {
    fprintf(stderr, "Usage: %s [options]\n", prog);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --block <name>    Block execution of command <name>\n");
    fprintf(stderr, "  --log-all         Log all exec events (default)\n");
    fprintf(stderr, "  --protect-passwd  Block writes to /etc/passwd\n");
    fprintf(stderr, "  --policy <file>   Load policy from simple YAML file\n");
    fprintf(stderr, "  --help            Show this help\n");
    fprintf(stderr, "\nExamples:\n");
    fprintf(stderr, "  Policy 1 (log all): %s --log-all\n", prog);
    fprintf(stderr, "  Policy 2 (block):   %s --block ps --block zcat --protect-passwd\n", prog);
}

int main(int argc, char **argv) {
    int err;
    struct bpf_object *obj;
    struct bpf_program *prog;
    struct bpf_link *link_exec = NULL, *link_file = NULL;
    int blocked_map_fd = -1;
    int ringbuf_fd = -1;
    struct ring_buffer *rb = NULL;
    struct rlimit rlim = {
        .rlim_cur = RLIM_INFINITY,
        .rlim_max = RLIM_INFINITY,
    };

    // Bump memlock rlimit
    err = setrlimit(RLIMIT_MEMLOCK, &rlim);
    if (err) {
        fprintf(stderr, "Warning: could not set RLIMIT_MEMLOCK: %s\n", strerror(errno));
    }

    // Parse args
    int log_all = 0;
    int protect_passwd = 0;
    const char *policy_file = NULL;
    char blocked_names[MAX_BLOCKED][COMM_LEN];
    int num_blocked = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--block") == 0 && i + 1 < argc) {
            if (num_blocked < MAX_BLOCKED) {
                memset(blocked_names[num_blocked], 0, COMM_LEN);
                strncpy(blocked_names[num_blocked], argv[++i], COMM_LEN - 1);
                num_blocked++;
            }
        } else if (strcmp(argv[i], "--log-all") == 0) {
            log_all = 1;
        } else if (strcmp(argv[i], "--protect-passwd") == 0) {
            protect_passwd = 1;
        } else if (strcmp(argv[i], "--policy") == 0 && i + 1 < argc) {
            policy_file = argv[++i];
        } else if (strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        }
    }

    // Default: log all
    if (!log_all && num_blocked == 0 && !protect_passwd && !policy_file) {
        log_all = 1;
    }

    // Parse simple policy file
    if (policy_file) {
        FILE *f = fopen(policy_file, "r");
        if (f) {
            char line[256];
            while (fgets(line, sizeof(line), f)) {
                char *p = line;
                while (*p == ' ' || *p == '\t') p++;
                // Remove newline
                char *nl = strchr(p, '\n');
                if (nl) *nl = 0;
                // Remove trailing whitespace
                char *end = p + strlen(p) - 1;
                while (end > p && (*end == ' ' || *end == '\t')) *end-- = 0;

                if (strncmp(p, "block:", 6) == 0) {
                    p += 6;
                    while (*p == ' ') p++;
                    if (num_blocked < MAX_BLOCKED) {
                        memset(blocked_names[num_blocked], 0, COMM_LEN);
                        strncpy(blocked_names[num_blocked], p, COMM_LEN - 1);
                        num_blocked++;
                    }
                } else if (strncmp(p, "log_all:", 8) == 0) {
                    p += 8;
                    while (*p == ' ') p++;
                    if (*p == 't' || *p == '1') log_all = 1;
                } else if (strncmp(p, "protect_passwd:", 15) == 0) {
                    p += 15;
                    while (*p == ' ') p++;
                    if (*p == 't' || *p == '1') protect_passwd = 1;
                }
            }
            fclose(f);
        } else {
            fprintf(stderr, "Warning: could not open policy file %s\n", policy_file);
        }
    }

    // Print configuration
    fprintf(stderr, "=== Cloud Defend Demo ===\n");
    fprintf(stderr, "Log all execs: %s\n", log_all ? "yes" : "no");
    fprintf(stderr, "Protect /etc/passwd: %s\n", protect_passwd ? "yes" : "no");
    fprintf(stderr, "Blocked commands (%d):", num_blocked);
    for (int i = 0; i < num_blocked; i++) {
        fprintf(stderr, " %s", blocked_names[i]);
    }
    fprintf(stderr, "\n");

    // Set up signal handler
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    // Open and load BPF object
    obj = bpf_object__open_file("lsm_demo.bpf.o", NULL);
    err = libbpf_get_error(obj);
    if (err) {
        fprintf(stderr, "Failed to open BPF object: %d (ensure lsm_demo.bpf.o is in current directory)\n", err);
        return 1;
    }

    err = bpf_object__load(obj);
    if (err) {
        fprintf(stderr, "Failed to load BPF object: %d\n", err);
        bpf_object__close(obj);
        return 1;
    }

    fprintf(stderr, "BPF programs loaded successfully\n");

    // Get the blocked_commands map
    struct bpf_map *map = bpf_object__find_map_by_name(obj, "blocked_commands");
    if (map) {
        blocked_map_fd = bpf_map__fd(map);
    }

    // Get the events ringbuf
    map = bpf_object__find_map_by_name(obj, "events");
    if (map) {
        ringbuf_fd = bpf_map__fd(map);
    }

    // Add blocked commands to the map
    for (int i = 0; i < num_blocked; i++) {
        if (add_blocked_command(blocked_map_fd, blocked_names[i]) == 0) {
            fprintf(stderr, "Blocking command: %s\n", blocked_names[i]);
        } else {
            fprintf(stderr, "Failed to add blocked command: %s\n", blocked_names[i]);
        }
    }

    // Attach the bprm_check_security LSM hook (always attach - needed for both log-all and block)
    prog = bpf_object__find_program_by_name(obj, "lsm_bprm_check");
    if (prog) {
        link_exec = bpf_program__attach_lsm(prog);
        err = libbpf_get_error(link_exec);
        if (err) {
            fprintf(stderr, "Failed to attach LSM exec hook: %d\n", err);
            link_exec = NULL;
        } else {
            fprintf(stderr, "Attached exec LSM hook (bprm_check_security)\n");
        }
    }

    // Attach the file_open LSM hook (only if protect_passwd is enabled)
    if (protect_passwd) {
        prog = bpf_object__find_program_by_name(obj, "lsm_file_open");
        if (prog) {
            link_file = bpf_program__attach_lsm(prog);
            err = libbpf_get_error(link_file);
            if (err) {
                fprintf(stderr, "Failed to attach LSM file hook: %d\n", err);
                link_file = NULL;
            } else {
                fprintf(stderr, "Attached file LSM hook (file_open) - protecting /etc/passwd\n");
            }
        }
    }

    if (!link_exec && !link_file) {
        fprintf(stderr, "No LSM hooks attached, exiting\n");
        bpf_object__close(obj);
        return 1;
    }

    // Set up ringbuf
    if (ringbuf_fd >= 0) {
        rb = ring_buffer__new(ringbuf_fd, print_event, NULL, NULL);
        err = libbpf_get_error(rb);
        if (err) {
            fprintf(stderr, "Failed to create ring buffer: %d\n", err);
            rb = NULL;
        }
    }

    fprintf(stderr, "Listening for events (Ctrl+C to stop)...\n");
    fprintf(stderr, "================================\n");

    // Event loop
    while (running) {
        if (rb) {
            err = ring_buffer__poll(rb, 100);
            if (err < 0 && err != -EINTR) {
                fprintf(stderr, "ringbuf poll error: %d\n", err);
                break;
            }
        } else {
            usleep(100000);
        }
    }

    // Cleanup
    if (rb) ring_buffer__free(rb);
    if (link_exec) bpf_link__destroy(link_exec);
    if (link_file) bpf_link__destroy(link_file);
    bpf_object__close(obj);

    fprintf(stderr, "\n================================\n");
    fprintf(stderr, "Exiting...\n");
    return 0;
}
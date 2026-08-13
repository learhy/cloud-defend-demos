# Minimal BPF-LSM demo Makefile
# Requires: clang-16, libbpf-dev, linux-headers-$(uname -r), build-essential

CLANG ?= clang-16
CC ?= gcc
CFLAGS := -O2 -g -Wall
BPF_CFLAGS := -O2 -g -Wall -Werror -target bpf -D__TARGET_ARCH_x86

# Find kernel headers
KERNEL_DIR ?= /lib/modules/$(shell uname -r)/build
ARCH_INCLUDES := -I$(KERNEL_DIR)/arch/x86/include \
                -I$(KERNEL_DIR)/arch/x86/include/generated \
                -I$(KERNEL_DIR)/include \
                -I$(KERNEL_DIR)/include/generated \
                -I$(KERNEL_DIR)/arch/x86/include/uapi \
                -I$(KERNEL_DIR)/arch/x86/include/generated/uapi \
                -I$(KERNEL_DIR)/include/uapi \
                -I$(KERNEL_DIR)/include/generated/uapi

# Try both multiarch and standard include paths
BPF_INCLUDES := -I/usr/include/x86_64-linux-gnu -I/usr/include -I./headers $(ARCH_INCLUDES)

.PHONY: all clean vmlinux

all: lsm_demo.bpf.o demo

# Generate vmlinux.h from the running kernel's BTF
vmlinux:
	mkdir -p headers
	bpftool btf dump file /sys/kernel/btf/vmlinux format c > headers/vmlinux.h

# Compile BPF program
lsm_demo.bpf.o: lsm_demo.bpf.c headers/vmlinux.h
	$(CLANG) $(BPF_CFLAGS) -c lsm_demo.bpf.c -o lsm_demo.bpf.o $(BPF_INCLUDES)

# Compile userspace program
demo: lsm_demo_user.c lsm_demo.bpf.o
	$(CC) $(CFLAGS) -o demo lsm_demo_user.c -lbpf

clean:
	rm -f lsm_demo.bpf.o demo
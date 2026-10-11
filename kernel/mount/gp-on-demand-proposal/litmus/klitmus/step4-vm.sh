#!/bin/bash
set -u
K=~/tmp/klitmus
exec timeout --foreground 5400 taskset -c 256-263 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m 4G -nographic -no-reboot \
	-kernel $K/bzImage -initrd $K/initrd.cpio \
	-append "console=ttyS0 panic=-1 klitmus_nruns=${KLITMUS_NRUNS:-10} klitmus_size=${KLITMUS_SIZE:-100000}" < /dev/null

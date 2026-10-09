#!/bin/bash
set -u
K=~/tmp/klitmus
~/src/umount-bench/bin/build-kernel.sh -s ~/src/git/linux -r 4379d47fd314 -o $K/build -c perf -C 256-511 -j 64 || exit 1
cp $K/build/arch/x86/boot/bzImage $K/bzImage && cp $K/build/.config $K/config || exit 1
grep -q '^CONFIG_MODULES=y' $K/config || { echo "CONFIG_MODULES not set"; exit 1; }
nice -n 19 taskset -c 256-511 make -C $K/build -j 64 -s modules_prepare < /dev/null || { echo "modules_prepare failed"; exit 1; }
echo "KERNEL ready: $K/bzImage"

#!/bin/bash
# Build the trace kernel in a private tmpfs; run inside unshare -rm --propagation private.
set -u
G=$HOME/tmp/gp-trace; W=/tmp/brauner-tomb-holders; LINUX=$HOME/src/git/linux
SHA=$(cat $G/SHA); T=$G/mnt; mkdir -p "$T"
say() { echo "$(date +%T) $*" | tee -a $G/progress.log; }
mount -t tmpfs -o size=100G,nr_inodes=10M,huge=never tmpfs "$T" || { say "tmpfs failed"; exit 1; }
cd ~/src/umount-bench || exit 1
say "BUILD start $SHA"
bin/build-kernel.sh -s "$LINUX" -r "$SHA" -o "$T/b" -w "$T/wt" -c perf -c "$G/trace.config" -C 256-511 -j 64 -t > $G/build.out 2>&1
grep -q "^KERNEL" $G/build.out || { say "BUILD FAILED: $(grep -m3 -iE 'error|fatal|did not take' $G/build.out | tr '\n' ' ')"; umount "$T"; exit 1; }
say "BUILD $(sed -n 's/^KERNEL //p' $G/build.out) didnottake=$(grep -c 'did not take' $G/build.out)"
grep -E '^CONFIG_(TRACEPOINTS|FTRACE|TRACING|EVENT_TRACING|VIRTIO_BLK|VFAT_FS)=' "$T/b/.config" | tee -a $G/progress.log
rm -rf $W/umb-trace; mkdir -p $W/umb-trace/arch/x86/boot
cp "$T/b/arch/x86/boot/bzImage" $W/umb-trace/arch/x86/boot/; cp "$T/b/.config" $W/umb-trace/; cp "$T/b/System.map" $W/umb-trace/ 2>/dev/null
cp -r "$T/b/selftests" $W/umb-trace/selftests 2>/dev/null; echo "$SHA" > $W/umb-trace/SHA
ls -la $W/umb-trace/selftests | tee -a $G/progress.log
git -C "$LINUX" worktree remove --force "$T/wt" 2>/dev/null; git -C "$LINUX" worktree prune
umount "$T"; say "BUILD done -> $W/umb-trace"

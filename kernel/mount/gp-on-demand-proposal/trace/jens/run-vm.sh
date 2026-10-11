#!/bin/bash
# Build the initramfs and boot the trace kernel once, pinned to host CPUs 256-263.
set -u
G=$HOME/tmp/gp-trace; W=/tmp/brauner-tomb-holders/umb-trace
say() { echo "$(date +%T) $*" | tee -a $G/progress.log; }
cd ~/src/umount-bench || exit 1
mkdir -p $G/x && (cd $G/x && cpio -id bin/gpbreak < ~/src/umount-bench/runs/gp1007b/initrd-churn.cpio 2>/dev/null)
[ -x $G/x/bin/gpbreak ] || { say "no gpbreak"; exit 1; }
python3 bin/mkinitrd.py -o $G/trace.cpio --init $G/trace-init.sh --selftests $W/selftests --add $G/x/bin/gpbreak:/bin/gpbreak | tee -a $G/progress.log || exit 1
rm -f $G/trace.img; truncate -s 6G $G/trace.img
say "VM start"
timeout 1500 taskset -c 256-263 qemu-system-x86_64 -enable-kvm -cpu host -nographic -no-reboot -m 8G -smp 8 \
	-kernel $W/arch/x86/boot/bzImage -initrd $G/trace.cpio \
	-drive file=$G/trace.img,if=virtio,format=raw \
	-append "console=ttyS0 panic=1 oops=panic quiet ${TRACE_APPEND:-}" < /dev/null > $G/vm.log 2>&1
say "VM end rc=$? alldone=$(grep -ac 'GPTRACE END' $G/vm.log) runs: $(grep -a '===== RUN' $G/vm.log | tr -d '\r' | tr '\n' ';')"
python3 $G/extract.py $G/trace.img $G/traces | tee -a $G/progress.log

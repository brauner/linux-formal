#!/bin/sh
# Init of the trace-collection initramfs: tracefs on, the mount events
# enabled, the workloads run one after the other, and the trace of each
# written to the virtio disk between unmistakable markers.
export PATH=/bin:/usr/bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys
mount -t devtmpfs dev /dev 2>/dev/null; mount -t tmpfs -o size=4g tmpfs /tmp
mount -t tracefs tracefs /sys/kernel/tracing
T=/sys/kernel/tracing
echo "===== GPTRACE START kernel=$(uname -r) cmdline=$(cat /proc/cmdline)"
echo global > $T/trace_clock
echo ${trace_bufkb:-262144} > $T/buffer_size_kb
echo 0 > $T/tracing_on
echo 1 > $T/events/mount/enable
echo "events: $(ls $T/events/mount | tr '\n' ' ')"
echo "clock: $(cat $T/trace_clock)"
exec 3> /dev/vda
run() {	# name cmd...
	name=$1; shift
	echo > $T/trace
	echo 1 > $T/tracing_on
	echo "===== RUN $name begin"
	"$@"
	rc=$?
	echo 0 > $T/tracing_on
	echo "===== RUN $name end rc=$rc"
	grep -h 'overrun\|entries' $T/per_cpu/cpu*/stats | sort | uniq -c
	echo "===== TRACE BEGIN $name" >&3
	cat $T/trace >&3
	echo "===== TRACE END $name" >&3
}
gpb() {	# mode seconds-as-float nproc: gpbreak stops cleanly on SIGALRM
	/bin/gpbreak "$1" 30 "$3" & p=$!
	sleep "$2" 2>/dev/null || sleep 1
	kill -ALRM $p
	wait $p
}
run selftest /t/unheld_umount_test
run walk gpb walk ${trace_walk_secs:-0.3} 4
run held gpb held ${trace_held_secs:-1} 2
run expire gpb expire ${trace_expire_secs:-1} 2
echo "===== ALL DONE" >&3
exec 3>&-
sync
echo "===== DMESG warnings:"
dmesg | grep -ai 'warn\|bug:\|call trace\|refcount' | head -20
echo "===== GPTRACE END"
sync; sleep 1; poweroff -f

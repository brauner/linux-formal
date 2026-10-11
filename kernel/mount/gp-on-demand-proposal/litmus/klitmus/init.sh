#!/bin/sh
# klitmus guest init: load each klitmus7 module, print /proc/litmus (herd-style result), unload, power off.
export PATH=/bin:/usr/bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs dev /dev 2>/dev/null
NRUNS=${klitmus_nruns:-10}; SIZE=${klitmus_size:-100000}
echo "===== KLITMUS START kernel=$(uname -r) nproc=$(nproc) nruns=$NRUNS size=$SIZE cmdline=$(cat /proc/cmdline)"
for ko in /klitmus/*.ko; do
	n=$(basename "$ko" .ko)
	echo "===== MODULE $n"
	if /bin/busybox insmod "$ko" size=$SIZE nruns=$NRUNS stride=1 avail=0; then
		cat /proc/litmus
		/bin/busybox rmmod litmus000 2>/dev/null || /bin/busybox rmmod "$n" 2>/dev/null || echo "rmmod failed for $n"
	else
		echo "insmod failed for $n"; dmesg | tail -5
	fi
done
echo "===== KLITMUS END"
sync; sleep 1; poweroff -f

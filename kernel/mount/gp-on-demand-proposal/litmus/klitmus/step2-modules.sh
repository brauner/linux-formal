#!/bin/bash
# klitmus7 -> one module per test, built against the O= tree, copied to kmod/<test>.ko
set -u
K=~/tmp/klitmus
H=~/.local/herdtools7/usr/bin
LIB=~/.local/herdtools7/usr/share/herdtools7/litmus
TESTS="MNT-E1-slowpath-no-outer-mb MNT-E2-busycheck-no-outer-mb MNT-A1-holder-get-before-put MNT-A1m-nowmb MNT-A1m-nomb-in-sum MNT-A1m-gets-first MNT-B1-walker-inc-vs-peek MNT-B1m-walker-nomb MNT-B1m-peek-no-outer-mb MNT-B2-walker-bail-sees-doomed-lazy MNT-B2m-walker-flags-unlocked MNT-C1-kern-unmount-get-before-put MNT-D1-dekker-fastpath-recheck MNT-D1m-holder-wmb-only"
mkdir -p $K/kmod
for t in $TESTS; do
	d=$K/kmod/$t; rm -rf $d; mkdir -p $d
	$H/klitmus7 -set-libdir $LIB -o $d ~/tmp/lkmm/litmus/$t.litmus > $d/klitmus7.log 2>&1
	[ -f $d/litmus000.c ] || { echo "no module source for $t:"; cat $d/klitmus7.log; continue; }
	if KBUILD_MODPOST_WARN=1 nice -n 19 taskset -c 256-511 make -C $K/build M=$d modules < /dev/null > $d/make.log 2>&1; then
		cp $d/litmus000.ko $K/kmod/$t.ko && echo "built $t.ko"
	else
		echo "module build failed for $t:"; tail -8 $d/make.log
	fi
done
ls -la $K/kmod/*.ko

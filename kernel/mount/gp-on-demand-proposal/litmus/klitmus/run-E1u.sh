#!/bin/bash
# klitmus7 x86 run of the reshaped slow path test, same rig and parameters as the Oct 9 run
set -u
K=~/tmp/klitmus
H=~/.local/herdtools7/usr/bin
LIB=~/.local/herdtools7/usr/share/herdtools7/litmus
LOCK=~/tmp/jens-bigvm.lock
T=MNT-E1u-slowpath-after-umount-tree
log() { echo "$(date -u +%FT%TZ) $*"; }
wait_lock() { while [ -e "$LOCK" ]; do log "lock $LOCK present, waiting 120s"; sleep 120; done; }
cd $K || exit 1
NRUNS=$(grep -ao 'nruns=[0-9]*' $K/vm.log | head -1 | cut -d= -f2)
SIZE=$(grep -ao 'size=[0-9]*' $K/vm.log | head -1 | cut -d= -f2)
log "parameters from the Oct 9 run: nruns=$NRUNS size=$SIZE"
echo E1u-start > $K/STATE-E1u
if [ ! -d $K/build ]; then
	wait_lock
	echo E1u-building-kernel > $K/STATE-E1u
	log "step1-build.sh start"
	bash $K/step1-build.sh > $K/build-E1u.log 2>&1; rc=$?
	log "step1-build.sh rc=$rc"; tail -3 $K/build-E1u.log
	[ $rc -eq 0 ] && [ -f $K/bzImage ] || { echo E1u-build-failed > $K/STATE-E1u; exit 1; }
fi
echo E1u-building-module > $K/STATE-E1u
d=$K/kmod/$T; rm -rf $d; mkdir -p $d
$H/klitmus7 -set-libdir $LIB -o $d ~/tmp/lkmm/litmus/$T.litmus > $d/klitmus7.log 2>&1
[ -f $d/litmus000.c ] || { echo "no module source:"; cat $d/klitmus7.log; echo E1u-klitmus-failed > $K/STATE-E1u; exit 1; }
if KBUILD_MODPOST_WARN=1 nice -n 19 taskset -c 256-511 make -C $K/build M=$d modules < /dev/null > $d/make.log 2>&1; then
	cp $d/litmus000.ko $K/kmod/$T.ko && log "built $T.ko"
else
	echo "module build failed:"; tail -8 $d/make.log; echo E1u-module-failed > $K/STATE-E1u; exit 1
fi
python3 ~/src/umount-bench/bin/mkinitrd.py -o $K/initrd-E1u.cpio --init $K/init.sh --add "$K/kmod/$T.ko:/klitmus/$T.ko" || { echo E1u-initrd-failed > $K/STATE-E1u; exit 1; }
wait_lock
echo E1u-running-vm > $K/STATE-E1u
log "qemu start"
timeout --foreground 5400 taskset -c 256-263 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m 4G -nographic -no-reboot \
	-kernel $K/bzImage -initrd $K/initrd-E1u.cpio \
	-append "console=ttyS0 panic=-1 klitmus_nruns=$NRUNS klitmus_size=$SIZE" < /dev/null > $K/vm-E1u.log 2>&1; log "qemu rc=$?"
grep -aE '^===== MODULE|^Observation|insmod failed' $K/vm-E1u.log
echo E1u-cleaning > $K/STATE-E1u
git -C ~/src/git/linux worktree remove --force $K/build/src || rm -rf $K/build/src
rm -rf $K/build; git -C ~/src/git/linux worktree prune
echo E1u-done > $K/STATE-E1u
log "done"

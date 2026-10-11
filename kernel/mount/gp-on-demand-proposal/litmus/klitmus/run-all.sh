#!/bin/bash
# klitmus pipeline on jens: kernel 4379d47fd314 -> klitmus7 modules -> KVM guest run -> cleanup.
# Every step is a separate script in ~/tmp/klitmus so one can be fixed while another runs.
set -u
K=~/tmp/klitmus
LOCK=~/tmp/jens-bigvm.lock
log() { echo "$(date -u +%FT%TZ) $*"; }
wait_lock() { while [ -e "$LOCK" ]; do log "lock $LOCK present, waiting 120s"; sleep 120; done; }
cd $K || exit 1
echo pipeline-start > $K/STATE
if [ ! -f $K/bzImage ]; then
	wait_lock
	echo building-kernel > $K/STATE
	log "build-kernel.sh start"
	bash $K/step1-build.sh > $K/build.log 2>&1; rc=$?
	log "build-kernel.sh rc=$rc"; tail -3 $K/build.log
	[ $rc -eq 0 ] && [ -f $K/bzImage ] || { echo build-failed > $K/STATE; exit 1; }
fi
echo building-modules > $K/STATE
bash $K/step2-modules.sh > $K/modules.log 2>&1; log "step2 rc=$?"; tail -15 $K/modules.log
echo building-initrd > $K/STATE
bash $K/step3-initrd.sh > $K/initrd.log 2>&1; rc=$?; log "step3 rc=$rc"; tail -5 $K/initrd.log
[ $rc -eq 0 ] || { echo initrd-failed > $K/STATE; exit 1; }
wait_lock
echo running-vm > $K/STATE
log "qemu start"
bash $K/step4-vm.sh > $K/vm.log 2>&1; log "qemu rc=$?"
log "observations in vm.log: $(grep -c '^Observation' $K/vm.log)"
grep '^Observation' $K/vm.log
echo cleaning > $K/STATE
bash $K/step5-cleanup.sh >> $K/cleanup.log 2>&1; log "cleanup rc=$?"
echo done > $K/STATE
log "pipeline done"

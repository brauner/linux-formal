#!/bin/bash
# VM-only rerun: wait for the lock, run step4, print the module results
set -u
K=~/tmp/klitmus
LOCK=~/tmp/jens-bigvm.lock
log() { echo "$(date -u +%FT%TZ) $*"; }
while [ -e "$LOCK" ]; do log "lock present, waiting 120s"; sleep 120; done
echo running-vm > $K/STATE
log "qemu start"
bash $K/step4-vm.sh > $K/vm.log 2>&1; log "qemu rc=$?"
log "observations: $(grep -c '^Observation' $K/vm.log)"
grep -aE '^===== MODULE|^Observation|insmod failed' $K/vm.log
echo vm-done > $K/STATE

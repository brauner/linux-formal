#!/bin/bash
# build, then boot; waits while a benchmark agent owns the machine
G=$HOME/tmp/gp-trace
say() { echo "$(date +%T) $*" | tee -a $G/progress.log; }
while [ -e $HOME/tmp/jens-bigvm.lock ]; do say "waiting for jens-bigvm.lock"; sleep 120; done
if [ ! -f /tmp/brauner-tomb-holders/umb-trace/SHA ] || [ "$(cat /tmp/brauner-tomb-holders/umb-trace/SHA)" != "$(cat $G/SHA)" ]; then
	unshare -rm --propagation private bash $G/build.sh || { say "pipeline: build failed"; exit 1; }
fi
while [ -e $HOME/tmp/jens-bigvm.lock ]; do say "waiting for jens-bigvm.lock"; sleep 120; done
bash $G/run-vm.sh
say "pipeline: done"

#!/bin/bash
# Run the trace validation over a selection of the converted gpbreak traces, 32 TLC instances at a time on CPUs 256-511.
# usage: tlc-batch.sh RUN [MAX_WITH_TASKS] [MAX_TRIVIAL]
set -u
G=$HOME/tmp/gp-trace; T=$G/tla; run=$1; maxt=${2:-400}; maxz=${3:-100}
cd $T || exit 1
say() { echo "$(date +%T) $*" | tee -a $G/progress.log; }
while [ -e $HOME/tmp/jens-bigvm.lock ]; do say "waiting for jens-bigvm.lock"; sleep 120; done
sel=$G/select-$run.txt
grep -v 'walkers=0 holders=0' $G/convert-$run.out | grep -o 'mnt-[0-9]*\.ndjson' | head -n $maxt > $sel
grep 'walkers=0 holders=0' $G/convert-$run.out | grep -o 'mnt-[0-9]*\.ndjson' | head -n $maxz >> $sel
say "TLC batch $run: $(wc -l < $sel) traces"
export MODEL=$T/model TLA2TOOLS=$T/tla2tools-1.8.0.jar COMMUNITY_MODULES=$T/CommunityModules-deps.jar TLC_TIMEOUT=900 TLC_HEAP=3g
sed "s|^|$G/ndjson/$run/|" $sel | taskset -c 256-511 xargs -P 32 -n 1 bash -c './validate.sh "$0" >> results-'$run'.tsv 2>/dev/null; true' > /dev/null 2>&1
say "TLC batch $run done: $(cut -f2 results-$run.tsv | sort | uniq -c | tr '\n' ' ')"

#!/bin/bash
# Run TLC on one configuration: ./check.sh <config-name> [workers]
# Needs tla2tools.jar; point TLA2TOOLS at it.
# TLC checkpoints every TLC_CHECKPOINT minutes (default 10) into the metadir
# and a rerun of the same configuration resumes from the newest checkpoint
# (TLC_RECOVER=no disables that).  Deadlock detection is on: MntCover
# only stutters once everything settled, so a state nothing can leave is
# a bug.  TLC_DEADLOCK=ignore turns it off.
set -u
cd "$(dirname "$0")"
cfg=$1
workers=${2:-8}
jar=${TLA2TOOLS:-./tla2tools.jar}
layout=${cfg%%_*}
module=MC_$layout
meta=${TLC_METADIR:-/tmp/tlc-mount-covers}/$cfg
mkdir -p "$meta/tmp" logs
recover=""
if [ "${TLC_RECOVER:-auto}" != "no" ]; then
    id=$(ls -1t "$meta" 2>/dev/null | grep -v '^tmp$' | head -1)
    if [ -n "$id" ] && ls "$meta/$id"/*.chkpt >/dev/null 2>&1; then
        recover="-recover $meta/$id"
        echo "resuming $cfg from checkpoint $id" | tee -a "logs/$cfg.log"
    fi
fi
deadlock=""; [ "${TLC_DEADLOCK:-check}" = "ignore" ] && deadlock="-deadlock"
java -XX:+UseParallelGC -Xmx${TLC_HEAP:-6g} -Djava.io.tmpdir="$meta/tmp" -cp "$jar" tlc2.TLC \
     -workers "$workers" $deadlock -checkpoint "${TLC_CHECKPOINT:-10}" $recover -metadir "$meta" \
     -config "$cfg.cfg" "$module.tla" 2>&1 | tee -a "logs/$cfg.log" | \
     grep -E 'Error|violated|Finished|states generated|distinct|Invariant|Temporal|is not|Deadlock|Assertion|Attempted|TLC threw|stack trace|Exception|EXCEPT|MC_|not enabled|line [0-9]+|resuming'
echo "exit: ${PIPESTATUS[0]}  (full log: logs/$cfg.log)"

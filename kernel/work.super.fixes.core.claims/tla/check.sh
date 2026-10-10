#!/bin/bash
# Run TLC on one configuration: ./check.sh <config-name> [workers]
# Needs tla2tools.jar (the symlink here, or point TLA2TOOLS at it).
# The configuration <layout>_<what>.cfg runs the module MC_<layout>.tla.
# Deadlock checking is ON (the models end in a stuttering Finished state, so a
# deadlock is a task stuck for good); a cfg with the line "\* deadlock: ignore"
# or TLC_DEADLOCK=ignore turns it off.  TLC_HEAP (default 4g), TLC_METADIR
# (default /tmp/$USER-tlc-super), TLC_CHECKPOINT minutes (default 10); a rerun
# resumes from the newest checkpoint unless TLC_RECOVER=no.  Every run gets its
# own java.io.tmpdir: two TLC instances sharing /tmp race on /tmp/TLC.tla.
# On a laptop wrap it: systemd-run --user --scope -p MemoryMax=6G ./check.sh cfg 4
set -u
cd "$(dirname "$0")"
cfg=$1
workers=${2:-4}
jar=${TLA2TOOLS:-./tla2tools.jar}
layout=${cfg%%_*}
module=MC_$layout
meta=${TLC_METADIR:-/tmp/$USER-tlc-super}/$cfg
mkdir -p "$meta/tmp" logs
recover=""
if [ "${TLC_RECOVER:-auto}" != "no" ]; then
    id=$(ls -1t "$meta" 2>/dev/null | grep -v '^tmp$' | head -1)
    if [ -n "$id" ] && ls "$meta/$id"/*.chkpt >/dev/null 2>&1; then
        recover="-recover $meta/$id"
        echo "resuming $cfg from checkpoint $id" | tee -a "logs/$cfg.log"
    fi
fi
deadlock=""
if [ "${TLC_DEADLOCK:-check}" = "ignore" ] || grep -q '^\\\* deadlock: ignore' "$cfg.cfg"; then
    deadlock="-deadlock"
fi
java -XX:+UseParallelGC -Xmx${TLC_HEAP:-4g} -Djava.io.tmpdir="$meta/tmp" -cp "$jar" tlc2.TLC \
     -workers "$workers" $deadlock -checkpoint "${TLC_CHECKPOINT:-10}" $recover -metadir "$meta" \
     -config "$cfg.cfg" "$module.tla" 2>&1 | tee -a "logs/$cfg.log" | \
     grep -E 'Error|violated|Finished|states generated|distinct|Invariant|Temporal|is not|Deadlock|Assertion|Attempted|TLC threw|stack trace|Exception|EXCEPT|MC_|not enabled|line [0-9]+|resuming'
echo "exit: ${PIPESTATUS[0]}  (full log: logs/$cfg.log)"

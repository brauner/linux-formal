#!/bin/bash
# Run TLC on one configuration: ./check.sh <config-name> [workers]
set -u
cd "$(dirname "$0")"
cfg=$1
workers=${2:-${TLC_WORKERS:-4}}
jar=${TLA2TOOLS:-./tla2tools.jar}
meta=${TLC_METADIR:-/tmp/tlc-file-ref}/$cfg
mkdir -p "$meta/tmp" logs
java -Xmx"${TLC_HEAP:-6g}" -XX:+UseParallelGC -Djava.io.tmpdir="$meta/tmp" -cp "$jar" tlc2.TLC \
     -workers "$workers" -deadlock -cleanup -metadir "$meta" \
     -config "$cfg.cfg" FileRef.tla > "logs/$cfg.log" 2>&1
expect=$(sed -n 's/.*expected: //p' "$cfg.cfg")
log=logs/$cfg.log
if grep -q 'TLC threw an unexpected exception\|Parsing or semantic analysis failed\|Error: .*Attempted' "$log"; then result=ERROR
elif grep -q 'Invariant .* is violated\|Temporal properties were violated' "$log"; then result=violation
elif grep -q 'Model checking completed. No error has been found' "$log"; then result=pass
else result=unknown; fi
states=$(sed -n 's/^\([0-9]*\) states generated, \([0-9]*\) distinct states found.*/\2/p' "$log" | tail -1)
secs=$(sed -n 's/^Finished in \(.*\) at.*/\1/p' "$log" | tail -1)
printf '%-26s %-10s %-10s %-10s %-10s %s\n' "$cfg" "$expect" "$result" "$states" "$secs" "$([ "$result" = "$expect" ] && echo ok || echo MISMATCH)"

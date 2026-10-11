#!/bin/bash
# Run the SuperFreeze and SuperHolder configurations (or the ones named on
# the command line) one after the other through check.sh and compare each
# result with the "expected:" line at the top of the cfg.
#   ./check-all-freeze-holder.sh [cfg...]
# On a laptop: systemd-run --user --scope -p MemoryMax=6G ./check-all-freeze-holder.sh
# freeze_all_fail, freeze_all_weak and holder_big* want a big machine
# (hundreds of millions of states); SKIP_BIG=1 leaves them out.
cd "$(dirname "$0")"
cfgs=("$@")
if [ ${#cfgs[@]} -eq 0 ]; then
    cfgs=($(ls freeze_*.cfg holder_*.cfg | sed 's/\.cfg$//'))
fi
mkdir -p logs
out=logs/summary-freeze-holder.txt
printf '%-30s %-28s %-28s %-12s %s\n' config expected result states verdict > "$out"
for cfg in "${cfgs[@]}"; do
    case "$cfg" in freeze_all_*|holder_big*) [ -n "${SKIP_BIG:-}" ] && continue ;; esac
    expect=$(sed -n '1s/.*expected: //p' "$cfg.cfg")
    rm -f "logs/$cfg.log"
    TLC_RECOVER=no ./check.sh "$cfg" "${TLC_WORKERS:-4}" > /dev/null 2>&1
    log=logs/$cfg.log
    if grep -q 'TLC threw an unexpected exception\|Parsing or semantic analysis failed\|Attempted' "$log"; then
        result=ERROR
    elif grep -q 'Deadlock reached' "$log"; then
        result=deadlock
    elif inv=$(sed -n 's/^Error: Invariant \(.*\) is violated.*/\1/p' "$log" | head -1) && [ -n "$inv" ]; then
        result="violation: $inv"
    elif grep -q 'Model checking completed. No error has been found' "$log"; then
        result=pass
    else
        result=unknown
    fi
    states=$(sed -n 's/^[0-9]* states generated, \([0-9]*\) distinct states found.*/\1/p' "$log" | tail -1)
    verdict=$([ "$result" = "$expect" ] && echo ok || echo MISMATCH)
    printf '%-30s %-28s %-28s %-12s %s\n' "$cfg" "$expect" "$result" "$states" "$verdict" | tee -a "$out"
done

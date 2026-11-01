#!/bin/bash
# Build logs/summary.txt from the logs of the configurations.
cd "$(dirname "$0")"
out=logs/summary.txt
printf '%-26s %-10s %-10s %-10s %-8s %s\n' config expected result states time check > $out
for cfg in $(ls *.cfg | sed 's/\.cfg$//'); do
    log=logs/$cfg.log
    [ -f "$log" ] || continue
    expect=$(sed -n '1s/.*expected: //p' "$cfg.cfg")
    if grep -q 'TLC threw an unexpected exception\|Parsing or semantic analysis failed\|Assertion\|OutOfMemory\|when writing the disk\|Error: TLC' "$log"; then result=ERROR
    elif grep -q 'Invariant .* is violated' "$log"; then result=violation
    elif grep -q 'Temporal properties were violated' "$log"; then result=violation
    elif grep -q 'Deadlock reached' "$log"; then result=deadlock
    elif grep -q 'Model checking completed. No error has been found' "$log"; then result=pass
    else result=running; fi
    states=$(sed -n 's/^\([0-9]*\) states generated, \([0-9]*\) distinct states found.*/\2/p' "$log" | tail -1)
    took=$(sed -n 's/^Finished in \(.*\) at .*/\1/p' "$log" | tail -1 | tr -d ' ')
    mark=$([ "$result" = "${expect%%:*}" ] && echo ok || echo MISMATCH)
    printf '%-26s %-10s %-10s %-10s %-8s %s\n' "$cfg" "${expect%%:*}" "$result" "${states:--}" "${took:--}" "$mark" >> $out
done
cat $out

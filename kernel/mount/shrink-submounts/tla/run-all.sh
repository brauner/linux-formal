#!/bin/bash
# run-all.sh <lanes> <workers> <cfg>...: run the configurations, <lanes> at a
# time, verdicts in logs/summary.txt.  TLC sometimes hangs after printing a
# counterexample; a run whose log carries the trace and stops growing is
# killed by its configuration name.
lanes=$1; workers=$2; shift 2
cd "$(dirname "$0")"
mkdir -p logs
run_one() {
	c=$1; start=$(date +%s)
	rm -f "logs/$c.log"
	( timeout "${TLC_TIMEOUT:-8h}" ./check.sh "$c" "$workers" > "logs/$c.out" 2>&1 ) &
	pid=$!
	last=0; same=0
	while kill -0 $pid 2>/dev/null; do
		sleep 30
		if grep -q "Error: The behavior up to this point" "logs/$c.log" 2>/dev/null; then
			sz=$(stat -c %s "logs/$c.log")
			if [ "$sz" = "$last" ]; then same=$((same + 1)); else same=0; last=$sz; fi
			[ $same -ge 2 ] && pkill -f "config $c.cfg"
		fi
	done
	v=$(grep -m1 -o "Invariant [A-Za-z]* is violated\|Finished in [0-9a-z]*\|TLC threw.*\|Exception.*\|Attempted.*" "logs/$c.log")
	d=$(grep -o "[0-9]* distinct states found" "logs/$c.log" | tail -1)
	echo "$c: ${v:-no verdict}; $d ($(( $(date +%s) - start ))s)" >> logs/summary.txt
}
export -f run_one; export workers
printf '%s\n' "$@" | xargs -P "$lanes" -I{} bash -c 'run_one {}'
echo BATCH_DONE >> logs/summary.txt

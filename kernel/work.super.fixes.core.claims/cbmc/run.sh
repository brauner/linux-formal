#!/bin/bash
# Run the device table harness (devtable.c).  One cbmc at a time, each under a
# 6G memory cap (the laptop has frozen from OOM before).
#
#   ./run.sh                  all configurations listed below
#   ./run.sh devtable-wait    one configuration
#   ./run.sh -l               list configurations
#   TRACE=1 ./run.sh ...      add --trace (counterexamples)
#   PROP=<id> ./run.sh ...    check one property only (implies a trace)
#   SLICE=1 ./run.sh ...      add --slice-formula
#   TIMEOUT=<s> ./run.sh ...  wall clock cap per run (default 1200)
#
# Logs go to results/<config>[.<property>].log; trace_ops.py condenses traces.

set -u
cd "$(dirname "$0")"

# CBMC 6.6.0 from PATH; for a local install point CBMC at it, e.g.
# CBMC="env LD_LIBRARY_PATH=$HOME/opt/fv/usr/lib $HOME/opt/fv/usr/bin/cbmc"
CBMC=${CBMC:-cbmc}
CAP="systemd-run --user --scope -q -p MemoryMax=6G --"
TIMEOUT=${TIMEOUT:-1200}
mkdir -p results

COMMON="--unwinding-assertions --bounds-check --sat-solver cadical"

# Every loop is bounded by the step count or a small constant (NENT, NSB,
# NDEV, NREG, NCUR <= 5); a cursor's wait is a separate step, not a loop.
devtable_unwind() {
	echo "--unwind $(($1 + 1))"
}

# name | steps | -D flags
# devtable.c knobs: CFG_UNBORN_WAIT (1: unborn-wait cursor, 0: fc1c25014ff8)
#   CHECK_REACH NDEV CFG_SERIAL CFG_INSERT_TAIL CFG_DYING_WINDOW CFG_FAIL_INSERT
CONFIGS=(
"devtable-wait|8|-DNDEV=2"
"devtable-wait-n10|10|-DNDEV=2"
"devtable-wait-reach|10|-DNDEV=2 -DCHECK_REACH=1"
"devtable-pin|8|-DNDEV=2 -DCFG_UNBORN_WAIT=0"
)

run_one() {
	local name=$1 steps=$2 defs=$3 unwind extra=""
	unwind=$(devtable_unwind "$steps")
	[ -n "${TRACE:-}" ] && extra="--trace"
	[ -n "${PROP:-}" ] && extra="--trace --property $PROP"
	[ -n "${SLICE:-}" ] && extra="$extra --slice-formula"
	local cmd="$CBMC devtable.c -DNSTEPS=$steps $defs $unwind $COMMON $extra"
	echo "== $name: $cmd"
	{
		echo "# $cmd"
		local t0=$(date +%s)
		$CAP timeout "$TIMEOUT" $cmd 2>&1
		echo "# exit=$? wall=$(( $(date +%s) - t0 ))s"
	} > "results/$name${PROP:+.$PROP}.log"
	grep -E "^VERIFICATION|FAILURE|^# exit" "results/$name${PROP:+.$PROP}.log"
}

if [ "${1:-}" = "-l" ]; then
	printf '%s\n' "${CONFIGS[@]}"
	exit 0
fi

for c in "${CONFIGS[@]}"; do
	IFS='|' read -r name steps defs <<<"$c"
	if [ $# -gt 0 ]; then
		match=0
		for want in "$@"; do [ "$want" = "$name" ] && match=1; done
		[ $match = 1 ] || continue
	fi
	run_one "$name" "$steps" "$defs"
done

#!/bin/bash
# Run the fs/super.c CBMC harnesses.  One cbmc at a time, each under a 6G
# memory cap (the laptop has frozen from OOM before).
#
#   ./run.sh                  all configurations listed below
#   ./run.sh freeze-pm        one configuration
#   ./run.sh -l               list configurations
#   TRACE=1 ./run.sh ...      add --trace (counterexamples)
#   PROP=<id> ./run.sh ...    check one property only (implies a trace)
#   SLICE=1 ./run.sh ...      add --slice-formula
#
# Logs go to results/<config>.log; trace_ops.py condenses traces.

set -u
cd "$(dirname "$0")"

# CBMC 6.6.0 from PATH; for a local install point CBMC at it, e.g.
# CBMC="env LD_LIBRARY_PATH=$HOME/opt/fv/usr/lib $HOME/opt/fv/usr/bin/cbmc"
CBMC=${CBMC:-cbmc}
CAP="systemd-run --user --scope -q -p MemoryMax=6G --"
TIMEOUT=${TIMEOUT:-3600}
mkdir -p results

COMMON="--unwinding-assertions --bounds-check --sat-solver cadical"

# Every loop is bounded by the step count or a small constant; only the
# coroutine back edges get a tight bound (they are taken at most once per
# step: a resumed freezer re-enters wait_for_partially_frozen()'s loop or
# freeze_super()'s "goto retry" at most once before it returns).
freeze_unwind() {
	echo "--unwind $(($1 + 1)) --unwindset freeze_super_co.0:2,freeze_super_co.1:2,bdev_freeze_co.0:2,bdev_thaw_co.0:2"
}
holder_unwind() {
	echo "--unwind $(($1 + 1)) --unwindset freeze_super_co.0:2,freeze_super_co.1:2,bdev_freeze_co.0:4,bdev_thaw_co.0:4"
}
devtable_unwind() {
	echo "--unwind $(($1 + 1))"
}

# name | file | steps | -D flags
# freeze.c knobs: CFG_PM CFG_K CFG_BDEV CFG_MULTIDEV CFG_REMOUNT CFG_MOUNTS
#   CFG_ANON_US_THAW CFG_EMERGENCY CFG_FS_ERROR_RO CFG_FAIL_SYNC_BLOCKDEV
#   CFG_FAIL_UNFREEZE_FS CHECK_ACCOUNTING PATCH_9ae90f06a813
F_PM="-DCFG_BDEV=0 -DCFG_REMOUNT=0 -DCFG_MOUNTS=0"
F_BDEV="-DCFG_PM=0 -DCFG_K=0 -DCFG_REMOUNT=0 -DCFG_MOUNTS=0"
F_LIFE="-DCFG_PM=0 -DCFG_MULTIDEV=0"
CONFIGS=(
"freeze-pm|freeze.c|6|$F_PM"
"freeze-pm-fixed|freeze.c|7|$F_PM -DPATCH_9ae90f06a813"
"freeze-bdev|freeze.c|6|$F_BDEV"
"freeze-bdev-nounfreezefail|freeze.c|7|$F_BDEV -DCFG_FAIL_UNFREEZE_FS=0"
"freeze-bdev-anon|freeze.c|6|$F_BDEV -DCFG_ANON_US_THAW=1 -DCHECK_ACCOUNTING=0 -DCFG_FAIL_UNFREEZE_FS=0"
"freeze-bdev-syncblk|freeze.c|6|$F_BDEV -DCFG_FAIL_SYNC_BLOCKDEV=1 -DCFG_FAIL_UNFREEZE_FS=0"
"freeze-emergency|freeze.c|6|$F_BDEV -DCFG_EMERGENCY=1 -DCHECK_ACCOUNTING=0 -DCFG_FAIL_UNFREEZE_FS=0"
"freeze-life|freeze.c|6|$F_LIFE"
"freeze-fserr-ro|freeze.c|6|$F_LIFE -DCFG_FS_ERROR_RO=1 -DCFG_BDEV=0 -DCFG_MOUNTS=0"
"freeze-all|freeze.c|5|-DPATCH_9ae90f06a813 -DCFG_FAIL_UNFREEZE_FS=0"
"freeze-bdev-anon-fixed|freeze.c|5|$F_BDEV -DCFG_ANON_US_THAW=1 -DCHECK_ACCOUNTING=0 -DCFG_FAIL_UNFREEZE_FS=0 -DPATCH_86d692e754a8"
"freeze-emergency-fixed|freeze.c|5|$F_BDEV -DCFG_EMERGENCY=1 -DCHECK_ACCOUNTING=0 -DCFG_FAIL_UNFREEZE_FS=0 -DPATCH_86d692e754a8"
"freeze-bdev-syncblk-fixed|freeze.c|5|$F_BDEV -DCFG_FAIL_SYNC_BLOCKDEV=1 -DCFG_FAIL_UNFREEZE_FS=0 -DPATCH_e7552629ff47"
"freeze-bdev-anon-n5|freeze.c|5|$F_BDEV -DCFG_ANON_US_THAW=1 -DCHECK_ACCOUNTING=0 -DCFG_FAIL_UNFREEZE_FS=0"
"freeze-emergency-n5|freeze.c|5|$F_BDEV -DCFG_EMERGENCY=1 -DCHECK_ACCOUNTING=0 -DCFG_FAIL_UNFREEZE_FS=0"
"freeze-bdev-syncblk-n5|freeze.c|5|$F_BDEV -DCFG_FAIL_SYNC_BLOCKDEV=1 -DCFG_FAIL_UNFREEZE_FS=0"
"holder-core|holder_errs.c|6|-DNSB=2"
"holder-core3|holder_errs.c|6|-DNSB=3"	# full-property runs: final UNSAT not reached in 22-27 min
"holder-erofs|holder_errs.c|6|-DNSB=2 -DCFG_SHARED_RDONLY=1"
"holder-anon|holder_errs.c|6|-DNSB=2 -DCFG_ANON_US_THAW=1"
"holder-emergency|holder_errs.c|6|-DNSB=2 -DCFG_EMERGENCY=1"
"holder-syncblk|holder_errs.c|6|-DNSB=2 -DCFG_FAIL_SYNC_BLOCKDEV=1"
"devtable-serial|devtable.c|8|-DNDEV=2"
"devtable-serial-n6|devtable.c|6|-DNDEV=2"
"devtable-serial-n10|devtable.c|10|-DNDEV=2"	# full-property: 1800 s cap hit; use SLICE=1 PROP=...
"devtable-serial-1dev|devtable.c|10|-DNDEV=1"
"devtable-tail|devtable.c|10|-DNDEV=2 -DCFG_INSERT_TAIL=1"
"devtable-nonserial|devtable.c|10|-DNDEV=2 -DCFG_SERIAL=0"
)

run_one() {
	local name=$1 file=$2 steps=$3 defs=$4 unwind extra=""
	case $file in
	freeze.c)	unwind=$(freeze_unwind "$steps") ;;
	holder_errs.c)	unwind=$(holder_unwind "$steps") ;;
	devtable.c)	unwind=$(devtable_unwind "$steps") ;;
	esac
	[ -n "${TRACE:-}" ] && extra="--trace"
	[ -n "${PROP:-}" ] && extra="--trace --property $PROP"
	[ -n "${SLICE:-}" ] && extra="$extra --slice-formula"
	local cmd="$CBMC $file -DNSTEPS=$steps $defs $unwind $COMMON $extra"
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
	IFS='|' read -r name file steps defs <<<"$c"
	if [ $# -gt 0 ]; then
		match=0
		for want in "$@"; do [ "$want" = "$name" ] && match=1; done
		[ $match = 1 ] || continue
	fi
	run_one "$name" "$file" "$steps" "$defs"
done

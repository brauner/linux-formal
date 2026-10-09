#!/bin/bash
# run-some.sh ARCH MODEL SPEEDCHECK(true|false) TEST...   -> ARCH/<test>[.full].out, appends to ARCH/summary-extra.txt
cd "$(dirname "$0")"
arch=$1; model=$2; sc=$3; shift 3
for n in "$@"; do
	suf=""; [ "$sc" = false ] && suf=".full"
	( time herd7 -model $model -speedcheck $sc $arch/$n.litmus ) > $arch/$n$suf.out 2>&1
	obs=$(grep -E "^Observation|rror" $arch/$n$suf.out | tr '\n' ' ')
	lk=$(grep -m1 -oE "LKMM result: [A-Za-z]+" $arch/$n.litmus)
	printf "%-42s %-24s speedcheck=%-5s %s\n" "$n" "$lk" "$sc" "$obs" | tee -a $arch/summary-extra.txt
done
echo "DONE $(date -u +%T) $*" | tee -a $arch/summary-extra.txt

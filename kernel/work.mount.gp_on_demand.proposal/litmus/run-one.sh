#!/bin/bash
# run-one.sh ARCH MODEL TEST -> ARCH/TEST.out (speedcheck); appends to ARCH/summary-par.txt
cd "$(dirname "$0")"
arch=$1; model=$2; n=$3
( time herd7 -model $model -speedcheck true $arch/$n.litmus ) > $arch/$n.out 2>&1
obs=$(grep -E "^Observation|rror" $arch/$n.out | tr '\n' ' ')
lk=$(grep -m1 -oE "LKMM result: [A-Za-z]+" $arch/$n.litmus)
printf "%-42s %-24s %s %s\n" "$n" "$lk" "$obs" "$(grep ^real $arch/$n.out)" >> $arch/summary-par.txt

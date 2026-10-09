#!/bin/bash
# run every generated asm litmus test under its architecture model; summary per arch
cd "$(dirname "$0")"
arch=$1; model=$2
: > $arch/summary.txt
for t in $arch/MNT-*.litmus; do
	n=$(basename $t .litmus)
	( time herd7 -model $model -speedcheck true $t ) > $arch/$n.out 2>&1
	obs=$(grep -E "^Observation|rror|^Flag" $arch/$n.out | tr '\n' ' ')
	lk=$(grep -m1 -oE "LKMM result: [A-Za-z]+" $t)
	printf "%-42s %-24s %s\n" "$n" "$lk" "$obs" | tee -a $arch/summary.txt
done
echo "ARCH $arch DONE $(date -u +%T)" | tee -a $arch/summary.txt

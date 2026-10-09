#!/bin/bash
# Tabulate LKMM / AArch64 / PPC herd7 results (and x86 klitmus results if x86-klitmus.txt exists)
cd "$(dirname "$0")"
res() { # arch test -> Never|Sometimes|witnessed|unfinished|-
	local f=$1/$2.out full=$1/$2.full.out o
	[ -f "$full" ] && o=$(grep -E "^Observation" $full | awk '{print $3" "$4" "$5}') && [ -n "$o" ] && { echo "$o (full)"; return; }
	[ -f "$f" ] || { echo "-"; return; }
	o=$(grep -E "^Observation" $f | awk '{print $3" "$4" "$5}')
	[ -z "$o" ] && { grep -q "rror" $f && echo "ERROR" || echo "unfinished"; return; }
	case $o in Always*) echo "witnessed (speedcheck)";; Never*) echo "Never";; *) echo "$o";; esac
}
printf "%-40s %-10s %-24s %-24s %s\n" test LKMM AArch64 POWER x86-klitmus
for t in $(ls aarch64/MNT-*.litmus | xargs -n1 basename | sed 's/.litmus$//' | sort); do
	lk=$(grep -m1 -oE "LKMM result: [A-Za-z]+" aarch64/$t.litmus | awk '{print $3}')
	x=$(grep -h "^Observation $t " x86-klitmus.txt 2>/dev/null | awk '{print $3" "$4"/"$5}')
	printf "%-40s %-10s %-24s %-24s %s\n" "$t" "$lk" "$(res aarch64 $t)" "$(res ppc $t)" "${x:--}"
done

#!/bin/bash
# run-hw.sh -> runs the hand-translated hardware litmus tests under the
# architecture models shipped with herdtools7 (aarch64.cat, ppc.cat) and
# writes RESULTS-hw.txt.  The LKMM result each translation corresponds
# to is in its header.
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
for t in aarch64/*.litmus; do herd7 -model aarch64.cat "$t" > "${t%.litmus}.out" 2>&1; done
for t in ppc/*.litmus; do herd7 -model ppc.cat "$t" > "${t%.litmus}.out" 2>&1; done
{
	printf "%-44s %-12s %s\n" test "LKMM" "architecture model"
	for t in aarch64/*.litmus ppc/*.litmus; do
		lk=$(grep -m1 -oE "LKMM result: [A-Za-z]+" "$t" | awk '{print $3}')
		obs=$(grep -m1 -E "^Observation" "${t%.litmus}.out" | awk '{print $3" ("$4" of "$4+$5")"}')
		printf "%-44s %-12s %s\n" "${t%.litmus}" "${lk:--}" "${obs:-ERROR}"
	done
} > RESULTS-hw.txt
cat RESULTS-hw.txt

#!/bin/bash
# run-lkmm.sh [TEST...] -> TEST.out next to each SUPER-*.litmus, then RESULTS-lkmm.txt
#
# Runs herd7 against the LKMM of the kernel tree the tests were written
# for (override with LKMM=<tree>/tools/memory-model).  The expected
# result is the "Expected:" line of each test's header comment.
set -e
here=$(cd "$(dirname "$0")" && pwd)
lkmm=${LKMM:?set LKMM to the tools/memory-model directory of a kernel tree}
cd "$here"
tests=("$@")
[ ${#tests[@]} -eq 0 ] && tests=($(ls SUPER-*.litmus | sed 's/\.litmus$//'))
for t in "${tests[@]}"; do
	t=${t%.litmus}
	(cd "$lkmm" && herd7 -conf linux-kernel.cfg "$here/$t.litmus") > "$t.out" 2>&1 || true
done
{
	printf "%-48s %-10s %-26s %s\n" test expected observation flags
	for f in SUPER-*.litmus; do
		t=${f%.litmus}
		exp=$(grep -m1 -oE "Expected: [A-Za-z]+" "$f" | awk '{print $2}')
		obs=$(grep -m1 -E "^Observation" "$t.out" 2>/dev/null | awk '{print $3" ("$4" of "$4+$5")"}')
		[ -z "$obs" ] && obs=ERROR
		flg=$(grep -E "^Flag" "$t.out" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
		ok=
		case "$obs" in "$exp"*) ok=;; *) ok=" <-- MISMATCH";; esac
		printf "%-48s %-10s %-26s %s%s\n" "$t" "$exp" "$obs" "${flg:--}" "$ok"
	done
} > RESULTS-lkmm.txt
cat RESULTS-lkmm.txt

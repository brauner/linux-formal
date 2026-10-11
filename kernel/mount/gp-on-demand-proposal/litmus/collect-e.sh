#!/bin/bash
# Tabulate the E family (the two tests the kernel carries, the reshaped slow path test and their
# mutations) under LKMM, every hardware model in this directory and x86 klitmus.  Full runs win over
# -speedcheck runs; "witnessed" is a -speedcheck run that found the bad outcome.
cd "$(dirname "$0")"
res() { # dir test [tag] -> Never|Sometimes|witnessed|unfinished|-
	local d=$1 t=$2 tag=${3:+.$3} f full o
	f=$d/$t$tag.out; full=$d/$t$tag.full.out
	[ -f "$full" ] && o=$(grep -E "^Observation" $full | awk '{print $3" "$4" "$5}') && [ -n "$o" ] && { echo "$o (full)"; return; }
	[ -f "$f" ] || { echo "-"; return; }
	o=$(grep -E "^Observation" $f | awk '{print $3" "$4" "$5}')
	[ -z "$o" ] && { grep -q "rror" $f && echo "ERROR" || echo "unfinished"; return; }
	case $o in Always*) echo "witnessed";; Never*) echo "Never";; *) echo "$o";; esac
}
lkmm() { grep -E "^Observation" $1.out 2>/dev/null | awk '{print $3" "$4" "$5}'; }
x86() { grep -h "^Observation $1 " x86-klitmus.txt 2>/dev/null | awk '{print $3" "$4"/"$5}'; }
fmt="%-36s %-18s %-16s %-16s %-16s %-16s %-16s %-16s %-16s %-16s %s\n"
printf "$fmt" test LKMM AArch64 POWER RISC-V RISC-V-lrsc MIPS MIPS-weak ARMv7 AArch32 x86-klitmus
for t in MNT-E1-slowpath-no-outer-mb MNT-E1u-slowpath-after-umount-tree MNT-E2-busycheck-no-outer-mb \
         MNT-E1m-nomb-in-sum MNT-E1m-walker-nomb MNT-E1um-nomb-in-sum MNT-E1um-walker-nomb \
         MNT-E2m-nomb-in-sum MNT-E2m-walker-nomb; do
	printf "$fmt" "$t" "$(lkmm $t)" "$(res aarch64 $t)" "$(res ppc $t)" "$(res riscv $t)" "$(res riscv-lrsc $t)" \
		"$(res mips $t)" "$(res mips-weak $t)" "$(res arm $t armv7)" "$(res arm $t aarch32)" "$(x86 $t)"
done

#!/bin/bash
# run.sh TARGET [BOUND] [VARIANT-REGEX]
#   TARGET: lkmm | arm8 | power | tso | power-c11 | arm8-c11 (C11 builtins, kernel fence mapping)
# Compiles each harness variant with clang (CC, default clang-19) and checks
# it with Dartagnan under the matching cat file.  Results append to
# ~/tmp/dat3m/results.tsv (target, variant, result, seconds, log).
set +u
T=$1; B=${2:-2}; FILTER=${3:-.}
D=~/tmp/dat3m; H=$D/harness
export DAT3M_HOME=$D/Dat3M DAT3M_OUTPUT=$D/output
export JAVA_HOME=~/opt/jdk21 PATH=~/opt/jdk21/bin:$PATH
CC=${CC:-clang-19}
JAR=$DAT3M_HOME/dartagnan/target/dartagnan.jar
mkdir -p $DAT3M_OUTPUT $H/ll $D/logs/$T
if [ -e ~/tmp/jens-bigvm.lock ]; then echo "lock present, not starting"; exit 2; fi
case $T in
  lkmm)  CAT=$DAT3M_HOME/cat/linux-kernel.cat; TDEF="-DTARGET_LKMM";    PROPS=program_spec,cat_spec; GP="";;
  arm8)  CAT=$DAT3M_HOME/cat/aarch64.cat;      TDEF="-DTARGET_LKMM_HW"; PROPS=program_spec; GP="-DGP_AS_NOP";;
  power) CAT=$DAT3M_HOME/cat/power.cat;        TDEF="-DTARGET_LKMM_HW"; PROPS=program_spec; GP="-DGP_AS_NOP";;
  tso)   CAT=$DAT3M_HOME/cat/tso.cat;          TDEF="-DTARGET_C11";     PROPS=program_spec; GP="-DGP_AS_NOP";;
  power-c11) CAT=$DAT3M_HOME/cat/power.cat;    TDEF="-DTARGET_C11 -DC11_HW_FENCES"; PROPS=program_spec; GP="-DGP_AS_NOP";;
  arm8-c11)  CAT=$DAT3M_HOME/cat/aarch64.cat;  TDEF="-DTARGET_C11 -DC11_HW_FENCES"; PROPS=program_spec; GP="-DGP_AS_NOP";;
  *) echo "bad target"; exit 1;;
esac
# name|defines.  On hardware targets A2/C2 run with the grace period replaced
# by smp_mb() (exploratory; equals MUT_NOGP) because RCU is not expressible.
VARIANTS="
A0|-DSCEN_A0
A1|-DSCEN_A1
A1m-nowmb|-DSCEN_A1 -DMUT_NOWMB
A1m-nomb-in-sum|-DSCEN_A1 -DMUT_NOMB_IN_SUM
A1m-gets-first|-DSCEN_A1 -DMUT_GETS_FIRST
A1mig|-DSCEN_A1MIG -DNR_CPUS=3 -DHPUTCPU=2
A2|-DSCEN_A2 GPMB
A2m-nogp|-DSCEN_A2 -DMUT_NOGP
B1|-DSCEN_B1
B1m-walker-nomb|-DSCEN_B1 -DMUT_WALKER_NOMB
B1m-peek-no-outer-mb|-DSCEN_B1 -DMUT_PEEK_NO_OUTER_MB
B2|-DSCEN_B2
B2m-flags-unlocked|-DSCEN_B2 -DMUT_FLAGS_UNLOCKED
C1|-DSCEN_C1
C2|-DSCEN_C2 GPMB
D1|-DSCEN_D1
D1m-holder-wmb-only|-DSCEN_D1 -DMUT_DEKKER_WMB
"
echo "$VARIANTS" | grep -v '^$' | grep -E "$FILTER" | while IFS='|' read -r NAME DEFS; do
  EXTRA=""
  if [[ "$DEFS" == *GPMB* ]]; then
    DEFS=${DEFS/GPMB/}
    if [ "$T" != lkmm ]; then EXTRA="-DGP_AS_MB"; NAME="$NAME-gp-as-mb"; fi
  fi
  LL=$H/ll/$T-$NAME.ll; LOG=$D/logs/$T/$NAME.log
  if ! $CC -I $DAT3M_HOME/include -Xclang -disable-O0-optnone -S -emit-llvm -g -gcolumn-info \
        $TDEF $GP $EXTRA $DEFS $H/mnt_gp.c -o $LL 2> $LOG; then
    echo -e "$T\t$NAME\tCOMPILE-ERROR\t0\t$LOG" | tee -a $D/results.tsv; continue
  fi
  S=$(date +%s.%N)
  timeout 1800 taskset -c 256-511 java -Xmx24g -jar $JAR $CAT --target=${T%-c11} $LL --bound=$B --property=$PROPS ${DAT3M_OPTS:-} >> $LOG 2>&1
  RC=$?
  E=$(date +%s.%N)
  SECS=$(python3 -c "print(round($E-$S,1))")
  RES=$(grep -oE "\b(PASS|FAIL|UNKNOWN)\b" $LOG | tail -1)
  [ -z "$RES" ] && RES="ERROR(rc=$RC)"
  echo -e "$T\t$NAME\t$RES\t$SECS\t$LOG" | tee -a $D/results.tsv
done

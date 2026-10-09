LOCKDIR=/tmp/klitmus-locked
trap "rmdir $LOCKDIR 2>/dev/null; exit" INT TERM
if ! mkdir $LOCKDIR 2>/dev/null; then
  echo "Already running, locked by $LOCKDIR"
  exit 1
fi
OPT="$*"
date
echo Compilation command: "/home/brauner/.local/herdtools7/usr/bin/klitmus7 -set-libdir /home/brauner/.local/herdtools7/usr/share/herdtools7/litmus -o /home/brauner/tmp/klitmus/kmod/MNT-D1m-holder-wmb-only /home/brauner/tmp/lkmm/litmus/MNT-D1m-holder-wmb-only.litmus"
echo "OPT=$OPT"
echo "uname -r=$(uname -r)"
echo

zyva () {
  name=$1
  ko=$2
  if test -f  $ko
  then
    insmod $ko $OPT
    cat /proc/litmus
    rmmod $ko
  fi
}

zyva "MNT-D1m-holder-wmb-only" litmus000.ko
rmdir $LOCKDIR 2>/dev/null
date

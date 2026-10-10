#!/bin/bash
# Run the SuperDevTable configurations on a big machine, MAXJOBS at a time.
# ./run-parallel.sh [workers-per-run] [heap-per-run] [cfg-glob...]
# e.g. on jens: MAXJOBS=12 setsid nohup ./run-parallel.sh 24 24g > run.out 2>&1 &
cd "$(dirname "$0")"
w=${1:-16}; h=${2:-16g}; shift $(( $# < 2 ? $# : 2 ))
export TLA2TOOLS=${TLA2TOOLS:-$PWD/tla2tools.jar} TLC_HEAP=$h TLC_RECOVER=${TLC_RECOVER:-no}
export TLC_METADIR=${TLC_METADIR:-/tmp/$USER-tlc-super}
mkdir -p logs
if [ $# -gt 0 ]; then cfgs=("$@"); else cfgs=($(ls dt*.cfg | sed 's/\.cfg$//')); fi
max=${MAXJOBS:-${#cfgs[@]}}
for cfg in "${cfgs[@]}"; do
    cfg=${cfg%.cfg}
    while [ "$(jobs -rp | wc -l)" -ge "$max" ]; do wait -n; done
    rm -f "logs/$cfg.log"; rm -rf "$TLC_METADIR/$cfg"
    ./check.sh "$cfg" "$w" > /dev/null 2>&1 &
done
wait
./summarize.sh > /dev/null
echo ALL-DONE >> logs/summary.txt

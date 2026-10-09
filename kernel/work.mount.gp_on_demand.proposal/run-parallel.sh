#!/bin/bash
# Run every configuration on a big machine, MAXJOBS at a time.
# ./run-parallel.sh [workers-per-run] [heap-per-run]
# MAXJOBS (default: all at once) bounds the concurrent TLC instances; pin the
# whole thing with taskset if the machine is shared, the children inherit it:
#   MAXJOBS=16 taskset -c 256-511 ./run-parallel.sh 16 8g
cd "$(dirname "$0")"
w=${1:-16}; h=${2:-8g}
export TLA2TOOLS=${TLA2TOOLS:-$PWD/tla2tools.jar} TLC_HEAP=$h
export TLC_METADIR=${TLC_METADIR:-/tmp/$USER-tlc-gp-proposal}
mkdir -p logs
cfgs=($(ls *.cfg | sed 's/\.cfg$//'))
max=${MAXJOBS:-${#cfgs[@]}}
for cfg in "${cfgs[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$max" ]; do wait -n; done
    ./check.sh "$cfg" "$w" > /dev/null 2>&1 &
done
wait
./summarize.sh > /dev/null
echo ALL-DONE >> logs/summary.txt

#!/bin/bash
# Run every configuration (or the ones named) one after the other, then
# summarize logs/ into logs/summary.txt.  ./run-all.sh [workers] [cfg...]
cd "$(dirname "$0")"
w=${1:-4}; shift $(( $# > 0 ? 1 : 0 ))
export TLC_RECOVER=${TLC_RECOVER:-no}
if [ $# -gt 0 ]; then cfgs=("$@"); else cfgs=($(ls *.cfg | sed 's/\.cfg$//')); fi
mkdir -p logs
for cfg in "${cfgs[@]}"; do
    cfg=${cfg%.cfg}
    rm -f "logs/$cfg.log"; rm -rf "${TLC_METADIR:-/tmp/$USER-tlc-offset-readdir}/$cfg"
    ./check.sh "$cfg" "$w" > /dev/null 2>&1
done
./summarize.sh

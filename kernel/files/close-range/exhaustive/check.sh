#!/bin/bash
# Build and run the exhaustive check for the word sizes in the README.
# Extra gcc flags go into EXTRA, e.g. EXTRA=-DMUT_HOP_OFF_BY_ONE ./check.sh
set -e
cd "$(dirname "$0")"
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
for size in "2 3" "3 2" "4 2"; do
    set -- $size
    gcc -O2 -Wall -Wno-unused-function -DW=$1 -DNW=$2 ${EXTRA:-} -o "$bin/crcheck" crcheck.c
    "$bin/crcheck" | tail -1
done

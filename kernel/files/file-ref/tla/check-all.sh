#!/bin/bash
# Run every configuration (sequentially) and write logs/summary.txt
cd "$(dirname "$0")"
mkdir -p logs
{ printf '%-26s %-10s %-10s %-10s %-10s %s\n' config expected result states time check
  for cfg in $(ls *.cfg | sed 's/\.cfg$//'); do ./check.sh "$cfg" "$@"; done; } | tee logs/summary.txt

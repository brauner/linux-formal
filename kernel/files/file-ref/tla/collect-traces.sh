#!/bin/bash
# After check-all.sh: copy the summary to RESULTS.txt and the counterexample
# of every configuration that is expected to fail to traces/<cfg>.txt
cd "$(dirname "$0")"
mkdir -p traces
{ echo "# TLC 2.19, 6 workers, 4g heap, local (laptop, 16 cores), $(date +%Y-%m-%d)"
  cat logs/summary.txt; } > RESULTS.txt
for cfg in $(grep -l 'expected: violation' *.cfg | sed 's/\.cfg$//'); do
	[ -f "logs/$cfg.log" ] || continue
	./extract-trace.sh "logs/$cfg.log" > "traces/$cfg.txt"
done
ls traces | wc -l

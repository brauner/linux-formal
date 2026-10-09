#!/bin/bash
# re-convert the three gpbreak traces with the current trace2ndjson.py, then run the TLC batch over each
G=$HOME/tmp/gp-trace
cd $G || exit 1
for r in walk held expire; do
	rm -rf ndjson/$r
	python3 -I trace2ndjson.py traces/$r.txt ndjson/$r > convert-$r.out 2>&1
	echo "$(date +%T) reconvert $r: $(head -1 convert-$r.out)" | tee -a progress.log
done
cd tla && mkdir -p old4 && mv results-*.tsv old4/ 2>/dev/null; rm -rf logs; mkdir -p logs
bash ./tlc-batch.sh walk 600 100
bash ./tlc-batch.sh held 400 100
bash ./tlc-batch.sh expire 400 100

#!/bin/bash
# Validate one or more per-mount NDJSON traces against MntPutTrace.tla.
# usage: validate.sh [-m MODELDIR] [-j JAR] FILE.ndjson...   (results appended to results.tsv)
set -u
cd "$(dirname "$0")"
MODEL=${MODEL:-$HOME/src/git/linux-tla/kernel/work.mount.gp_on_demand.proposal}
TLA=${TLA2TOOLS:-$HOME/src/git/linux-tla/kernel/mount/tla2tools.jar}
CM=${COMMUNITY_MODULES:-$(dirname "$0")/CommunityModules-deps.jar}
while getopts "m:j:" o; do case $o in m) MODEL=$OPTARG;; j) CM=$OPTARG;; esac; done; shift $((OPTIND-1))
mkdir -p logs
for f in "$@"; do
	name=$(basename "$f" .ndjson)
	TRACE_PATH="$(realpath "$f")" timeout ${TLC_TIMEOUT:-600} java -XX:+UseParallelGC -Xmx${TLC_HEAP:-4g} -DTLA-Library="$MODEL" \
		-cp "$TLA:$CM" tlc2.TLC -workers 1 -deadlock -metadir "/tmp/tlc-trace-$$/$name" \
		-config MntPutTrace.cfg MntPutTrace.tla > "logs/$name.log" 2>&1
	rc=$?
	verdict=$(grep -o '"ACCEPTED"\|"REJECTED"' "logs/$name.log" | head -1 | tr -d '"')
	[ -z "$verdict" ] && verdict="ERROR(rc=$rc)"
	inv=$(grep -m1 -o 'Invariant [A-Za-z]* is violated' "logs/$name.log")
	states=$(grep -m1 -o '[0-9]* distinct states' "logs/$name.log")
	detail=$(grep -m1 -o '"consumed", [0-9]*, "of", [0-9]*' "logs/$name.log")
	printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$verdict" "${inv:-}" "${states:-}" "${detail:-}" | tee -a "${RESULTS:-results.tsv}"
done

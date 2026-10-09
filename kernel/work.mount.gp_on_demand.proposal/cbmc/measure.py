#!/usr/bin/env python3
"""Run a command, print wall time and peak RSS (ru_maxrss of the children) to stderr
as a single machine-readable line: MEASURE wall=<s> maxrss_kb=<kb> rc=<rc>."""
import os, resource, subprocess, sys, time
t0 = time.monotonic()
rc = subprocess.call(sys.argv[1:])
wall = time.monotonic() - t0
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
sys.stderr.write(f"MEASURE wall={wall:.1f} maxrss_kb={ru.ru_maxrss} rc={rc}\n")
sys.exit(rc)

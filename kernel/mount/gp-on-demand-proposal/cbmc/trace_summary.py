#!/usr/bin/env python3
"""Compact a CBMC --trace log: for the property whose description matches argv[2], print thread/function/line and
the assignments to the interesting variables in order."""
import re, sys
log = open(sys.argv[1], errors="replace").read()
want = sys.argv[2]
# traces are preceded by "Trace for <id>:" ; property table maps id -> desc
props = dict(re.findall(r"^\[([^\]]+)\] (.*): FAILURE\s*$", log, re.M))
ids = [i for i, d in props.items() if want in d]
if not ids:
    print("no failing property matching", want); sys.exit(1)
pid = ids[0]
m = re.search(r"^Trace for " + re.escape(pid) + r":\n(.*?)(?=^Trace for |\Z)", log, re.M | re.S)
tr = m.group(1)
interesting = re.compile(r"(ghost_|mnt_flags|mnt_ns|mnt_gets|mnt_puts|mnt_count|in_rcu|mount_lock|thread_done|task_work|tid|retval|count|seq|found|cpu|res)")
state_re = re.compile(r"^State \d+ file \S+ line (\d+) function (\S+) thread (\d+)\n-+\n\s*(.*?)\n", re.M)
last = None
out = []
for line, func, thread, assign in state_re.findall(tr):
    if not interesting.search(assign): continue
    if "__CPROVER" in assign or "#" in assign.split("=")[0]: continue
    key = (thread, func)
    prefix = f"T{thread} {func}:{line}"
    out.append(f"{prefix:45} {assign[:90]}")
print(f"property: {pid}: {props[pid]}")
print("\n".join(out[-70:]))

#!/usr/bin/env python3
"""Replace the RESULTS_TABLE marker in README.md with the summaries in logs/."""
import pathlib, re
here = pathlib.Path(__file__).resolve().parent
rows = []
for f in ["summary.txt", "summary-bugs.txt"]:
    p = here / "logs" / f
    if not p.exists():
        continue
    for line in p.read_text().splitlines()[1:]:
        parts = line.split()
        if len(parts) < 4 or parts[0] == "BUGS-DONE":
            continue
        rows.append(parts)
desc = {
 "signals_fixed": "as queued, all properties",
 "cdhole_fixed": "as queued, all properties",
 "plain_fixed": "as queued, all invariants (full budgets)",
 "plain_live": "as queued, all invariants and both liveness properties (no USR signal, no retry)",
 "sqpoll_fixed": "as queued, all properties",
 "signals_no_rcu": "FIX_RCU_RELEASE off: NoUseAfterFree",
 "signals_no_retarget": "FIX_RETARGET_GROUP_EXIT and FIX_SIGPENDING_DUMPCORE off: TruncationJustified",
 "signals_retarget_only": "only FIX_RETARGET_GROUP_EXIT off: TruncationJustified (nothing filters the retargeted signal anymore)",
 "signals_retarget_only_v3": "v3, FIX_RETARGET_GROUP_EXIT off: TruncationJustified (the signal_pending() filter of v3 covers the retarget)",
 "signals_sigpending_only": "only FIX_SIGPENDING_DUMPCORE off: TruncationJustified (nothing but the retarget sets TIF_SIGPENDING on the dumper)",
 "signals_no_freezer": "FIX_SIGPENDING_DUMPCORE off: FreezeAbortsDump (a cgroup v2 freeze lets a file dump complete)",
 "signals_no_freeze_check": "FIX_FREEZE_BEFORE_DUMP off: FreezeAbortsDump (zap_threads() clears the TIF_SIGPENDING of a freeze that came first)",
 "sqpoll_deadlock": "FIX_PTRACE_MASK off: DumpEnds (the io-wq worker of an SQPOLL ring dumps, the SQPOLL thread waits for it)",
 "sqpoll_nodump_only": "FIX_PTRACE_MASK off, FIX_WORKER_NODUMP on: DumpEnds (the dropped v3 patch was enough on its own)",
 "sqpoll_forced": "as queued, a coredump signal forced onto a user worker: DumpEnds",
 "sqpoll_forced_nodump": "the same with FIX_WORKER_NODUMP on: DumpEnds",
 "sqpoll_no_gate_signaled": "FIX_GATE_SIGNALED off: CountConsistent (the SQPOLL thread creates an uncounted worker from its cancel loop)",
 "plain_strict": "as queued: TruncationJustifiedStrict",
 "plain_strict_no_guard": "FIX_NO_NOTIFY_SIGNAL off: TruncationJustifiedStrict (TIF_NOTIFY_SIGNAL from a worker creation cuts the dump)",
 "plain_no_exec_cancel": "FIX_EXEC_CANCEL_FIRST off: SingleThreadedExec (a create_worker_cont() survives de_thread())",
 "cdhole_no_gate": "FIX_GATE_POSTCOREDUMP off: CountConsistent (the exit(2) thread creates an uncounted worker)",
}
def workers(cfg):
    log = here / "logs" / f"{cfg}.log"
    m = re.search(r"with (\d+) workers on", log.read_text()) if log.exists() else None
    return m.group(1) if m else ""
out = ["| Configuration | Checks | Expected | Result | Distinct states | TLC time | Workers |",
       "|---|---|---|---|---|---|---|"]
seen = set()
for parts in rows:
    cfg, expect, result = parts[0], parts[1], parts[2]
    if cfg not in desc or cfg in seen:
        continue
    states = parts[3] if len(parts) >= 6 else ""
    took = parts[4] if len(parts) >= 6 else ""
    seen.add(cfg)
    out.append(f"| `{cfg}` | {desc[cfg]} | {expect} | {result} | {states} | {took} | {workers(cfg)} |")
readme = here / "README.md"
s = readme.read_text()
s = s.replace("RESULTS_TABLE", "\n".join(out))
readme.write_text(s)
print("\n".join(out))

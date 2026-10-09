#!/usr/bin/env python3
"""Split an ftrace text dump of the events/mount/* tracepoints into one NDJSON
trace per mount for MntPutTrace.tla.

Line 1 of each file is the configuration (the tasks and the model constants
derived from the trace), the following lines are the events in file order.
Each event names the model task that performs it:

  U          the umounter: the pid of mnt_umount_tree; its protocol events
             (umount_tree, caller_drop, peek, gp, the slowpath that follows
             the grace period) and, once it finished the mount, cleanup
  W<pid>.<k> one __legitimize_mnt() episode of that pid: the mnt_legitimize
             event and, for result 0 or -1, the put that drops the reference
  H<pid>.<k> a holder of that pid: mntget()/mntput() pairs; its first get
             when it holds nothing is the holder's initial reference of the
             model's Init and is not emitted
  rcu        mnt_free (the RCU callback, any pid)

The acquisition of U's own reference (its last open legitimize or get before
umount_tree) is the model's Init and is not emitted either.  Episodes and
holders whose events all precede umount_tree and net to zero are pruned:
no locked sum can have observed them.  Locked events get `lk`, their rank in
mount_lock sequence order, which the spec enforces; lockless ones lk=0.
"""
import json, os, re, sys
from collections import defaultdict

LINE = re.compile(r"^\s*(?P<comm>.*?)-(?P<lpid>\d+)\s+\[(?P<lcpu>\d+)\]\s+\S+\s+(?P<ts>\d+)\.(?P<us>\d+):\s+(?P<ev>mnt_\w+):\s+(?P<kv>.*)$")

def parse(path):
    evs = []
    with open(path, "rb") as f:
        for n, raw in enumerate(f):
            line = raw.decode("utf-8", "replace").rstrip("\n")
            m = LINE.match(line)
            if not m:
                continue
            kv = {}
            for tok in m.group("kv").split():
                k, _, v = tok.partition("=")
                kv[k] = int(v)
            e = {"n": n, "ev": m.group("ev"), "ts": int(m.group("ts")) * 1000000 + int(m.group("us").ljust(6, "0")[:6]),
                 "comm": m.group("comm").strip()}
            e.update(kv)
            evs.append(e)
    return evs

def locked(e):
    ev = e["ev"]
    if ev in ("mnt_umount_tree", "mnt_caller_drop", "mnt_peek", "mnt_final", "mnt_slowpath"):
        return True
    if ev == "mnt_legitimize":
        return e["result"] != 0 and not e["early"]
    return False

def is_put(e):
    return e["ev"] in ("mnt_put_fast", "mnt_slowpath")

def convert(evs, notes):
    """evs: the events of one mount in file order. Returns (cfg, out_events) or None."""
    ut = [e for e in evs if e["ev"] == "mnt_umount_tree"]
    if len(ut) != 1:
        notes.append(f"skipped: {len(ut)} umount_tree events")
        return None
    ut = ut[0]
    upid = ut["pid"]
    shape = "umount" if any(e["ev"] == "mnt_caller_drop" for e in evs) else "nsdeath"
    # mount_lock sequence order of the locked events; it must agree with file order
    lk_events = [e for e in evs if locked(e)]
    for a, b in zip(lk_events, lk_events[1:]):
        if b["seq"] < a["seq"]:
            notes.append(f"locked events out of seq order at line {b['n']}: {a['seq']} then {b['seq']}")
    for i, e in enumerate(lk_events, 1):
        e["lk"] = i
    for e in evs:
        e.setdefault("lk", 0)
        e["task"] = None

    # ---- U's protocol events
    gp_end_seen = False
    ns_put_done = False
    doomer = None
    for e in evs:
        ev = e["ev"]
        if ev in ("mnt_umount_tree", "mnt_caller_drop", "mnt_peek", "mnt_gp", "mnt_final"):
            e["task"] = "U"
            if ev == "mnt_gp" and e["end"]:
                gp_end_seen = True
            if ev == "mnt_peek" and e["unheld"]:
                doomer = "U"
        elif ev == "mnt_slowpath" and e["pid"] == upid and gp_end_seen and not ns_put_done:
            e["task"] = "U"; e["role"] = "nsput"; ns_put_done = True
            if e["count"] == 0 and not e["doomed"]:
                doomer = "U"
        elif ev == "mnt_free":
            e["task"] = "rcu"
    # ---- the ledger of everybody else, per pid in program order
    rest = [e for e in evs if e["task"] is None and e["ev"] not in ("mnt_cleanup",)]
    bypid = defaultdict(list)
    for e in rest:
        bypid[e["pid"]].append(e)
    tasks = {}          # name -> {"role":..., "pid":..., "events":[...], "gets":n}
    inits = []          # events consumed as Init
    for pid, pes in bypid.items():
        wk = hk = 0
        open_walkers = []   # names of walker episodes holding a reference
        holder = None       # (name, refs)
        own_done = pid != upid
        def take_own_ref():
            # U's own reference: its last open acquisition when umount_tree runs
            nonlocal holder, own_done
            own_done = True
            if open_walkers:
                w = open_walkers.pop()
                e0 = tasks[w]["events"][0]
                e0["task"] = "U"; e0["role"] = "init"; inits.append(e0)
                del tasks[w]
            elif holder and holder[1] > 0 and tasks[holder[0]].get("init_event") is not None \
                    and not tasks[holder[0]]["events"]:
                # a bare mntget() before umount_tree with nothing else: the caller's reference
                h = tasks.pop(holder[0]); h["init_event"]["role"] = "init"; h["init_event"]["task"] = "U"
                inits.append(h["init_event"]); holder = None
            else:
                notes.append("U's own reference acquisition not in the trace (implicit)")
        for e in pes:
            ev = e["ev"]
            if not own_done and e["n"] > ut["n"]:
                take_own_ref()
            if ev == "mnt_legitimize":
                wk += 1
                name = f"W{pid}.{wk}"
                tasks[name] = {"role": "walker", "pid": pid, "events": [e], "gets": 0}
                e["task"] = name
                if e["result"] in (0, -1):
                    open_walkers.append(name)
            elif ev == "mnt_get":
                if holder is None or holder[1] == 0:
                    hk += 1
                    holder = [f"H{pid}.{hk}", 1]
                    tasks[holder[0]] = {"role": "holder", "pid": pid, "events": [], "gets": 0, "init_event": e}
                    e["task"] = holder[0]; e["role"] = "init"
                    inits.append(e)
                else:
                    holder[1] += 1
                    tasks[holder[0]]["events"].append(e); tasks[holder[0]]["gets"] += 1
                    e["task"] = holder[0]
            elif is_put(e):
                if open_walkers:
                    name = open_walkers.pop(0)
                    tasks[name]["events"].append(e); e["task"] = name
                else:
                    if holder is None or holder[1] == 0:
                        # a reference that predates the trace: a holder with the Init reference
                        hk += 1
                        holder = [f"H{pid}.{hk}", 1]
                        tasks[holder[0]] = {"role": "holder", "pid": pid, "events": [], "gets": 0, "preexisting": True}
                    holder[1] -= 1
                    tasks[holder[0]]["events"].append(e); e["task"] = holder[0]
                    if e["ev"] == "mnt_slowpath" and e["count"] == 0 and not e["doomed"]:
                        doomer = holder[0]
            else:
                notes.append(f"unhandled event {ev} at line {e['n']}")
        if not own_done:
            take_own_ref()
        # walkers that did a slowpath put to zero finish the mount
        for name, t in tasks.items():
            if t["pid"] != pid:
                continue
            for e in t["events"]:
                if e["ev"] == "mnt_slowpath" and e["count"] == 0 and not e["doomed"]:
                    doomer = name
    # cleanup belongs to the doomer
    for e in evs:
        if e["ev"] == "mnt_cleanup":
            e["task"] = doomer or "U"
            if doomer is None:
                notes.append("cleanup without an observed doom")
    # ---- prune what no locked sum could have seen
    pruned = []
    for name in list(tasks):
        t = tasks[name]
        es = t["events"]
        if not es or es[-1]["n"] >= ut["n"]:
            continue
        if any(e["ev"] == "mnt_umount_tree" for e in es):
            continue
        if t["role"] == "walker":
            net = sum(1 for e in es if e["ev"] == "mnt_legitimize" and e["result"] in (0, -1)) - sum(1 for e in es if is_put(e))
        else:
            net = 1 + sum(1 for e in es if e["ev"] == "mnt_get") - sum(1 for e in es if is_put(e))
        if net == 0:
            pruned.append(name)
            for e in es:
                e["task"] = None
            del tasks[name]
    walkers = sorted(n for n, t in tasks.items() if t["role"] == "walker")
    holders = sorted(n for n, t in tasks.items() if t["role"] == "holder")
    getbudget = max([t["gets"] for t in tasks.values() if t["role"] == "holder"] + [1])
    out = [e for e in evs if e["task"] is not None and e.get("role") != "init"]
    # the locked ranks over the emitted events only: a pruned or Init-mapped
    # locked event (U's own reference taken under mount_lock) must leave no gap
    lk_events = [e for e in out if locked(e)]
    for i, e in enumerate(lk_events, 1):
        e["lk"] = i
    cpus = sorted({e["cpu"] for e in evs})
    cfg = {"id": evs[0]["id"], "shape": shape, "sync": bool(ut["sync"]), "count_at_utree": ut["count"],
           "upid": upid, "tasklist": ["U"] + walkers + holders, "walkers": walkers, "holders": holders,
           "getbudget": getbudget, "ncpu": 2, "cpus_seen": cpus, "nevents": len(out),
           "nlocked": len(lk_events), "pruned": pruned, "inits": [f"{e['task']}:{e['ev']}@{e['n']}" for e in inits],
           "preexisting": [n for n, t in tasks.items() if t.get("preexisting")],
           "has_free": any(e["ev"] == "mnt_free" for e in evs), "notes": notes}
    return cfg, out

def main():
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    evs = parse(src)
    byid = defaultdict(list)
    for e in evs:
        byid[e["id"]].append(e)
    summary = []
    for mid, mevs in sorted(byid.items()):
        notes = []
        r = convert(mevs, notes)
        if r is None:
            summary.append({"id": mid, "skipped": notes, "n": len(mevs)})
            continue
        cfg, out = r
        path = os.path.join(outdir, f"mnt-{mid}.ndjson")
        with open(path, "w") as f:
            f.write(json.dumps(cfg) + "\n")
            for i, e in enumerate(out, 1):
                rec = {"i": i, "task": e["task"], "ev": e["ev"], "lk": e["lk"], "ts": e["ts"], "cpu": e["cpu"],
                       "pid": e["pid"], "seq": e["seq"]}
                for k in ("count", "unheld", "doomed", "result", "early", "sync", "batch", "end", "sample"):
                    if k in e:
                        rec[k] = bool(e[k]) if k in ("unheld", "doomed", "early", "sync", "end") else e[k]
                if "role" in e:
                    rec["role"] = e["role"]
                f.write(json.dumps(rec) + "\n")
        summary.append({"id": mid, "file": os.path.basename(path), **{k: cfg[k] for k in ("shape", "sync", "count_at_utree", "nevents", "nlocked", "walkers", "holders", "pruned", "has_free", "notes")}})
    with open(os.path.join(outdir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    conv = [s for s in summary if "file" in s]
    print(f"{len(evs)} events, {len(byid)} mounts, {len(conv)} converted, {len(summary)-len(conv)} skipped -> {outdir}")
    for s in conv:
        print(f"  {s['file']}: shape={s['shape']} sync={s['sync']} count@utree={s['count_at_utree']} events={s['nevents']} "
              f"walkers={len(s['walkers'])} holders={len(s['holders'])} pruned={len(s['pruned'])} free={s['has_free']}"
              + (f" NOTES={s['notes']}" if s['notes'] else ""))

if __name__ == "__main__":
    main()

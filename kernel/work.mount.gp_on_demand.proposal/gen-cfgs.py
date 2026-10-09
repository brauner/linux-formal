#!/usr/bin/env python3
"""Generate the TLC configurations and the MC_* layout modules of the MntPut
model of work.mount.gp_on_demand.proposal (4379d47fd314): two mounts unmounted
in one batch, mntput_unmounted() finishing the unheld ones under one
mount_lock hold and waiting one grace period for the held ones.

A configuration is named <layout>_<what>; check.sh picks MC_<layout>.tla.
"""
import pathlib

# layout: (holders, walkers); task names end in the mount they hold or walk
LAYOUTS = {
    "hw":   (["HA"], ["WB"]),            # A held, B walked
    "wh":   (["HB"], ["WA"]),            # A walked, B held
    "hh":   (["HA", "HB"], []),          # both held
    "ww":   ([], ["WA", "WB"]),          # both walked
    "h":    (["HA"], []),                # A held, nothing else touches B
    "w":    ([], ["WA"]),                # A walked, nothing else touches B
    "hwa":  (["HA"], ["WA"]),            # A held AND walked (the walker can find A as the holder's pwd), nothing on B
    "full": (["HA", "HB"], ["WA", "WB"]),  # everything at once
}
LAYOUT_DESC = {
    "hw": "the umounter, a holder of A, a walker of B",
    "wh": "the umounter, a walker of A, a holder of B",
    "hh": "the umounter, a holder of A and a holder of B",
    "ww": "the umounter, a walker of A and a walker of B",
    "h":  "the umounter and a holder of A; nothing else touches B",
    "w":  "the umounter and a walker of A; nothing else touches B",
    "hwa": "the umounter, a holder of A and a walker of A, which can reach A as the holder's fs->pwd (ViaPwd); nothing else touches B",
    "full": "the umounter, a walker and a holder of each mount",
}

FIXES = ["FIX_MB_LEGIT", "FIX_MB_UMOUNT", "FIX_MB_PUT", "FIX_MB_PEEK", "FIX_RCU_DELAY",
         "FIX_PUT_RCU", "FIX_SYNC_FLAG", "FIX_DOOMED_FLAG"]
MUTS = ["PEEK_LOOSE", "PREV_SHAPE", "QUEUE_LATE", "FIX_PUT_RECHECK"]
SAFETY = ["TypeOK", "Ledger", "NoUAF", "DoomedIsLast", "NoNegative", "SyncClean"]
LIVE = ["Freed", "AllDone"]

CONFIGS = {}


def add(name, layout, mode="umount", lazy=True, order="AB", migrate=False, weak=False,
        split=True, off=(), muts=(), invs=SAFETY, props=LIVE, expect="pass", getbudget=1):
    assert name.startswith(layout + "_"), name
    assert mode != "kern" or not LAYOUTS[layout][1], name  # a kern_mount() has no walkers
    CONFIGS[name] = dict(layout=layout, mode=mode, lazy=lazy, order=order, migrate=migrate,
                         weak=weak, split=split, off=list(off), muts=list(muts),
                         invs=list(invs), props=list(props), expect=expect, getbudget=getbudget)


# ---- the series: umount(2) of A taking B along, lazy and synchronous -------
add("hw_lazy", "hw")
add("hw_lazy_ba", "hw", order="BA")
add("wh_lazy", "wh")
add("wh_lazy_ba", "wh", order="BA")
add("hh_lazy", "hh")
add("ww_lazy", "ww")
add("h_lazy", "h")
add("h_lazy_ba", "h", order="BA")
add("w_lazy", "w")
add("hwa_lazy", "hwa")
add("hwa_lazy_ba", "hwa", order="BA")
add("full_lazy", "full", expect="pass: the five-task layout; the biggest run")
add("full_lazy_g0", "full", getbudget=0, expect="pass: the five-task layout without the holders' extra mntget()/mntput() pairs")
add("hw_sync", "hw", lazy=False)
add("wh_sync", "wh", lazy=False)
add("wh_sync_ba", "wh", lazy=False, order="BA")
add("ww_sync", "ww", lazy=False)
add("h_sync", "h", lazy=False)
add("hwa_sync", "hwa", lazy=False)
add("hh_lazy_migrate", "hh", migrate=True)
add("hw_lazy_weak", "hw", migrate=True, weak=True)
add("wh_sync_weak", "wh", lazy=False, migrate=True, weak=True)
add("hh_lazy_weak", "hh", migrate=True, weak=True)

# ---- the witnesses ---------------------------------------------------------
add("h_witness_fast", "h", invs=[], props=["NoFastFinal"],
    expect="violation: NoFastFinal, the witness: a mount is finished off without any grace period")
add("h_witness_after_held", "h", invs=[], props=["NoFinishAfterHeld"],
    expect="violation: NoFinishAfterHeld, the witness: B (count one) is finished right after A went on the held list, no grace period before it")
add("wh_witness_after_held_ba", "wh", order="BA", invs=[], props=["NoFinishAfterHeld"],
    expect="violation: NoFinishAfterHeld, the witness with the other order: A (the root, count one) finished after B went on the held list")
add("h_prev_witness_after_held", "h", muts=["PREV_SHAPE"], invs=[], props=["NoFinishAfterHeld"],
    expect="pass: the previous shape put every mount behind the first held one the plain way, after the grace period")

# ---- the mutations ---------------------------------------------------------
add("hh_no_rcu_delay", "hh", off=["FIX_RCU_DELAY"],
    expect="violation: Freed, a held mount must still wait: the holder's fast-path put lands after the plain put found the count non-zero")
add("ww_sync_no_rcu_delay", "ww", lazy=False, off=["FIX_RCU_DELAY"],
    expect="violation: Freed, the walker's transient increment counted, its decrement under mount_lock after the plain put")
add("hw_prev", "hw", muts=["PREV_SHAPE"], expect="pass: the previous shape, one lock hold per mount, for comparison")
add("hw_prev_ba", "hw", order="BA", muts=["PREV_SHAPE"], expect="pass: the previous shape, the held mount first")
add("wh_sync_prev", "wh", lazy=False, muts=["PREV_SHAPE"], expect="pass: the previous shape, synchronous")
add("hw_queue_late", "hw", muts=["QUEUE_LATE"],
    expect="pass: the cleanups queued after the grace period and the held puts, the order is immaterial for safety")
add("h_queue_late", "h", muts=["QUEUE_LATE"], expect="pass: the same with B unheld")
add("hh_loose", "hh", muts=["PEEK_LOOSE"], props=[],
    expect="violation: DoomedIsLast, finishing a mount off at a count of two dooms it under its holder")
add("ww_sync_loose", "ww", lazy=False, muts=["PEEK_LOOSE"],
    expect="pass: for a synchronous umount a count of two at the peek can only be a walker's transient increment, and that walker finds MNT_DOOMED under mount_lock")
add("hwa_lazy_no_mb_peek", "hwa", off=["FIX_MB_PEEK"], props=[],
    expect="pass: the smp_mb() of mntput_unmounted() has no partner in this abstraction: a mount at count one has no holder through whose fs->pwd a walker could still find it, and a holder dropping its reference after the write section sees mnt_ns NULL and takes the slow path, whose lock_mount_hash() bumps the seqcount; a stale mnt_ns read on weakly ordered hardware is outside the abstraction")
add("ww_sync_no_mb_peek", "ww", lazy=False, off=["FIX_MB_PEEK"], props=[],
    expect="pass: without a holder of the same mount no walker finds an unmounted mount anymore (the hash is gone, the pwd path needs a holder), so the peek's barrier has no partner here either")
add("hwa_lazy_no_mb_put", "hwa", off=["FIX_MB_PUT"], props=[],
    expect="violation: DoomedIsLast or NoUAF, the contrast: the smp_mb() of mntput_no_expire_slowpath() is load-bearing, the holder's final put of a lazily unmounted mount races a walker that found it as the holder's pwd, and without the barrier the sum misses the walker's increment while the walker reads the old seqcount")
add("hwa_lazy_no_mb_legit", "hwa", off=["FIX_MB_LEGIT"], props=[],
    expect="violation: DoomedIsLast or NoUAF, the walker's side of the same Dekker pairing: its increment stays buffered while the holder's final put sums")
add("w_lazy_no_doomed_flag", "w", off=["FIX_DOOMED_FLAG"], props=[],
    expect="violation: NoUAF, the walker whose increment the sum missed must see MNT_DOOMED under mount_lock (250cf3693060)")
add("w_sync_no_mb_legit", "w", lazy=False, off=["FIX_MB_LEGIT"], props=[],
    expect="violation: SyncClean or DoomedIsLast, the walker's increment stays in its store buffer while the count reads one")
add("h_sync_torn_sum", "h", lazy=False, migrate=True, split=False, props=[],
    expect="violation: SyncClean or DoomedIsLast, with the single counter of before 7eb84d54fac5 the sum of a migrating holder can read one with the reference held")

# ---- a namespace dying: put_mnt_ns() -> umount_tree(ns->root, 0) -----------
add("hw_nsdeath", "hw", mode="nsdeath")
add("hw_nsdeath_ba", "hw", mode="nsdeath", order="BA")
add("hh_nsdeath", "hh", mode="nsdeath")
add("h_nsdeath_witness_after_held", "h", mode="nsdeath", invs=[], props=["NoFinishAfterHeld"],
    expect="violation: NoFinishAfterHeld, the witness for a dying namespace")

# ---- kern_unmount_array(): mnt_make_shortterm() without lock or seqcount ---
add("hh_kern", "hh", mode="kern")
add("hh_kern_ba", "hh", mode="kern", order="BA")
add("h_kern", "h", mode="kern")
add("hh_kern_weak", "hh", mode="kern", migrate=True, weak=True)
add("hh_kern_no_mb_peek", "hh", mode="kern", off=["FIX_MB_PEEK"],
    expect="pass: no walker can find a kern_mount(), and the RMW of lock_mount_hash() already drains the umounter's buffer in this abstraction, so the model cannot show the barrier mattering here")
add("hh_kern_no_rcu_delay", "hh", mode="kern", off=["FIX_RCU_DELAY"],
    expect="violation: Freed, a held kern_mount() still needs the grace period")
add("h_kern_witness_fast", "h", mode="kern", invs=[], props=["NoFastFinal"],
    expect="violation: NoFastFinal, the witness: the unheld kern_mount() goes without a grace period")
add("hh_kern_prev", "hh", mode="kern", muts=["PREV_SHAPE"], expect="pass: the previous shape for kern_unmount_array()")

# ---- EXPLORATORY: the fast path re-reads mnt_ns, no grace period at all ----
EXPL = "exploratory, not in the series: "
add("hh_recheck", "hh", off=["FIX_RCU_DELAY"], muts=["FIX_PUT_RECHECK"],
    expect="pass: " + EXPL + "holders only: the recheck catches every put that raced the peek")
add("hw_recheck", "hw", off=["FIX_RCU_DELAY"], muts=["FIX_PUT_RECHECK"],
    expect="pass: " + EXPL + "a lazy walker that got -1 finishes the mount itself")
add("hwa_recheck", "hwa", off=["FIX_RCU_DELAY"], muts=["FIX_PUT_RECHECK"],
    expect="pass: " + EXPL + "a walker reaching the unmounted mount as the holder's pwd, lazy")
add("ww_sync_recheck", "ww", lazy=False, off=["FIX_RCU_DELAY"], muts=["FIX_PUT_RECHECK"],
    expect="violation: Freed, " + EXPL + "the synchronous walker only drops its transient count under mount_lock (48a066e72d97) and never finishes a mount; without the grace period that drop can land after the plain put")
add("hh_recheck_weak", "hh", migrate=True, weak=True, off=["FIX_RCU_DELAY"], muts=["FIX_PUT_RECHECK"],
    expect="pass: " + EXPL + "weakly ordered stores")
add("hh_kern_recheck", "hh", mode="kern", off=["FIX_RCU_DELAY"], muts=["FIX_PUT_RECHECK"],
    expect="pass: " + EXPL + "kern_unmount_array()")
add("hh_kern_recheck_weak", "hh", mode="kern", migrate=True, weak=True, off=["FIX_RCU_DELAY"], muts=["FIX_PUT_RECHECK"],
    expect="pass: " + EXPL + "kern_unmount_array(), weakly ordered stores")

here = pathlib.Path(__file__).resolve().parent
tf = lambda b: "TRUE" if b else "FALSE"
tla_set = lambda xs: "{" + ", ".join(f'"{x}"' for x in xs) + "}"

for layout, (holders, walkers) in LAYOUTS.items():
    tasks = ["U"] + sorted(holders + walkers, key=lambda t: (t[1], t[0]))
    tmount = " @@ ".join(f'("{t}" :> "{t[1]}")' for t in tasks[1:])
    (here / f"MC_{layout}.tla").write_text(f"""{'-' * 29} MODULE MC_{layout} {'-' * 29}
(* The layout for MntPut: {LAYOUT_DESC[layout]}; two CPUs. *)
(* Generated by gen-cfgs.py. *)
EXTENDS MntPut, TLC

TaskListDef == <<{', '.join(f'"{t}"' for t in tasks)}>>
TaskMountDef == {tmount}
OrderAB == <<"A", "B">>
OrderBA == <<"B", "A">>
{'=' * 77}
""")

for name, c in CONFIGS.items():
    holders, walkers = LAYOUTS[c["layout"]]
    lines = [f"\\* generated by gen-cfgs.py: MntPut (work.mount.gp_on_demand.proposal), expected: {c['expect']}",
             "SPECIFICATION Spec", "CONSTANTS",
             "  TaskList <- TaskListDef", "  TaskMount <- TaskMountDef",
             f"  BatchOrder <- Order{c['order']}",
             f"  Walkers = {tla_set(walkers)}", f"  Holders = {tla_set(holders)}",
             "  NCPU = 2", f"  GetBudget = {c['getbudget']}",
             f"  MIGRATE = {tf(c['migrate'])}", f"  MigBudget = {2 if c['migrate'] else 1}",
             f"  MODE = \"{c['mode']}\"", f"  LAZY = {tf(c['lazy'])}"]
    for f in FIXES:
        lines.append(f"  {f} = {tf(f not in c['off'])}")
    lines += [f"  FIX_SPLIT_COUNT = {tf(c['split'])}", "  SPLIT_GETS_FIRST = FALSE",
              f"  WEAK_STORES = {tf(c['weak'])}", f"  FIX_PUT_WMB = {tf(c['split'])}"]
    for mu in MUTS:
        lines.append(f"  {mu} = {tf(mu in c['muts'])}")
    if c["invs"]:
        lines.append("INVARIANTS")
        lines += [f"  {i}" for i in c["invs"]]
    if c["props"]:
        lines.append("PROPERTIES")
        lines += [f"  {p}" for p in c["props"]]
    (here / f"{name}.cfg").write_text("\n".join(lines) + "\n")
print(f"{len(CONFIGS)} configurations, {len(LAYOUTS)} layouts")

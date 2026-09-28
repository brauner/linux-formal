#!/usr/bin/env python3
"""Generate the TLC configurations of the MntPut model of work.mount.gp_on_demand:
the reference count of one mount under __legitimize_mnt(), the final mntput()
and namespace_unlock() dropping the mount's own reference without a grace
period when the count under mount_lock is one (mntput_unheld())."""
import pathlib

FIXES = ["FIX_MB_LEGIT", "FIX_MB_UMOUNT", "FIX_MB_PUT", "FIX_RCU_DELAY",
         "FIX_PUT_RCU", "FIX_SYNC_FLAG", "FIX_DOOMED_FLAG"]
SAFETY = ["TypeOK", "Ledger", "NoUAF", "DoomedIsLast", "NoNegative", "SyncClean"]
LIVE = ["Freed", "AllDone"]
# the tree the series sits on has the split counters and the smp_wmb() of
# 7eb84d54fac5 (F2), so every configuration runs with them unless it says so
# name: (lazy, migrate, split, weak stores, fixes off, on demand, loose, invariants, properties, expectation)
CONFIGS = {
    "mntput_ondemand":              (False, False, True, False, [], True, False, SAFETY, LIVE, "pass"),
    "mntput_ondemand_lazy":         (True,  False, True, False, [], True, False, SAFETY, LIVE, "pass"),
    "mntput_ondemand_migrate":      (False, True,  True, False, [], True, False, SAFETY, LIVE, "pass"),
    "mntput_ondemand_migrate_lazy": (True,  True,  True, False, [], True, False, SAFETY, LIVE, "pass"),
    "mntput_ondemand_weak":         (False, True,  True, True,  [], True, False, SAFETY, LIVE, "pass"),
    "mntput_ondemand_weak_lazy":    (True,  True,  True, True,  [], True, False, SAFETY, LIVE, "pass"),
    "mntput_ondemand_witness_fast": (False, False, True, False, [], True, False, [], ["NoFastFinal"], "violation: NoFastFinal, the witness: the mount is finished off without the grace period"),
    "mntput_ondemand_witness_fast_lazy": (True, False, True, False, [], True, False, [], ["NoFastFinal"], "violation: NoFastFinal, the witness: the holder closed its file before the put, no grace period"),
    "mntput_ondemand_no_rcu_delay": (True,  False, True, False, ["FIX_RCU_DELAY"], True, False, SAFETY, LIVE, "violation: Freed, a count of two must still wait: the holder's fast-path put lands after the plain put found the count non-zero"),
    "mntput_ondemand_no_rcu_delay_sync": (False, False, True, False, ["FIX_RCU_DELAY"], True, False, SAFETY, LIVE, "violation: Freed, the walker's transient increment counted, its decrement under mount_lock after the put"),
    "mntput_ondemand_loose":        (False, False, True, False, [], True, True,  SAFETY, LIVE, "pass: for a synchronous umount a count of two at the peek can only be the walker's transient increment (a legitimized walker would have made do_umount() refuse), and that walker finds MNT_DOOMED under mount_lock"),
    "mntput_ondemand_loose_lazy":   (True,  False, True, False, [], True, True,  SAFETY, [], "violation: DoomedIsLast, finishing the mount off at two dooms it under the holder"),
    "mntput_ondemand_no_mb_legit":  (False, False, True, False, ["FIX_MB_LEGIT"], True, False, SAFETY, [], "violation: SyncClean or DoomedIsLast, the walker's increment stays in its store buffer while the count reads one"),
    "mntput_ondemand_no_doomed_flag": (True, False, True, False, ["FIX_DOOMED_FLAG"], True, False, SAFETY, [], "violation: NoUAF, the walker whose increment the sum missed must see MNT_DOOMED under mount_lock"),
    "mntput_ondemand_torn_sum":     (False, True,  False, False, [], True, False, SAFETY, [], "violation: SyncClean or DoomedIsLast, with the single counter the sum of a migrating holder can read one with the reference held (F2)"),
    "mntput_caller74":              (False, False, True, False, [], False, False, SAFETY, LIVE, "pass", "caller"),
    "mntput_caller74_lazy":         (True,  False, True, False, [], False, False, SAFETY, LIVE, "pass", "caller"),
    "mntput_caller74_migrate":      (False, True,  True, False, [], False, False, SAFETY, LIVE, "pass", "caller"),
    "mntput_caller74_migrate_lazy": (True,  True,  True, False, [], False, False, SAFETY, LIVE, "pass", "caller"),
    "mntput_caller74_weak_lazy":    (True,  True,  True, True,  [], False, False, SAFETY, LIVE, "pass", "caller"),
    "mntput_caller74_witness_fast": (False, False, True, False, [], False, False, [], ["NoFastFinal"], "violation: NoFastFinal, the witness: the root goes without the grace period", "caller"),
    "mntput_caller74_no_rcu_delay": (True,  False, True, False, ["FIX_RCU_DELAY"], False, False, SAFETY, LIVE, "violation: Freed, a root somebody else holds still waits for the grace period", "caller"),
    "mntput_caller74_torn_sum":     (False, True,  False, False, [], False, False, SAFETY, [], "violation: SyncClean or DoomedIsLast, the single counter of before 7eb84d54fac5", "caller"),
    "mntput_owndrop74":             (False, False, True, False, [], False, False, SAFETY, LIVE, "violation: Freed, the rejected shape: the own reference goes at two and the caller's final put counts a walker's transient increment; the walker never finishes a mount off", "own"),
    "mntput_owndrop74_lazy":        (True,  False, True, False, [], False, False, SAFETY, LIVE, "violation: Freed, the rejected shape", "own"),
    "mntput_upstream":              (False, False, True, False, [], False, False, SAFETY, LIVE, "pass: the tree without the series"),
    "mntput_upstream_lazy":         (True,  False, True, False, [], False, False, SAFETY, LIVE, "pass: the tree without the series"),
}

here = pathlib.Path(__file__).resolve().parent
tf = lambda b: "TRUE" if b else "FALSE"
for name, cfg in CONFIGS.items():
    lazy, migrate, split, weak, off, ondemand, loose, invs, props, expect = cfg[:10]
    shape = cfg[10] if len(cfg) > 10 else ""
    lines = [f"\\* generated by gen-cfgs.py: MntPut (work.mount.gp_on_demand), expected: {expect}",
             "SPECIFICATION Spec", "CONSTANTS",
             "  TaskList <- TaskListDef", '  Walkers = {"W1"}', '  Holders = {"H1"}',
             "  NCPU = 2", "  GetBudget = 1",
             f"  MIGRATE = {tf(migrate)}", "  MigBudget = 2", f"  LAZY = {tf(lazy)}"]
    for f in FIXES:
        lines.append(f"  {f} = {tf(f not in off)}")
    lines += [f"  FIX_SPLIT_COUNT = {tf(split)}", "  SPLIT_GETS_FIRST = FALSE",
              f"  WEAK_STORES = {tf(weak)}", f"  FIX_PUT_WMB = {tf(split)}",
              f"  GP_ON_DEMAND = {tf(ondemand)}", f"  PEEK_LOOSE = {tf(loose)}",
              f"  CALLER_DROP = {tf(shape == 'caller')}", f"  OWN_DROP = {tf(shape == 'own')}"]
    if invs:
        lines.append("INVARIANTS")
        lines += [f"  {i}" for i in invs]
    if props:
        lines.append("PROPERTIES")
        lines += [f"  {p}" for p in props]
    (here / f"{name}.cfg").write_text("\n".join(lines) + "\n")
print(f"{len(CONFIGS)} configurations")

# TLA+ model of the grace period on demand (work.mount.gp_on_demand)

Tree: work.mount.gp_on_demand at e9d8e1e39df1 "fs: unmount without a
grace period when nothing else holds the mount", on work.mount.knullfs.4
at ba922416101e (the vacant-mount series on vfs-7.4.mount, which has the
split per-CPU counters and the smp_wmb() of 7eb84d54fac5).  The series
is not in mainline; the mainline models are in `kernel/mount/`, whose
conventions this directory follows.

`MntPut.tla` here is `kernel/mount/MntPut.tla` plus the series: with
`GP_ON_DEMAND` namespace_unlock() does not wait for a grace period.  The
puts of the unmounted list run from task work after path_umount() has
dropped the caller's own reference, and mntput_unheld() sums the count
under mount_lock first.  Exactly one (the mount's own reference) means
that no holder can be on the fast path of mntput_no_expire() with a
reference and no walker holds one, so the reference is dropped and the
mount finished off right there.  Anything else means
synchronize_rcu_expedited(), then the plain put.  `PEEK_LOOSE` is the
mutation that also finishes the mount off at a count of two.  Diff the
two files to see the delta.

## Files

| File | What it is |
|------|------------|
| `MntPut.tla`, `MC_mntput.tla` | the reference count of one mount under __legitimize_mnt(), mntput_no_expire() with its slow path, cleanup_mnt(), do_umount() (sync and MNT_DETACH), namespace_unlock() with or without the grace period, path_umount()'s own put, mntput_unheld()'s sum under mount_lock, mntget()/mntput() pairs of a holder, migration; per-CPU counters, split into gets and puts, TSO or weakly ordered store buffers; RCU grace periods |
| `*.cfg` | TLC configurations from `gen-cfgs.py`; the header says what to expect |
| `check.sh`, `run-parallel.sh`, `summarize.sh`, `show-put-trace.py` | run one, all at once, summarize, print a counterexample compactly |

## Switches

The mainline switches are documented in `kernel/mount/README.md`.  Every
configuration here runs with `FIX_SPLIT_COUNT` and `FIX_PUT_WMB` on
unless it says so, that is the tree the series sits on.

| Constant | Meaning |
|----------|---------|
| `GP_ON_DEMAND` | on: the series; off: the tree without it |
| `PEEK_LOOSE` | on: mntput_unheld() finishes the mount off at a count of two as well (mutation) |

`NoFastFinal` is a witness: mntput_unheld() never finishes the mount off
without the grace period; its violation shows the fast path being taken.

## Results (jens and local runs, 2026-09-27)

| Configuration | Result | What it shows |
|---------------|--------|---------------|
| `mntput_ondemand`, `mntput_ondemand_lazy`, `mntput_ondemand_migrate`, `mntput_ondemand_migrate_lazy`, `mntput_ondemand_weak`, `mntput_ondemand_weak_lazy` | pass | with the series nothing is freed early, doomed early or leaked, the mount is freed, and a synchronous umount that returns 0 leaves no reference behind and shuts the filesystem down from the caller; with a migrating holder (F2) and with weakly ordered stores as well |
| `mntput_ondemand_witness_fast`, `mntput_ondemand_witness_fast_lazy` | `NoFastFinal` violated | the witness: the mount is finished off without any grace period, for a synchronous umount and for a lazy one whose holder closed its file before the put |
| `mntput_ondemand_no_rcu_delay`, `mntput_ondemand_no_rcu_delay_sync` | `Freed` violated | a count that is not one must still wait: without the grace period the holder's fast-path put, or the walker's decrement under mount_lock, lands after the plain put found the count non-zero and nobody frees the mount (9ea0a46ca2c3 again) |
| `mntput_ondemand_loose_lazy` | `DoomedIsLast` violated | finishing the mount off at a count of two dooms it under the holder |
| `mntput_ondemand_loose` | pass | for a synchronous umount a count of two at the peek can only be a walker's transient increment (a legitimized walker would have made do_umount() refuse), and that walker finds MNT_DOOMED under mount_lock; the exact count matters for lazy unmounts |
| `mntput_ondemand_no_mb_legit` | `SyncClean` violated | the walker's increment stays in its store buffer while the count reads one: the smp_mb() of __legitimize_mnt() pairs with the peek as it pairs with the slow path |
| `mntput_ondemand_no_doomed_flag` | `NoUAF` violated | the walker whose increment the sum missed must see MNT_DOOMED under mount_lock (250cf3693060) |
| `mntput_ondemand_torn_sum` | `SyncClean` violated | with the single counter of before 7eb84d54fac5 the sum of a migrating holder can read one with the reference held: the series depends on the split counters |
| `mntput_upstream`, `mntput_upstream_lazy` | pass | the tree without the series, for reference |

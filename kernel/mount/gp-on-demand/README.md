# The grace period on demand, first shapes

Status: not merged, superseded by the series as proposed in
[`kernel/mount/gp-on-demand-proposal/`](../gp-on-demand-proposal/).

Unmounting waits for an RCU grace period before the references of the
unmounted mounts are dropped, because a holder may be on the lockless
fast path of mntput_no_expire() and a path walker may be in the middle
of __legitimize_mnt(). "fs: unmount without a grace period when nothing
else holds the mount" skips that wait when it can prove nobody is
there: if the count summed under mount_lock is exactly one, the only
reference left is the mount's own, so drop it and finish the mount off
right away. Any other count still waits for the grace period.

The model is `kernel/mount/core/`'s `MntPut` plus the series. It covers
the series as it was first written on work.mount.knullfs.4, where the
puts run from task work, the shape on vfs-7.4.mount, where do_umount()
drops the caller's reference in the write section and the peek drops the
mount's own, and a shape that was rejected.

Tree: work.mount.gp_on_demand at e9d8e1e39df1 on work.mount.knullfs.4
ba922416101e, which has the split per-CPU counters of 7eb84d54fac5.
The series as proposed on vfs-7.4.mount, with two mounts unmounted as a
batch, is modelled in
[`kernel/mount/gp-on-demand-proposal/`](../gp-on-demand-proposal/).

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `MntPut` with the series as switches: one mount, a holder that may migrate between CPUs, a walker, TSO or weakly ordered stores |

## Results

- With the series nothing is freed early, doomed early or leaked, with a
  migrating holder and with weakly ordered stores as well, and a
  synchronous umount that returns 0 leaves no reference behind
  (`mntput_ondemand` and `mntput_caller74` with their `_lazy`,
  `_migrate` and `_weak` variants).
- The series depends on the split counters. With the single counter
  from before 7eb84d54fac5 the sum of a migrating holder reads one while
  the reference is still held (`mntput_ondemand_torn_sum`).
- A count that is not one still needs the grace period
  (`mntput_ondemand_no_rcu_delay`), and finishing a mount off at a count
  of two dooms it under its holder for a lazy unmount
  (`mntput_ondemand_loose_lazy`).
- Rejected: do_umount() dropping the mount's own reference at a count of
  two and leaving the caller's put as the final one. That put can find a
  walker's transient increment in its sum and leave, and the walker,
  which never finishes a mount off, drops the count to zero for nobody
  (`mntput_owndrop74`). The peek has to be the last put.

Every configuration finishes in a few minutes at most.

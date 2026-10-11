# The vacant-mount series

Status: not merged. Mainline took "namespace: rework connected mounts"
(01cbebb42070) instead, see [`kernel/mount/covers/`](../covers/).
knullfs itself went in on its own with "namespace: keep the private
nullfs instance in knullfs" (4209cd7f546b).

"namespace: prevent UMOUNT_CONNECTED reference count cycles" is the
answer to the cycle described in
[`kernel/mount/ownership/`](../ownership/). Every victim of
umount_tree() keeps its own reference, and namespace_unlock() drops
those from task work, parents before children. A mount that loses its
last reference while it is still attached to a dead parent is vacated
in place: vacate_mount() points it at knullfs, a superblock that is
never released, and the filesystem it carried can go. Freeing it there
would leave a doomed mount in the hash, and unhashing it would reveal
what it covered. The parent's final put drops the vacant children,
__detach_mounts() cuts a vacant mount loose, and whoever comes second,
the last put of a vacant mount or the release of the filesystem it
carried, frees it, decided under mount_lock.

Two models. `MountWalk` is `kernel/mount/core/`'s RCU path walk with
vacate_mount() as one more thing that can happen to a mount while a
walker is on it. `MntVacant` is written for the series: a lazily
unmounted subtree left attached, holders with open files and fanotify
marks, walkers, rmdir of the mountpoints, loop images pinning the
mounts above them, RCU grace periods, with upstream's ownership as a
switch. Its `NOREF` mode is work.mount.knullfs.7, where a vacant mount
has no reference of its own and a walker marks the stand-in it takes.

Tree: work.mount.knullfs.4 at 095b9753ac15 on vfs-7.4.mount
b4698e50d460; `NOREF`: work.mount.knullfs.7 at 7eeb6da1e4d7.
[`kernel/mount/vacant-root-by-root/`](../vacant-root-by-root/)
reruns these models on the next version of the branch.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `MountWalk` against vacate_mount(), with weakly ordered stores; `MntVacant` for .4 and, as `NOREF`, for .7 |

## Results

With every piece in place nothing is put below zero, freed twice or
freed while anything refers to it, a hashed mount is always referenced,
no walk lands in a directory a mount covered, and once everything from
outside is gone every mount is freed and every filesystem is down
(`mntvacant_fixed`, `mntvacant_noref` and their variants without pins,
without holders, with two walkers and so on). Each piece is needed.
Taking one out, or putting the obvious alternative in its place, gives
the trace:

- vacate_mount() swaps mnt_sb and mnt_root while the mount is hashed. A
  walker that crossed into a bind mount of a subdirectory before the
  swap climbs out of the bind with "..", because path_connected() takes
  a knullfs mount with a dentry of the superblock it stood in for as
  connected (`mountwalk3_no_vacant_connected`). The series makes
  path_connected() fail for a knullfs mount and a dentry of another
  superblock. That holds with weakly ordered stores as well
  (`mountwalk3_weak_vacate`).
- Deciding the handoff between the last put and the release after
  mount_lock is dropped frees the mount twice
  (`mntvacant_handoff_unlocked`). Re-reading the flags after the unlock,
  as mntput_slow() did before the fixup 757a689090dd, frees a vacant
  mount with its release never queued, so its filesystem and the pin it
  holds stay around for good (`mntvacant_last_unlocked`).
- A vacant mount that __detach_mounts() cut loose must not ride the
  unmounted list: the list's first mount carries the task work in the
  same union the pending release sits in, and the release is lost
  (`mntvacant_ring_carrier_lost`).
- fsnotify has to take a mark's accounting back from the superblock its
  connector recorded, not from the one the mount points at now, or the
  release of the old superblock waits forever in fsnotify_sb_delete()
  (`mntvacant_marks_no_conn_sb`). That's the fsnotify prep a23a2e46164a.
- Putting the children before their parents, the order upstream builds
  the list in, vacates mounts for nothing (`mntvacant_lifo`).
- Upstream's ownership leaks the reported cycle
  (`mntvacant_upstream`), dooming the mount in place leaves a doomed
  mount in the hash (`mntvacant_doom`), and unhashing it reveals what it
  covered (`mntvacant_unhash`).

The `NOREF` runs found no kernel defect.

An RCU walker can still be on the dentries of a filesystem that is being
torn down, with and without the series
(`mntvacant_witness_rcu_teardown*`). What makes that safe is the
contract of the RCU path walk, not a grace period, and the series adds
no requirement mainline doesn't already have.

The walk models finish in seconds and `mntvacant_fixed` in a minute or
two. The runs with two walkers take minutes and want a lot of disk for
TLC's state queue.

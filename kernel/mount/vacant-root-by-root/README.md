# The vacant-mount series, root by root

Status: not merged, like the version in
[`kernel/mount/vacant/`](../vacant/).

work.mount.knullfs.7.order is the vacant-mount series of
work.mount.knullfs.7 with its tree-order prep replaced by one inside
propagate_umount(), "namespace: let propagate_umount() hand the set back
root by root". umount_tree() no longer hides the set from the parents'
lists of children, trim_one() skips the members of the set and keeps
track of a candidate child that is still undecided, and the final pass
hands the committed copies back root by root, each root followed by its
subtree. The lifetime protocol of the series is the one of .7.

Three models, each pinned to this tree. `MountWalk` is
[`kernel/mount/vacant/`](../vacant/)'s, rerun here because the path walk
and vacate_mount() are unchanged. `MntVacant` is that directory's model
plus the mark and the increment of __legitimize_mnt()'s fast path as
buffered stores, in program order or in either order, against the
parent's verdict on a stand-in. And the propagation algebra of
[`kernel/mount/core/`](../core/) with the prep behind three switches and
the claims of the prep checked after every umount.

Tree: work.mount.knullfs.7.order at 5308f2ea619f on vfs-7.4.mount
b4698e50d460.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `MountWalk`, `MntVacant` with buffered stores, `Propagation`/`MountOps`/`MountTree` with the series' propagate_umount() |

## Results

No kernel defect found.

- The path walk gives the verdicts and state counts of
  work.mount.knullfs.4.
- With buffered stores a walker can end up holding a stand-in it hasn't
  marked yet, an interleaving the one-step model of .7 could not show.
  Its second read_seqretry() fails on that path and the lock path marks
  the stand-in, so the parent's verdict is still right
  (`mntvacant_noref_tso`, `mntvacant_noref_weak`).
- What makes that safe is mainline's MNT_DOOMED check on that lock path
  (119e1ef80ecf): a walker whose increment lands on a stand-in that was
  doomed in the meantime takes it back instead of putting it. Without
  the check the walker's put reaches zero on a doomed mount, and with
  the release ahead of it, a freed one
  (`mntvacant_noref_*_no_lock_doomed*`).
- With the prep, every invariant of the propagation algebra holds and
  the set comes back root by root, each root followed by its subtree
  (`*_order_fixed`). Mainline hands the copies back children first
  (`*_order_mainline_handback`). Without the undecided flag, trim_one()
  commits a parent copy whose child copy stays later, and the parent is
  unmounted with a surviving mount inside it
  (`crossbind_order_no_undecided`).

The walk models finish in seconds, `MntVacant` with every piece in
place in a minute or two, the mutations in seconds. The propagation
algebra on the bigger layouts takes hours at four workers.

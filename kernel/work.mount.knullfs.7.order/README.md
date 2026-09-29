# TLA+ models of work.mount.knullfs.7.order

Tree: work.mount.knullfs.7.order at 5308f2ea619f, ten commits on
vfs-7.4.mount b4698e50d460: the fsnotify prep ab7c40b23eae, the prep
"namespace: let propagate_umount() hand the set back root by root"
c2f2e1258325, the task-work prep 442a926bb8ca "namespace: drop the
references of unmounted mounts from task work", the mechanism e3e42bec41de
"namespace: prevent UMOUNT_CONNECTED reference count cycles", five
selftests, the documentation commit and the cover.  The branch is
work.mount.knullfs.7 (7eeb6da1e4d7, modelled in `kernel/mount-knullfs/`
as `NOREF`) with the tree-order prep replaced by c2f2e1258325:
umount_tree() no longer hides the set from the parents' lists of children,
trim_one() skips the members of the set and remembers an undecided
candidate child, the final pass of propagate_umount() walks every
committed copy whose parent stays with next_mnt(), reparents a surviving
overmount at the visit of the mount it overmounts and moves the copies to
the set as they are visited, and the take-down unhashes the disconnected
members and leaves the connected ones where they are.  The diff
7eeb6da1e4d7..5308f2ea619f touches fs/pnode.c, fs/pnode.h, umount_tree()
and next_mnt() in fs/namespace.c and
Documentation/filesystems/propagate_umount.txt only, so the lifetime
protocol of the series (every victim keeps its own reference, dropped from
task work in tree order; vacate_mount() for a mount that loses its last
reference while attached; the stand-in without a reference of its own,
freed by the parent's final put or __detach_mounts() unless the mark
__legitimize_mnt() left and the count say a walk holds it; the handoff
between the release and the last put) is the one of .7.

Three models, each pinned to this tree:

* `MountWalk.tla`, the RCU path walk against vacate_mount(): a verbatim
  copy of `kernel/mount-knullfs/MountWalk.tla` (the path walk and
  vacate_mount() are unchanged since work.mount.knullfs.4), rerun here.
* `MntVacant.tla`, the vacant-mount protocol: `kernel/mount-knullfs/`'s
  module plus `MARK_STORES` and `FIX_LOCK_DOOMED`.  `NOREF` adds a second
  lockless pair to that model: the mark (WRITE_ONCE(mnt_vacant_held)) and
  the per-CPU increment of __legitimize_mnt()'s fast path, with no barrier
  between them and the smp_mb() that follows, against
  disown_vacant_mount()'s smp_mb() and its reads of the mark and the count
  under mount_lock.  The .7 runs took the first read_seqretry(), the mark
  and the increment as one step; here the two stores sit in the walker's
  store buffer, drained in program order (`"tso"`) or in either order
  (`"weak"`, arm64), so the parent's or __detach_mounts()' verdict can land
  between the first read_seqretry() and the stores, or between the
  stores.  The kernel is safe there because a verdict of dead dooms the
  stand-in under mount_lock and the walker's lock_mount_hash() path takes
  its increment back on a MNT_DOOMED mount instead of mntput()ing it
  (mainline's check, 119e1ef80ecf); `FIX_LOCK_DOOMED` off drops that check.
  Run in `NOREF` mode; the .4 mode is `kernel/mount-knullfs/`'s, and
  `mntvacant_fixed` is kept as the regression that the additions leave it
  untouched.
* `Propagation.tla`, `MountOps.tla`, `MountTree.tla` and the layouts, the
  propagation algebra with the series' propagate_umount(): copies of
  `kernel/mount/`'s Family A (the mount record, fs/pnode.c and the tree
  surgery of fs/namespace.c as functions, the syscalls as atomic steps,
  the declarative rules) with the prep behind three switches, and the
  claims of the prep folded into the history.  Diff against `kernel/mount`
  to see the delta.

## Files

| File | What it is |
|------|------------|
| `MountWalk.tla`, `MC_mountwalk.tla`, `MC_mountwalk3.tla` | Family B: the RCU path walk against a mounter, a lazy umount, a move and vacate_mount(), with `WEAK_VACATE` for weakly ordered memory around the vacate; see `kernel/mount-knullfs/README.md` |
| `MntVacant.tla`, `MC_mntvacant.tla` | Family B: the vacant-mount protocol on the layout P (the root of a lazily unmounted subtree, disconnected), M attached to P, G attached to M; namespace_unlock()'s puts from task work, the slow path with vacate_mount() and disown_vacant_mount(), cleanup_mnt() as task work, holders, RCU walkers with __legitimize_mnt()'s fast path and lock path, vfs_rmdir() of a mountpoint, superblocks pinning a mount through a file, fsnotify's accounting, knullfs, RCU; see `kernel/mount-knullfs/README.md` for the model and the .4 and .7 switches |
| `MountTree.tla`, `Propagation.tla`, `MountOps.tla`, `MC_small.tla`, `MC_chain.tla`, `MC_peers.tla`, `MC_locked.tla`, `MC_parentcand.tla`, `MC_crossbind.tla`, `MC_propns.tla` | Family A: `kernel/mount/`'s propagation algebra.  `Propagation.tla` carries the series' trim_one(), umount_one(), the final pass of propagate_umount() and the take-down of umount_tree() behind `KEEP_LINKED`, `ROOT_BY_ROOT` and `TRACK_UNDECIDED`, the reset of the old parent's ->overmount in mnt_change_mountpoint() (476ef286a7a5, in the series' base), and returns the set in the order umount_tree() takes it down together with the claims of the prep; `MountOps.tla` folds those claims into `hist` (`HandbackOK`, the witnesses `NoUMoved` and `NoMultiRoot`); `MountTree.tla` and the layouts are verbatim copies of `kernel/mount/`'s |
| `*.cfg` | TLC configurations from `gen-cfgs.py`; the header says what to expect |
| `check.sh`, `show-walk-trace.py`, `show-vacant-trace.py`, `show-trace.py` | run one configuration; print a counterexample compactly |

## Switches

The switches of the two Family B models are documented in
`kernel/mount-knullfs/README.md`, those of the propagation algebra in
`kernel/mount/README.md`.  New here:

`MntVacant.tla`:

| Constant | Meaning |
|----------|---------|
| `MARK_STORES` (`"sc"` by default) | `"tso"`: the mark and the increment of __legitimize_mnt()'s fast path sit in the walker's store buffer and become visible in program order, the smp_mb() before the second read_seqretry() drains it; `"weak"`: they become visible in either order (no barrier sits between them); `"sc"`: the first read_seqretry(), the mark and the increment in one step, the .7 runs |
| `FIX_LOCK_DOOMED` | off: __legitimize_mnt()'s lock_mount_hash() path returns -1 on a MNT_DOOMED mount and leaves the mntput() to the caller, instead of taking the increment back and returning 1 (mainline's check since 119e1ef80ecf, which the stand-in relies on: a verdict of dead is final and the walker's increment must not turn into a put) |

`Propagation.tla`:

| Constant | Meaning |
|----------|---------|
| `KEEP_LINKED` | off: mainline, umount_tree() hides the set from the parents' lists of children before propagate_umount() and umount_one() hides each committed copy, so "no children left" in trim_one() is an empty list, and the take-down puts a connected member back at the tail of its parent's list; on: they stay where they are, trim_one() skips the members of the set |
| `TRACK_UNDECIDED` | off, with `KEEP_LINKED`: trim_one() commits a candidate that has no surviving child even while a candidate child of it is still undecided (mutation) |
| `ROOT_BY_ROOT` | off: mainline's final pass, the reparent loop over to_umount and its splice at the tail of the set in commit order; on: the committed copies whose parent stays are walked with next_mnt(), a surviving overmount reparented at the visit of the mount it overmounts and before the descent, every visited mount moved to the tail of the set (a member of the original set below a committed ancestor moves too) |

## What is checked

`MntVacant.tla` checks what `kernel/mount-knullfs/README.md` lists, with
`HeldCoversRefs` restated for buffered stores: a walk that holds a
stand-in past its smp_mb() has marked it, unless its sequence sample is
stale, in which case its lock_mount_hash() path marks it or takes the
increment back.  New witnesses: `NoSplit` (a verdict landed while a
walker's stores were still buffered) and `NoPhantom` (the lock path took
an increment back from a stand-in doomed in the meantime).

The propagation algebra checks `kernel/mount/`'s invariants (the victims
are the maximal non-revealing non-shifting subset of the tree plus its
cognates, survivors reparented to the first surviving ancestor, the
structure of the tree and of the propagation graph, the lock covers,
propagate_mount_busy()'s decision, `DeadUnderDead`) plus `HandbackOK`: at
every umount_tree() the set is a concatenation of blocks, each a root of
the set followed by its subtree through members of the set in next_mnt()
order, the walk never visited a mount outside the set, and nothing was
left on to_umount (the three claims of the prep, the last two its
VFS_WARN_ON_ONCEs); witnesses `NoUMoved` (a member of the original set
moved behind a committed ancestor) and `NoMultiRoot`.

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar
    TLC_DEADLOCK=check ./check.sh mountwalk3_fixed_vacate 4     # seconds
    TLC_DEADLOCK=check ./check.sh mntvacant_noref_weak 4        # 3,961,832 states, a minute or two
    ./check.sh mntvacant_noref_tso_no_lock_doomed 2             # the mutation, a second
    ./check.sh propns_order_mainline_handback 2                 # seconds: mainline's order, children first
    ./check.sh locked_order_fixed 4                             # the series' propagate_umount() on the locked layout, hours at 4 workers

## Results

### MountWalk against vacate_mount() (jens, 2026-09-29)

The path walk and vacate_mount() are the ones of work.mount.knullfs.4;
the eleven configurations of `kernel/mount-knullfs/` rerun from this
directory give the same verdicts, and the same counts for the runs that
pass (a violation's count varies with the workers' schedule):
`mountwalk3_fixed_vacate`
82,598, `mountwalk3_dotdot_mseq` 87,934,
`mountwalk3_fixed_umount` 144,668, `mountwalk3_fixed_move`
236,189, `mountwalk_vacate_fullmount`
901,285, `mountwalk3_weak_vacate`
102,850, `mountwalk3_weak_dotdot_mseq`
109,374, `mountwalk_weak_vacate_fullmount`
1,095,119 states, all passing;
`mountwalk3_no_vacant_connected`, `mountwalk3_weak_no_vacant_connected`
and `mountwalk3_witness_vacant` violated as expected
(32,982, 44,059
and 12,840 states).  What they mean is in
`kernel/mount-knullfs/README.md`.

### MntVacant with `NOREF` (jens, 2026-09-29)

The .7 protocol on this tree, with the first read_seqretry(), the mark and
the increment as one step (`MARK_STORES = "sc"`): the .7 verdicts and
counts.  Deadlock detection is on for the green runs.

| Configuration | Result | Meaning |
|---------------|--------|---------|
| `mntvacant_noref` | pass, 2,446,668 states | the protocol with every piece in place, both holders, the pins, the walker and the rmdirs |
| `mntvacant_noref_nopins`, `mntvacant_noref_noholder`, `mntvacant_noref_walk2`, `mntvacant_noref_2walkers`, `mntvacant_noref_inline`, `mntvacant_noref_marks` | pass, 1,632,324 / 1,810 / 21,932,346 / 31,976,168 / 2,163,857 / 7,917,612 states | without the pins, without holders, with two walks per walker, with two walkers at once, in the task-work shape, and with fanotify marks |
| `mntvacant_noref_sum_only` | pass, 2,446,668 states | no mark at all and the parent always sums |
| `mntvacant_noref_no_mark`, `mntvacant_noref_no_sum`, `mntvacant_noref_hashed_dooms`, `mntvacant_noref_detach_leak` | `HeldCoversRefs`, `Reaped`, `HashedHasRef`, `Reaped` violated, 2,027 / 1,628,551 / 5,381 / 585,914 states | the .7 mutations |
| `mntvacant_noref_witness_dead_free`, `mntvacant_noref_witness_hashed_zero`, `mntvacant_noref_witness_put_first`, `mntvacant_noref_witness_release_first` | fire, 1,970 / 6,702 / 9,977 / 1,058 states | the .7 witnesses |
| `mntvacant_fixed` | pass, 6,262,506 states | the .4 mode through the edited module: `kernel/mount-knullfs/`'s count |

### MntVacant with `NOREF` and buffered stores (jens, 2026-09-29)

The first TSO run tripped `HeldCoversRefs` as the .7 runs stated it: a
walker had legitimized M before it was vacated, its increment still in
the buffer when the vacating sum ran, and after the drain it held a
stand-in it had not marked.  Its second read_seqretry() fails on that
path and the lock path marks the stand-in, so the invariant now allows a
walker whose sequence sample is stale; the parent's verdict is right
either way.  The interleaving exists in the kernel and was invisible to
the one-step model.

| Configuration | Result | Meaning |
|---------------|--------|---------|
| `mntvacant_noref_tso`, `mntvacant_noref_weak` | pass, 3,942,088 / 3,961,832 states | the mark and the increment as buffered stores, in program order and in either order: every invariant of the .7 runs, with deadlock detection; a verdict landing between the first read_seqretry() and the stores, or between the stores, always ends in the lock path marking the stand-in or taking the increment back |
| `mntvacant_noref_weak_nopins`, `mntvacant_noref_weak_inline`, `mntvacant_noref_weak_walk2`, `mntvacant_noref_weak_2walkers` | pass, 2,514,924 / 3,486,590 / 37,104,468 / 76,120,424 states | the same without the pins, in the task-work shape, with two walks per walker, and with two walkers at once |
| `mntvacant_noref_weak_no_mark` | `HeldCoversRefs` violated, 3,461 states | the walk does not mark the stand-in it holds: the parent frees it under the walker, as in the .7 run |
| `mntvacant_noref_tso_no_lock_doomed_last` | `DoomedIsLast` violated, 22,518 states | the lock path without mainline's MNT_DOOMED check: U's put vacates M while a walker's increment is still buffered, rmdir of M's mountpoint disowns the unmarked stand-in and dooms it, and the walker's lock path leaves its increment on the doomed stand-in instead of taking it back |
| `mntvacant_noref_tso_no_lock_doomed`, `mntvacant_noref_weak_no_lock_doomed` | `NoWarn` violated, 45,704 states; `NoWarn` violated, 47,065 states | the same, one step on: the walker's mntput() reaches zero on the doomed stand-in (`put_doomed`, the slow path's early return) |
| `mntvacant_noref_weak_no_lock_doomed_uaf` | `NoDangling` violated, 143,027 states | and with the release and its call_rcu() ahead of that mntput(), once the walker left its RCU read section: the mntput() reaches a freed mount |
| `mntvacant_noref_sc_no_lock_doomed` | pass, 2,446,668 states | the same mutation under the one-step fast path: no verdict can land inside the step, the count is that of `mntvacant_noref`, the window the check closes does not exist in that model |
| `mntvacant_noref_weak_witness_split`, `mntvacant_noref_tso_witness_phantom`, `mntvacant_noref_weak_witness_phantom` | fire, 3,150 / 21,988 / 22,154 states | a verdict does land while a walker's stores are buffered, and the lock path does take an increment back from a stand-in doomed in the meantime |
| `mntvacant_noref_sc_witness_phantom` | pass, 2,446,668 states | with the one-step fast path the lock path never meets a doomed stand-in |

### The propagation algebra with the series' propagate_umount() (jens, 2026-09-29)

With the switches off the fork is mainline, up to the record of the
hand-back claim, and gives `kernel/mount/`'s counts; with them on every
mainline invariant holds and so do the claims of the prep.  `MC_crossbind` is the layout where the
undecided flag matters: the cognate of the victim's child sits above the
cognate of the victim and is discovered after it, so trim_one() looks at
the parent copy while its child copy is still undecided; the child keeps
a mount of its own and stays, and without the flag the parent copy is
unmounted with a surviving mount inside it.  `MC_propns` is one namespace
receiving a two-level tree: the copies are committed child first, so
mainline's order is children first and the series' is not.
`MC_parentcand` (the victim's parent is a candidate itself) is the case
where a member of the original set moves behind a committed root.

| Configuration | Result | Meaning |
|---------------|--------|---------|
| `chain_order_fixed`, `peers_order_fixed`, `locked_order_fixed` | pass, 359,454 / 59,634 / 191,853 states (MaxOps 3) | the series' propagate_umount() on the three-namespace chain, the peers and the locked layouts: every mainline invariant plus `HandbackOK` |
| `parentcand_order_fixed`, `crossbind_order_fixed`, `propns_order_fixed` | pass, 54 / 122 / 42 states | the three scripted layouts |
| `chain_order_mainline`, `peers_order_mainline`, `locked_order_mainline`, `parentcand_order_mainline`, `crossbind_order_mainline`, `propns_order_mainline` | pass, 359,358 / 59,632 / 191,805 / 54 / 122 / 42 states | the switches off: mainline, plus the record of the hand-back claim, which mainline's order violates in a few states (the `_mainline_handback` runs); with that record left out of mainline mode the counts are `kernel/mount/`'s exactly, 359,356 / 59,631 / 191,799 / 53 against 359,356 / 59,631 / 191,799 / 53 |
| `propns_order_mainline_handback`, `peers_order_mainline_handback`, `chain_order_mainline_handback`, `locked_order_mainline_handback` | `HandbackOK` violated, 9 / 1,015 / 43,434 / 28,297 states | mainline's order: the committed copies come children first, on every layout that reaches a copy with a child |
| `propns_order_keep_splice`, `propns_order_keep_splice_handback` | pass, 42 states; `HandbackOK` violated, 9 states | leaving the set linked without the walk is sound and does not order it: the walk does |
| `crossbind_order_no_undecided` | `AlgebraOK` violated, 54 states | trim_one() without the undecided flag: 6 is committed while its child 7 is undecided, 7 keeps 8 and is taken off the candidates by its own trim_one(), trim_ancestors() finds 6 committed already and stops, and 6 is unmounted with the surviving 7 inside it (`Structure` and `DeadUnderDead` fall as well) |
| `locked_order_no_handle_locked`, `crossbind_order_no_trim` | `AlgebraOK` violated, 332 states; `AlgebraOK` violated, 54 states | the mainline mutations still fire through the fork: handle_locked() dropped on the locked layout, trim_ancestors() dropped on the cross-bind layout (6 is taken with the surviving 7 inside, the same shape as the undecided flag's) |
| `locked_order_no_trim` | pass, 191,853 states | the locked layout does not reach a trimmed ancestor within three operations, so the mutation has no effect there, in `kernel/mount` as well (locked_no_trim passes with 191,799 states) |
| `chain_order_witness_multiroot`, `parentcand_order_witness_umoved`, `locked_order_witness_reparent`, `locked_order_witness_connected` | fire, 92 / 27 / 2,584 / 14,732 states | the runs cover several roots (copies in two namespaces), a member of the original set moved behind a committed root, a surviving overmount reparented during the walk, and propagated copies left connected |

What the fork does not model: the epilogue keeps mainline's ownership
(`Collect` frees a detached unreferenced mount and orphans its children),
so a dead child under a held parent stays attached in the table as
before; the vacant stand-in that takes its place in the series, and
everything about references, is `MntVacant`'s.  The two are joined by the
order: the fork proves umount_tree() hands namespace_unlock() a parent
before its children and each root's subtree in one run, and `MntVacant`
takes that order as `FIX_TREE_ORDER` (`mntvacant_tree_order` and
`mntvacant_lifo` in `kernel/mount-knullfs/`).

No kernel defect found.

# TLA+ models of shrink_submounts()

Tree: work.mount.fixes.3 at a3fe58f6edea, the twelve fixes and five
selftests of the series on vfs-7.4.mount b4698e50d460, the cover, and two
fixups above it: fc3486b17758 replaces the one-at-a-time rescan of
shrink_submounts() from "namespace: check a submount for references right
before unmounting it" (4078866927ff) with a single walk, and a3fe58f6edea
adds its selftest case.

The series fixed shrink_submounts() checking every shrinkable submount
for references first and unmounting them afterwards, while an earlier
umount_tree() can slide a surviving overmount to where the propagated
copy of a later victim is looked up (the layout of `MC_shrinkkres`).
The fix in the series checks one submount and unmounts it, then walks
the tree again from the top, which is quadratic in the number of
submounts the walk passes before it finds the next candidate.  The fixup
keeps the check and the umount adjacent and keeps walking: a childless
shrinkable mount is unmounted where the walk finds it, a parent is
checked on the way back up once its children are gone, and the walk
starts over only when the parent of the mount it just unmounted went
along with it (the layout of `MC_shrinkparent`) or when a pass unmounted
something at all.

One model: `kernel/mount/core/`'s propagation algebra (Family A) with
shrink_submounts() as one of three algorithms.  `MountTree.tla`,
`Propagation.tla` and the layouts `MC_small`, `MC_chain`, `MC_peers`,
`MC_locked` are verbatim copies; `MountOps.tla` differs from
`kernel/mount/core/`'s in:

* `SHRINK`: `"gather"` is mainline, select_submounts() gathers every
  shrinkable leaf that is not busy and umount_tree() takes them one after
  the other, repeated while a pass found something (`ShrinkGather`);
  `"rescan"` is the series, select_submount() hands back the first leaf
  that is not busy, umount_tree() takes it, the walk starts from the top
  (`ShrinkRescan`); `"walk"` is the fixup (`ShrinkWalk`), transcribed with
  its cursor: `cur` is this_parent and `next` the saved next child, the
  list head as `NoMnt`.
* `FIX_WALK_RESTART`: off, the walk keeps its cursor when the parent of
  the mount it just unmounted went along.  A cursor that names a mount no
  longer on `cur`'s children list, or the links of a `cur` that went, is
  a stale cursor: the kernel would walk another list or spin on an
  unlinked node.  The model records it (`hist.cursorbad`) and stops the
  walk.
* the victims of the shrink phase count for `SyncUmountNotBusy`;
  `kernel/mount/core/` only looked at the final umount_tree() of the mount
  being unmounted, which is why its `Umount` never showed the finding.
* the shrink phase's busy checks see do_umount()'s own path reference on
  the mount being unmounted (`[refs EXCEPT ![m] = @ + 1]`): a shrink can
  make it a propagated victim, and that reference is what keeps
  propagate_mount_busy() from taking it.  The covers the shrink phase's
  umounts lift are passed on like the final umount's.
* `hist` gained `cursorbad`, `shrunk` and `parentwent`; the invariant
  `ShrinkCursorOK` and the witnesses `NoShrink`, `NoParentWent`.

## Files

| File | What it is |
|------|------------|
| `MountTree.tla`, `Propagation.tla` | verbatim copies of `kernel/mount/core/`'s; the series does not touch fs/pnode.c |
| `MountOps.tla` | `kernel/mount/core/`'s syscalls with the three shrink_submounts() algorithms, see above |
| `MC_shrinkkres.tla` | the scripted layout of the finding, the selftest's `busy_mount_moved_into_reach`: P (3) shrinkable and shared at R@Ra, P1 (4) its slave made shared at R@Rb, P2 (5) P1's peer at R@Rc, B (6) shrinkable on P@Fo with the copies 7 on P1 and 8 on P2, the copy on P2 private with R (9) on its root as the working directory, P moved to P1@Fi (its copies 10, 11 on P2); MaxOps 1: the synchronous umount of P1 is one of the next steps |
| `MC_shrinkparent.tla` | the scripted layout of the selftest's `parent_goes_with_child`: V (3) at R@Ra, T (4) shrinkable and shared at V@Gt, M (5) shrinkable on T@Fo made before T has a receiver, Q (6) a bind of T at V@Gq made a slave of T, T moved to Q@Fo so that it sits at M's dentry under a receiver of itself; MaxOps 1: the synchronous umount of V is one of the next steps |
| `MC_small.tla`, `MC_chain.tla`, `MC_peers.tla`, `MC_locked.tla` | `kernel/mount/core/`'s random layouts, MaxOps 3 |
| `*.cfg` | TLC configurations from `gen-cfgs.py`; the header says what to expect |
| `check.sh`, `run-all.sh`, `show-trace.py` | run one configuration, a batch, print a counterexample compactly |

## What is checked

Every invariant of `kernel/mount/core/` (`TypeOK`, `AlgebraOK`, `Structure`,
`IteratorsOK`, `NsOK`, `RefsOK`, `CoverOK`, `SyncUmountNotBusy`,
`BusyMirrorOK`, `DeadUnderDead`) plus:

| Invariant | Meaning |
|-----------|---------|
| `ShrinkCursorOK` | the walk of shrink_submounts() never used a stale cursor: the saved next child was on this_parent's list when it was read, and this_parent was mounted when its links were read to ascend |
| `SyncUmountNotBusy` | now also over the shrink phase: no submount a synchronous umount shrinks away, nor anything its propagation pulls out, is referenced |

Witnesses: `NoShrink` (a shrink unmounted something), `NoParentWent`
(the parent of a shrunk mount went along with it).

## Results

Local, TLC 2.19 with 4 workers, seconds each (the scripted layouts end
with the umount, `MaxOps 0`):

| Configuration | Result | What it shows |
|---------------|--------|---------------|
| `shrinkkres_gather` | `SyncUmountNotBusy` violated, 12 states | the finding: the copy of B on P1 goes first, its cognate on P2 with it, R slides to P2@Fo, and B's umount pulls R out although it is the working directory; B was checked before the first umount |
| `shrinkkres_rescan`, `shrinkkres_walk` | pass, 13 states | the series and the fixup keep R: B's check runs after the first umount and finds R busy |
| `shrinkkres_witness_shrink` | `NoShrink` violated | the shrink phase runs on this layout |
| `shrinkparent_gather`, `shrinkparent_rescan`, `shrinkparent_walk` | pass, 9 states | M's umount takes T along and Q goes on the next pass; the walk starts over when T went |
| `shrinkparent_walk_norestart` | `ShrinkCursorOK` violated, 9 states | without the restart the walk ascends through T's links after T went |
| `shrinkparent_witness_parentwent` | `NoParentWent` violated | the parent-goes-along case is reached |

The random layouts of `kernel/mount/core/` at `MaxOps 3`, on jens with
`run-all.sh 3 32`, every invariant of `kernel/mount/core/` plus
`ShrinkCursorOK`:

| Layout | `_walk` | `_walk_norestart` | `_rescan` | `_gather` |
|--------|---------|-------------------|-----------|-----------|
| `small` | pass, 98,495 states, 15 min | pass | pass | pass |
| `chain` | pass, 359,369 states, 20 min | pass | pass | pass |
| `peers` | pass, 59,631 states, 6 min | pass | pass | pass |
| `locked` | pass, 191,803 states, 18 min | pass | pass | pass |

`small_witness_shrink` fires at 19,457 states.  The four algorithms
reach the same states on every layout, and the counts are `kernel/mount/core/`'s
(98,492 / 359,356 / 59,631 / 191,799) plus the few states the new history
fields tell apart.  Neither the finding nor the stale cursor is reachable
within three free syscalls: the first needs the eleven steps of
`MC_shrinkkres`, the second the seven of `MC_shrinkparent`, which is what
the scripted layouts are for.

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar
    ./check.sh shrinkkres_gather 4            # the finding, seconds
    ./check.sh shrinkparent_walk_norestart 4  # the stale cursor, seconds
    ./run-all.sh 3 32 small_walk chain_walk peers_walk locked_walk   # the random layouts, minutes each

TLC 2.19 sometimes does not return after printing a counterexample here;
`run-all.sh` kills such a run by its configuration name once the log has
stopped growing.

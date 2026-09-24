# TLA+ models of the vacant-mount series (work.mount.knullfs)

Tree: work.mount.knullfs at 8a7c60fb32cb, the b4 cover on top of the
mechanism commit 8b7635f9b9a6 "namespace: prevent UMOUNT_CONNECTED
reference count cycles", on vfs.fixes 2d2a2d7aa987 (which holds the
revert of 0342482a4d15): every victim of umount_tree() keeps its own
reference, namespace_unlock() puts in tree order, a mount that loses its
last reference while still attached is vacated in place (vacate_mount()),
its last put and the release of the filesystem it carried hand the free to
whoever comes second (vacant_mount_put(), vacant_mount_released()),
__detach_mounts() puts a vacant mount it unhashes, and path_connected()
fails for a dentry of another superblock than the mount's.  The series is
not in mainline; the mainline models are in `kernel/mount/`, whose
conventions this directory follows.

`MountWalk.tla` here is `kernel/mount/MountWalk.tla` plus the vacate change
(`CHANGE = "vacate"`, `FIX_VACANT_CONNECTED`, `FIX_DOTDOT_MSEQ`,
`WEAK_VACATE`, the `sb` field of the mount record, the `NewRoot` and
`NullSb` constants); diff the two files to see the delta.  `MntVacant.tla`
is written for the series alone, with upstream's ownership as a switch.

## Files

| File | What it is |
|------|------------|
| `MountWalk.tla`, `MC_mountwalk.tla`, `MC_mountwalk3.tla` | Family B: the RCU path walk (path_init(), __follow_mount_rcu() with __lookup_mnt()'s possible miss while a writer runs and the rechecks after a hop and a miss, follow_dotdot_rcu()/choose_mountpoint_rcu() with its recheck and path_connected() over the current mnt_root and mnt_sb before the step to d_parent, step_into()'s -ENOENT on a negative dentry with no recheck, handle_dots()'s scoped -EAGAIN, complete_walk()'s legitimization, -ECHILD restarts in REF mode with lookup_mnt()/choose_mountpoint()) against a mounter (d_set_mounted(), then the write section; the mounts it makes may be bind mounts of a subdirectory), a lazy umount (unhash, DCACHE_MOUNTED cleared, synchronize_rcu(), the put that frees), a move (unhash, new parent and mountpoint, rehash) and vacate_mount() (mnt_sb, then mnt_root pointed at knullfs, inside the slow path's mount_lock section, the mount still hashed under its parent), each section one store per step |
| `MntVacant.tla`, `MC_mntvacant.tla` | Family B: the vacant-mount protocol of work.mount.knullfs ("namespace: prevent UMOUNT_CONNECTED reference count cycles"). An unmounted subtree left attached (P disconnected, M under it, G under M, all MNT_UMOUNT and out of every namespace), from namespace_unlock()'s up_write() on: its synchronize_rcu_expedited() and the puts of `unmounted` in tree order; mntput_no_expire_slowpath() with the last put of an attached mount vacating it in place (vacate_mount(): children unhashed, the vacant ones stuck, mnt_sb/mnt_root/the instance list moved to knullfs, one reference for the parent, the release pending), the last put of a vacant mount (vacant_mount_put()), the parent's final put putting only vacant children; cleanup_mnt() as task work in any order (stuck children, the filesystem's release, the free, or the release visit of a vacant mount ending in vacant_mount_released()); holders closing files on P or M; RCU walkers from a holder's file into the mount below (__lookup_mnt(), __legitimize_mnt() with its lock_mount_hash() path, mntput(), the REF walk after -ECHILD); vfs_rmdir() of a mountpoint (__detach_mounts() unhashing the mount there and putting it if vacant, then namespace_unlock()); superblocks that pin a mount through a file (the loop image on P, an image inside it on M), dropped when the superblock is deactivated; RCU grace periods and call_rcu() frees |
| `*.cfg` | TLC configurations from `gen-cfgs.py`; the header says what to expect |
| `check.sh`, `show-walk-trace.py`, `show-vacant-trace.py` | run one configuration; print a counterexample compactly |

## Switches

`MountWalk.tla` (the mainline switches are documented in `kernel/mount/README.md`):

| Constant | Off means |
|----------|-----------|
| `FIX_VACANT_CONNECTED` | path_connected() trusts mnt_root and mnt_sb as it did before work.mount.knullfs: a knullfs mount with a dentry of the superblock it stood in for counts as connected; on, it fails for that pair (the fixup 92e32b28cc09) |
| `FIX_DOTDOT_MSEQ` (off by default) | on: follow_dotdot_rcu() rechecks m_seq after path_connected() on the d_parent step, the alternative fix; the tree does not have it |
| `CHANGE` | what happens to the first new mount: "none", "umount", "move" or "vacate" |
| `WEAK_VACATE` (off by default) | on: weakly ordered memory around vacate_mount(): its two stores, mnt_sb and mnt_root, become visible in either order, and every load follow_dotdot_rcu() and path_connected() make on the d_parent branch, which has no recheck, returns the old or the new value on its own once a write section has run since the walker's m_seq sample (path_init()'s smp_rmb() keeps loads after the sample; the recheck's smp_rmb() keeps the validated loads consistent) |

What `MountWalk.tla` checks beyond the mainline invariants: `NoVacantEscape`
(a ".." lands on a dentry outside the mount it is taken in: outside the
subtree of its root and of the root it had before it was vacated).

`MntVacant.tla`:

| Constant | Off means |
|----------|-----------|
| `FIX_OWN_REF` | upstream's ownership: an attached victim is owned by its unmounted parent, whose cleanup_mnt() puts every child its final put unhashed; `unmounted` holds only the disconnected victims |
| `VACATE_MODE` | `"vacate"` is the series; `"doom"` keeps upstream's slow path with the own references: the last put of an attached mount sets MNT_DOOMED in place and frees it while it is still hashed; `"unhash"` disconnects it instead, revealing what it covered |
| `FIX_STUCK_VACANT_ONLY` | the parent's final put makes every unhashed child a stuck child, as upstream, although the children hold their own references |
| `FIX_TREE_ORDER` | namespace_unlock() puts the children before the parent (the hlist order upstream builds) |
| `FIX_DETACH_PUTS_VACANT` | __detach_mounts() never puts a vacant mount it unhashes; `DETACH_PUTS_ALL` on: it puts every unmounted mount it unhashes (upstream's line kept) |
| `FIX_HANDOFF_LOCKED` | vacant_mount_released() reads MNT_DOOMED and vacant_mount_put() reads mnt_old_root after dropping mount_lock (the first draft of the handoff) |
| `FIX_STUCK_BEFORE_HANDOFF` | the release visit hands off before it puts the stuck children |
| `RELEASE_PUTS` (a variant, not a fix) | on: the earlier design: vacate_mount() takes two references and the release visit ends in mntput() instead of the handoff |
| `HOLDER_ORDER` | `"any"`; `"early"`: the holder of the subtree root closes before U's puts, which is what dissolve_on_fput() dropping the file's reference under namespace_sem and ksys_unshare() freeing the old fs_struct before the old namespaces amount to; `"late"`: after U is done, the old order |

What `MntVacant.tla` checks: `NoNegative` (the WARN_ON(count < 0) of
the slow path: no mount is put more often than it was referenced),
`NoWarn` (the VFS_WARN_ON_ONCEs of vacant_mount_put() and
free_vacant_mount() and the model's own marks: a vacant mount put while
attached, freed with stuck children or on an instance list, freed while
hashed, freed twice, used after call_rcu(), doomed while attached, a
filesystem released twice, a final put on a doomed mount), `ExactlyOnce`
(every mount is freed once and releases its filesystem once),
`NoDangling` (nothing refers to a freed mount: hash, instance list,
parent pointers, stuck lists, put lists, pins, task work, holders,
walkers holding it), `HashedHasRef` (a hashed mount is referenced and
never doomed: what keeps the covered directory covered), `DoomedIsLast`,
`VacantOK`, `NoReveal` (no walk lands in the directory a mount covered),
`NoHang` (lookup_mnt() never spins on a hashed doomed mount), `Reaped`
(once every reference from outside is gone and every deferred piece of
work has run, every mount is freed and every filesystem is down: no cycle
kept anything), deadlock freedom, and the witnesses `NoVacate`,
`NoNeedlessVacate` (a vacate the put order alone caused: the parent lived
on the reference U had not dropped yet), `NoWalkerVacate`, `NoPinDoom`,
`NoPutFirst`, `NoReleaseFirst`, `NoDetachPut`.

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar
    TLC_DEADLOCK=check ./check.sh mountwalk3_fixed_vacate 4   # seconds
    TLC_DEADLOCK=check ./check.sh mntvacant_fixed 4           # 10M states, a minute or two
    TLC_DEADLOCK=check ./check.sh mntvacant_fixed_2walkers 8  # 77M states, minutes; needs a big /tmp or TLC_METADIR elsewhere

## Results

### MountWalk against vacate_mount() (local runs, 2026-09-24)

work.mount.knullfs keeps an unmounted mount attached to its unmounted
parent until its own reference is gone, then vacate_mount() points it at
knullfs in place: mnt_sb, then mnt_root, under mount_lock, the mount
still hashed, so a walk through the dead parent (held by an fd) still
crosses into it.  follow_dotdot_rcu() decides between choose_mountpoint_rcu()
and d_parent by comparing the current dentry with mnt_root, and asks
path_connected() whether d_parent is still inside the mount.
path_connected() answers from mnt_root and mnt_sb too, and that arm has no
m_seq recheck (the climb arm does).  A walker that crossed into a bind
mount of a subdirectory before the swap, holding the old root as its
dentry, finds after the swap that its dentry is not mnt_root, takes
d_parent, and path_connected() says yes because the knullfs root is its
superblock's root: the walk continues above the bind's root in the
filesystem the bind was cut from.  A negative dentry there is returned as
-ENOENT without a recheck (step_into()), from a position no locked walk
ever reaches.  The `MC_mountwalk3` layout has that shape: the mounter binds
`pub`, a subdirectory of F, on A; "x" exists at the root of S and is
negative at the root of F; W1 walks a, .., x and W2 walks a, s, .., .., x.
The source filesystem stays mounted elsewhere, so the old root's d_seq does
not move (dentry lifetimes are not modelled; the source filesystem's
teardown while a walker is inside it is the filesystem's RCU contract, as
for a lazy umount).  The kernel's vacate needs a mount nobody holds, so
the changer vacates only a mount no REF walker holds; the mount's own
reference stands in for the one namespace_unlock() drops.

| Configuration | Result | Meaning |
|---------------|--------|---------|
| `mountwalk3_no_vacant_connected` | `RcuResultOK` violated, 33k states | the race: W1 crosses into the bind at (2, pub), the changer swaps mnt_sb and mnt_root to knullfs, W1's ".." climbs to (2, F), the root of the source filesystem, and its "x" hits the negative dentry there: -ENOENT for a path that resolves to (1, X) at every instant, before and after the vacate |
| `mountwalk3_witness_vacant` | `NoVacantEscape` violated, 14k states | the same climb, caught at the ".." step |
| `mountwalk3_fixed_vacate` | pass, 83k states | the fixup: path_connected() fails for a knullfs mount and a dentry of another superblock, the walker gets -ECHILD and restarts in REF mode, where it crosses into the vacant mount properly; every RCU result equals the sequential walk, no ".." ever leaves its mount |
| `mountwalk3_dotdot_mseq` | pass, 88k states | the alternative, an m_seq recheck after path_connected(), closes it as well |
| `mountwalk_vacate_fullmount` | pass, 901k states | vacate against a mount of a whole filesystem, without the fix: the stale root is its own d_parent, the walker stays on the old root and sees the tree of an instant before the swap, which is a legitimate result; the race needs a bind mount whose root has a parent |
| `mountwalk3_fixed_umount`, `mountwalk3_fixed_move` | pass, 145k and 236k states | the bind layout under the lazy umount and the move |
| `mountwalk3_weak_vacate` | pass, 102,850 states | weakly ordered memory (`WEAK_VACATE`): vacate_mount()'s stores of mnt_sb and mnt_root become visible in either order and every load the d_parent branch makes returns the old or the new value on its own; with the fix no combination lets the walk out of the bind: a new mnt_sb fails the superblock test, an old one with a new mnt_root fails the s_root test and is_subdir() against the knullfs root, an old one with the old root is the pre-series logic on a dentry above the bind's root |
| `mountwalk3_weak_no_vacant_connected` | `RcuResultOK` violated, 38,004 states | the race is still there without the fix |
| `mountwalk3_weak_dotdot_mseq`, `mountwalk_weak_vacate_fullmount` | pass, 109,374 and 1,095,119 states | the m_seq alternative holds under weak ordering (read_seqretry()'s smp_rmb() orders the loads before the seqcount), and a whole-filesystem mount cannot be climbed past whatever the loads return |

### MntVacant (local runs, 2026-09-24, rerun after the teardown witness was added)

The layout is P, the root of a lazily unmounted subtree, with M attached
to it and G attached to M, all out of every namespace and left attached
(UMOUNT_CONNECTED, or M and G locked), at the moment namespace_unlock()
drops namespace_sem.  M's filesystem pins P (a loop device's backing file
on P) and G's pins M; H1 holds a file on P, H2 one on M; W1 walks from a
holder's file into the mount below it; D removes the mountpoint of M or
of G.  Every mount_lock section is one step, cleanup_mnt() items run in
any order, memory is sequentially consistent (the increment/sum pair of
__legitimize_mnt() and the slow path is MntPut's), RCU readers and grace
periods are explicit.  Deadlock detection is on for the green runs.

| Configuration | Result | Meaning |
|---------------|--------|---------|
| `mntvacant_fixed` | pass, 14,528,836 states | the series with every piece in place, both holders, the pins, the walker and the rmdirs: nothing is put below zero, no mount is freed twice or while hashed or while anything refers to it, the handoff between the release visit and the last put frees exactly once, a hashed mount is always referenced and never doomed, no walk lands in a covered directory, lookup_mnt() never spins, and once everything from outside is gone every mount is freed and every filesystem is down |
| `mntvacant_fixed_nopins`, `mntvacant_fixed_noholder`, `mntvacant_fixed_walk2`, `mntvacant_fixed_2walkers` | pass, 11,624,674, 10,276, 93,143,698 and 128,197,398 states | the same without the pins, without holders, with two walks in a row, and with two walkers at once |
| `mntvacant_count_two` | pass, 14,927,104 states | the earlier design (two references at vacate_mount(), the release visit ends in mntput()) is sound as well; the handoff only saves the second slow path |
| `mntvacant_tree_order`, `mntvacant_holder_early` | pass, 283 and 286 states, `NoVacate` holds | a subtree nobody holds collapses without a single vacate when the puts go parents first; with the subtree root's holder closing before the puts (dissolve_on_fput() dropping the file's reference under namespace_sem, ksys_unshare() freeing the old fs_struct first) the same |
| `mntvacant_holder_late` | `NoVacate` violated, 34 states | the old order: the file's reference on the root outlives the puts of its children, every child is vacated, then unhashed and put again by the root's cleanup |
| `mntvacant_holder_early_walk` | `NoVacate` violated, 311 states | with a walker present the early order still vacates now and then: a walker that legitimized the dead parent keeps it alive for a moment while its child is put; a transient reference like any other, not a defect |
| `mntvacant_lifo` | `NoNeedlessVacate` violated, 4 states | children before parents (the hlist order upstream builds): G is put while M lives on the reference U has not dropped yet, vacated for nothing |
| `mntvacant_upstream` | `Reaped` violated, 248 states | upstream's ownership: U's put of P leaves it alive on the pin, H1's close too, M is owned by P and never put, its filesystem never releases the pin (Michael Vogt's report, 6 steps) |
| `mntvacant_upstream_nopins` | pass, 2,589,796 states | without pins upstream's ownership is fine: the invariants are not tuned to the series |
| `mntvacant_doom` | `NoWarn` violated (`doomed_attached`), 96 states | own references without vacate_mount(): the last put of M while P is held dooms M in place; it stays hashed, its cleanup frees it under the parent's list, a later lookup_mnt() would spin on it and the parent's final put would touch freed memory |
| `mntvacant_unhash` | `NoReveal` violated, 153 states | disconnecting at the last put instead: a walk from the file on P finds nothing at M's mountpoint and continues in the directory M covered |
| `mntvacant_stuck_all` | `NoNegative` violated, 1,159 states | the parent's final put owning every unhashed child: M is put by namespace_unlock() and by P's cleanup |
| `mntvacant_detach_no_put` | `Reaped` violated, 799,643 states | __detach_mounts() unhashing a vacant mount without putting it: G is vacated, rmdir of its mountpoint unhashes it, nobody puts the parent's reference again |
| `mntvacant_detach_put_all` | `NoNegative` violated, 1,034 states | __detach_mounts() putting every unmounted mount it unhashes, as upstream: a mount holding its own reference is put twice |
| `mntvacant_handoff_unlocked` | `NoWarn` violated (`double_free`, `use_after_free`), 34,650 states | the first draft of the handoff, deciding after mount_lock is dropped: the last put and the release visit each find the other's mark and both free, the second one reading a mount already handed to call_rcu() |
| `mntvacant_handoff_first` | `NoDangling` violated, 13,757 states | the release visit handing off before it puts the stuck children: the last put has already come, the handoff frees the mount and the visit goes on to walk its stuck list |
| `mntvacant_witness_*` | fire | the runs above cover a vacate (`vacate`), a vacate by a walker's put (`walker_vacate`), a pin drop's put dooming the parent (`pin_doom`), the last put coming before the release visit and after it (`put_first`, `release_first`), and a vacant mount put through rmdir (`detach_put`) |
| `mntvacant_witness_rcu_teardown`, `mntvacant_witness_rcu_teardown_upstream` | fire, 4,244 and 3,781 states | an RCU walker that crossed into M through the hash from the file on P is still on M's dentries when the filesystem M carried is torn down: with the series through the release visit after U's put vacated M, upstream through the stuck children (P's final put unhashes M and its cleanup puts M, with no grace period in between).  The class exists on both sides; what makes it safe is the RCU-pathwalk contract (053fc4f755ad and the rest of the 2023 series: what an RCU-mode callback may touch is freed under RCU), not a grace period, and the series adds no requirement mainline does not already have |

Two things the green runs say beyond the invariants: `put_doomed` never
fired, so no put ever reaches zero on a doomed mount (the early return in
the slow path is defensive), and no run needed the kernel's per-task LIFO
order of task work: the release visits and cleanups may run in any order.

What is covered elsewhere or not at all: the store-buffer argument for
__legitimize_mnt()'s increment against the slow path's sum is MntPut's
(`kernel/mount/`); the RCU walk's climb out of a vacated bind mount and
the weakly ordered loads and stores around vacate_mount() are the
MountWalk section above; the teardown of the filesystem a vacated mount
carried while an RCU walker is still inside it is the witness pair above;
the fsnotify accounting of the prep patch and the two put-order patches
beyond their effect on the number of vacates are not modelled.

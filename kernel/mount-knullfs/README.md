# TLA+ models of the vacant-mount series (work.mount.knullfs.4)

Tree: work.mount.knullfs.4 at 095b9753ac15, the b4 cover on top of the
documentation commit eca972c8f1d8, the selftests, the fixup 757a689090dd
(the last put of a vacant mount decided under mount_lock) and the
mechanism commit ba922416101e "namespace: prevent UMOUNT_CONNECTED
reference count cycles", with the fsnotify prep a23a2e46164a, on
vfs-7.4.mount b4698e50d460 (which holds the revert of 0342482a4d15, the
split per-CPU counters and the two put-order fixes): every victim of
umount_tree() keeps its own reference, namespace_unlock() drops those from
task work in tree order with each cleanup inline, a mount that loses its
last reference while still attached is vacated in place (vacate_mount()),
its parent's final put drops the references of its vacant children right
after its mount_lock section, __detach_mounts() cuts a vacant mount loose
on `disowned` and namespace_unlock() puts it with no grace period, the last
put of a vacant mount and the release of the filesystem it carried hand the
free to whoever comes second (mntput_final_locked() and
vacant_mount_released(), both deciding under mount_lock), a mark's
accounting follows the superblock recorded in its connector, and
path_connected() fails for a dentry of another superblock than the mount's.
The series is not in mainline; the mainline models are in `kernel/mount/`,
whose conventions this directory follows.

`MountWalk.tla` here is `kernel/mount/MountWalk.tla` plus the vacate change
(`CHANGE = "vacate"`, `FIX_VACANT_CONNECTED`, `FIX_DOTDOT_MSEQ`,
`WEAK_VACATE`, the `sb` field of the mount record, the `NewRoot` and
`NullSb` constants); diff the two files to see the delta.  `MntVacant.tla`
is written for the series alone, with upstream's ownership as a switch.

## Files

| File | What it is |
|------|------------|
| `MountWalk.tla`, `MC_mountwalk.tla`, `MC_mountwalk3.tla` | Family B: the RCU path walk (path_init(), __follow_mount_rcu() with __lookup_mnt()'s possible miss while a writer runs and the rechecks after a hop and a miss, follow_dotdot_rcu()/choose_mountpoint_rcu() with its recheck and path_connected() over the current mnt_root and mnt_sb before the step to d_parent, step_into()'s -ENOENT on a negative dentry with no recheck, handle_dots()'s scoped -EAGAIN, complete_walk()'s legitimization, -ECHILD restarts in REF mode with lookup_mnt()/choose_mountpoint()) against a mounter (d_set_mounted(), then the write section; the mounts it makes may be bind mounts of a subdirectory), a lazy umount (unhash, DCACHE_MOUNTED cleared, synchronize_rcu(), the put that frees), a move (unhash, new parent and mountpoint, rehash) and vacate_mount() (mnt_sb, then mnt_root pointed at knullfs, inside the slow path's mount_lock section, the mount still hashed under its parent), each section one store per step |
| `MntVacant.tla`, `MC_mntvacant.tla` | Family B: the vacant-mount protocol of work.mount.knullfs.4. An unmounted subtree left attached (P disconnected, M under it, G under M, all MNT_UMOUNT and out of every namespace), from namespace_unlock()'s up_write() on: its synchronize_rcu_expedited() and the puts of `unmounted` in tree order from mntput_unmounted_work(); mntput_slow() -> mntput_final_locked() with the last put of an attached mount vacating it in place (vacate_mount(): children unhashed, mnt_sb/mnt_root/the instance list moved to knullfs, one reference for the parent, the release pending) and the putting task dropping the references of the vacant children right after the section (mntput_list()); the last put of a vacant mount with its verdict under mount_lock; cleanup_mnt() as task work in any order (the filesystem's release, the free, or the release of a vacant mount ending in vacant_mount_released()); holders closing files on P or M and placing fanotify mount marks (fanotify_mark(FAN_MARK_MOUNT), refused on knullfs); RCU walkers from a holder's file into the mount below (__lookup_mnt(), __legitimize_mnt() with its lock_mount_hash() path, mntput(), the REF walk after -ECHILD); vfs_rmdir() of a mountpoint (__detach_mounts() unhashing the mount there and cutting it loose on `disowned` if vacant, namespace_unlock() putting it without a grace period); superblocks that pin a mount through a file (the loop image on P, an image inside it on M), dropped when the superblock is deactivated; fsnotify's per-superblock watched-objects accounting and fsnotify_sb_delete()'s wait for it; knullfs as a superblock that is never released; RCU grace periods and call_rcu() frees |
| `*.cfg` | TLC configurations from `gen-cfgs.py`; the header says what to expect |
| `check.sh`, `show-walk-trace.py`, `show-vacant-trace.py` | run one configuration; print a counterexample compactly |

## Switches

`MountWalk.tla` (the mainline switches are documented in `kernel/mount/README.md`):

| Constant | Off means |
|----------|-----------|
| `FIX_VACANT_CONNECTED` | path_connected() trusts mnt_root and mnt_sb as it did before work.mount.knullfs: a knullfs mount with a dentry of the superblock it stood in for counts as connected; on, it fails for that pair |
| `FIX_DOTDOT_MSEQ` (off by default) | on: follow_dotdot_rcu() rechecks m_seq after path_connected() on the d_parent step, the alternative fix; the tree does not have it |
| `CHANGE` | what happens to the first new mount: "none", "umount", "move" or "vacate" |
| `WEAK_VACATE` (off by default) | on: weakly ordered memory around vacate_mount(): its two stores, mnt_sb and mnt_root, become visible in either order, and every load follow_dotdot_rcu() and path_connected() make on the d_parent branch, which has no recheck, returns the old or the new value on its own once a write section has run since the walker's m_seq sample (path_init()'s smp_rmb() keeps loads after the sample; the recheck's smp_rmb() keeps the validated loads consistent) |

What `MountWalk.tla` checks beyond the mainline invariants: `NoVacantEscape`
(a ".." lands on a dentry outside the mount it is taken in: outside the
subtree of its root and of the root it had before it was vacated).

`MntVacant.tla`:

| Constant | Off means |
|----------|-----------|
| `FIX_OWN_REF` | upstream's ownership: an attached victim is owned by its unmounted parent, whose cleanup_mnt() puts every child its final put unhashed (the stuck children); `unmounted` holds only the disconnected victims |
| `VACATE_MODE` | `"vacate"` is the series; `"doom"` keeps upstream's slow path with the own references: the last put of an attached mount sets MNT_DOOMED in place and frees it while it is still hashed; `"unhash"` disconnects it instead, revealing what it covered |
| `FIX_PUT_VACANT_ONLY` | the parent's final put puts every child it unhashed, although the children hold their own references |
| `FIX_TREE_ORDER` | namespace_unlock() puts the children before the parent (the hlist order upstream builds) |
| `FIX_DETACH_PUTS_VACANT` | __detach_mounts() never puts a vacant mount it unhashes; `DETACH_PUTS_ALL` on: it puts every unmounted mount it unhashes (upstream's line kept) |
| `FIX_DISOWNED` | a vacant mount __detach_mounts() cut loose rides the unmounted list (a grace period, then the put from task work carried in the first mount's mnt_rcu) instead of `disowned`; the carrier's mnt_rcu is the union its pending release sits in, so that release is lost |
| `FIX_HANDOFF_LOCKED` | the release reads MNT_DOOMED and the last put reads mnt_old_root after dropping mount_lock (the first draft of the handoff) |
| `FIX_LAST_UNDER_LOCK` | mntput_slow() decides whether the last put of a vacant mount frees it from the flags re-read after unlock_mount_hash() (the shape before the fixup 757a689090dd) instead of while it holds mount_lock |
| `FIX_CONN_SB` | a mark's accounting is taken back from the superblock the vfsmount points at when the mark goes, knullfs for a vacated mount, instead of the one recorded in its connector (the fsnotify prep a23a2e46164a) |
| `FIX_MARK_GATE` | fanotify takes mount marks on a knullfs mount instead of refusing them (SB_NOUSER) |
| `RELEASE_PUTS` (a variant, not a fix) | on: the earlier design: vacate_mount() takes two references and the release ends in mntput() instead of the handoff |
| `HOLDER_ORDER` | `"any"`; `"early"`: the holder of the subtree root closes before U's puts, which is what dissolve_on_fput() dropping the file's reference under namespace_sem and ksys_unshare() freeing the old fs_struct before the old namespaces amount to; `"late"`: after U is done, the old order |
| `Marks` (off by default) | on: holders may place a mount mark on their mount or the one below it before they close |
| `U_INLINE` (off by default) | on: U runs the cleanup of each final put to completion before its next put and the puts it owes come first, the shape of mntput_unmounted_work(); off: cleanups run in any order, a superset |

What `MntVacant.tla` checks: `NoNegative` (the WARN_ON(count < 0) of
mntput_slow(): no mount is put more often than it was referenced),
`NoWarn` (the VFS_WARN_ON_ONCEs of mntput_final_locked() and
free_vacant_mount() and the model's own marks: a vacant mount put while
attached, freed with children, stuck children or marks, on an instance
list or hashed, freed twice, used after call_rcu(), doomed while
attached, a filesystem released twice, a final put on a doomed mount, a
free with the release still pending), `ExactlyOnce` (every mount is
freed once and releases its filesystem once), `NoDangling` (nothing
refers to a freed mount: hash, instance list, parent pointers, stuck
lists, put lists, owed puts, checks, pins, marks, task work, holders,
walkers holding it), `HashedHasRef` (a hashed mount is referenced and
never doomed: what keeps the covered directory covered), `DoomedIsLast`,
the reference count rules `OwnRefOnRing` (a mount whose own reference is
still to be dropped is neither vacant nor doomed and referenced) and
`VacantCount` (a vacant mount is held by exactly its parent's reference,
in flight once the parent unhashed it, plus the walkers that legitimized
it, and by nothing else), `VacantOK`, `KnullfsOK` (only vacant mounts
stand on knullfs' instance list, a vacant mount has no children, and
knullfs is never released), `NoVacantOnRing` (a vacant mount never rides
the unmounted list), `NoReveal` (no walk lands in the directory a mount
covered), `NoHang` (lookup_mnt() never spins on a hashed doomed mount),
the fsnotify rules `NoNegativeWatch`, `NoTeardownHang` (no release waits
in fsnotify_sb_delete() for a count that never drops) and
`WatchedBalanced`, `Reaped` (once every reference from outside is gone
and every deferred piece of work has run, every mount is freed and every
filesystem is down: no cycle kept anything), deadlock freedom, and the
witnesses `NoVacate`, `NoNeedlessVacate` (a vacate the put order alone
caused: the parent lived on the reference U had not dropped yet),
`NoWalkerVacate`, `NoPinDoom`, `NoPutFirst`, `NoReleaseFirst`,
`NoDetachPut`, `NoNullSeen` (no walk lands on the knullfs stand-in),
`NoMarkRefused`, `NoLostRelease`, `NoRcuTeardown`.

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar
    TLC_DEADLOCK=check ./check.sh mountwalk3_fixed_vacate 4   # seconds
    TLC_DEADLOCK=check ./check.sh mntvacant_fixed 4           # 6M states, a minute or two
    TLC_DEADLOCK=check ./check.sh mntvacant_fixed_2walkers 8  # 60M+ states, minutes; needs a big /tmp or TLC_METADIR elsewhere

## Results

### MountWalk against vacate_mount() (jens, 2026-09-28; the path walk and vacate_mount() are unchanged since 09-24, the counts are identical)

work.mount.knullfs.4 keeps an unmounted mount attached to its unmounted
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
| `mountwalk3_no_vacant_connected` | `RcuResultOK` violated, 32,185 states | the race: W1 crosses into the bind at (2, pub), the changer swaps mnt_sb and mnt_root to knullfs, W1's ".." climbs to (2, F), the root of the source filesystem, and its "x" hits the negative dentry there: -ENOENT for a path that resolves to (1, X) at every instant, before and after the vacate |
| `mountwalk3_witness_vacant` | `NoVacantEscape` violated, 17,949 states | the same climb, caught at the ".." step |
| `mountwalk3_fixed_vacate` | pass, 82,598 states | the series' path_connected(): it fails for a knullfs mount and a dentry of another superblock, the walker gets -ECHILD and restarts in REF mode, where it crosses into the vacant mount properly; every RCU result equals the sequential walk, no ".." ever leaves its mount |
| `mountwalk3_dotdot_mseq` | pass, 87,934 states | the alternative, an m_seq recheck after path_connected(), closes it as well |
| `mountwalk_vacate_fullmount` | pass, 901,285 states | vacate against a mount of a whole filesystem, without the fix: the stale root is its own d_parent, the walker stays on the old root and sees the tree of an instant before the swap, which is a legitimate result; the race needs a bind mount whose root has a parent |
| `mountwalk3_fixed_umount`, `mountwalk3_fixed_move` | pass, 144,668 and 236,189 states | the bind layout under the lazy umount and the move |
| `mountwalk3_weak_vacate` | pass, 102,850 states | weakly ordered memory (`WEAK_VACATE`): vacate_mount()'s stores of mnt_sb and mnt_root become visible in either order and every load the d_parent branch makes returns the old or the new value on its own; with the fix no combination lets the walk out of the bind: a new mnt_sb fails the superblock test, an old one with a new mnt_root fails the s_root test and is_subdir() against the knullfs root, an old one with the old root is the pre-series logic on a dentry above the bind's root |
| `mountwalk3_weak_no_vacant_connected` | `RcuResultOK` violated, 43,563 states | the race is still there without the fix |
| `mountwalk3_weak_dotdot_mseq`, `mountwalk_weak_vacate_fullmount` | pass, 109,374 and 1,095,119 states | the m_seq alternative holds under weak ordering (read_seqretry()'s smp_rmb() orders the loads before the seqcount), and a whole-filesystem mount cannot be climbed past whatever the loads return |

### MntVacant (the green runs on jens, the rest local, 2026-09-28)

The layout is P, the root of a lazily unmounted subtree, with M attached
to it and G attached to M, all out of every namespace and left attached
(UMOUNT_CONNECTED, or M and G locked), at the moment namespace_unlock()
drops namespace_sem.  M's filesystem pins P (a loop device's backing file
on P) and G's pins M; H1 holds a file on P, H2 one on M; W1 walks from a
holder's file into the mount below it; D removes the mountpoint of M or
of G.  Every mount_lock section is one step, a task that made a final put
drops the references of the vacant children right after it and before
anything else, cleanup_mnt() items run in any order (a superset of the
kernel's; `U_INLINE` narrows U to the task-work shape), memory is
sequentially consistent (the increment/sum pair of __legitimize_mnt() and
the slow path is MntPut's), RCU readers and grace periods are explicit.
Deadlock detection is on for the green runs.  The counts are smaller
than those of the 09-24 model of the v1 tree: a stuck list and a second
slow-path round trip per vacant child are gone, and the owed puts follow
their final put right away.

| Configuration | Result | Meaning |
|---------------|--------|---------|
| `mntvacant_fixed` | pass, 6,262,506 states | the series with every piece in place, both holders, the pins, the walker and the rmdirs: nothing is put below zero, no mount is freed twice or while hashed or while anything refers to it, the handoff between the release and the last put frees exactly once, a hashed mount is always referenced and never doomed, the reference count rules hold, a vacant mount has no children and stands on knullfs' list alone, no walk lands in a covered directory, lookup_mnt() never spins, and once everything from outside is gone every mount is freed and every filesystem is down |
| `mntvacant_fixed_nopins`, `mntvacant_fixed_noholder`, `mntvacant_fixed_walk2`, `mntvacant_fixed_2walkers` | pass, 3,610,412, 3,952, 49,672,812 and 69,565,302 states | the same without the pins, without holders, with two walks in a row, and with two walkers at once |
| `mntvacant_fixed_inline` | pass, 5,428,328 states | the task-work shape of mntput_unmounted_work(): each final put's owed puts and cleanup before the next put |
| `mntvacant_count_two` | pass, 6,507,880 states | the earlier design (two references at vacate_mount(), the release ends in mntput()) is sound as well; the handoff only saves the second slow path |
| `mntvacant_marks` | pass, 18,623,440 states | holders place mount marks on P, on M and on the stand-in of a vacated M: the marks placed before a vacate are taken back from the superblock the connector recorded, every release finds its superblock's count at zero, the stand-in refuses marks, and every count is back at zero at the end |
| `mntvacant_tree_order`, `mntvacant_holder_early` | pass, 151 and 154 states, `NoVacate` holds | a subtree nobody holds collapses without a single vacate when the puts go parents first; with the subtree root's holder closing before the puts (dissolve_on_fput() dropping the file's reference under namespace_sem, ksys_unshare() freeing the old fs_struct first) the same |
| `mntvacant_holder_late` | `NoVacate` violated, 34 states | the old order: the file's reference on the root outlives the puts of its children, every child is vacated, then unhashed and put again by the root's final put |
| `mntvacant_holder_early_walk` | `NoVacate` violated, 259 states | with a walker present the early order still vacates now and then: a walker that legitimized the dead parent keeps it alive for a moment while its child is put; a transient reference like any other, not a defect |
| `mntvacant_lifo` | `NoNeedlessVacate` violated, 4 states | children before parents (the hlist order upstream builds, and the order handle_locked() emits locked propagated copies in): G is put while M lives on the reference U has not dropped yet, vacated for nothing |
| `mntvacant_upstream` | `Reaped` violated, 117 states | upstream's ownership: U's put of P leaves it alive on the pin, H1's close too, M is owned by P and never put, its filesystem never releases the pin (Michael Vogt's report) |
| `mntvacant_upstream_nopins` | pass, 1,837,144 states | without pins upstream's ownership is fine: the invariants are not tuned to the series |
| `mntvacant_doom` | `NoWarn` violated (`doomed_attached`), 50 states | own references without vacate_mount(): the last put of M while P is held dooms M in place; it stays hashed, its cleanup frees it under the parent's list, a later lookup_mnt() would spin on it and the parent's final put would touch freed memory |
| `mntvacant_unhash` | `NoReveal` violated, 157 states | disconnecting at the last put instead: a walk from the file on P finds nothing at M's mountpoint and continues in the directory M covered |
| `mntvacant_put_all` | `OwnRefOnRing` violated, 458 states | the parent's final put putting every child it unhashed: M, still on the unmounted list with its own reference, is put and vacated by P's final put, and put again by namespace_unlock() |
| `mntvacant_detach_no_put` | `VacantCount` violated, 233 states | __detach_mounts() unhashing a vacant mount without putting it: G is vacated, rmdir of its mountpoint unhashes it, the parent's reference stays on a mount nobody will put (`Reaped` later) |
| `mntvacant_detach_put_all` | `OwnRefOnRing` violated, 64 states | __detach_mounts() putting every unmounted mount it unhashes, as upstream: a mount holding its own reference is put twice |
| `mntvacant_ring_carrier`, `mntvacant_ring_carrier_lost` | `NoVacantOnRing` violated, 229 states; `Reaped` violated, 2,804 states | a vacant mount __detach_mounts() cut loose riding the unmounted list: the list's first mount carries the task work in its mnt_rcu, the union the pending release of a vacant mount sits in, so the release is lost, the filesystem the mount carried stays up and its pin keeps the parent for good (the perf.2 bug of 09-27, reproduced with vacant_race_demo) |
| `mntvacant_handoff_unlocked` | `NoWarn` violated (`double_free`, `use_after_free`), 12,028 states | the first draft of the handoff, deciding after mount_lock is dropped: the last put and the release each find the other's mark and both free, the second one reading a mount already handed to call_rcu() |
| `mntvacant_last_unlocked` | `NoWarn` violated (`release_pending_at_free`), 1,892 states | mntput_slow() before the fixup: the flags are re-read after unlock_mount_hash(), P's final put cuts and dooms the M it just vacated in that window, the check sees a vacant doomed mount and frees it with the release never queued: M's filesystem is never released and its pin keeps P (`Reaped` later) |
| `mntvacant_marks_no_conn_sb` | `NoNegativeWatch` violated, 3,002 states | the fsnotify accounting from the object's current superblock: the mark of a vacated M is taken back from knullfs, whose count goes below zero, while M's old superblock keeps a count that never drops and its release would wait in fsnotify_sb_delete() for good (`NoTeardownHang`) |
| `mntvacant_marks_no_gate` | `NoWarn` violated (`free_marks`), 25,668 states | fanotify taking marks on the stand-in: a mark placed after the release is never cleared, free_vacant_mount() warns and knullfs' count never returns to zero |
| `mntvacant_witness_*` | fire, 290 to 6,900 states | the runs above cover a vacate (`vacate`), a vacate by a walker's put (`walker_vacate`), a pin drop's put dooming the parent (`pin_doom`), the last put coming before the release and after it (`put_first`, `release_first`), a vacant mount put through rmdir (`detach_put`), a walk landing on the knullfs stand-in (`null_seen`), and fanotify refusing a mark on it (`mark_refused`) |
| `mntvacant_witness_rcu_teardown`, `mntvacant_witness_rcu_teardown_upstream` | fire, 1,834 and 3,628 states | an RCU walker that crossed into M through the hash from the file on P is still on M's dentries when the filesystem M carried is torn down: with the series through the release after U's put vacated M, upstream through the stuck children (P's final put unhashes M and its cleanup puts M, with no grace period in between).  The class exists on both sides; what makes it safe is the RCU-pathwalk contract (053fc4f755ad and the rest of the 2023 series: what an RCU-mode callback may touch is freed under RCU), not a grace period, and the series adds no requirement mainline does not already have |

Two things the green runs say beyond the invariants: `put_doomed` never
fired, so no put ever reaches zero on a doomed mount (the early return in
mntput_final_locked() is defensive), and the superset of cleanup orders
passes, so the kernel's per-task order of task work is not what the
protocol relies on.

What is covered elsewhere or not at all: the store-buffer argument for
__legitimize_mnt()'s increment against the slow path's sum is MntPut's
(`kernel/mount/`), and the grace period before the own references are
dropped against mntput_no_expire()'s fast path is
`kernel/mount-gp-on-demand/`; the RCU walk's climb out of a vacated bind
mount and the weakly ordered loads and stores around vacate_mount() are
the MountWalk section above; the teardown of the filesystem a vacated
mount carried while an RCU walker is still inside it is the witness pair
above; the fresh unique mount id of a stand-in, the mnt_pins of a vacated
mount and the order of locked propagated copies beyond their effect on
the number of vacates are not modelled.

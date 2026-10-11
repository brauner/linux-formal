# TLA+ models of superblock freezing and the block-layer holder operations

Tree: work.super.fixes at fc1c25014ff8 ("Merge tag 'fsverity-for-linus'",
v7.3-rc6-301, identical to vfs master).  Every line number below is at that
commit (`git show fc1c25014ff8:<file>`); fs/super.c unless a file is named.
The branch has since moved on ("super: don't put the remount context under
s_umount" and "quota: really wait for the thaw in quotactl_block()", which
adds `sb_freeze_wake()` and a new `s_writers.frozen` waiter in
quotactl_block()); `HAS_QWAIT` models that waiter, nothing else here follows
the newer tree.

Two models:

* **SuperFreeze** -- one superblock: freeze_super(), thaw_super_locked(),
  may_freeze()/may_unfreeze(), the three percpu rwsems of `s_writers` and
  the writers holding them, `s_umount`, `s_active` and the one active
  reference all freezers share, wait_for_partially_frozen() and its
  wakeups (optionally with the frozen store sitting in a store buffer),
  remount, umount, the emergency thaw's thaw_super_locked(), and filesystems
  that set SB_RDONLY on an error without `s_umount`.
* **SuperHolder** -- devices and superblocks: bdev_freeze()/bdev_thaw(),
  `bd_fsfreeze_count` with its sign-encoded denies, `bd_fsfreeze_mutex`,
  the holder ops, fs_bdev_freeze()/fs_bdev_thaw() walking the device table,
  the mount of a block-device superblock (sget_dev(), setup_bdev_super(), an
  extra device opened in fill_super()), umount (kill_block_super()),
  device-mapper suspend/resume, the shutdown ioctls, FIFREEZE/FITHAW, the
  emergency thaw with its bdev_thaw() loop, a btrfs-like device add/remove
  under bdev_deny_freeze(), and devices shared by two read-only superblocks
  (erofs).  A superblock's freeze is one step here; SuperFreeze checks what
  happens inside it.

The device table's RCU walks, pins and claims are modelled precisely in
SuperDevTable (see README.md); SuperHolder abstracts the table to a set of
(device, superblock) entries and checks the freeze semantics on top.

## Findings

Status as of the model runs; [`../README.md`](../README.md) says what became of each finding.

| # | What | Configurations | Classification |
|---|------|----------------|----------------|
| F1 | A sync_blockdev() failure at the end of fs_bdev_freeze() (L1578-1579) after the walk froze the superblocks makes bdev_freeze() fail and drop `bd_fsfreeze_count` (block/bdev.c L325-326), but every superblock stays frozen with a hold nobody owns: dm's lock_fs() failed so unlock_fs() never runs (drivers/md/dm.c L2996-3000), the shutdown ioctls return early (fs/ext4/ioctl.c L826-828; xfs_fs_goingdown() fs/xfs/xfs_fsops.c L457 even returns 0 without shutting down) | `holder_one_sync`; fixed by thawing what the walk froze: `holder_one_sync_rollback`, `holder_multi_all_fixed` | real kernel bug since v6.8 (fbcb8f39e96d "bdev: surface the error from sync_blockdev()" with 49ef8832fb1a; 7a7ef107b449 kept "a sync_blockdev() failure is always reported") |
| F2 | A superblock thawed behind the block layer's back makes the device's next bdev_thaw() fail (fs_bdev_thaw() returns thaw_super()'s -EINVAL for a single superblock, L1605-1618) and bdev_thaw() keeps `bd_fsfreeze_count` (block/bdev.c L367-368); dm's unlock_fs() ignores it (dm.c L2948-2954).  The count never drops again: the device can never be mounted (L1811-1815, extra devices L1668-1673), bdev_deny_freeze() refuses (btrfs device add/remove/replace), and every later bdev_freeze() nests (block/bdev.c L311-314) without freezing the filesystem, so a dm snapshot taken then is of a live filesystem.  Triggers: (a) FITHAW from a task that did not freeze while a block-device freeze holds `freeze_ucount` (FIFREEZE and FREEZE_MAY_NEST\|FREEZE_HOLDER_USERSPACE share it; may_unfreeze() only checks `freeze_ucount > 0`, L2186-2187); (b) the emergency thaw on a filesystem frozen through a device that is not `s_bdev` (xfs log/rt, ext4 journal, btrfs/f2fs members, erofs extra devices): do_thaw_all_callback() loops bdev_thaw() on `s_bdev` only (L1210-1212) and thaw_super_locked(USERSPACE) (L1215) takes the other device's hold; (c) the emergency thaw racing a dm suspend of `s_bdev` between that loop and thaw_super_locked(); (d) xfs_dax_notify_failure_thaw()'s unconditional USERSPACE thaw (fs/xfs/xfs_notify_failure.c L161) | (a) `holder_one_steal`, `holder_one_steal_count`, `freeze_steal`; (b) `holder_multi_ethaw`, `holder_shared_ro` (the next mount using the shared device fails in the trace); (c) `holder_one_ethaw`; fixed for the count by letting fs_bdev_thaw() treat -EINVAL (no userspace hold left) as thawed: `holder_one_steal_fixed`, `holder_one_ethaw_fixed`, `holder_multi_ethaw_fixed`, `holder_shared_ro_fixed`, `holder_multi_all_fixed` | real kernel bug, the consequence fe967191e585 fixed for the nested case; (a) is long-standing (pre-6.8 thaw_bdev() restored the count on a failed thaw_super() too), (b) since freezes propagate from every device (7366f8b6fc6a, v6.8).  The thaw under a suspended dm device itself (`FrozenWhileHeld` in `holder_one_steal`) is the long-standing meaning of a shared `freeze_ucount`; fe967191e585's "Thawing without holding a freeze still fails with -EINVAL" does not hold while a block-device freeze holds `freeze_ucount` |
| F3 | thaw_super_locked() decides by sb_rdonly() at thaw time (L2366-2371) whether the freeze took the `s_writers` rwsems, but jfs (fs/jfs/super.c L77, errors=remount-ro by default), nilfs2 (fs/nilfs2/super.c L145, default), ext2 (fs/ext2/super.c L79), fat (fs/fat/misc.c L38), exfat (fs/exfat/misc.c L44), hfs, hfsplus, affs and gfs2 set SB_RDONLY on an error without `s_umount`.  An error between a full freeze and its thaw leaves the three rwsems write-held for good: every later sb_start_write()/sb_start_pagefault()/sb_start_intwrite() sleeps uninterruptibly (mnt_want_write() takes sb_start_write() before it looks at the read-only flag, so even a write attempt that should get -EROFS hangs), a later read-write remount hangs every writer, the next freeze blocks in percpu_down_write() forever (holding `bd_fsfreeze_mutex` when it comes from dm) | `freeze_ro_async`; fixed by remembering how the freeze was taken: `freeze_ro_async_fixed`, `freeze_ro_async_mix` | real; known class (d3476f3dad4a, v6.12, stopped ext4 from doing this after syzbot hit freeze warnings), still open for the filesystems listed; FIFREEZE on jfs/nilfs2, a read that hits corruption, FITHAW |
| F4 | On a device shared by several superblocks a per-superblock freeze error is swallowed (L1576-1577): the device counts as frozen with that superblock unfrozen, and fs_bdev_thaw() later thaws it anyway, taking a FIFREEZE hold its owner still counts on | `holder_shared_fail`, `holder_shared_steal`; before 7a7ef107b449 the error failed bdev_freeze() and left the others frozen: `holder_shared_noswallow` | documented and intended by 7a7ef107b449; latent: only erofs shares devices (holder = the file_system_type), erofs is read-only so its freeze cannot fail (L2279-2287), and erofs has no ->freeze_fs so FIFREEZE returns -EOPNOTSUPP (fs/ioctl.c L393-394) |
| F5 | btrfs -o degraded: a member's registration refused because the device is frozen (L1668-1673) was visible in the table between super_dev_insert() (L1664) and the check; a bdev_thaw() walk that pinned it waits for SB_BORN and thaws a superblock that never froze through the device (count stuck, or another device's freeze taken), and a bdev_freeze() walk that pinned it freezes the superblock through a device it then does not hold, so the thaw finds no holder and the superblock stays frozen | `holder_degraded`, `holder_degraded_steal`, `holder_degraded_leak` | the device-table model's `dtdeg_tree`/`dtmultideg_tree`/`dtdrop_tree` reproduced independently; the proposed fs_bdev_thaw() fix covers the stuck count only |
| W1 | No lost wakeup in wait_for_partially_frozen() although wake_up_var(&s_writers.frozen) is called without the smp_mb() its documentation asks for (kernel/sched/wait_bit.c L225-233): the waiter only ever samples SB_FREEZE_WRITE (the only value visible while `s_umount` is dropped, L2289-2293) and the SB_FREEZE_PAGEFAULT store is followed by percpu_down_write()'s atomic_xchg() (kernel/locking/percpu-rwsem.c L89) | `freeze_wake_weak`, `freeze_all_weak` pass; `freeze_wake_nobarrier` shows the lost wakeup without that barrier | benign at fc1c25014ff8 |
| W2 | The quotactl_block() of "quota: really wait for the thaw in quotactl_block()" waits for `frozen == SB_UNFROZEN` on `s_writers.frozen`; that waiter does lose the thaw's wakeup without a full barrier before wake_up_var() -- the `sb_freeze_wake()` smp_mb() of the same change is required | `freeze_qwait_nomb` fails, `freeze_qwait_mb`, `freeze_qwait_ro_mb` pass | the commit carries the smp_mb() |

No deadlock in any configuration of the kernel as it is (`s_umount`,
`bd_fsfreeze_mutex`, `bd_holder_lock`, the freeze levels, writers that take
`s_umount` with SB_FREEZE_WRITE held, kills run from inside a walk); the
freeze counters stay consistent with the frozen state; the exclusive
freeze stays its owner's; the shared active reference is held exactly
while SB_FREEZE_COMPLETE; nothing frozen dies; a mount racing a block
device freeze is either refused or frozen by the walk.  The mutations show
what each piece buys: fe967191e585 (`freeze_nested_ret`,
`holder_one_nested_ret`), 749d7aa0377a (`holder_one_ethaw_locked`), the
drop of `s_umount` around sb_wait_write(SB_FREEZE_WRITE)
(`freeze_drop_umount`), the frozen checks of setup_bdev_super() and
fs_bdev_register() (`holder_one_mountrace_nocheck`,
`holder_multi_xrace_nocheck`), bdev_deny_freeze() and unregister before
allow in btrfs (`holder_btrfs_nodeny`, `holder_btrfs_allow_first`),
may_unfreeze()'s owner check (`freeze_kern_no_owner`).

Every counterexample has a file in `traces/` with the interleaving in words
and the kernel lines.

## Files

| File | What it is |
|------|------------|
| `SuperFreeze.tla` | the freeze protocol of one superblock |
| `SuperHolder.tla` | block device freezes against the superblocks on the devices |
| `MC_freeze.tla`, `MC_holder.tla` | layouts: freezer kinds, writers; devices, superblocks, tasks |
| `freeze_*.cfg`, `holder_*.cfg` | configurations from `gen-cfgs-freeze-holder.py`; line 1 says what to expect, line 2 what the configuration is |
| `gen-cfgs-freeze-holder.py` | writes the configurations |
| `check.sh` | runs one configuration (shared with SuperLife/SuperDevTable; deadlock checking on) |
| `check-all-freeze-holder.sh` | runs all of them and compares with the expectation (`logs/summary-freeze-holder.txt`) |
| `show-trace-freeze-holder.py` | prints a counterexample compactly: per step the action and the fields that changed |
| `traces/freeze_*.txt`, `traces/holder_*.txt` | every counterexample below, explained |

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar      # or the tla2tools.jar symlink here
    ./gen-cfgs-freeze-holder.py
    systemd-run --user --scope -p MemoryMax=6G ./check.sh holder_one_sync 4
    ./show-trace-freeze-holder.py logs/holder_one_sync.log
    SKIP_BIG=1 systemd-run --user --scope -p MemoryMax=6G ./check-all-freeze-holder.sh

Everything but `freeze_all_fail` and `freeze_all_weak` finishes in seconds
to a few minutes with 4-6 workers; those two want a big machine.

## SuperFreeze

### Tasks and the kernel code they stand for

| Action | Kernel |
|--------|--------|
| `FGas`, `TGas` | get_active_super() L1193: super_lock_excl() (waits for SB_BORN\|SB_DYING, fails on SB_DYING, L113-138), atomic_inc_not_zero(&s_active) L1198; for the "bdev" kind from fs_bdev_freeze() L1561 / fs_bdev_thaw() L1606, for "excl" from filesystems_freeze_callback() L1252 / filesystems_thaw_callback() L1280 |
| `FLock` | freeze_super() L2248: super_lock_excl() L2252 (WARN and -EINVAL on SB_DYING), atomic_inc(&s_active) L2256 |
| `FCheck` | L2259-2290: SB_FREEZE_COMPLETE -> may_freeze() L2105 (EXCL takes the owner if frozen, L2113-2131), freeze_inc() L2081, deactivate_locked_super() L2265; partially frozen -> wait_for_partially_frozen() L2269-2277; SB_UNFROZEN and sb_rdonly() -> freeze_inc(), freeze_owner, SB_FREEZE_COMPLETE, wake_up_var(), super_unlock_excl() L2279-2287 (no `s_writers` lock taken); else SB_FREEZE_WRITE L2289 and super_unlock_excl() L2291 (`FIX_DROP_UMOUNT`) |
| `FSw1`/`FSw1w`, `FSw2`/`FSw2w`, `FSw3`/`FSw3w` | sb_wait_write() L2026 = percpu_down_write(): `->block` set by atomic_xchg() (kernel/locking/percpu-rwsem.c L89; new readers block), then the wait for the readers; for SB_FREEZE_WRITE L2292, SB_FREEZE_PAGEFAULT L2297, SB_FREEZE_FS L2311 |
| `FRelock` | __super_lock_excl() L2293, SB_FREEZE_PAGEFAULT L2296 |
| `FSync` | sync_filesystem() L2300; failure: SB_UNFROZEN, sb_freeze_unlock(SB_FREEZE_PAGEFAULT) (the WRITE and PAGEFAULT rwsems), wake_up_var(), deactivate_locked_super() L2301-2306; else SB_FREEZE_FS L2310 |
| `FFreezeFs` | ->freeze_fs() L2313-2324 (failure: SB_UNFROZEN, sb_freeze_unlock(SB_FREEZE_FS), wake_up_var(), deactivate_locked_super()); success: freeze_inc(), freeze_owner, SB_FREEZE_COMPLETE, wake_up_var(), super_unlock_excl() L2329-2334 -- the freezer's active reference becomes the shared one |
| `FWaitEnq`, `FWaitKill`, `FWaitRelock` | wait_for_partially_frozen() L2060-2076: `old = frozen`, up_write(), wait_var_event_killable(frozen != old) (prepare_to_wait_event() queues the task and orders it with set_current_state() before the condition), down_write(), loop while partially frozen; a fatal signal ends it with an error -> deactivate_locked_super() L2272 |
| `FPut`, `TPut`, `EPut` | deactivate_super() L610 of the task's get_active_super() reference (atomic_add_unless(), or s_umount and deactivate_locked_super() L581 for the last one) |
| `TLock` + `ThawLocked` | thaw_super() L2416 (super_lock_excl(), WARN on SB_DYING) -> thaw_super_locked() L2345: not SB_FREEZE_COMPLETE or may_unfreeze() L2142 fails -> -EINVAL L2350-2354; freeze_dec() L2361 leaves holders -> 0 (fe967191e585, `FIX_NESTED_THAW_RET`) L2361-2364; sb_rdonly() -> SB_UNFROZEN, wake_up_var(), deactivate_locked_super() without sb_freeze_unlock() L2366-2371; ->unfreeze_fs() L2375 failing -> freeze_inc() again, -E L2376-2382; else SB_UNFROZEN, wake_up_var(), sb_freeze_unlock(SB_FREEZE_FS), deactivate_locked_super() L2385-2390 |
| `WakeStep`, `RelStep`, `Flush` | with `WEAK_WAKE`: the store to `s_writers.frozen` sits in the store buffer; wake_up_var() -> __wake_up_bit() reads waitqueue_active() without a lock (kernel/sched/wait_bit.c L124-129); the store drains at a full barrier (`SBW_BARRIER`), at the release of `s_umount`, or at any time; `FIX_WAKE_MB` puts an smp_mb() before wake_up_var() |
| `Rogue` | FITHAW (ioctl_fsthaw() fs/ioctl.c L402: thaw_super(FREEZE_HOLDER_USERSPACE)) or a kernel thaw from a task that never froze |
| `EGas`, `ELock`, `EPut` | do_thaw_all_callback() L1204: get_active_super() L1206, [the bdev_thaw() loop L1210-1212 is SuperHolder's], super_lock_excl() + thaw_super_locked(FREEZE_HOLDER_USERSPACE) L1214-1215, deactivate_super() L1216 |
| `WStart`, `WUm`, `WEnd` | __sb_start_write() = percpu_down_read() of the level (include/linux/fs/super.h), a writer that then takes and drops `s_umount` (f2fs_ioc_shutdown(): mnt_want_write_file() then f2fs_do_shutdown()'s down_write(&s_umount), fs/f2fs/file.c L2622/L2588), __sb_end_write() |
| `Remount` | reconfigure_super() L1067 under `s_umount`: -EBUSY unless SB_UNFROZEN L1077-1078; read-only with no writers (sb_prepare_remount_readonly()), or read-write |
| `AsyncRo` | `sb->s_flags \|= SB_RDONLY` from an error handler without `s_umount` (the filesystems under F3) |
| `Umount` | the mount's reference: cleanup_mnt() -> deactivate_super() L610; the last reference -> ->kill_sb(), SB_DYING, kill_super_notify() |
| `QLock`, `QWait`, `QKill` | quotactl_block() for a write command as changed by "quota: really wait for the thaw in quotactl_block()": user_get_super(), while not SB_UNFROZEN drop `s_umount` and wait_var_event_killable(&frozen, frozen == SB_UNFROZEN); at fc1c25014ff8 it waits with sb_start_write()/sb_end_write() instead (fs/quota/quota.c L892-902) |

Freezer kinds: "user" FIFREEZE (FREEZE_HOLDER_USERSPACE, fs/ioctl.c L385);
"bdev" fs_super_freeze()/fs_super_thaw() L1476-1490 (FREEZE_MAY_NEST |
FREEZE_HOLDER_USERSPACE); "kernel" xchk_fsfreeze(), btrfs_ioctl_shutdown(),
f2fs_resize_fs() (FREEZE_HOLDER_KERNEL); "excl" filesystems_freeze()
(FREEZE_EXCL | FREEZE_HOLDER_KERNEL with the owner, L1244-1291).

### Abstractions

* One superblock, one freeze or thaw per freezer (a failed ->unfreeze_fs()
  is retried); writers do one write.
* The percpu rwsems are a reader set and two flags (writer waiting, held);
  their own correctness is assumed.  The rwsems stay held from the freeze
  to the thaw without an owner, as lockdep_sb_freeze_release() says.
* The superblock's lifetime beyond `s_active` (passive references, the
  device table, RCU) is SuperLife's.
* Users of the mount (writers, FIFREEZE, FITHAW, remount, the error) finish
  before the mount's reference goes; "bdev" and "excl" freezers do not need
  the mount.
* Memory is sequentially consistent except for `s_writers.frozen` under
  `WEAK_WAKE` (TSO store buffer of the `s_umount` holder; the waiter's
  enqueue is ordered before its condition by set_current_state()).
* Not covered: ->freeze_super()/->thaw_super() of their own (gfs2), the
  quotactl_block() of fc1c25014ff8 (it spins with sb_start_write() on a
  superblock frozen by the read-only shortcut -- a busy wait, not a
  safety property), lockdep's view of the rwsems.

### Invariants

| Invariant | Meaning |
|-----------|---------|
| `NoErr` | no freeze or thaw of a dying superblock, no deactivate_locked_super() in them dropping the last reference, no kill of a frozen superblock |
| `CountsOK` | SB_FREEZE_COMPLETE exactly while `freeze_kcount + freeze_ucount > 0` |
| `HoldsOK` | the counters are the holds the kernel granted the freezers and did not take back: nobody's hold is taken by a thaw of someone else |
| `BeliefOK` | a freezer that is done was told the truth about whether it still holds a freeze |
| `ActiveOK` | `s_active` = the mount + the tasks' own references + the shared freeze reference, which exists exactly while SB_FREEZE_COMPLETE |
| `ExclOK` | an exclusive freeze keeps its owner and a kernel hold |
| `DeadOK` | a dying superblock is not frozen and holds no level |
| `RwsemOK` | SB_UNFROZEN holds no level and has no writer waiting; SB_FREEZE_COMPLETE holds all three unless it was the sb_rdonly() shortcut |
| `NoLostWakeup` | a task asleep on `s_writers.frozen` whose condition is visibly true has a wakeup coming (a wake_up_var() still to run, or a freezer still in its sequence) |
| deadlock | TLC's deadlock check: every task finishes |

### Switches

| Constant | Meaning |
|----------|---------|
| `FIX_DROP_UMOUNT` | freeze_super() drops `s_umount` around sb_wait_write(SB_FREEZE_WRITE) (L2290-2293) |
| `FIX_NESTED_THAW_RET` | fe967191e585: a thaw that drops its hold while others remain returns 0 |
| `FIX_EXCL_OWNER` | may_unfreeze() refuses a plain kernel thaw of the owner's last kernel hold (L2180-2182) |
| `FIX_RO_RECORD` | proposed for F3: the thaw releases the levels when the freeze took them, whatever sb_rdonly() says now |
| `FIX_WAKE_MB` | smp_mb() between the store to `frozen` and wake_up_var() (sb_freeze_wake() of "quota: really wait for the thaw in quotactl_block()") |
| `SBW_BARRIER` | percpu_down_write()'s atomic_xchg() orders the earlier store to `frozen` |
| `WEAK_WAKE`, `KILLABLE`, `SYNC_FAIL`, `FREEZEFS_FAIL`, `UNFREEZE_FAIL`, `ASYNC_RO`, `RO_INIT`, `HAS_*` | environment: buffered stores, fatal signals, failures, the error setting SB_RDONLY, a read-only superblock, which tasks exist |

## SuperHolder

### Tasks and the kernel code they stand for

| Action | Kernel |
|--------|--------|
| `BfLock` | bdev_freeze() (block/bdev.c L300): mutex_lock(&bd_fsfreeze_mutex) L304, atomic_inc_unless_negative() L307 (-EBUSY while denied), a nested freeze returns 0 at once L311-314 |
| `BfHops`, `BfBsync` | mutex_lock(&bd_holder_lock) L316: fs_holder_ops -> ->freeze L317-319, else sync_blockdev() L320-322 (`SYNC_FAIL`) |
| `BfWalk`, `BfGas`, `BfFrz`, `BfPut` | fs_bdev_freeze() L1549: mutex_unlock(&bd_holder_lock) L1558, super_dev_first()/super_dev_next() L1560 (entries inserted after the walk started sit in front of the cursor and are not seen), get_active_super() L1561, fs_super_freeze() L1563 (freeze_super(FREEZE_MAY_NEST \| FREEZE_HOLDER_USERSPACE) L1481 as one step: nests if frozen, else freezes, `FREEZE_FAIL`), deactivate_super() L1566 (may run ->kill_sb()), count++ L1567 |
| `BfSync`, `BfRollback`, `BfEnd` | per-superblock errors swallowed when count > 1 (L1576-1577, `FIX_SWALLOW`), sync_blockdev() L1578-1579 (`SYNC_FAIL`; `FIX_SYNC_ROLLBACK` thaws what the walk froze); bdev_freeze(): atomic_dec() on error L325-326, mutex_unlock() L328 |
| `BtLock` | bdev_thaw() L341: mutex_lock() L345, `nr_freeze <= 0` -> -EINVAL L348-350, `> 1` -> atomic_dec() L353-356 |
| `BtHops`, `BtWalk`, `BtGas`, `BtThw`, `BtPut`, `BtEnd` | ->thaw under bd_holder_lock L359-365 -> fs_bdev_thaw() L1594: the walk L1605-1613 with fs_super_thaw() L1608 (thaw_super(FREEZE_MAY_NEST \| FREEZE_HOLDER_USERSPACE): -EINVAL unless frozen with `freeze_ucount > 0`; `FIX_THAW_EINVAL_OK` counts that as thawed), errors swallowed when count > 1 L1616-1617; bdev_thaw(): atomic_dec() only without an error L367-368 |
| `DStart`, `DFrzRet`, `DHold` | dm suspend/resume: __dm_suspend() -> lock_fs() (drivers/md/dm.c L2996, L2936-2946: bdev_freeze(), DMF_FROZEN on success; on failure the suspend fails L2997-3000); __dm_resume() -> unlock_fs() L3133 (L2948-2954: bdev_thaw(), result ignored, DMF_FROZEN cleared) |
| `SStart`, `SFrzRet`, `SHold` | the shutdown ioctls with the default flags: ext4_force_shutdown() fs/ext4/ioctl.c L826-830, xfs_fs_goingdown() fs/xfs/xfs_fsops.c L457-459, f2fs_do_shutdown() fs/f2fs/file.c L2543-2547, exfat_force_shutdown() fs/exfat/super.c L167-170, ntfs3 ntfs_force_shutdown() fs/ntfs3/file.c L206-210: bdev_freeze(s_bdev), shutdown flag, bdev_thaw(s_bdev) |
| `FFrz`, `FThaw`, `Rogue` | ioctl_fsfreeze() fs/ioctl.c L385 (freeze_super(FREEZE_HOLDER_USERSPACE): -EBUSY while frozen with `freeze_ucount > 0`), ioctl_fsthaw() L402 |
| `EStart`, `ENext`, `EGas`, `EBtRet`, `ELock`, `EPut` | do_thaw_all() -> __iterate_supers(SUPER_ITER_UNLOCKED) (skips SB_DYING, L969), do_thaw_all_callback() L1204: get_active_super() L1206, `while (sb->s_bdev && !bdev_thaw(sb->s_bdev))` L1210-1212, super_lock_excl() + thaw_super_locked(FREEZE_HOLDER_USERSPACE) L1214-1215, deactivate_super() L1216; before 749d7aa0377a `s_umount` was held across the loop (`FIX_THAW_ALL_UNLOCKED`) |
| `MSget` | get_tree_bdev_flags() L1840 -> sget_dev() L1858 -> sget_fc(): set() registers (s_dev, sb) (super_s_dev_set() L1437 -> super_dev_register() L493), the superblock new with `s_umount` held |
| `MClaim`, `MCheck` | setup_bdev_super() L1784: fs_bdev_file_open_by_dev() L1791 (bdev_file_open_by_dev() -> bd_finish_claiming() sets bd_holder_ops under bd_holder_lock, block/bdev.c L693-696; fs_bdev_register() shares the sget entry L1652-1658); smp_mb() L1810, `bd_fsfreeze_count > 0` -> -EBUSY L1811-1816 (`FIX_SETUP_CHECK`), deactivate_locked_super() L1874 |
| `MXClaim`, `MXReg`, `MXChk` | fill_super() opening an extra device: fs_bdev_file_open_by_path() L1727 (claim), fs_bdev_register() L1646: super_dev_insert() L1664, smp_mb() L1669, `bd_fsfreeze_count > 0` -> super_dev_put(), -EBUSY L1670-1673 (`FIX_REGISTER_CHECK`), bdev_fput() L1739-1741; the mount fails (xfs, ext4, f2fs, erofs) or goes on without the device (`XDegraded`: btrfs open_fs_devices()) |
| `MBorn` | SB_ACTIVE L1877, vfs_get_tree() super_wake(SB_BORN) L1955, fc_mount() up_write(&s_umount) (fs/namespace.c L1280) |
| `Umount`, `KillSb` | deactivate_super() L610 of the mount's reference; the last reference: deactivate_locked_super() L581 -> kill_block_super() L1899 (generic_shutdown_super() SB_DYING L787, fs_bdev_file_release() of `s_bdev_file` L1906 and of the extra devices from ->put_super()/->kill_sb(), bd_end_claim() clears bd_holder_ops with the last claim, block/bdev.c L731-735) -> kill_super_notify() L543 (the sget entry goes, SB_DEAD) |
| `ADeny`, `AClaim`, `AReg`, `AJoin` | btrfs device add: btrfs_open_device_deny_freeze() fs/btrfs/volumes.c L2896 (bdev_deny_freeze() block/bdev.c L393 on a probe open, fs_bdev_file_open_by_dev()), bdev_allow_freeze() L405 when the add completes, or btrfs_release_device_allow_freeze() volumes.c L1133 when it aborts (`ADD_ABORT`) |
| `XDeny`, `XUnreg`, `XAllow`, `XPut` | btrfs_rm_device(): bdev_deny_freeze() volumes.c L2405-2410; btrfs_release_device_allow_freeze() L1133-1141: fs_bdev_unregister(), bdev_allow_freeze(), bdev_fput() (`FIX_UNREGISTER_FIRST`) |
| `Abandon` | a task that needs the mounted filesystem gives up when the mount failed |

### Abstractions

* freeze_super()/thaw_super_locked() are one step under `s_umount` with
  `freeze_kcount`/`freeze_ucount` and a frozen flag; what they do while
  `s_umount` is dropped only delays other freezers (SuperFreeze).
* bd_holder_lock is never held across a wait (each holder op drops it
  first), so its sections are single steps; bdev_lock and the disk's
  open_mutex likewise.
* The device table is a set of (device, superblock) entries.  A walk sees
  the entries present when it starts that are still there when it reaches
  them, and holds on to the one it stands on (the pin); entries inserted
  after it started are not seen (rhltable_insert() links them in front).
  SuperDevTable checks that this is what the RCU code does.
* Claims: the superblocks holding the device open with fs_holder_ops;
  `bd_holder_ops` is set while there is one.
* Sequential consistency: the publish-smp_mb()-read pairings of
  setup_bdev_super() and fs_bdev_register() with bdev_freeze()'s fully
  ordered atomic_inc_unless_negative() are taken as correct.
* No ->unfreeze_fs() failure, no remount, no writers (SuperFreeze's).
* Not covered: at most one extra device per superblock; partitions;
  bdev_mark_dead()/fs_bdev_sync(); btrfs dropping a member again before
  SB_BORN (__btrfs_free_extra_devids(), SuperDevTable's `dtdrop_tree`);
  freezes from the kernel (KERNEL/EXCL holders, SuperFreeze's).

### Invariants

| Invariant | Meaning |
|-----------|---------|
| `NoErr` | no superblock is killed while frozen |
| `SbOK` | a superblock is frozen exactly while it has holds |
| `FrozenWhileHeld` | while a dm device or a shutdown ioctl holds a device frozen (bdev_freeze() returned 0 and bdev_thaw() is not yet called), every live superblock using the device is frozen |
| `UserOK` | while a FIFREEZE caller holds its freeze, the filesystem is frozen |
| `CountOK` | with the freeze mutex free, `bd_fsfreeze_count` = the freezes whose callers have not returned from their bdev_thaw() - the denies held |
| `FinalOK` | when every task is done, nothing is frozen and every count is 0 |
| deadlock | TLC's deadlock check |

### Switches

| Constant | Off means |
|----------|-----------|
| `FIX_SETUP_CHECK`, `FIX_REGISTER_CHECK` | setup_bdev_super() / fs_bdev_register() do not refuse a frozen device |
| `FIX_NESTED_THAW_RET` | before fe967191e585 |
| `FIX_THAW_ALL_UNLOCKED` | before 749d7aa0377a: the emergency thaw holds `s_umount` across bdev_thaw() |
| `FIX_SWALLOW` | before 7a7ef107b449: a per-superblock error fails a shared device's freeze/thaw |
| `FIX_DENY`, `FIX_UNREGISTER_FIRST` | btrfs without bdev_deny_freeze(); bdev_allow_freeze() before fs_bdev_unregister() |
| `FIX_SYNC_ROLLBACK` | (proposed, off is the kernel) on a sync_blockdev() failure fs_bdev_freeze() thaws the superblocks it froze before returning the error |
| `FIX_THAW_EINVAL_OK` | (proposed, off is the kernel) fs_bdev_thaw() counts a superblock without a userspace hold as thawed: only a real ->unfreeze_fs() failure keeps the device frozen |

## Results

Local runs (4-6 workers, 2026-10-10) unless noted; "jens" ran with 48-64
workers.

| Configuration | Expected | Result | Distinct states | What it is |
|---------------|----------|--------|-----------------|------------|
| `freeze_all_fail` | pass | pass | 519,330,295 (jens) | FIFREEZE, two block devices, xfs scrub and filesystems_freeze() against a writer taking s_umount and a page fault, a remount, every failure (large: run on a big machine) |
| `freeze_all_weak` | pass | pass | 301,689,131 (jens) | the same set of freezers with buffered stores to s_writers.frozen and NoLostWakeup (large) |
| `freeze_drop_umount` | deadlock | deadlock | 71 | freeze_super() holding s_umount across sb_wait_write(SB_FREEZE_WRITE) deadlocks against a writer that takes s_umount |
| `freeze_ethaw` | pass | pass | 7,918 | the emergency thaw against a block device freeze, filesystems_freeze() and umount |
| `freeze_ethaw_hold` | violation: HoldsOK | violation: HoldsOK | 800 | the emergency thaw takes the block device's hold (documented: it thaws every userspace freeze) |
| `freeze_kern_fixed` | pass | pass | 896 | xfs scrub's kernel freeze, filesystems_freeze() and a kernel thaw without a freeze: the owner check keeps the exclusive freeze |
| `freeze_kern_no_owner` | violation: ExclOK | violation: ExclOK | 263 | without may_unfreeze()'s owner check a kernel thaw takes the last kernel hold of filesystems_freeze() |
| `freeze_mix_fail` | pass | pass | 91,700 | the mix with sync_filesystem(), ->freeze_fs() and ->unfreeze_fs() failing and fatal signals in wait_for_partially_frozen() |
| `freeze_mix_fixed` | pass | pass | 60,548 | FIFREEZE, a block device freeze and filesystems_freeze() against a writer that takes s_umount with SB_FREEZE_WRITE held, a remount and the umount |
| `freeze_nested_ret` | violation: BeliefOK | violation: BeliefOK | 192 | before fe967191e585 a nested thaw that dropped its hold returned -EINVAL |
| `freeze_qwait_mb` | pass | pass | 3,732 | the same with sb_freeze_wake()'s smp_mb() ("quota: really wait for the thaw in quotactl_block()") |
| `freeze_qwait_nomb` | violation: NoLostWakeup | violation: NoLostWakeup | 781 | quotactl_block() waiting for SB_UNFROZEN on s_writers.frozen ("quota: really wait for the thaw in quotactl_block()" without its smp_mb()) before wake_up_var(): the thaw's wakeup is lost |
| `freeze_qwait_ro_mb` | pass | pass | 876 | the same on a read-only superblock (frozen by the shortcut, the case the change is for) |
| `freeze_ro_async` | violation: RwsemOK | violation: RwsemOK | 143 | a filesystem that sets SB_RDONLY on an error while frozen: thaw_super_locked() takes the sb_rdonly() branch and never releases the freeze levels |
| `freeze_ro_async_fixed` | pass | pass | 140 | the same with the thaw deciding by how the freeze was taken (proposed fix) |
| `freeze_ro_async_mix` | pass | pass | 611,970 | the mix with the error setting SB_RDONLY and the proposed fix |
| `freeze_ro_init` | pass | pass | 23,844 | the mix on a read-only superblock (the sb_rdonly() shortcuts) with a remount read-write |
| `freeze_steal` | violation: HoldsOK | violation: HoldsOK | 62 | FITHAW from a task that holds no freeze takes the block device's FREEZE_MAY_NEST hold (they share freeze_ucount) |
| `freeze_twodev_fail` | pass | pass | 8,805 | two block devices of one filesystem freezing it with FREEZE_MAY_NEST, a page fault and an internal writer, every failure |
| `freeze_wake_mb` | pass | pass | 1,727 | no barrier in percpu_down_write() but smp_mb() before wake_up_var() |
| `freeze_wake_nobarrier` | violation: NoLostWakeup | violation: NoLostWakeup | 642 | the same without the full barrier of percpu_down_write() after the SB_FREEZE_PAGEFAULT store: the wakeup is lost |
| `freeze_wake_weak` | pass | pass | 3,827 | stores to s_writers.frozen buffered: no smp_mb() before wake_up_var(), still no lost wakeup in wait_for_partially_frozen() |
| `holder_big` | pass | pass | 16,023,923 (jens) | two read-write superblocks sharing a device: mounts, umounts, dm on all three devices, FIFREEZE on both, a shutdown ioctl (large: run on a big machine) |
| `holder_big_fixed` | pass | pass | 1,096,718,937 (jens) | the same plus the emergency thaw, a FITHAW without a freeze, failing freezes and sync_blockdev(), with both proposed fixes (large) |
| `holder_btrfs_allow_first` | violation: FinalOK | violation: FinalOK | 433 | re-allowing the freeze before unregistering the removed device strands a freeze |
| `holder_btrfs_fixed` | pass | pass | 11,719 | a device removed and a device added (with an abort) under dm suspend/resume of both |
| `holder_btrfs_nodeny` | violation: FinalOK | violation: FinalOK | 26,739 | without bdev_deny_freeze() a removal or an aborted add strands a freeze |
| `holder_degraded` | violation: CountOK | violation: CountOK | 232 | btrfs -o degraded: the member's registration is refused while frozen but its entry was briefly visible; a bdev_thaw() walk pinned it, waits for SB_BORN and thaws a superblock that was never frozen through the device: bd_fsfreeze_count stays 1 (the device-table model's dtdeg_tree) |
| `holder_degraded_leak` | violation: FinalOK | violation: FinalOK | 232 | the freeze direction: a bdev_freeze() walk pins the refused entry, freezes the superblock once born, and the thaw finds no holder on the device: the superblock stays frozen |
| `holder_degraded_steal` | violation: FrozenWhileHeld | violation: FrozenWhileHeld | 3,888 | and with a freeze of the main device the stray thaw takes that device's freeze (dtmultideg_tree); the proposed fix does not cover this |
| `holder_multi_all_fixed` | pass | pass | 5,886,104 | everything on the two-device filesystem including the emergency thaw and a FITHAW without a freeze, with both proposed fixes and sync_blockdev() failing |
| `holder_multi_ethaw` | violation: FinalOK | violation: FinalOK | 1,351 | the emergency thaw thaws the filesystem frozen through the extra device; dm resume of that device then fails and its count stays |
| `holder_multi_ethaw_fixed` | pass | pass | 72,623 | the same with the proposed fs_bdev_thaw() fix |
| `holder_multi_fail` | pass | pass | 60,304 | the two-device filesystem with failing freezes, two dm devices, FIFREEZE, the shutdown ioctl and umount |
| `holder_multi_fixed` | pass | pass | 25,603 | a filesystem on two devices: dm on either, FIFREEZE, a shutdown ioctl, umount |
| `holder_multi_xrace_nocheck` | violation: FrozenWhileHeld | violation: FrozenWhileHeld | 182 | without fs_bdev_register()'s check the extra device is opened while frozen |
| `holder_one_ethaw` | violation: FinalOK | violation: FinalOK | 2,883 | the emergency thaw's bdev_thaw() loop finds the device unfrozen, dm suspends, thaw_super_locked() takes dm's hold, dm resume fails: bd_fsfreeze_count stays 1 |
| `holder_one_ethaw_fixed` | pass | pass | 2,811 | the same with fs_bdev_thaw() counting a superblock without a userspace hold as thawed (proposed fix) |
| `holder_one_ethaw_locked` | deadlock | deadlock | 441 | before 749d7aa0377a the emergency thaw held s_umount across bdev_thaw(), which takes it again |
| `holder_one_fail` | pass | pass | 2,054 | the same with freezes that fail |
| `holder_one_fixed` | pass | pass | 1,079 | one filesystem: mount, dm suspend/resume, FIFREEZE/FITHAW, a shutdown ioctl, umount |
| `holder_one_mountrace` | pass | pass | 149 | a mount racing with dm suspend: refused while the device is frozen, else frozen by the walk |
| `holder_one_mountrace_nocheck` | violation: FrozenWhileHeld | violation: FrozenWhileHeld | 134 | without setup_bdev_super()'s check the superblock is mounted unfrozen on a frozen device |
| `holder_one_nested_ret` | violation: CountOK | violation: CountOK | 311 | before fe967191e585: FIFREEZE, dm suspend, dm resume leaves bd_fsfreeze_count at 1 |
| `holder_one_steal` | violation: FrozenWhileHeld | violation: FrozenWhileHeld | 250 | FITHAW without a freeze thaws the filesystem under a suspended dm device |
| `holder_one_steal_count` | violation: CountOK | violation: CountOK | 250 | and dm resume then fails, bd_fsfreeze_count stays 1: the device can never be mounted again |
| `holder_one_steal_fixed` | pass | pass | 3,206 | FITHAW without a freeze with the proposed fs_bdev_thaw() fix: the filesystem is still thawed under dm, but the count goes |
| `holder_one_sync` | violation: FinalOK | violation: FinalOK | 186 | sync_blockdev() fails after fs_bdev_freeze() froze the superblock: bdev_freeze() fails, drops the count, the filesystem stays frozen |
| `holder_one_sync_rollback` | pass | pass | 1,974 | the same with the frozen superblocks thawed again on that failure (proposed fix) |
| `holder_remount` | pass | pass | 1,019 | umount while dm-frozen, the thaw kills the superblock, a new superblock mounts the device |
| `holder_shared_fail` | violation: FrozenWhileHeld | violation: FrozenWhileHeld | 3,399 | read-write superblocks sharing a device: a swallowed per-superblock freeze failure leaves one unfrozen under the frozen device (intended by 7a7ef107b449) |
| `holder_shared_noswallow` | violation: FinalOK | violation: FinalOK | 3,740 | before 7a7ef107b449 the per-superblock error failed bdev_freeze() and left the others frozen |
| `holder_shared_ro` | violation: FinalOK | violation: FinalOK | 71,718 | two read-only superblocks (erofs) sharing a device under dm suspend/resume and the emergency thaw: the shared device is never s_bdev, its count is left at 1 and the next mount using it fails |
| `holder_shared_ro_fixed` | pass | pass | 72,640 | the same with the proposed fs_bdev_thaw() fix |
| `holder_shared_ro_held` | pass | pass | 3,238 | the same without the emergency thaw, every invariant |
| `holder_shared_steal` | violation: UserOK | violation: UserOK | 8,128 | and fs_bdev_thaw() then thaws that superblock anyway, taking the FIFREEZE hold of its owner |

All 56 configurations end as expected.  `freeze_all_fail`,
`freeze_all_weak` and `holder_big` were repeated with the final modules
(the switch `HAS_QWAIT`, comments and an unused operator changed after the
first round) and gave the same state counts; `holder_big_fixed` (1h36m)
ran once, before the SuperHolder change, which touched no action.

## What the findings would need

* F1: on a sync_blockdev() failure after the walk froze superblocks, thaw
  them before returning the error (`FIX_SYNC_ROLLBACK`), or keep reporting
  success as before v6.8 -- 7a7ef107b449 wants the error reported, so the
  rollback.  Reproducer sketch: a read-only filesystem on a dm-flakey (or
  dm-dust) device, a buffered write to the block device that fails in
  writeback (CONFIG_BLK_DEV_WRITE_MOUNTED=y, nobody consumes AS_EIO), then
  `dmsetup suspend` -- freeze_super()'s read-only shortcut skips
  sync_filesystem(), so the stale error surfaces in fs_bdev_freeze()'s
  sync_blockdev(): the suspend fails with EIO and the filesystem stays
  frozen (remount -EBUSY; after umount the superblock lingers frozen with
  the device claimed).  The same with any member device that is not
  `s_bdev`.  Not run.
* F2: make fs_bdev_thaw() treat -EINVAL from thaw_super() as "this
  device's hold is already gone" (`FIX_THAW_EINVAL_OK`), so only a real
  ->unfreeze_fs() failure keeps the device frozen; that ends the stuck
  count for every trigger the model has.  Keeping FITHAW and the emergency
  thaw from taking block-device holds at all would need a holder class of
  their own instead of the shared `freeze_ucount`.  Reproducer for (a):
  `dmsetup suspend dut; fsfreeze -u /mnt; dmsetup resume dut; umount /mnt;
  mount /dev/mapper/dut /mnt` -> "Can't mount, blockdev is frozen".  Not
  run.
* F3: decide in thaw_super_locked() by how the freeze was taken (a flag
  set by the sb_rdonly() shortcut, `FIX_RO_RECORD`), or have the listed
  filesystems stop setting SB_RDONLY asynchronously as ext4 did.

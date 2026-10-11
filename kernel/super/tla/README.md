# TLA+ models of fs/super.c

Tree: work.super.fixes at fc1c25014ff8 ("Merge tag 'fsverity-for-linus'",
v7.3-rc6-301, identical to vfs master).  Line numbers are fs/super.c at that
commit unless a file is named (block/bdev.c, fs/namespace.c,
fs/btrfs/volumes.c, drivers/md/dm.c).

This directory holds two families of models that share `check.sh`, `logs/`
and `traces/`:

| Models | What | Generator, trace printer, configurations |
|--------|------|------------------------------------------|
| `SuperLife.tla`, `SuperDevTable.tla` | the superblock lifecycle (allocation, publication, SB_BORN/SB_DYING/SB_DEAD, s_active, s_passive, s_umount, sb_lock, the RCU-delayed free; sget_fc(), grab_super(), the iterators, user_get_super(), the shrinker) and the device-to-superblock table (struct super_dev in the rhltable, its claims and cursors, fs_holder_ops' walks against bd_fsfreeze_count) | `gen-cfgs-life-devtable.py`, `show-trace-life-devtable.py`, `lf*.cfg`, `dt*.cfg`, `MC_lf*.tla`, `MC_dt*.tla`, `run-parallel-life-devtable.sh`, `summarize-life-devtable.sh` |
| `SuperFreeze.tla`, `SuperHolder.tla` | freezing and the block-layer holder operations, described in `README-freeze-holder.md` | `gen-cfgs-freeze-holder.py`, `show-trace-freeze-holder.py`, `freeze_*.cfg`, `holder_*.cfg`, `MC_freeze.tla`, `MC_holder.tla`, `check-all-freeze-holder.sh` |

The rest of this README is about SuperLife and SuperDevTable.

## Files

| File | What it is |
|------|------------|
| `SuperDevTable.tla` | the device table: entries {sd_dev, sd_sb, sd_ref, sd_node, sd_rcu}, one RCU list per device as the rhltable keeps it, kfree_rcu(), the passive reference of each entry; filesystem tasks registering and releasing claims (sget_fc()'s set(), setup_bdev_super(), a member device during the mount or on the live superblock under bdev_deny_freeze()), the unmount, bdev_freeze()/bdev_thaw() -> fs_bdev_freeze()/fs_bdev_thaw(), user_get_super(), a racing second registration |
| `SuperLife.tla` | the superblock lifecycle: mounters (sget_fc() with test(), alloc_super(), set(), grab_super(), fill_super() success or failure, the unmount down to put_super() and the RCU-delayed free), an iterator (__iterate_supers() or iterate_supers_type()), user_get_super() through the superblock's own table entry, a shrinker (super_cache_scan()/super_cache_count()) |
| `MC_dt*.tla`, `MC_lf*.tla` | the layouts (which tasks, devices, superblocks), generated |
| `dt*.cfg`, `lf*.cfg` | TLC configurations, generated; `<layout>_<what>.cfg` runs `MC_<layout>.tla`, the header line says what to expect |
| `gen-cfgs-life-devtable.py` | writes the two above |
| `check.sh` | run one configuration (deadlock checking on: every model ends in a stuttering `Finished` state) |
| `run-parallel-life-devtable.sh`, `summarize-life-devtable.sh` | run them all on a big machine, summarize `logs/` into `logs/summary-life-devtable.txt` |
| `RESULTS-life-devtable.txt` | that summary for the run below |
| `show-trace-life-devtable.py` | print a counterexample compactly: per step the action, the tasks that moved, every variable that changed |
| `traces/dt*.txt`, `traces/lf*.txt` | every counterexample of the tables below, with the interleaving in words and the kernel lines |

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar          # or the tla2tools.jar symlink here
    ./check.sh dtdrop_tree 4                          # one configuration
    systemd-run --user --scope -p MemoryMax=6G ./check.sh dtwalk_tree 6   # on a laptop
    MAXJOBS=10 ./run-parallel-life-devtable.sh 24 20g # everything, on a big machine
    ./show-trace-life-devtable.py logs/dtdrop_tree.log

Every configuration but `dtshare_tree` (59M states), `lftripletype_tree`
(25M) and `lftriple_tree` (146M) finishes in seconds to a minute; those
three want a big machine.

## SuperDevTable: the device-to-superblock table

### The rhltable as the model sees it

`super_dev_table` is an rhltable keyed by dev_t (struct super_dev L438-444,
the table L446-451).  What a reader can observe of it
(include/linux/rhashtable.h, lib/rhashtable.c):

* All entries with the same key hang off one bucket-chain node as a list
  linked through `rhlist_head.next`.  `rhltable_insert()` of a key already
  present links the new node in FRONT of that list
  (`__rhashtable_insert_fast()`: `list->next = plist`, the new node takes
  the old head's place in the bucket chain; the slow path
  `rhashtable_lookup_one()` does the same in whichever table holds the key).
* `rhltable_remove()` unlinks a node by storing its `->next` into its
  predecessor (or, for the head, by making the next list node the
  bucket-chain node); the removed node's own `->next` is left alone, so an
  RCU reader standing on it continues to the successor it had at removal.
* A resize moves a key's whole list (`rhashtable_rehash_one()` relinks the
  bucket-chain node only), and a lookup racing it retries through the nulls
  marker and `future_tbl`: the order of a key's list changes only by insert
  and remove, and a lookup returns the list head of some moment during the
  lookup (possibly one being removed).
* Writers are serialized by the bucket bit lock.

So the model keeps one list per device: `head[d]` and each entry's `next`;
insert is one step (front), remove is one step (predecessor's next or the
head), readers read the head once and then follow `next` one step at a time.
`kfree_rcu()` frees an entry once every task that was inside a read section
when it was called has left one (`gp`).  The memory model is sequentially
consistent: the smp_mb() pairings (the registration's publish-then-read of
bd_fsfreeze_count against bdev_freeze()'s fully ordered
atomic_inc_unless_negative()) are taken as given and the
`FIX_PUBLISH_FIRST` mutation shows what the order buys.

### Tasks and the kernel code they stand for

| Action | Kernel |
|--------|--------|
| `fs_alloc` | alloc_super() L323: down_write_nested(s_umount) L351, s_passive 1 L376, s_active 1 L377, s_super_dev = super_dev_alloc(0, s) L401 (unregistered) |
| `fs_set`, `fs_setpass` | sget_fc() L881 set() -> super_dev_register() L493 -> super_dev_insert(): rhltable_insert() L486, refcount_inc(&sd_sb->s_passive) L488 (under sb_lock) |
| `fs_open`, `fs_bdevchk`, `fs_mfput` | setup_bdev_super() L1792: fs_bdev_file_open_by_dev() L1799 (bdev_file_open_by_dev() with fs_holder_ops, then fs_bdev_register(), which shares the sget entry); smp_mb() L1818, bd_fsfreeze_count > 0 L1819 -> fs_bdev_file_release() L1822, -EBUSY, the mount fails |
| `fs_x`, `fs_xchk` | a member device opened in fill_super(): fs_bdev_file_open_by_path() L1735 or fs_bdev_file_open_by_dev() L1701 (xfs log/rt, ext4 journal, f2fs, erofs: a refusal fails the mount, `onfail "fail"`; btrfs open_fs_devices() fs/btrfs/volumes.c L1262 goes on without it, `onfail "degraded"`) |
| `fs_xdrop`, `fs_xdfput` | the member released again before SB_BORN while the mount goes on: fs_bdev_file_release() L1785 from btrfs __btrfs_free_extra_devids() (volumes.c L1068, from open_ctree() fs/btrfs/disk-io.c L3595) or btrfs_open_one_device()'s devid/uuid mismatch (volumes.c L662) |
| `fs_born` | vfs_get_tree() L1929: super_wake(SB_BORN) L1963; fc_mount() up_write(s_umount) (fs/namespace.c L1280); or fill_super() fails (`mayfail`) |
| `fs_live`, `fs_addchk` | btrfs device add on the live superblock: btrfs_open_device_deny_freeze() (volumes.c L2896): bdev_deny_freeze() (block/bdev.c L393), fs_bdev_file_open_by_dev(); bdev_allow_freeze() (block/bdev.c L405) |
| `fs_live2`, `fs_rmallow` | btrfs device remove: btrfs_rm_device() (volumes.c L2355) under the deny, btrfs_release_device_allow_freeze() (volumes.c L1133): fs_bdev_unregister(), bdev_allow_freeze(), bdev_fput() |
| `fs_live3`, `fs_fail` | deactivate_super() L610 for the last active reference, or the failed mount's deactivate_locked_super(): s_active -> 0 L584 (the model lets the filesystem task wait for freezers' active references: the kill is the same whoever runs it) |
| `fs_relx`, `fs_relxput` | ->kill_sb() -> generic_shutdown_super() -> ->put_super() closes the member device (fs_bdev_file_release()) |
| `fs_dying` | generic_shutdown_super(): super_wake(SB_DYING) L787, super_unlock_excl() L788 |
| `fs_relm`, `fs_relmput` | kill_block_super() L1907: fs_bdev_file_release(sb->s_bdev_file) L1914 if s_bdev was set L1912 |
| `fs_notify` | deactivate_locked_super() L588 -> kill_super_notify() L543: super_dev_put(s_super_dev) L552-553 |
| `fs_dead`, `fs_put` | super_wake(SB_DEAD) under sb_lock L565-567; put_super() L594 |
| `R0`..`R6` | fs_bdev_register() L1654: scoped_guard(rcu) L1660, super_dev_lookup() L1661 (rhltable_lookup() L1645, the first entry with sd_sb == sb L1646-1648), refcount_inc_not_zero() L1662 (share), super_dev_alloc() L1668, super_dev_insert() L1672 (L486, L488), smp_mb() L1677, bd_fsfreeze_count > 0 L1678, super_dev_put() L1680 (-EBUSY) |
| `U0`..`U2` | fs_bdev_unregister() L1766: rcu_read_lock() L1771, super_dev_lookup() L1772 (no reference taken), rcu_read_unlock() L1773, super_dev_put() L1774 |
| `P1`..`P3`, `RcuFree` | super_dev_put() L466: refcount_dec_and_test() L469, rhltable_remove() L470, put_super(sd_sb) L471, kfree_rcu() L472 and its callback |
| `W0`..`W3`, `WN` | super_dev_first() L521 (rcu_read_lock() L525, lookup and super_dev_get() L526), super_dev_get() L509 (->next L513, refcount_inc_not_zero() L515), super_dev_next() L531 (prev->sd_node.next L535-536, rcu_read_unlock() L537, super_dev_put(prev) L539) |
| `F_bdf`, `F_hold` | bdev_freeze() (block/bdev.c L300): atomic_inc_unless_negative() L307 (-EBUSY while denied), nested L311, under bd_holder_lock ->freeze if a holder with fs_holder_ops has the device open, else sync_blockdev() L316-322 |
| `F_gas`, `T_gas` | get_active_super() L1201 from fs_bdev_freeze() L1569 / fs_bdev_thaw() L1614: super_lock_excl() (wait for SB_BORN\|SB_DYING L118, SB_DYING -> false L121/L131, down_write() L124), atomic_inc_not_zero(s_active) L1206 |
| `F_frz`, `F_fend` | fs_super_freeze() L1484 -> freeze_super(sb, FREEZE_MAY_NEST \| FREEZE_HOLDER_USERSPACE) L1571 (the first freeze keeps one active reference for all freezers), deactivate_super() L1574, count++ L1575; L1584-1588 |
| `F_frozen`, `F_bdt` | the device stays frozen (dm suspend, lock_fs() drivers/md/dm.c L2936); bdev_thaw() (block/bdev.c L341): count <= 0 L349, nested L353-355, ->thaw under bd_holder_lock L359-365 |
| `T_thw`, `T_end` | fs_super_thaw() L1492 -> thaw_super() L1616 (freeze_ucount 0: -EINVAL), deactivate_super() L1619, count++ L1620; a single superblock's error is returned L1624-1625; bdev_thaw() decrements only without an error L367-368 (dm's unlock_fs() L2948-2952 ignores the result) |
| `C_*` | user_get_super() L1043: the walk, super_lock() L1050, refcount_inc(s_passive) L1054, super_dev_put() L1055, drop_super() L923 |
| `D_*` | a second fs_bdev_file_open_by_path() / fs_bdev_file_release() pair of the same (device, superblock), concurrent with the filesystem's own (contract witness) or once it started releasing its claim (a re-add) |

### Switches

| Constant | Meaning |
|----------|---------|
| `FsCfg[s]` | per superblock: `main` device, member device `xdev` registered during the mount (`xmode "mount"`) or on the live superblock (`"live"`), `onfail` (`"fail"`/`"degraded"`), `dropx` (`"early"`: released before SB_BORN, `"live"`: removed from the live superblock), `umount`, `mayfail` |
| `Freezers`, `Cursors`, `Dups` | the bdev_freeze()/bdev_thaw() tasks per device, the user_get_super() tasks per device, the second registrations |
| `FIX_RCU_FREE` | off: super_dev_put() frees with kfree() right at removal |
| `FIX_NEXT_PIN` | off: super_dev_next() drops prev before it reads prev->sd_node.next |
| `FIX_PUBLISH_FIRST` | off: fs_bdev_register() reads bd_fsfreeze_count before it inserts |
| `FIX_DENY` | off: btrfs device add/remove without bdev_deny_freeze() |
| `FIX_FIRST_MATCH` | off: super_dev_lookup() returns the last (dev, sb) match |

### Invariants

| Invariant | Meaning |
|-----------|---------|
| `NoErr` | no action hit a defect: super_dev_put() of an entry at zero (refcount_t underflow) or of a freed one, a lookup or cursor reading a freed entry, a passive reference dropped that was never taken, `refcount_inc(s_passive)` from zero, get_active_super()/super_lock() on a freed superblock, a cursor revisiting an entry or skipping one that stayed live through the walk, user_get_super() returning a superblock being torn down, and the freeze balance: after bdev_thaw() the device is thawed (`"the device stays frozen for good"`), no freeze taken through it is left (`"a freeze taken through the device outlives its thaw"`), and no thaw took another device's freeze |
| `ListOK` | each device's list is acyclic and holds exactly its linked entries |
| `RefLinked` | an entry with a non-zero count is linked ("Unlink only once unpinned", L468) |
| `NoFreedReach` | no task's reader position, pin, lookup result or pending put points to a freed entry |
| `PassLedger` | s_passive = alloc_super()'s reference + one per registered entry + one per user_get_super() caller |
| `EntryKeepsSb` | an entry holding a passive reference keeps its superblock |
| `FrozenCovers` | while a freezer holds a device frozen, every live superblock using the device is frozen |
| `NoLeak` | at the end no entry and no superblock of an unmounted filesystem is left |
| `NoUnderflow` | only the refcount underflow part of `NoErr` (`dtdup_underflow`) |

## SuperLife: the superblock lifecycle

### Tasks and the kernel code they stand for

| Action | Kernel |
|--------|--------|
| `m_lock`, `m_scan`, `m_test` | sget_fc() L839: spin_lock(&sb_lock) L861, hlist_for_each_entry(fs_supers) L863, SB_DEAD -> continue L865, test() L867 (may dereference s_fs_info: `TEST_DEREF`; `TEST` "single" = get_tree_single(), "keyed" = matches the superblocks of the same key, "none" = get_tree_nodev()) |
| `m_nomatch`, `m_alloc` | L871-877: spin_unlock() L872, alloc_super() L874 (L323: s_umount L351, s_passive 1 L376, s_active 1 L377, s_super_dev L401), retry |
| `m_set`, `m_shreg` | s_fs_info, set() L881 (the entry and its passive reference, L493), list_add_tail(super_blocks) L899, hlist_add_head(fs_supers) L900, spin_unlock() L901, shrinker_register() L903 |
| `m_fill`, `m_unlock` | fill_super(): success -> vfs_get_tree() super_wake(SB_BORN) L1963, fc_mount() up_write() (fs/namespace.c L1280); failure -> deactivate_locked_super() with s_umount held (vfs_get_super() L1385, get_tree_bdev_flags() L1848) |
| `m_grab0`..`m_grab3`, `m_grabwait` | grab_super() L632: refcount_inc(s_passive) under sb_lock L636, spin_unlock() L637, super_lock_excl() L638 (wait SB_BORN\|SB_DYING L118, SB_DYING L121, down_write() L124, SB_DYING L131), atomic_inc_not_zero(s_active) L640 -> put_super(); else super_unlock_excl() L644, wait for SB_DEAD L646, put_super(), sget_fc() retries L916 |
| `m_gotold` | destroy_unused_super(s) L918 (L302) of the never-published allocation; the existing superblock is returned with s_umount and an active reference |
| `m_deact`, `m_dls` | deactivate_super() L610: atomic_add_unless(-1, 1) L612, __super_lock_excl() L613; deactivate_locked_super() L581: atomic_dec_and_test() L584, else super_unlock_excl() L596 |
| `m_shfree` | shrinker_free() L585: waits for callbacks in flight, none starts afterwards |
| `m_gss` | ->kill_sb() L586 -> generic_shutdown_super() L723: super_wake(SB_DYING) L787, super_unlock_excl() L788 |
| `m_notify`, `m_dead` | kill_super_notify() L543: SB_DEAD -> return L548, super_dev_put(s_super_dev) L552-553, spin_lock(sb_lock) super_wake(SB_DEAD) spin_unlock() L565-567; from kill_anon_super() L1364 right after generic_shutdown_super() (`KILL "anon"`) or from deactivate_locked_super() L588 after ->kill_sb() returned (`KILL "block"`) |
| `m_freefsi` | the filesystem frees what s_fs_info points to: after kill_anon_super() returned (`KILL "anon"`: nfs, ceph, cifs, afs, fuse, virtiofs, kernfs, ubifs, btrfs) or inside ->kill_sb() before the notify (`KILL "block"`) |
| `m_put0`, `m_put`, `PS1`, `PS2`, `RcuFree` | list_lru_destroy(); put_super() L594 -> L419: refcount_dec_and_test() L421, at zero spin_lock(sb_lock) L424, list_del_init(s_list) L425, hlist_del_init(s_instances) L426, spin_unlock() L427, call_rcu() L432 -> destroy_super_rcu() L294 -> destroy_super_work() L279 |
| `i_lock`, `i_loop` | __iterate_supers() L958 over super_blocks (`ITER "all"`) or iterate_supers_type() L1008 over fs_supers (`ITER "type"`): spin_lock() L964/L1013, SB_DYING -> continue L969/L1017, refcount_inc_not_zero() L972/L1020, spin_unlock() L975/L1023; at the end spin_unlock(), put_super(p) L989-991/L1036-1038 |
| `i_slock`, `i_cb` | super_lock() shared L979/L1025 (L113), f(sb) with s_umount shared L980/L1027, super_unlock() L981/L1028 |
| `i_putprev`, `i_relock` | put_super(p) L984-985/L1031-1032, p = sb L986/L1033, spin_lock() L987/L1034, then the advance from sb: next_super() L950 (L968) or the hlist ->next (L1014) -- sb must still be linked |
| `u_pin`..`u_drop` | user_get_super() L1043 through the superblock's s_super_dev: refcount_inc_not_zero() under RCU (L515), super_lock() L1050 (SB_DYING: the pin is dropped, NULL), refcount_inc(s_passive) L1054, super_dev_put() L1055, the caller uses the superblock, drop_super_exclusive() L931 |
| `h_pick`..`h_end` | shrink_slab() takes the shrinker's reference (shrinker_free() waits for it), super_cache_scan() L181 (super_trylock_shared() L200/L668: down_read_trylock(), !SB_DYING, s_root, SB_BORN; the caches) or super_cache_count() L238 (SB_BORN read without locks L260, then the filesystem's counts) |

Waits (wait_var_event()) are enabling conditions on monotonic flags; a task
waiting for a flag that never comes is a TLC deadlock.  s_umount is an
rwsem with exclusive and shared holders and no writer preference.

### Switches

| Constant | Meaning |
|----------|---------|
| `Mnt`, `MntSb`, `Umount`, `FillFail`, `Key` | the mounters, the slot alloc_super() gives each, whether it unmounts, whether its fill_super() may fail, its key (`TEST "keyed"`) |
| `TEST`, `TEST_DEREF`, `KILL` | see above |
| `ITER`, `UGS`, `SHRINK` | the iterator, user_get_super()'s superblock, the number of shrinker callbacks |
| `FIX_DEAD_SKIP` | off: sget_fc() does not skip SB_DEAD superblocks |
| `FIX_DEAD_LOCK` | off: SB_DEAD set without sb_lock |
| `FIX_UNLINK_LATE` | off: fs_supers unlinked in kill_super_notify(), the shape before 2d2a2d7aa987 |
| `FIX_ITER_PIN` | off: the iterator drops the current superblock before it advances from it |
| `FIX_SHRINK_FIRST` | off: shrinker_free() after ->kill_sb() |
| `FIX_RCU_SB` | off: put_super() frees at once (no call_rcu()) |

### Invariants

| Invariant | Meaning |
|-----------|---------|
| `NoErr` | no action hit a defect: use of a freed superblock, test() dereferencing a freed s_fs_info, `refcount_inc(s_passive)` from zero (grab_super(), user_get_super()), s_passive underflow, s_umount released by a task that does not hold it, deactivate_locked_super() without s_umount, an iterator advancing from an unlinked node, an iterator callback or user_get_super() on a superblock being torn down, a shrinker callback using a freed filesystem, destroy_unused_super() of a superblock others can see, a superblock freed with its entry linked, its shrinker registered, or before SB_DEAD |
| `PassLedger` | s_passive = alloc_super()'s reference + the registered entry + the tasks' temporary references + a put in flight |
| `ActLedger` | s_active = the mounters holding the superblock |
| `Lists` | a published superblock is on both lists until its last passive reference; an unpublished or freed one on neither |
| `Flags` | SB_DEAD implies SB_DYING; SB_DYING implies s_active 0 |
| `UmountSane` | nobody holds s_umount of a superblock that is gone |
| `NoLeak` | at the end every superblock nobody holds active is freed |
| (deadlock) | every waiter in super_lock(), grab_super() (SB_BORN\|SB_DYING, SB_DEAD), shrinker_free() and on s_umount proceeds |

## Results (jens, 2026-10-10)

jens (512 cores), TLC 2.19, 24 workers and 30g heap per run, 12 runs at a time,
deadlock checking on; `RESULTS-life-devtable.txt` is the raw summary.  All 33
configurations end as their header predicts.

### SuperDevTable, the tree

| Configuration | Result | Distinct states | Time | What it is / what it shows |
|---------------|--------|-----------------|------|----------------------------|
| `dtbase_tree` | pass | 20836 | 01s | s1 on d1 (sget entry + setup_bdev_super claim), mount may fail, unmounted; a freezer and a user_get_super() cursor on d1 |
| `dtdeg_tree` | violation | 835 | 00s | NoErr, a walk of d2 pins the entry of the refused registration and waits for SB_BORN while the mount goes on without d2: bdev_thaw()'s walk thaws s1 that was never frozen, -EINVAL, bd_fsfreeze_count stays 1 for good (or bdev_freeze()'s walk freezes s1 through a device it does not use) |
| `dtdegc_tree` | pass | 276311 | 02s | s1 on d1 with extra member d2 refused and the mount going on (btrfs -o degraded), s2 on d2, both unmounted; a user_get_super() cursor on d2 |
| `dtdrop_tree` | violation | 2219 | 01s | NoErr, the freeze walk pins s1's d2 entry, s1 releases d2 before SB_BORN, the walk freezes s1 through d2 anyway and bdev_thaw(d2) never thaws it |
| `dtdropc_tree` | pass | 302227 | 02s | s1 on d1 with extra member d2 accepted and released before SB_BORN, s2 on d2, both unmounted; a user_get_super() cursor on d2 |
| `dtdup_tree` | violation | 834 | 00s | NoErr, two live entries for (d2, s1); an unregister finds the one whose count already hit zero first: refcount underflow, use-after-free after the grace period, the other entry and s1's passive reference leak |
| `dtdup_underflow` | violation | 1383 | 01s | NoUnderflow, the two live entries for (d2, s1): the first unregister takes the front one to zero, the second one's lookup still finds it first and puts it at zero |
| `dtlive_tree` | pass | 2103 | 01s | s1 on d1, d2 added to the live superblock and removed again (btrfs device add/remove under bdev_deny_freeze()), unmounted; a freezer on d2 |
| `dtmulti_tree` | pass | 61050 | 01s | s1 on d1 with extra member d2 (refused -> the mount fails); a freezer on d1 and one on d2 |
| `dtmultideg_tree` | violation | 10333 | 01s | NoErr, as dtdeg_tree; with d1 frozen as well a thaw of d2 can take d1's freeze |
| `dtreadd_tree` | pass | 501 | 00s | s1 on d1 with extra member d2 accepted and released before SB_BORN, then registered and released again by another task (a re-add) |
| `dtshare_tree` | pass | 59438917 | 06min49s | s1 on d1 with extra member d2 registered during the mount (refused -> the mount fails), s2 on d2; both unmounted; a freezer and a cursor on d2 |
| `dtsharefz_tree` | pass | 684477 | 07s | s1 on d1 with extra member d2 (refused -> the mount fails), s2 on d2, nobody unmounts; a freezer on d2 |
| `dtwalk_tree` | pass | 7657503 | 51s | s1 on d1 with extra member d2 (refused -> the mount fails) and s2 on d2, both unmounted, mount of s2 may fail; two user_get_super() cursors on d2 |

### SuperDevTable, mutations (a FIX_* switched off)

| Configuration | Result | Distinct states | Time | What it is / what it shows |
|---------------|--------|-----------------|------|----------------------------|
| `dtlive_no_deny` | violation | 1762 | 01s | NoErr, without bdev_deny_freeze() the live add/remove of d2 races the freeze walk: a freeze through a refused or removed claim outlives the thaw |
| `dtreadd_no_first_match` | violation | 523 | 00s | NoErr, super_dev_lookup() returning the last match finds a dying older entry behind the live one |
| `dtsharefz_no_publish_first` | violation | 13847 | 01s | FrozenCovers, the registration reads the count before the freezer increments it and inserts after the walk: s1 uses the frozen d2 unfrozen |
| `dtwalk_no_next_pin` | violation | 299009 | 03s | NoFreedReach, super_dev_next() drops prev, prev is removed and freed, then prev->sd_node.next is read |
| `dtwalk_no_rcu_free` | violation | 96922 | 02s | NoFreedReach, a cursor that read the head or a ->next before the removal reaches the entry after kfree() |

### SuperLife, the tree

| Configuration | Result | Distinct states | Time | What it is / what it shows |
|---------------|--------|-----------------|------|----------------------------|
| `lfblock_noderef` | pass | 2178 | 01s | a test() that does not dereference s_fs_info (sget_dev()'s super_s_dev_test(), test_keyed_super()) is fine with any ->kill_sb() |
| `lfblock_tree` | violation | 289 | 00s | NoErr, test() runs on the dying superblock after ->kill_sb() freed s_fs_info and before SB_DEAD: the contract of a test() that dereferences s_fs_info is kill_anon_super() (or kill_super_notify()) before the free |
| `lfnodev_tree` | pass | 1267850 | 10s | two mounters of a get_tree_nodev() filesystem (two superblocks), the first one's fill_super() may fail, both unmount; __iterate_supers(), user_get_super() and two shrinker callbacks |
| `lfnodevtype_tree` | pass | 18417 | 01s | as lfnodev, with iterate_supers_type() over fs_supers |
| `lfsingle_tree` | pass | 1280384 | 09s | two mounters of a get_tree_single() filesystem (test() matches, dereferences s_fs_info), the first one's fill_super() may fail, both unmount, kill_anon_super(); iterate_supers_type(), user_get_super() and two shrinker callbacks |
| `lfsingleall_tree` | pass | 915222 | 08s | as lfsingle, with __iterate_supers() over super_blocks |
| `lftriple_tree` | pass | 145534386 | 13min00s | three mounters of a keyed filesystem (test() dereferences s_fs_info): m1 and m2 share a key, m3 has its own; m1's fill_super() may fail; all unmount; __iterate_supers(), user_get_super() of m1's superblock, a shrinker callback |
| `lftripletype_tree` | pass | 25491716 | 02min11s | as lftriple with iterate_supers_type(), m3's fill_super() may fail instead of m1's, no user_get_super() |

### SuperLife, mutations (a FIX_* switched off)

| Configuration | Result | Distinct states | Time | What it is / what it shows |
|---------------|--------|-----------------|------|----------------------------|
| `lfnodev_no_iter_pin` | violation | 64752 | 02s | NoErr, the iterator drops its reference before it advances: the node is unlinked (and freed) under it |
| `lfnodev_no_rcu_sb` | pass | 1225074 | 10s | nobody in these tasks reaches a superblock after its last put without sb_lock or a reference; the RCU delay of put_super() is not load-bearing for fs/super.c's own walkers |
| `lfnodevtype_no_unlink_late` | violation | 1320 | 01s | NoErr, the shape before 2d2a2d7aa987: iterate_supers_type() holds a passive reference, kill_super_notify() unlinks the node, the iterator advances from an unlinked node and misses the rest |
| `lfsingle_no_dead_lock` | violation | 15902 | 01s | NoErr, SB_DEAD set while sget_fc() is between the SB_DEAD check and test(): the filesystem frees s_fs_info under the running test() |
| `lfsingle_no_dead_skip` | violation | 16919 | 02s | NoErr, test() on a dead superblock whose s_fs_info is freed (in other interleavings grab_super()'s refcount_inc() of an s_passive that hit zero) |
| `lfsingle_no_shrink_first` | violation | 24443 | 01s | NoErr, a shrinker callback runs after ->kill_sb() freed the filesystem |


## Findings

Status as of the model runs; [`../README.md`](../README.md) says what became of each finding.

### 1. fs_holder_ops act on a superblock through a claim that is already gone (SUSPECTED, real with btrfs)

`dtdrop_tree`, `dtdeg_tree`, `dtmultideg_tree` (`traces/`).  A cursor of
fs_bdev_freeze()/fs_bdev_thaw() (and fs_bdev_mark_dead(), fs_bdev_sync(),
user_get_super()) pins an entry with refcount_inc_not_zero() and acts on
sd_sb.  sd_ref counts claims and pins together, so a pinned entry stays
linked after its last claim is dropped ("a pinning cursor defers the actual
unlink", L1760) and the cursor acts on a superblock that no longer uses
the device.  bdev_deny_freeze() closes this for membership changes of a live
superblock (`dtlive_tree` passes, `dtlive_no_deny` fails); before SB_BORN
nothing closes it, and the cursor waits in get_active_super() for SB_BORN.
For xfs, ext4, f2fs and erofs a member device that is refused or released
fails the mount, the superblock goes SB_DYING and the cursor skips it
(`dtshare_tree`, `dtsharefz_tree`, `dtmulti_tree` pass).  btrfs mounts on:

* `dtdrop_tree`: btrfs_open_devices() registers every scanned member,
  open_ctree() -> btrfs_free_extra_devids() releases the ones not in the
  metadata (and btrfs_open_one_device() releases one with a devid/uuid
  mismatch) with fs_bdev_file_release(), no deny.  A bdev_freeze() of that
  device in between (a dm suspend) pins the entry, waits for SB_BORN, then
  freeze_super()s the btrfs superblock through a device it no longer has;
  bdev_thaw() finds no holder and no entry: the filesystem stays frozen
  (FREEZE_HOLDER_USERSPACE, one active reference) until someone FITHAWs it,
  and an unmount never shuts it down.  The window is wide (the chunk tree
  is read in between).
* `dtdeg_tree`: the device is frozen before the mount, the registration is
  refused (L1678) and rolled back (L1680), the mount goes on degraded; a
  bdev_thaw() whose walk pinned the entry between L486 and L1680 waits for
  SB_BORN and thaw_super()s a superblock that was never frozen: -EINVAL with
  count 1, bdev_thaw() keeps bd_fsfreeze_count at 1 (block/bdev.c L367-368),
  dm's unlock_fs() ignores it, and the device refuses every later mount
  ("Can't mount, blockdev is frozen") for good -- the outcome of
  fe967191e585, from another cause.  The pin window is a few instructions.
* `dtmultideg_tree`: with d1 frozen as well, the thaw of d2 through the
  rolled-back entry takes d1's freeze: the filesystem is thawed while d1 is
  still frozen and writes reach a frozen dm device.
* The other walks are benign: user_get_super() (ustat(), quotactl_block())
  can hand out the btrfs superblock for a device it just dropped,
  fs_bdev_sync() syncs it, fs_bdev_mark_dead() calls btrfs_remove_bdev(),
  which does not find the device and returns 0.

I re-read every step of the three traces against fs/super.c, block/bdev.c,
fs/btrfs/{super,volumes,disk-io}.c and drivers/md/dm.c (see the trace
files); none is a modelling artefact.  Reproduction: a multi-device btrfs on
dm devices, a stale member (or -o degraded with a frozen member), `dmsetup
suspend`/`resume` of that member racing the mount; `dtdeg_tree` needs the
L1677 window widened (kprobe/mdelay), `dtdrop_tree` does not.  A fix in
fs/super.c could count claims apart from pins (or mark an entry dead when
its last claim goes) and have the fs_holder_ops walks skip an entry without
claims once get_active_super() succeeded: a release before SB_BORN happens
before the acquire of SB_BORN in super_lock(), and releases on the live
superblock are already excluded by the deny.

### 2. Concurrent fs_bdev_register() of the same (device, superblock): caller contract

`dtdup_tree`, `dtdup_underflow`.  Two registrations of one (dev, sb) in
flight at once both miss each other (L1661) and insert two entries.  A
later fs_bdev_unregister() looks up without a reference (L1772-1774) and
can find the one whose count another unregister just took to zero: refcount_t
underflow, a use-after-free once its kfree_rcu() grace period ends, and the
other entry -- with its passive reference -- is never put, so the superblock
is never freed.  The first counterexample TLC finds is worse: an unregister
removes the second entry between its rhltable_insert() (L486) and its
refcount_inc(s_passive) (L488) and drops a passive reference that was never
taken.  No in-tree caller registers the same (dev, sb) twice at once (mount
paths run under s_umount, btrfs device add/replace are exclusive
operations); sequential re-registration is fine (`dtreadd_tree`) because
insertion goes in front and the lookup takes the first match
(`dtreadd_no_first_match` shows why both matter).  Worth a comment at
fs_bdev_register().

### 3. test() and s_fs_info: filesystem contract, holds in-tree

`lfblock_tree`: a test() that dereferences s_fs_info runs on a dying
superblock until SB_DEAD; a ->kill_sb() that frees s_fs_info before
kill_super_notify() (generic_shutdown_super() or kill_block_super() and then
kfree()) is a use-after-free.  Every test() passed to sget_fc() in the tree
that dereferences s_fs_info -- virtio_fs_test_super, nfs compare_super,
btrfs_fc_test_super, ubifs sb_test, fuse_test_super, kernfs_test_super, ceph
compare_super, cifs_match_super, afs_test_super, afs_dynroot_test_super (gfs2's
test_meta_super, sget_dev()'s super_s_dev_test(), test_keyed_super() and
test_single_super() do not) -- belongs to a ->kill_sb() that frees only after
kill_anon_super() returned (virtio_kill_sb() and fuse_kill_sb_anon() tear
down the connection before it, but the fuse_conn the test reads stays
referenced by the fuse_mount until fuse_mount_destroy() after
kill_anon_super()).  `lfblock_noderef` passes.

### What holds

* sget_fc()/grab_super(): grab_super()'s refcount_inc() always finds
  s_passive >= 1 -- a superblock not SB_DEAD under sb_lock still has the
  killer's alloc_super() reference, which is put only after SB_DEAD; test()
  never runs after kill_super_notify() returned; every waiter for
  SB_BORN|SB_DYING or SB_DEAD proceeds; the allocation of a mounter that
  found an existing superblock was never visible.
* The iterators: the current node stays linked while its passive reference
  is held (the unlink is at the last put since 2d2a2d7aa987), the advance
  never reads an unlinked or freed node, callbacks run on live superblocks.
* user_get_super(): the pinned entry's passive reference makes its
  refcount_inc() safe; the returned superblock is live under s_umount.
* The shrinker: SB_BORN keeps super_cache_count()'s lockless read and
  super_cache_scan()'s trylock off a filesystem under construction, and
  shrinker_free() before ->kill_sb() keeps both off one being torn down
  (`lfsingle_no_shrink_first`).
* The put_super() RCU delay is not load-bearing for fs/super.c's own
  walkers (`lfnodev_no_rcu_sb` passes): they see a superblock only under
  sb_lock or with a reference.  Users elsewhere may rely on it.
* The device table: an entry is unlinked only at zero, freed only after
  removal and a grace period (`dtwalk_no_rcu_free`); its passive reference
  is taken once and dropped once; a cursor resumes only from a pinned node
  (`dtwalk_no_next_pin`), never revisits an entry and never skips one that
  stayed live through the walk; fs_bdev_unregister() always finds the
  entry holding the caller's claim -- the live (dev, sb) entry is the only
  one and stands in front of every dying one -- so it never picks a dying
  entry unless the contract of finding 2 is broken; the publish-then-check
  of fs_bdev_register() and setup_bdev_super() keeps every superblock
  using a frozen device frozen (`dtsharefz_no_publish_first`).

## Not modelled

* Memory ordering: sequentially consistent interleavings; the barrier
  pairings (registration vs bdev_freeze(), super_wake() vs wait_var_event(),
  super_cache_count()'s smp_rmb()) belong in litmus tests.
* The rhltable's internals (bucket chains, resize, nested tables) are
  abstracted to one list per device with the observable semantics above.
* s_flags is one atomic word per flag.  super_wake() stores
  `sb->s_flags | flag` with a plain read-modify-write (L164), and many
  filesystems set SB_RDONLY from error paths with a plain read-modify-write
  and no s_umount (ext2_error(), __fat_fs_error(), __exfat_fs_error(),
  ufs_error(), jfs_handle_error(), __nilfs_error(), hpfs_error(),
  affs_error(), ocfs2_handle_error(), gfs2 do_withdraw(),
  zonefs_handle_io_error(), btrfs_set_sb_rdonly(), ubifs_ro_mode()).  One
  of them overlapping vfs_get_tree()'s super_wake(SB_BORN) (L1963) would
  lose SB_BORN (super_lock() waiters sleep until SB_DYING,
  super_trylock_shared() fails for writeback and the shrinker) or the
  SB_RDONLY.  The window is a few instructions; not modelled and not
  claimed as a finding.
* fill_super() and ->kill_sb() are single steps around the device opens and
  closes; the filesystem's own locks (uuid_mutex, ...) and its RCU users of
  superblocks are not modelled; freeze_super() never fails and nobody else
  freezes (FIFREEZE, filesystems_freeze() are the business of
  SuperFreeze/SuperHolder).
* fs_bdev_mark_dead() and fs_bdev_sync() walk like user_get_super(); their
  effect on a superblock reached through a dropped claim (finding 1) is a
  spurious sync or, for btrfs, btrfs_remove_bdev() not finding the device
  (harmless).
* One mount per mounter, at most three mounters, two superblocks per
  device list, four entries.

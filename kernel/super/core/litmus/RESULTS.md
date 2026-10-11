# Results: fs/super.c ordering protocols under LKMM

herd7 7.58, LKMM from `work.super.fixes/tools/memory-model`, tree at
`fc1c25014ff8`.  38 LKMM tests, all matching their expected result
(`RESULTS-lkmm.txt`), plus 6 architecture-model runs (`RESULTS-hw.txt`).

## Summary

Status as of the model runs; [`../README.md`](../README.md) says what became of each finding.

| # | finding | tests | status |
|---|---|---|---|
| 1 | `fserror_unmount()` (called from `generic_shutdown_super()`) can sleep forever: `fserror_pending_dec()` wakes after `refcount_dec_and_test()`, which is not a full barrier | F3, F3f, F4, aarch64/F3, ppc/F3 | real ordering bug on arm64/POWER/RISC-V (LKMM, Arm and POWER models all allow it); SUSPECTED until reproduced |
| 2 | `s_flags` lost updates: the VFS's non-atomic read-modify-writes (`super_wake()`, `\|= SB_ACTIVE`, `reconfigure_super()`) race with filesystems that write `s_flags` without `s_umount` (FUSE INIT reply, efivarfs notifier, error handlers forcing `SB_RDONLY`) | G1, G1f, G1h, G2, G3 | real race, allowed even under SC; lost `SB_BORN` hangs `sync(2)` and friends until unmount |
| 3 | `bdev_allow_freeze()`'s relaxed `atomic_inc()` is not ordered after the preceding `fs_bdev_unregister()` put | C4, C4f, Z1, aarch64/C4 | LKMM-only gap; forbidden on Arm because the compiled put always branches on its result |
| 4 | every `wake_up_var(&sb->s_writers.frozen)` lacks the barrier `wake_up_var()` requires | F1, F2 | contract violated, code correct: `percpu_down_write()`'s `smp_mb()` after the SB_FREEZE_PAGEFAULT store covers the only waiter |
| 5 | `super_cache_count()` pairs with `super_wake()`'s release store, not with `mount_fs()`; its SB_BORN load is plain | B1, B1m, B1p | sound; stale comment; formal data race |
| - | everything else asked about | A1-A3, B2, C1-C3, D1-D2, E1-E2, G3-G4, H1-H2 | correct, each barrier/lock shown load-bearing by its mutant |

## All tests

| test | question | expected | LKMM | kernel code |
|---|---|---|---|---|
| A1 wake-born-no-lost-wakeup | `super_wake()` (release, `smp_mb()`, `wake_up_var()`) vs `super_lock()`'s `wait_var_event()`: lost wake-up? | Never | Never | correct |
| A1m wake-born-no-mb | same without the `smp_mb()` at super.c:170 | Sometimes | Sometimes | (mutant) the barrier is load-bearing |
| A2 born-publishes-fill-super | waiter that sees SB_BORN sees `s_root`/`s_op`/`s_bdi` (plain accesses) | Never | Never, race-free | correct |
| A2m born-relaxed-load | `super_flags()` with a relaxed load | Sometimes | Sometimes + data race | (mutant) the acquire is load-bearing |
| A3 grab-super-waits-dead | `grab_super()`'s wait for SB_DEAD vs `kill_super_notify()` under `sb_lock` | Never | Never | correct |
| B1 cache-count-born-rmb | `super_cache_count()` SB_BORN (marked) + `smp_rmb()` vs release in `super_wake()` | Never | Never | pairing sound (comment names `mount_fs()`) |
| B1m cache-count-no-rmb | without the `smp_rmb()` | Sometimes | Sometimes | (mutant) load-bearing |
| B1p cache-count-plain-flags | with the kernel's plain SB_BORN load | Sometimes | Sometimes + data race | formal data race only, see finding 5 |
| B2 cache-scan-trylock | `super_cache_scan()`: SB_BORN/`s_root` checked under `s_umount` trylock | Never | Never | correct, needs no barrier |
| C1 register-vs-freeze | `fs_bdev_register()` insert, `smp_mb()`, count vs `bdev_freeze()` inc, lookup (SB) | Never | Never | correct |
| C1m register-no-mb | without the `smp_mb()` at super.c:1669 | Sometimes | Sometimes | (mutant) load-bearing |
| C1m2 freeze-relaxed-inc | freezer increment relaxed instead of fully ordered | Sometimes | Sometimes | (mutant) `atomic_inc_unless_negative()`'s full ordering is load-bearing |
| C2 setup-bdev-super-vs-freeze | entry from `sget_fc()`'s `set()` under `sb_lock`, share path, `setup_bdev_super()`'s `smp_mb()` + count | Never | Never | correct |
| C3 deny-register-allow-vs-freeze | device add: deny, register (count -1), relaxed allow; freezer after the allow misses the claim? | Never | Never | correct (the register `smp_mb()` orders the insert before the allow) |
| C3m deny-register-allow-no-mb | same without the register `smp_mb()` | Sometimes | Sometimes | (mutant) load-bearing |
| C4 unregister-allow-vs-freeze | device removal: unregister then relaxed allow; freezer after the allow pins the dropped claim? | Sometimes | Sometimes | LKMM gap, see finding 3 |
| C4f unregister-allow-ordered | `smp_mb__before_atomic()` in `bdev_allow_freeze()` | Never | Never | fix candidate |
| D1 grab-super-inc-never-zero | `grab_super()`'s `refcount_inc()` under `sb_lock` after the SB_DEAD check can see 0? | Never | Never | correct |
| D1m dead-outside-sb-lock | SB_DEAD set without `sb_lock` | Sometimes | Sometimes | (mutant) `sb_lock` around `super_wake(SB_DEAD)` is load-bearing (fails even under SC) |
| D2 iterate-inc-not-zero-vs-final-put | `__iterate_supers()` `refcount_inc_not_zero()` vs final `put_super()`, unlink, `call_rcu()` | Never | Never | correct |
| E1 cursor-pin-vs-claim-put | cursor pins, drops RCU, resumes from `prev->sd_node.next` vs owner's `super_dev_put()` | Never | Never | correct |
| E1m unlink-at-owner-put | unlink at the owner's put instead of at zero | Sometimes | Sometimes | (mutant) "unlink only once unpinned" is load-bearing |
| E2 cursor-skips-dying-entry | cursor meets an entry at ref 0 within one RCU section | Never | Never | correct (remove before `kfree_rcu()`) |
| F1 frozen-wake-no-mb-isolated | `frozen = X; wake_up_var()` without barrier, in isolation | Sometimes | Sometimes | contract violated, see finding 4 |
| F2 frozen-wake-covered-by-pagefault-mb | with the SB_FREEZE_PAGEFAULT store and `percpu_down_write()`'s `smp_mb()` | Never | Never | code correct |
| F3 fserror-unmount-lost-wakeup | `fserror_pending_dec()` vs `fserror_unmount()` | Sometimes | Sometimes | BUG, finding 1 |
| F3f fserror-wake-after-mb | `smp_mb()` before `wake_up_var()` | Never | Never | fix |
| F4 cgwb-drain-atomic-dec-and-test | `cgroup_writeback_unpin()` (`atomic_dec_and_test()`) vs drain | Never | Never | correct, the pattern F3 should follow |
| G1 born-lost-to-lockless-sflags-rmw | FUSE `process_init_reply()` `\|= SB_NOSEC` vs `\|= SB_ACTIVE` + `super_wake(SB_BORN)` | Sometimes | Sometimes | BUG, finding 2 |
| G1f sflags-atomic-both-sides | all writers atomic | Never | Never | what a lock-free fix needs |
| G1h sflags-atomic-vfs-only | only the VFS side atomic | Sometimes | Sometimes | not a fix |
| G2 rdonly-lost-to-reconfigure-or-reuse | error handler `\|= SB_RDONLY` vs `reconfigure_super()` and a reusing mount's `super_wake(SB_BORN)` | Sometimes | Sometimes | BUG, finding 2 |
| G3 vfs-sflags-writers-serialised | VFS writers among themselves (`s_umount`) | Never | Never | correct |
| G4 remount-ro-vs-write-access | `s_readonly_remount` protocol around `reconfigure_super()`'s `s_flags` write vs `mnt_get_write_access()` | Never | Never | correct |
| H1 dio-wq-publish | `try_cmpxchg()` publication of `s_dio_done_wq` vs a dereferencing reader | Never | Never | correct (reader load plain) |
| H1m dio-wq-publish-relaxed | relaxed cmpxchg | Sometimes | Sometimes | (mutant) full ordering is load-bearing |
| H2 dio-wq-racing-init | two initialisers and a reader | Never | Never | correct |
| Z1 lkmm-ctrl-dep-ends-at-if | reference: control dependency past the end of an if | Sometimes | Sometimes | (LKMM semantics) |

Architecture models (`RESULTS-hw.txt`): aarch64/F3 Sometimes, aarch64/F3f
Never, ppc/F3 Sometimes, ppc/F3f Never, aarch64/C4 Never,
aarch64/C4m-no-branch Sometimes.

## Finding 1: fserror_unmount() lost wake-up (F3)

`generic_shutdown_super()` (super.c:733, `s_umount` held) calls
`fserror_unmount()`:

    31	if (!refcount_dec_and_test(&sb->s_pending_errors))
    32		wait_var_event(&sb->s_pending_errors,
    33			       refcount_read(&sb->s_pending_errors) < 1);

and the last queued error report frees itself through
`fserror_pending_dec()`:

    38	if (refcount_dec_and_test(&sb->s_pending_errors))
    39		wake_up_var(&sb->s_pending_errors);

`wake_up_var()` needs a full barrier between making the condition true
and its `waitqueue_active()` check ("If the variable was updated by a
fully ordered operation such as atomic_dec_and_test() then no extra
barrier is required. Otherwise smb_mb() is needed.").
`refcount_dec_and_test()` is `atomic_fetch_sub_release()` plus, on
success, `smp_acquire__after_ctrl_dep()` = `smp_rmb()`: that orders the
decrement's load, not its store, before the queue check.  Store buffering:
the worker's `waitqueue_active()` can read an empty queue while the
unmount, already queued and past `set_current_state()`'s `smp_mb()`,
re-reads `s_pending_errors == 1`.  LKMM allows it (F3), so do the Arm
model (`LDADDL; DMB ISHLD; LDR`) and the POWER model
(`lwsync; lwarx/stwcx.; lwsync; lwz`).  x86 is immune (`LOCK XADD`).

Consequence: the unmount (or the last `deactivate_super()`) sleeps in
`TASK_UNINTERRUPTIBLE` forever inside `generic_shutdown_super()` with
`s_umount` held exclusively and SB_DYING not yet set; every
`super_lock()` on that superblock then blocks on `s_umount`, so
`sync(2)` hangs system-wide too.  Reference budget: the worker touches
only the address of `s_pending_errors` after its decrement, so there is no
use-after-free, only the hang.

Trigger: a filesystem that reports through fserror (iomap buffered
write errors in `fs/iomap/ioend.c:63`, ext4, f2fs, btrfs) with write
errors injected during the final sync (dm-flakey/dm-error table switch
or scsi_debug), unmount, repeated, on arm64/POWER/RISC-V.  No window to
widen: it is a store-buffer reorder, so it needs many iterations on
weakly ordered hardware.  Status: SUSPECTED (memory-model proof, not
reproduced).

Fix (F3f): `smp_mb()` between `refcount_dec_and_test()` and
`wake_up_var()` in `fserror_pending_dec()`, or an `atomic_t` with
`atomic_dec_and_wake_up()`.  `cgroup_writeback_umount()`, one line later
in `generic_shutdown_super()`, has the same shape and is correct because
it uses `atomic_dec_and_test()` (F4).  While at it: the wait condition
uses `refcount_read()`; `wait_var_event()`'s comment asks for an acquire,
and the accesses after the wait are only ordered by the control
dependency and later locks (a formal gap of the C4 kind, not a separate
bug).

## Finding 2: s_flags lost updates (G1, G2)

The VFS writers of `s_flags` are non-atomic read-modify-writes and are
serialised among themselves (G3, enumeration below): `super_wake()`
for SB_BORN and SB_DYING, `vfs_get_super()`/`get_tree_bdev_flags()`'s
`|= SB_ACTIVE`, `generic_shutdown_super()`'s `&= ~SB_ACTIVE` and
`reconfigure_super()`'s `WRITE_ONCE()` all hold `s_umount` exclusively
(and `reconfigure_super()` an active reference, so never during
shutdown); `super_wake(SB_DEAD)` runs under `sb_lock` only, after every
other writer is excluded.  No VFS writer can lose another's bit.

Filesystems write `s_flags` without `s_umount`, and a plain `|=` against
those VFS read-modify-writes loses one side's update even under
sequential consistency (G1, G2; making only the VFS side atomic does not
help, G1h):

- FUSE, `process_init_reply()` (fs/fuse/inode.c:1367,
  `fm->sb->s_flags |= SB_NOSEC`), runs in the daemon's `write(2)` of the
  FUSE_INIT reply.  With the default asynchronous INIT,
  `fuse_fill_super()` returns right after queueing the request, and the
  mounter then does `sb->s_flags |= SB_ACTIVE` (super.c:1394) and
  `super_wake(sb, SB_BORN)` (super.c:1955) while the daemon may be
  answering.  If the daemon's load precedes the mounter's store and its
  store follows it, SB_BORN (or SB_ACTIVE) is lost.  Lost SB_BORN:
  `super_lock()` waits for SB_BORN|SB_DYING, so every `sync(2)`,
  drop_caches write, quota sync and emergency remount/thaw that reaches
  this superblock sleeps uninterruptibly until it is unmounted, which the
  daemon owner controls (`filesystems_freeze()` skips FUSE, which has no
  `freeze_fs`); `super_trylock_shared()`
  fails, so the flusher never writes back its dirty inodes, and
  `super_cache_count()` returns 0, so it is never shrunk.  Lost
  SB_ACTIVE: `fuse_evict_inode()` stops sending FORGETs, `iput_final()`
  stops caching.  FUSE is `FS_USERNS_MOUNT`, so an unprivileged user can
  run the daemon.  The shutdown side is safe: `fuse_conn_destroy()` waits
  for an in-flight INIT reply (`fuse_chan_wait_aborted()`; the end
  callback runs before `fuse_put_request()` drops `num_waiting`).
  Status: CONFIRMED by inspection (two unsynchronised plain
  read-modify-writes of one word, no common lock), window of a few
  instructions on each side; a reproducer needs the window widened (debug
  delay between the load and the store in `process_init_reply()`) or
  many mount attempts with a daemon thread already blocked in
  `read(/dev/fuse)`.
- efivarfs, `efivarfs_ops_notifier()` (`|= SB_RDONLY` / `&= ~SB_RDONLY`),
  registered in `efivarfs_fill_super()`, fires from `efivars_register()`
  at any time (e.g. a backend module loading while efivarfs is mounted):
  same race with `|= SB_ACTIVE`/`super_wake(SB_BORN)` at mount, with a
  reusing `get_tree_single()` mount and with remount.  A lost SB_BORN
  here also hangs suspend's `filesystems_freeze()` (efivarfs has
  `freeze_fs` and `FS_POWER_FREEZE`).  Unregistered before
  `kill_anon_super()`, so shutdown is safe.
- Error handlers forcing read-only with a lockless `|= SB_RDONLY`
  (list below).  Against `reconfigure_super()` (any remount) and against
  the `super_wake(SB_BORN)` that `vfs_get_tree()` repeats on a reused live
  superblock (second mount of the same device, `get_tree_single()`,
  `get_tree_keyed()`), the forced SB_RDONLY can be lost (G2): the
  filesystem announced "remounting read-only" but `mnt_want_write()`
  keeps granting writes.  For filesystems whose background threads run
  during `fill_super()` (jfs, nilfs2, ocfs2, gfs2, ubifs) the same race
  against a new mount's `|= SB_ACTIVE`/`super_wake(SB_BORN)` can lose
  SB_BORN.  btrfs avoids the new-mount case by checking SB_BORN first.
  ext4 stopped doing this in d3476f3dad4a ("ext4: don't set SB_RDONLY
  after filesystem errors": "that requires sb->s_umount").

Fix direction: no `s_flags` writes without `s_umount` on the filesystem
side (FUSE can record `handle_killpriv_v2` and apply SB_NOSEC under
`s_umount` or test its own flag; error handlers can use a private flag as
ext4 does), or every writer an atomic bit operation (G1f).  A cheap VFS
hardening is to skip `super_wake(SB_BORN)` in `vfs_get_tree()` when the
superblock is already born, so a reusing mount stops rewriting the flags
of a live superblock; it does not fix the new-mount case.

## Finding 3: bdev_allow_freeze() after fs_bdev_unregister() (C4)

btrfs drops a claim taken under a freeze deny and then re-allows
freezing (`btrfs_release_device_allow_freeze()`, volumes.c:1137-1139,
"Unregister before re-allowing (strand-safe)").  The put is
`refcount_dec_and_test()` (release; acquire only on success) and the
allow a relaxed `atomic_inc()` after the put returned.  Under LKMM
nothing orders the put's load of `sd_ref` before the allow's store (the
release orders what precedes the put, and a control dependency ends at
the end of the if, Z1), so a `bdev_freeze()` that read the allow can
still pin the claim before the put in `sd_ref`'s coherence order, freeze
the superblock through it and strand that freeze (its own put unlinks
the claim, the matching thaw walk finds nothing).  On real CPUs the put
always ends in branches on its result (`old > 0 && old == i`, the
saturation check, `super_dev_put()`'s if), and stores are not performed
before those branches resolve: the Arm model forbids the outcome
(aarch64/C4) and allows it once the branch is removed
(aarch64/C4m-no-branch).  Not an observable bug.  If the deny/allow pair
is meant to be self-contained under LKMM, `bdev_allow_freeze()` should
be fully ordered like `bdev_deny_freeze()`: `smp_mb__before_atomic()`
before the `atomic_inc()` (C4f).

The add direction (C3) is correct: a freezer can only succeed after the
deny by reading the allow, and `fs_bdev_register()`'s `smp_mb()` orders
the insert before the allow (C3m shows it is the barrier that does it).

## Finding 4: s_writers.frozen wake-ups (F1, F2)

None of the six `wake_up_var(&sb->s_writers.frozen)` calls
(super.c:2284, 2304, 2320, 2332, 2369, 2387) has the barrier
`wake_up_var()` requires after the plain `frozen` store; `sb_freeze_unlock()`
between store and wake on two of them is a lock/unlock pair, not a full
barrier.  In isolation that allows a lost wake-up (F1).  The code is
nevertheless correct (F2): the only waiter, `wait_for_partially_frozen()`,
can only have read SB_FREEZE_WRITE under `s_umount` (`freeze_super()`
drops `s_umount` only in that stage; nothing outside fs/super.c writes
`frozen`), so it waits for `frozen != SB_FREEZE_WRITE`.  The store that
first makes that true, SB_FREEZE_PAGEFAULT (super.c:2296), is always
followed by `sb_wait_write()` -> `percpu_down_write()`, which executes
`smp_mb()` in `readers_active_check()` before returning, and every later
wake (COMPLETE, the UNFROZEN error paths, a later thaw or rdonly freeze)
comes after that barrier.  Store buffering against that store forbids
the lost wake-up.  Fragile, undocumented, and the lockless `frozen`
reads/writes are plain (a data race); `store_release_wake_up()` at each
site would make every pair correct on its own.  Not a bug.

## Finding 5: super_cache_count() (B1, B1p)

The SB_BORN check plus `smp_rmb()` pairs with the release store in
`super_wake(SB_BORN)` (B1: Never; B1m without the `smp_rmb()`:
Sometimes).  The comment's "matched with the one in mount_fs()" names a
function that no longer exists; `vfs_get_tree()`'s comment at
super.c:1949 names the real partner.  The SB_BORN load is plain and races
with the release store (B1p: herd7 flags the race and LKMM then gives no
guarantee).  In practice the compiler emits one load and the code works;
`super_flags(sb, SB_BORN)` would make it race-free and subsume the
`smp_rmb()`.  `super_cache_scan()` needs nothing extra: its checks run
under the `s_umount` trylock (B2).

## Item-by-item

1. `super_wake()` vs `super_lock()`/`super_flags()`: no lost wake-up (A1,
   A3 for SB_DEAD under `sb_lock`), and SB_BORN publishes the
   `fill_super()` state through the acquire alone (A2).  Both the
   `smp_mb()` and the acquire are load-bearing (A1m, A2m).
2. `super_cache_count()`: sound, see finding 5.  The shrinker registered
   in `sget_fc()` before `fill_super()` is harmless: count bails until
   SB_BORN, scan's `super_trylock_shared()` fails while the mounter holds
   `s_umount` and checks SB_BORN/`s_root` under it afterwards (B2).
3. Device table vs freeze: the SB shape is forbidden for
   `fs_bdev_register()` (C1) and `setup_bdev_super()` (C2); both
   `smp_mb()`s and the full ordering of `atomic_inc_unless_negative()` are
   load-bearing (C1m, C1m2).  Device add under deny/allow cannot hide a
   claim from a freezer (C3).  Device removal under deny/allow: finding 3.
4. `put_super()` vs walkers: `grab_super()`'s `refcount_inc()` can never
   see zero, because SB_DEAD is set inside `sb_lock` before the last
   reference can go (D1); without `sb_lock` it fails even under SC (D1m).
   `refcount_inc_not_zero()` walkers are safe by atomicity (D2).
5. `super_dev_put()` vs cursors: a pinned entry is never unlinked under a
   cursor (E1), the relaxed `refcount_inc_not_zero()` is enough because
   the removal is program-ordered after the cursor's resume, and an entry
   at zero is safe to step over within one RCU section (E2).  Unlinking at
   the owner's put instead would break it (E1m).
6. Freeze wake-ups: finding 4.  The only `wake_up_var(&sb->s_flags)`
   (`super_wake()`) has its `smp_mb()`.  Beyond fs/super.c proper, the
   `fserror_unmount()` wait in `generic_shutdown_super()` is broken
   (finding 1); `cgroup_writeback_umount()` is fine (F4).
7. `s_flags`: finding 2.  The RO remount protocol that lets write paths
   read SB_RDONLY locklessly is correct (G4).
8. `sb_init_dio_done_wq()`: the fully ordered `try_cmpxchg()` publishes
   the workqueue (H1, H1m); racing initialisers publish exactly one
   (H2).  `generic_shutdown_super()`'s `destroy_workqueue()` cannot race
   with it: callers hold an open file, hence an active reference, and the
   final `fput()` from a DIO completion is deferred to `delayed_fput`, not
   run on `s_dio_done_wq`.

## Enumeration of s_flags writers (item 7)

`grep -rnE` over the tree for `->s_flags (|=|&=|^=|=)`, `WRITE_ONCE(..s_flags`,
`smp_store_release(&..s_flags` and bit operations on `&..->s_flags`, then
filtered to `struct super_block` (175 sites; bit operations: none).

VFS core, serialised (G3):

| site | context |
|---|---|
| super.c:363 `alloc_super()` `s->s_flags = flags` | unpublished superblock |
| super.c:164 `super_wake()` SB_BORN (super.c:1955) | `s_umount` excl, mounter |
| super.c:164 `super_wake()` SB_DYING (super.c:787) | `s_umount` excl |
| super.c:164 `super_wake()` SB_DEAD (super.c:566) | `sb_lock` only, after `generic_shutdown_super()`; all `s_umount` takers back off on SB_DYING |
| super.c:731 `&= ~SB_ACTIVE` | `s_umount` excl |
| super.c:1138 `reconfigure_super()` | `s_umount` excl + active ref (also via `do_emergency_remount_callback()` after "super: don't put the remount context under s_umount") |
| super.c:1394, 1877 `\|= SB_ACTIVE` | `s_umount` excl, mounter |

Filesystem `fill_super()`/`get_tree()`/`kill_sb()` paths (`s_umount`
held by the mounting/unmounting thread, sequential with the VFS writers
in the same thread): 9p, adfs, affs (super.c), afs, befs, btrfs
(super.c:995), ceph, coda, cramfs, ecryptfs, erofs, efivarfs (377), exfat
(super.c), ext2 (941, 1205), ext4 (super.c:2880/2881/3662/5434/5646,
orphan.c), f2fs (fill_super, recovery.c, disable_checkpoint,
recover_quota_*, kill_f2fs_super), fat (inode.c, namei_msdos.c), fuse
(1613, 1707, 1769), virtio_fs (1747), gfs2 (ops_fstype.c), hfs (mdb.c:225,
289, 293, btree.c), hfsplus (super.c fill, btree.c), hpfs (550), jffs2,
jfs (483), kernfs, mtd, nfs, nilfs2 (super.c:872, 1230, the_nilfs.c),
ntfs (load_system_files), ntfs3, ocfs2 (1024, 1970), openpromfs,
overlayfs, proc, qnx4, qnx6, romfs, cifs, squashfs, ubifs (super.c),
ufs (fill_super), xfs (xfs_log.c:697/701, xfs_super.c:1933,
`set_posix_acl_flag()`), zonefs (fill), shmem.

Reconfigure callbacks (`s_umount` held via `reconfigure_super()`): ext2,
ext4, f2fs, gfs2, hfs, hfsplus, jfs, nilfs2, ocfs2, ufs, btrfs
(super.c:1325, 1354).

Boot-time on internal mounts: `nsfs_init()`, `aa_create_aafs()`.

Lockless runtime writers (no `s_umount`, any thread) - the racing side of
finding 2:

| site | trigger |
|---|---|
| fs/fuse/inode.c:1367 `process_init_reply()` `\|= SB_NOSEC` | daemon's FUSE_INIT reply, async by default |
| fs/efivarfs/super.c:33, 36 `efivarfs_ops_notifier()` | `efivars_register()`/`unregister()` |
| fs/affs/amigaffs.c:484 `affs_error()` | error |
| fs/btrfs/super.h:28 via messages.c:175 `btrfs_handle_fs_error()` | error, only after SB_BORN |
| fs/exfat/misc.c:44 `__exfat_fs_error()` | error |
| fs/ext2/super.c:79 `ext2_error()` | error |
| fs/fat/misc.c:38 `__fat_fs_error()` | error |
| fs/gfs2/util.c:136 `do_withdraw()` | withdraw |
| fs/hfs/mdb.c:346, 380 `hfs_mdb_commit()` | `flush_mdb()` delayed work |
| fs/hpfs/super.c:84 `hpfs_error()` | error |
| fs/jfs/super.c:77 `jfs_handle_error()` | error |
| fs/nilfs2/super.c:145 `__nilfs_error()` | error |
| fs/ntfs/super.c:341 `ntfs_handle_error()` | error |
| fs/ocfs2/super.c:2490 `ocfs2_handle_error()` | error |
| fs/ubifs/io.c:75 `ubifs_ro_mode()` | error |
| fs/zonefs/super.c:347, 408; file.c:838 | I/O error, file close |

Readers that matter: `super_flags()` (acquire), `super_lock()`'s SB_DYING
check under `s_umount`, `super_cache_count()` (plain, finding 5),
`super_trylock_shared()` (under `s_umount`), `sb_rdonly()` (plain, inside
the `s_readonly_remount` protocol for write paths, G4).

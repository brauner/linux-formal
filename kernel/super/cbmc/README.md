# CBMC harnesses for fs/super.c freeze/thaw and the device table

Tree: `vfs/work.super.fixes` @ **fc1c25014ff8** (v7.3-rc6-301), `fs/super.c`
and `block/bdev.c`.  The harnesses copy the fc1c25014ff8 text.  Three fixes
that came out of this work can be switched on; the switches carry the SHA
the commit had when the harness was written, the commits now live on
work.super.fixes.core:

| switch | commit |
|---|---|
| `PATCH_9ae90f06a813` | "super: don't warn when resume thaws a userspace freeze" (the may_unfreeze() reorder) |
| `PATCH_86d692e754a8` | "fs: don't keep a device frozen when its freeze is already gone" |
| `PATCH_e7552629ff47` | "fs: don't fail fs_bdev_freeze() once a superblock is frozen" |

The `sb_freeze_wake()` hunk of "quota: really wait for the thaw in
quotactl_block()" (`smp_mb()` before `wake_up_var()`) is a memory-ordering
change and invisible here.

CBMC 6.6.0 (`~/opt/fv`), CaDiCaL backend, every run under
`systemd-run --user --scope -p MemoryMax=6G`, one at a time (`run.sh`).

## Results

All runs: CBMC 6.6.0, CaDiCaL, `--unwinding-assertions --bounds-check`
(CBMC 6 adds pointer/overflow checks by default), step loop bound
NSTEPS+1, coroutine back edges 2 (holder walks 4).  "PASS" = no
counterexample within the bound.  Logs: `results/<config>[.<property>].log`.

### freeze.c (one superblock; fc1c25014ff8 unless a PATCH is named)

| config | steps | callers | result | wall |
|---|---|---|---|---|
| freeze-pm | 6 | FIFREEZE/FITHAW, in-kernel KERNEL freezer, filesystems_freeze/thaw | **FAIL** 1/1033: `WARN may_unfreeze: EXCL thaw with freeze_kcount == 0` (F1) | 15 s |
| freeze-pm-fixed (`PATCH_9ae90f06a813`) | 7 | same | PASS 0/1033 | 28 s |
| freeze-bdev | 6 | FIFREEZE/FITHAW (holder only), bdev_freeze/thaw on 1-2 devices | **FAIL** 1/1569: count stuck above holders (`->unfreeze_fs()` failure, F4) | 343 s |
| freeze-bdev-nounfreezefail | 7 | same, `->unfreeze_fs()` cannot fail | PASS 0/1569 | 1067 s |
| freeze-bdev-anon | 6 | + USERSPACE thaws by non-holders | **FAIL** 2/1569: count stuck; bdev holder exists but sb thawed (F2) | 504 s |
| freeze-bdev-syncblk | 6 | + `sync_blockdev()` failure | **FAIL** 1/1569: failed bdev_freeze() left an orphaned hold (F3) | 450 s |
| freeze-emergency | 6 | + SysRq-j emergency thaw | **FAIL** 1/1571: count stuck (member device, F2) | 1252 s |
| freeze-life | 6 | FIFREEZE/FITHAW, KERNEL freezer, bdev (1 dev), remount, umount/mount | **FAIL** 1/1578: count stuck (`->unfreeze_fs()` failure, F4); remount/rdonly/active-ref properties pass | 468 s |
| freeze-fserr-ro | 6 | FIFREEZE/FITHAW, KERNEL freezer, remount, fs error sets SB_RDONLY | **FAIL** 2/1006: rwsems write-held while UNFROZEN; rwsems don't match the freeze path (F5) | 8 s |
| freeze-all (`PATCH_9ae90f06a813`, no `->unfreeze_fs()` failure) | 5 | every paired caller, 1-2 devices, remount, mounts | PASS | 393 s |
| freeze-bdev-anon-n5 / freeze-bdev-anon-fixed (`PATCH_86d692e754a8`) | 5 | as freeze-bdev-anon, property "count stuck" only | **FAIL** 8 s / PASS 9 s |
| freeze-emergency-n5 / freeze-emergency-fixed (`PATCH_86d692e754a8`) | 5 | as freeze-emergency, property "count stuck" only | **FAIL** 12 s / PASS 14 s |
| freeze-bdev-syncblk-n5 / freeze-bdev-syncblk-fixed (`PATCH_e7552629ff47`) | 5 | as freeze-bdev-syncblk, property "orphaned hold" only | **FAIL** 7 s / PASS 8 s |

### holder_errs.c (1..NSB superblocks on one device; targeted properties)

| config | steps | property | result | wall |
|---|---|---|---|---|
| holder-core (NSB=2) | 6 | `bdev_freeze()==0 but a live sb on the device is not frozen (swallowed error)` | **FAIL** (two writable sbs, one freeze fails) | 16 s |
| holder-core | 6 | `bdev_thaw()==0 but an sb keeps the device's hold (swallowed error)` | **FAIL** (two sbs, one `->unfreeze_fs()` fails) | 17 s |
| holder-core | 6 | count stuck above holders | **FAIL** (second sb died before the walk, so the remaining sb's `->unfreeze_fs()` error is reported, F4) | 17 s |
| holder-syncblk | 6 | failed bdev_freeze() left an orphaned hold | **FAIL** (F3) | 15 s |
| holder-anon | 6 | device hold recorded but the sb is thawed | **FAIL** (F2) | 18 s |
| holder-anon | 6 | count stuck above holders | **FAIL** (F2) | 16 s |
| holder-emergency | 6 | count stuck above holders | **FAIL** (F2) | 30 s |
| holder-erofs (shared device => SB_RDONLY, no `->freeze_fs`) | 6 | swallowed freeze error | PASS | 16 s |
| holder-erofs | 6 | swallowed thaw error | PASS | 18 s |
| holder-erofs | 6 | count stuck above holders | **FAIL** (nsb=1, writable, `->unfreeze_fs()` failure: F4) | 18 s |

Full-property holder runs (NSB=3/8 steps, NSB=3/6 steps) found their
counterexamples in the first SAT iterations but did not finish the final
UNSAT call (stopped at 27 and 22 minutes), so they have no summary.

### devtable.c (NDEV=2)

| config | steps | property | result | wall |
|---|---|---|---|---|
| devtable-serial (sliced, per property) | 8 | no `refcount_dec_and_test()` below 0 (row refs, `s_passive`) | PASS | 236 s |
| devtable-serial | 8 | `fs_bdev_unregister()` finds a claimed row | PASS | 129 s |
| devtable-serial | 8 | no `refcount_inc()` on 0 | PASS | 53 s |
| devtable-serial | 8 | a row drops its passive ref exactly once | PASS | 35 s |
| devtable-serial | 8 | no superblock freed while a row points to it | PASS | 66 s |
| devtable-serial | 8 | `s_passive == base + rows + user_get_super refs` | PASS | 243 s |
| devtable-serial | 8 | quiescent: table empty / rows freed / superblocks freed | PASS / PASS / PASS | 25 / 26 / 47 s |
| devtable-serial | 8 | refs of a pair's rows == claims + pins + pending | no result (900 s cap) | |
| devtable-tail (`CFG_INSERT_TAIL`) | 10 | no refcount underflow | **FAIL** (depends on rhltable head insertion) | 263 s |
| devtable-nonserial (`CFG_SERIAL=0`) | 10 | no refcount underflow | **FAIL** (concurrent same-pair registers) | 53 s |
| devtable-nonserial | 10 | `fs_bdev_unregister()` finds a claimed row | PASS | 544 s |
| devtable-nonserial | 10 | quiescent: no row leaked | **FAIL** (same root cause; sb never freed) | 340 s |

Full-property devtable-serial runs at 10 and 8 steps hit the 1800 s cap in
their first (UNSAT) SAT call.

## Findings

Status as of the model runs; [`../README.md`](../README.md) says what became of each finding.

The traces are in `results/` (`trace_ops.py` condenses them); in short
(fc1c25014ff8 line numbers):

| # | what | classification | fixed on |
|---|---|---|---|
| F1 | `may_unfreeze()` WARN (`freeze_kcount == 0`, super.c:2157) from `filesystems_thaw()` on every resume while an fs is frozen by FIFREEZE or a bdev freeze; reported 2026-09-11 ("[BUG] WARNING in thaw_super_locked"), the reply attributing it to fe967191e585 is wrong | WARN reachable but harmless (panic with panic_on_warn) | "super: don't warn when resume thaws a userspace freeze" (work.super.fixes.core); verified by freeze-pm-fixed |
| F2 | a USERSPACE thaw by a non-holder (FITHAW, qemu-guest-agent's thaw loop, gfs2 sysfs, `xfs_dax_notify_failure_thaw()`, SysRq-j for non-`s_bdev` devices) consumes the bdev freeze's `MAY_NEST\|USERSPACE` hold; the device's `bdev_thaw()` then gets -EINVAL and keeps `bd_fsfreeze_count` at 1 forever (unmountable, later dm suspends don't freeze) | real kernel bug, long-standing | "fs: don't keep a device frozen when its freeze is already gone" (work.super.fixes.core) for the stuck count; thawing under a suspended device stays by design (shared `freeze_ucount`) |
| F3 | `fs_bdev_freeze()` returns `sync_blockdev()`'s error after freezing: `bdev_freeze()` fails, nobody thaws, the sb stays frozen | real kernel bug, since v6.8 (fbcb8f39e96d) | "fs: don't fail fs_bdev_freeze() once a superblock is frozen" (work.super.fixes.core) |
| F4 | `->unfreeze_fs()` failure inside `bdev_thaw()`: hold restored, count kept, callers forget | real only for jfs (only failing `->unfreeze_fs()`); transient | jfs part of F5 on work.fs.sb_rdonly ("jfs: don't set SB_RDONLY after filesystem errors"); the kept count is intended (hold still there) |
| F5 | SB_RDONLY set by an fs error path while frozen: final thaw takes the `sb_rdonly()` branch, the sb_writers rwsems stay write-held, every writer hangs | real, filesystem-contract class (d3476f3dad4a) | work.fs.sb_rdonly (ext2, jfs, nilfs2, fat, exfat, hfs, affs, ufs, hpfs, ntfs, ocfs2, zonefs, btrfs, gfs2, efivarfs) |
| F6 | shared device: per-sb freeze/thaw errors swallowed when several sbs use the device | not reachable in-tree (only erofs shares, erofs is read-only without `->freeze_fs`; holder-erofs PASS) | - |
| F7 | device table: serial case verified; correctness depends on rhltable inserting a duplicate key at the head; without the per-pair serialisation two concurrent registers of one (dev, sb) give a double put / use-after-free and a leaked row | harness demonstration of assumptions, no in-tree trigger | - |

No harness artefact remains among the reported failures.  One was found and
fixed during the work: deferring the removal for every last
`super_dev_put()` produced a same-pair counterexample the kernel cannot
reach (the filesystem's own put removes the row before it returns); the
dying window is now modelled for cursor puts only.


## Files

| file | what |
|---|---|
| `kernel_freeze.h` | copied kernel code: `freeze_inc/dec`, `may_freeze`, `may_unfreeze`, `freeze_super` + `wait_for_partially_frozen` (as one coroutine), `thaw_super_locked`, `thaw_super`, `super_lock`, `deactivate_(locked_)super`, `get_active_super`, `bdev_freeze`/`bdev_thaw` with `fs_bdev_freeze`/`fs_bdev_thaw`/`fs_super_freeze`/`fs_super_thaw` inlined (as coroutines); stubs; result checkers; per-sb invariants |
| `freeze.c` | harness 1: one superblock, every real caller of `freeze_super()`/`thaw_super()` |
| `holder_errs.c` | harness 3: 1..3 superblocks on one device, `fs_bdev_freeze()`/`fs_bdev_thaw()` error aggregation and `bd_fsfreeze_count` |
| `devtable.c` | harness 2: `super_dev` table claim counting (sget registration, `fs_bdev_register()`/`fs_bdev_unregister()`, cursors, `kill_super_notify()`, passive refs) |
| `run.sh` | configurations and the exact cbmc command lines (`./run.sh -l`) |
| `trace_ops.py` | condenses a `--trace` log into the operation sequence |
| `results/` | one log per configuration (`<config>.log`), traces as `<config>.<property>.log` |

## Method

Threaded CBMC is unusable for this kind of code (see
`../../work.mount.gp_on_demand.proposal/cbmc/README.md`), so every harness is
sequential.  Concurrency is a nondeterministic sequence of NSTEPS atomic
steps; a step starts one caller operation or resumes one that sleeps with
the lock dropped.  Each operation runs atomically under the locks the
kernel holds for it.  The places where the kernel drops a lock mid-operation
are resume points of a coroutine:

- `freeze_super()`: after `super_unlock_excl()`, before
  `sb_wait_write(SB_FREEZE_WRITE)` (`frozen == SB_FREEZE_WRITE`, s_umount free);
- `wait_for_partially_frozen()`: after `up_write(&sb->s_umount)`, in
  `wait_var_event_killable()`.  The waiter is resumed only when
  `frozen != old` holds (the wait returns 0), or - when it does not hold -
  by a fatal signal (`-ERESTARTSYS`), as `___wait_event()` tests the
  condition before the signal;
- `fs_bdev_freeze()`/`fs_bdev_thaw()` walks: between two rows (only
  `bd_fsfreeze_mutex` is held there; a row pinned by the cursor can lose
  its superblock before the visit, so `get_active_super()` fails), and
  inside the per-row `freeze_super()`.

Up to two freezers can sleep at once in `freeze.c` (one in the
`SB_FREEZE_WRITE` window, one in `wait_for_partially_frozen()`).

The code between two resume points is the kernel text.  Two CBMC lessons
from writing these: (1) arrays of large structs indexed by a symbolic
value made one step cost 8.7M variables; separate objects (`FR0/FR1`,
`BDEV0/BDEV1`, `SB0..SB2`) behind pointers with small value sets cost 128k;
(2) the coroutine back edges (`goto retry`, the wait loop) are taken at
most once per step, so they get `--unwindset ...:2` instead of the global
step bound.

## Stubbing decisions

| kernel | model | why it is safe / what it hides |
|---|---|---|
| `s_umount` rw_semaphore | `int` owner flag; `down_write()`/`up_write()` assert balance; all modelled users take it exclusive | the modelled paths (freeze, thaw, get_active_super, grab_super, reconfigure) all take it exclusive; asserts catch double acquire/release and "held between steps" |
| `percpu_rw_semaphore s_writers.rw_sem[3]` | write-held flag per level; `percpu_down_write()` asserts the level is free | `sb_start_write()` readers are not modelled (they only delay the freezer); a level that a thaw forgets stays "held" and is caught by the invariants |
| `WARN_ON_ONCE(c)` / `WARN_ONCE(1, ...)` | `WARN_ON_ONCE(SITE, c)`: per-site assertion, path continues | every WARN is a separate CBMC property; the kernel continues after a WARN, so does the model |
| `wake_up_var()` | no-op | the scheduler resumes a sleeper only when its condition holds |
| `wait_var_event()` in `super_lock()` | `assume(SB_BORN \| SB_DYING)` | all modelled superblocks are born; dying ones fail `super_lock()` as in the kernel |
| `atomic_t` | `int` | steps are atomic |
| `sync_filesystem()`, `->freeze_fs()`, `->unfreeze_fs()`, `sync_blockdev()` | nondeterministic `0`/`-EIO`, per config (`CFG_FAIL_*`) | `->unfreeze_fs()` can only fail in jfs in-tree; `sync_blockdev()` failure is off by default |
| `deactivate_locked_super()` last ref | `model_kill_sb()`: assert UNFROZEN and no holders, `SB_DYING`, drop s_umount (generic_shutdown_super), release the device claims (kill_block_super), `SB_DEAD` (kill_super_notify) | `->kill_sb()` internals are not the subject |
| `hweight32()` | 2-bit popcount + assertion that the argument is `who & FREEZE_HOLDERS` | every call site masks with `FREEZE_HOLDERS`; avoids a 32-bit multiplier per call |
| `->freeze_super`/`->thaw_super` overrides | not modelled | only gfs2 has them; gfs2 passes the caller's `who`/`owner` through to `freeze_super()`/`thaw_super()` |
| super_dev table in `kernel_freeze.h` | array of rows per device, `sd_linked[i]`; cursor = "the walk reached row i while it was linked" | entry lifetime is checked in `devtable.c` |
| rhltable (devtable.c) | array of rows; the chain of a key is "linked rows of that dev, newest first" | `__rhashtable_insert_fast()`/`rhashtable_lookup_one()` insert a duplicate key at the head of the key's list (`list->next = plist`); resizes move a key's list as a unit; `-DCFG_INSERT_TAIL=1` flips it |
| `refcount_t` (devtable.c) | `int` with the refcount_t WARN conditions as assertions (`addition on 0`, `underflow`) | |
| `kfree_rcu()` / RCU | immediate free after unlink; asserts unlinked, ref 0, no passive ref held | a cursor pins its row, nothing else holds a row pointer across a step |
| `super_dev_put()` dropping the last ref | when the put comes from a cursor (`super_dev_next()`, `user_get_super()`), the row stays linked with `sd_ref == 0` and the tail (`rhltable_remove()`, `put_super()`, `kfree_rcu()`) is a separate PUT_FINISH step (`CFG_DYING_WINDOW`); a put issued by the filesystem (unregister, register rollback, `kill_super_notify()`) finishes in place | the window between `refcount_dec_and_test()` and `rhltable_remove()` is visible to the row's own pair only when someone else drops the last ref; a first version deferred every put and produced a same-pair counterexample the kernel cannot reach (the filesystem's own put returns only after the removal) |
| fs_bdev_unregister() lookup/put split | separate steps only with `CFG_SERIAL=0` | under serialisation only cursors and other pairs run in between, and neither can drop the row the caller's claim keeps above zero |
| devices (devtable.c) | `NDEV=2` | with one dev every claim of a live sb shares the `sget_fc()` row, which cannot die while the sb lives; the interesting rows are member devices (`s_dev` != claimed dev: btrfs, erofs, external log/journal) |

## Callers and the flags they pass (git grep at fc1c25014ff8)

| caller | `freeze_super()` | `thaw_super()` |
|---|---|---|
| `ioctl_fsfreeze()`/`ioctl_fsthaw()` (FIFREEZE needs `->freeze_fs`, FITHAW does not) | `USERSPACE, NULL` | `USERSPACE, NULL` |
| gfs2 sysfs `freeze` store, `gfs2_freeze_func()` | `USERSPACE, NULL` | `USERSPACE, NULL` |
| `xfs_dax_notify_failure_thaw()` | | `KERNEL, NULL` if it froze, then **unconditionally** `USERSPACE, NULL` |
| `xchk_fsfreeze()`/`xchk_fsthaw()`, `xfs_dax_notify_failure_freeze()`, `btrfs_ioctl_shutdown()`, `f2fs_ioc_resize_fs()` | `KERNEL, NULL` | `KERNEL, NULL` |
| `filesystems_freeze_callback()`/`filesystems_thaw_callback()` (suspend, hibernate) | `EXCL\|KERNEL, filesystems_freeze_ptr`, only with `freeze_filesystems=1` or `FS_POWER_FREEZE` (efivarfs) | same, on **every** resume, for every sb with `->freeze_fs` |
| `fs_super_freeze()`/`fs_super_thaw()` (`fs_bdev_freeze()`/`fs_bdev_thaw()` from `bdev_freeze()`/`bdev_thaw()`: dm suspend/resume, ext4/xfs/f2fs/exfat/ntfs/ntfs3 shutdown ioctls, emergency thaw) | `MAY_NEST\|USERSPACE, NULL` | `MAY_NEST\|USERSPACE, NULL` |
| `do_thaw_all_callback()` (SysRq-j) | | `bdev_thaw(sb->s_bdev)` until it fails, then `thaw_super_locked(USERSPACE, NULL)` |

No caller passes `KERNEL|MAY_NEST`.  `filesystems_freeze_ptr` is the only
owner token in the tree.

## Properties

freeze.c (after every step; `kernel_freeze.h:check_sb_invariants()` +
`freeze.c:check_invariants()`):

- `freeze_kcount >= 0`, `freeze_ucount >= 0`;
- `frozen == SB_FREEZE_COMPLETE` iff `kcount + ucount > 0`; no
  `SB_FREEZE_PAGEFAULT`/`SB_FREEZE_FS` visible between steps;
- `s_active == mounts + (frozen == COMPLETE) + refs of sleeping operations`
  (the freezers' shared active reference, exactly);
- `freeze_owner == NULL` unless COMPLETE, and only `filesystems_freeze_ptr`;
- EXCL: `freeze_owner == filesystems_freeze_ptr` iff the
  `filesystems_freeze()` hold is outstanding, and that hold implies COMPLETE
  with `kcount >= 1` (never undone by a non-owner or a non-EXCL thaw);
- sb_writers rwsems: none held while UNFROZEN, all three held while COMPLETE
  through the read-write path, none through the `sb_rdonly()` path;
- every `freeze_super()`/`thaw_super()` that returns: `ret <= 0`; `0` added /
  removed exactly one hold of its kind and nothing else; an error changed
  nothing (`check_freeze_result()`/`check_thaw_result()`);
- accounting (`CHECK_ACCOUNTING`): `kcount` = filesystems_freeze hold +
  in-kernel freezer hold, `ucount` = FIFREEZE holds + one per device whose
  bdev freeze holds the sb;
- block layer: `bd_fsfreeze_count` == number of `bdev_freeze()==0` callers
  that have not called `bdev_thaw()` yet (+1 while a bdev freeze is in
  flight), split into "stuck above" and "below"; a bdev freeze holder
  implies the sb is frozen with `ucount >= 1`; a failed `bdev_freeze()`
  leaves no hold behind;
- every WARN site; lock balance; `kill_sb` only on an unfrozen sb without
  holders.

holder_errs.c: per-sb invariants above for every sb, plus: after
`bdev_freeze()==0` every superblock alive at its visit got the hold; a
failed `bdev_freeze()` left no hold; after `bdev_thaw()==0` (count 1 -> 0)
no superblock keeps the device's hold; `bd_fsfreeze_count` ==
holders - deniers (+ in-flight freeze).

devtable.c: no `refcount_inc()` on 0, no `refcount_dec_and_test()` below 0
(row refs and `s_passive`); a linked row has `sd_ref > 0` or a pending
removal; every linked row holds its passive ref and drops it exactly once;
`s_passive == base + rows + user_get_super() refs`; no row points at a freed
superblock; `fs_bdev_unregister()`'s lookup finds a row (the caller holds a
claim); with `CFG_SERIAL`: the refs of a pair's live rows == the pair's
claims (sget + fs_bdev) + cursor pins + inserted-not-yet-counted rows; in a
quiescent end state (all superblocks released, no cursors, nothing in
flight) the table is empty, every row is freed (except a never-registered
`s_super_dev` of a superblock that never got set()) and every released
superblock has `s_passive == 0`.

## Reproduce

    ./run.sh -l                       # configurations
    ./run.sh freeze-pm                # one configuration
    PROP=warn_check.assertion.17 ./run.sh freeze-pm   # trace one property
    ./trace_ops.py freeze results/freeze-pm.warn_check.assertion.17.log

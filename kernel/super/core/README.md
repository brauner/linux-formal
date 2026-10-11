# Models of fs/super.c

| method | directory |
|---|---|
| TLA+ models of the superblock lifecycle and the device table (`SuperLife`, `SuperDevTable`) | [`tla/`](tla/README.md) |
| TLA+ models of freezing and the block-layer holder operations (`SuperFreeze`, `SuperHolder`) | [`tla/`](tla/README-freeze-holder.md) |
| CBMC harnesses of freeze/thaw, the bdev freeze aggregation and the device table | [`cbmc/`](cbmc/README.md) |
| LKMM litmus tests of the ordering protocols, with AArch64 and POWER translations | [`litmus/`](litmus/README.md) |

Tree: fc1c25014ff8 (v7.3-rc6-301, vfs master at the time); fs/super.c,
block/bdev.c and the callers in the filesystems. The models were written
for a review of fs/super.c and its API. Fixes for what they found are
switches in the models and sit on work.super.fixes.core, .7.3 and .fs and
on work.fs.sb_rdonly. The status lines in the method READMEs are as of the
model runs; the table below says what became of each finding.

## Findings

| Finding | Models | Outcome |
|---|---|---|
| The fs_holder_ops walks act on a superblock through a device claim it dropped before SB_BORN (btrfs_free_extra_devids(), the -EBUSY rollback of fs_bdev_register() under btrfs -o degraded): a freeze outlives its thaw, or a thaw takes another device's freeze | `tla/` SuperDevTable finding 1, SuperHolder F5 | "super: don't act on superblocks that dropped their device claim" (work.super.fixes.core); the claim btrfs drops when it cancels a suspended replace without bdev_deny_freeze(): "btrfs: deny freezing the target when cancelling a suspended replace" (work.super.fixes.7.3). A version of the first fix that was not taken is modelled in `kernel/super/unborn-wait/` |
| A sync_blockdev() failure at the end of fs_bdev_freeze() fails bdev_freeze() and leaves the superblocks frozen with a hold nobody owns | SuperHolder F1, `cbmc/` F3 | "fs: don't fail fs_bdev_freeze() once a superblock is frozen" (work.super.fixes.core) |
| A superblock thawed behind the block layer's back (FITHAW from a non-holder, the emergency thaw, ...) makes bdev_thaw() keep bd_fsfreeze_count up for good: the device can't be mounted again | SuperHolder F2, `cbmc/` F2 | "fs: don't keep a device frozen when its freeze is already gone" (work.super.fixes.core) |
| A filesystem error path sets SB_RDONLY while the superblock is frozen; the final thaw takes the read-only branch and leaves the s_writers rwsems write-held | SuperFreeze F3, `cbmc/` F5 | the "<fs>: don't set SB_RDONLY after filesystem errors" conversions on work.fs.sb_rdonly |
| filesystems_thaw() on resume WARNs in may_unfreeze() for a superblock frozen through FIFREEZE or a block device | `cbmc/` F1 | "super: don't warn when resume thaws a userspace freeze" (work.super.fixes.core) |
| fserror_unmount() can sleep forever on weakly ordered CPUs: the last refcount_dec_and_test() is not a full barrier before wake_up_var() | `litmus/` finding 1 | "fserror: fully order the last pending error decrement" (work.super.fixes.core) |
| Lost s_flags updates between the VFS's read-modify-writes and filesystems writing s_flags without s_umount (the FUSE INIT reply, efivarfs, error handlers forcing SB_RDONLY) | `litmus/` finding 2 | "fuse: don't lose superblock flags when processing the INIT reply" (work.super.fixes.fs); efivarfs and the error handlers on work.fs.sb_rdonly |
| The new s_writers.frozen waiter of quotactl_block() loses the thaw's wakeup without a full barrier before wake_up_var() | SuperFreeze W2, `litmus/` finding 4 | the smp_mb() of sb_freeze_wake() in "quota: really wait for the thaw in quotactl_block()" (work.super.fixes.core) |
| bdev_allow_freeze()'s relaxed atomic_inc() is not ordered after the preceding fs_bdev_unregister() put | `litmus/` finding 3 | LKMM-only, forbidden on Arm; unchanged |
| On a device shared by several superblocks a per-superblock freeze error is swallowed | SuperHolder F4, `cbmc/` F6 | intended (7a7ef107b449) and latent: only erofs shares devices and it can't fail a freeze |
| Two concurrent fs_bdev_register() calls of one (device, superblock) pair | SuperDevTable finding 2, `cbmc/` F7 | caller contract; no in-tree caller does that |
| test() dereferencing s_fs_info of a dying superblock | SuperLife finding 3 | filesystem contract; holds in-tree |
| jfs's ->unfreeze_fs() failure keeps the count | `cbmc/` F4 | intended: the hold is still there; the SB_RDONLY part of jfs is on work.fs.sb_rdonly |

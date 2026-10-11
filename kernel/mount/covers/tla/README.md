# TLA+ model of the covers on unmounted mounts

Tree: master at a5ebb76233b7 (v7.3-rc6-386), with "namespace: rework
connected mounts" (01cbebb42070) and "namespace: simplify
disconnect_mount()" (3d3992244255) from vfs-7.3-rc7.fixes. Files:
fs/namespace.c (struct mnt_cover, alloc_vfsmnt(), free_vfsmnt(),
__lookup_mnt(), lookup_mnt(), maybe_free_mountpoint(), leave_cover(),
drop_cover(), needs_cover(), umount_tree(), __detach_mounts(),
mntput_no_expire_slowpath(), namespace_unlock()) and the mount crossing
of fs/namei.c (__follow_mount_rcu(), complete_walk()).

`MntCover` is one namespace with a small tree of mounts, holders that
keep a file open on a mount, walkers that look a mountpoint dentry up
from a holder's file, and one task that runs umount_tree() for the
operations of the layout:

- umount2(MNT_DETACH): umount_tree() with UMOUNT_PROPAGATE, so only a
  locked child leaves a cover;
- rmdir of a mountpoint: __detach_mounts() drops the name, runs
  umount_tree() with UMOUNT_COVER for every mount on the dentry, then
  drops the covers left on the dentry;
- the death of the namespace: put_mnt_ns() runs umount_tree() on the
  root with no flags.

Every victim is detached, and one that needs_cover() leaves its cover
on the parent first. namespace_unlock() waits for a grace period and
puts the victims. A put of a mount that is no longer in a namespace
takes mount_lock, and the last one dooms the mount and drops the covers
on it. cleanup_mnt() and delayed_free_vfsmnt() free the mount after
another grace period, and free_vfsmnt() frees a cover the mount didn't
leave behind.

A walker borrows its holder's file, so the mount it starts from is
referenced for the whole walk. In RCU mode it samples mount_lock once no
writer holds it, then reads DCACHE_MOUNTED, the mount hash, the racy
MNT_UMOUNT flag, the covers list and the covers it found, each a step of
its own. The recheck of mount_lock in __follow_mount_rcu() and
complete_walk() keeps the result and legitimizes the mount it found, or
drops to ref mode, where lookup_mnt() runs against a quiescent
mount_lock. Every section that takes mount_lock for writing makes the
samples of the walkers in RCU mode stale. A grace period waits for the
walkers that are in RCU mode when it starts.

## Files

| File | What it is |
|------|------------|
| `MntCover.tla` | the model, with the switches below |
| `MC_lazy.tla` | R the root, P on R at dP, C on P at dC and locked, F on P at the file dF; a holder on P; walkers at dC and dF on P; umount2(MNT_DETACH) of P and rmdir of dC |
| `MC_rmdir.tla` | R, P on R at dP, C on P at dC, G on C at dG, nothing locked; holders on P and C; walkers at dC on P and at dG on C; rmdir of dP and of dG |
| `MC_ns.tla` | R, P on R at dP and locked, C on P at dC; holders on R and P; walkers at dP on R and at dC on P; the death of the namespace and rmdir of dP |
| `*.cfg` | TLC configurations from `gen-cfgs.py`; the header says what to expect |
| `check.sh` | run one configuration (`TLA2TOOLS` must point at tla2tools.jar) |

## Switches

All of them are TRUE for mainline.

| Constant | Off means |
|----------|-----------|
| `FIX_COVER` | no cover: a victim is detached and nothing is left behind |
| `MP_PIN` | the cover doesn't pin the mountpoint through m_covers, so the last umount_mnt() on the dentry frees the mountpoint and clears DCACHE_MOUNTED |
| `COVER_FIRST` | leave_cover() runs after umount_mnt() instead of before it |
| `PUT_DROPS` | the final mntput() leaves the covers on the mount alone |
| `DETACH_DROPS` | __detach_mounts() leaves the covers on the removed dentry alone |
| `RCU_FREE` | drop_cover() frees the cover with kfree() instead of kfree_rcu() |

## What is checked

Deadlock detection is on. The model only stutters once everything has
settled, so a state nothing can leave is a bug in the model or the
code.

| Invariant | Meaning |
|-----------|---------|
| `NoBad` | no mount, cover or mountpoint is used after it was freed, no cover is left or dropped twice, and nothing is attached to a mount at its final put (the VFS_WARN_ON_ONCE() in mntput_no_expire_slowpath()) |
| `NoReveal` | a walk on a parent never lands on the dentry a child covers while the child is mounted there or was unmounted with a cover it needed, as long as the dentry is linked |
| `CoversOK` | a cover sits on its unmounted parent while the parent lives, and pins its mountpoint and DCACHE_MOUNTED |
| `MountpointOK` | a mountpoint exists exactly while a mount or a cover is on it, and DCACHE_MOUNTED with it |
| `Reaped` | once everything has settled, every unmounted mount and every cover is freed and only the dentries mounts sit on are mountpoints |

`NoReveal` only counts a linked dentry. __detach_mounts() unhashes the
dentry before the mounts on it go, so that no lookup that starts
afterwards finds the name, and the model does not look up names: a
walker that already holds the dentry when it is removed is outside of
what the kernel promises.

Witnesses: `NoStandIn` and `NoFileStandIn` (a walk finds knullfs or
knullfs_file), `NoPutDrop` and `NoDetachDrop` (a final put or an rmdir
drops a cover), `NoAllowedReveal` (a walk lands on the dentry of a
child that was unmounted without needing a cover).

## Results

Local, TLC 2.19 with 8 workers, every configuration in seconds:

| Configuration | Result | What it shows |
|---------------|--------|---------------|
| `lazy_fixed`, `lazy_fixed_file_locked`, `rmdir_fixed`, `ns_fixed` | pass, 557,907, 1,196,728, 809,823 and 472,710 states | mainline on every layout, with F locked as well in the second |
| `*_no_cover` | `NoReveal` violated, 10 to 11 steps | without the cover the last umount_mnt() on the dentry frees the mountpoint, DCACHE_MOUNTED goes, and the walk lands on what the child covered |
| `lazy_no_pin`, `rmdir_no_pin` | `NoReveal` violated | the same with a cover that doesn't pin the mountpoint |
| `ns_no_pin` | `NoBad` violated (mp_uaf) | here the parent's final put gets there first and drops the cover onto the freed mountpoint |
| `*_cover_late` | `NoBad` violated (mp_uaf), 4 steps | leave_cover() after umount_mnt() pins a mountpoint that is already freed; in the kernel umount_mnt() also resets mnt_mp and mnt_parent, so the cover would not even find it |
| `*_no_put_drop` | `CoversOK` violated | the parent's final put leaves its covers behind |
| `*_no_rcu_free` | `NoBad` violated (cover_uaf), 20 to 21 steps | a walk that sampled mount_lock before an rmdir reads the covers list, the rmdir drops and frees the cover, and the walk dereferences it |
| `*_no_detach_drop` | pass, 294,258 (lazy), 516,934 (rmdir) and 349,260 (ns) states | the parent's final put drops the covers later; the drop in __detach_mounts() only makes the removed dentry go earlier |
| `*_witness_standin`, `lazy_witness_file_standin` | `NoStandIn`, `NoFileStandIn` violated | the walks find knullfs, and knullfs_file for a locked file mount |
| `*_witness_put_drop`, `lazy_witness_detach_drop`, `rmdir_witness_detach_drop` | `NoPutDrop`, `NoDetachDrop` violated | final puts and rmdir both drop covers |
| `lazy_witness_allowed`, `ns_witness_allowed` | `NoAllowedReveal` violated | an unlocked child of a lazily unmounted mount or of a dead namespace leaves no cover, so the walk lands on its mountpoint, as it always did |

The counts of the failing configurations depend on the number of
workers; the length of the counterexample doesn't.

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar
    ./check.sh lazy_fixed 4         # seconds
    ./check.sh lazy_no_rcu_free 4   # the use after free without kfree_rcu()

## What isn't modelled

- Propagation: the propagated victims of a lazy umount and the covers
  they leave are the same code with other parents.
- dissolve_on_fput() passes UMOUNT_COVER like rmdir and isn't a
  separate operation. A synchronous umount never leaves a cover.
- Moving mounts. The tree only shrinks.
- A walk in RCU mode from a working directory another thread changes,
  which holds no reference on the mount it starts from. Its final put
  could then happen during the walk. The covers are freed with
  kfree_rcu() and the mount with call_rcu(), so the walk stays safe, but
  the model doesn't show that.
- What the walk does with the stand-in it found. knullfs is a global
  mount and is never freed.

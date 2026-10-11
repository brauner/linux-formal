# Covers instead of connected mounts

Status: mainline since vfs-7.3-rc7.fixes, as modelled. "namespace:
rework connected mounts" (01cbebb42070) and "namespace: simplify
disconnect_mount()" (3d3992244255).

An unmounted mount used to stay attached to its unmounted parent when
the umount asked for it, as rmdir of a mountpoint does, or when it was
locked. A lookup on the dead parent then kept finding the child instead
of what the child covered. For a locked mount that is a security
property: it must not reveal what is below it. But the parent owned the
child that way, and every reference from the child's superblock back to
an ancestor turned into a reference count cycle (cf.
[`kernel/mount/ownership/`](../ownership/)).

Now every victim of umount_tree() is detached and put by
namespace_unlock(). A victim that would have stayed attached leaves a
cover behind first. leave_cover() hangs the struct mnt_cover the mount
was allocated with on the parent's mnt_covers and pins the mountpoint
through m_covers, so the dentry stays DCACHE_MOUNTED. __lookup_mnt() on
an unmounted mount that misses the mount hash looks at the covers and
returns a stand-in, knullfs for a directory and knullfs_file for
anything else. The parent's final mntput() and __detach_mounts() on the
covered dentry drop the cover under mount_lock and free it with
kfree_rcu().

Two models look at it:

- `MntCover` is the cover itself: path walks that look a mountpoint up
  on an unmounted parent, one read per step, against umount_tree(), the
  drops, the final puts, cleanup_mnt() and RCU.
- `MntOwn` in [`kernel/mount/ownership/`](../ownership/) has the covers
  as a fourth answer to the reference count cycle, the one mainline
  took (`FIX_COVER`).

Tree: master at a5ebb76233b7 (v7.3-rc6-386).

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `MntCover`: umount2(MNT_DETACH), rmdir of a mountpoint and the death of a namespace against path walks from a file on the unmounted parent, the final puts, cleanup_mnt() and RCU |
| TLA+ (TLC) | [`../ownership/tla/`](../ownership/tla/README.md) | `MntOwn` with `FIX_COVER`: who owns an unmounted mount once covers exist |

## Results

- A walk on an unmounted parent never lands on a dentry that a child
  had to keep covered while that dentry is still there. It finds the
  child while the child is mounted and the stand-in after that. No
  mount, cover or mountpoint is used after it was freed, every cover is
  gone once the parent is, and every unmounted mount is freed in the
  end. That holds for a lazy umount, rmdir of a mountpoint and the
  death of a namespace, 470k to 1.2M states each.
- Every part of the design is needed. Without the cover, or with a
  cover that doesn't pin the mountpoint, DCACHE_MOUNTED goes with the
  mountpoint and the walk lands on what the locked child covered. With
  leave_cover() after umount_mnt() the mountpoint is already freed.
  Without the drop in the final mntput() the cover outlives its parent.
  With kfree() instead of kfree_rcu() a walk that read the covers list
  before an rmdir dereferences the freed cover.
- The drop in __detach_mounts() isn't needed for any of this. Without
  it the parent's final mntput() drops the cover later. What it buys is
  that the removed dentry and its mountpoint go when the dentry does.
- An unlocked child of a lazily unmounted mount or of a dead namespace
  leaves no cover, and the walk lands on its mountpoint. That's what a
  lazy umount always did and the series doesn't change it.
- With covers, every mount on the reported layout is freed, and on all
  343 pin configurations of `MntOwn` the only survivors are cycles of
  pins, as with the tombstones. Filesystems that hold files on each
  other's mounts still survive. No mount teardown can see those pins.

Every configuration finishes in seconds.

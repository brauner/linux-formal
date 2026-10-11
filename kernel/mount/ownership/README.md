# Who owns an unmounted mount

Status: mainline, modelled at v7.3-rc3 with the revert of 0342482a4d15,
which went into mainline as 2e2142a35d80. Three of the four answers
compared here were not merged. Mainline took the fourth, "namespace:
rework connected mounts" (01cbebb42070) in vfs-7.3-rc7.fixes: an
unmounted mount is disconnected like any other and leaves a cover
behind, and a lookup that hits the cover finds knullfs. The cover itself
is modelled in [`kernel/mount/covers/`](../covers/).

Michael Vogt reported a reference count cycle. A loop device keeps its
backing file open, and if that file lives on a mount A while the loop
mount L sits below A in the same tree, then L's superblock pins A and A,
as L's parent, owns L. When the namespace goes away neither count ever
reaches zero, so the loop device, both mounts and the filesystem on the
image stay around for good. 0342482a4d15 made put_mnt_ns() leave the
tree connected, and with that the cycle closes as soon as the namespace
dies.

The model is mainline with that commit reverted, and four answers to
the general problem as switches, compared on every way three
superblocks can pin mounts in one layout (343 pin configurations, mutual
pins and self-pins included). The four answers are the tombstones of
work.put_mnt_ns.tombstone, which became the vacant-mount series
modelled in [`kernel/mount/vacant/`](../vacant/), the pinner rule of
work.mount.pins, the internal clones of work.mount.private_clone, and
the covers mainline took.

Tree: master at 50d05c7c76c9 (v7.3-rc3) plus the revert of put_mnt_ns()
to `umount_tree(ns->root, 0)`, the four answers as switches, the covers
as they are in master at a5ebb76233b7 (v7.3-rc6-386).

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `MntOwn`: umount_tree() for every entry point, namespace_unlock()'s puts, the cascade over stuck children, the covers, superblocks that pin mounts through files they keep open |

## Results

- **0342482a4d15** closes the reported cycle in ten states
  (`mntown_connected_ns`). The revert fixes that path (`mntown_revert`),
  but the same cycle still closes through a lazy umount or a dying
  namespace with locked children (`mntown_revert_locked`) and through
  rmdir of the mountpoint (`mntown_revert_detach`). The rmdir case was
  reproduced on 7.3-rc2 in a VM, and the kselftest `loop_cycle_test` on
  work.detach.cycle fails there and passes with the tombstones.
- **Tombstones**: once everything external is gone, whatever survives
  is rooted in a cycle of pins, a set of mounts each pinned by the
  superblock of a member, on all 343 pin configurations
  (`mntown_disown_anypin*`). The VFS can't see a cycle like that.
- **Pinners**: disconnecting at umount_tree() time the victims whose
  superblock pins a victim is not enough. A mount an earlier teardown
  left connected is not a victim of the next one, so a cycle over two
  pins closes in two steps (`mntown_pinners_*`). Walking the dead
  connected mounts again at the end of every umount_tree() leaves only
  cycles of pins, like the tombstones (`mntown_reexamine_*`), and that
  is what work.mount.pins implements.
- **Internal clones**: no mount is ever pinned, so every mount is freed
  whatever the pins, and only cycles of superblocks survive
  (`mntown_clone_anypin*`).
- **Covers**, mainline's answer: every victim is detached and holds
  only its own reference, so no unmounted mount owns another one and
  nothing stays attached to an unmounted mount. On the reported layout
  every mount is freed, with locked children or not and with
  put_mnt_ns() connected or not (`mntown_cover`, `mntown_cover_locked`,
  `mntown_cover_connected`). On all 343 pin configurations only cycles
  of pins survive, as with the tombstones (`mntown_cover_anypin*`).
- What every answer leaves behind is filesystems holding files on each
  other's mounts, a ring of three in the counterexamples of the
  tombstones and the covers and a ring of two in the one of the clones
  (`mntown_disown_anypin_reaped`, `mntown_cover_anypin_reaped`,
  `mntown_clone_anypin_reaped`).
  No mount teardown can see through a loop device or a FUSE server to
  know that those files are pins.

[`tla/README.md`](tla/README.md) has the argument for why the bounded
runs generalise. Every configuration finishes in seconds to minutes.

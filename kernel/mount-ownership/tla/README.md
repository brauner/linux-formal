# TLA+ model of the ownership of unmounted mounts

Tree: master at 50d05c7c76c9 (v7.3-rc3) plus the revert of put_mnt_ns() to
`umount_tree(ns->root, 0)` (2e2142a35d80 in vfs.fixes since), with three
unmerged answers to the reference count cycle Michael Vogt reported as
switches: the tombstone mechanism of work.put_mnt_ns.tombstone (the design
that became work.mount.knullfs, modelled as it stood on 2026-09-21: two
references at conversion, the release visit ending in mntput()), the
pinner rule of work.mount.pins, and the internal-clone rule of
work.mount.private_clone.  None of the three is in mainline; the current
form of the first is modelled precisely in `kernel/work.mount.knullfs.4/`.  The
mainline models are in `kernel/mount/`, whose conventions this directory
follows.

## Files

| File | What it is |
|------|------------|
| `MntOwn.tla`, `MC_mntown.tla` | Family B: who owns an unmounted mount. A namespace's tree of mounts on superblocks that may pin a mount through a file they keep open (a loop device's backing file, an ecryptfs lower path); umount_tree() with disconnect_mount() for umount(2) with MNT_DETACH, a synchronous umount, put_mnt_ns() and __detach_mounts(); namespace_unlock()'s puts, mntput_no_expire_slowpath()'s cascade over stuck children, cleanup_mnt(), deactivate_super() releasing the pin; the tombstone mechanism of work.put_mnt_ns.tombstone, the pinner rule of work.mount.pins and the internal-clone rule of work.mount.private_clone as switches. The layout is the loop topology of Michael Vogt's report plus an image inside the image and a subtree under a directory that gets removed |
| `*.cfg` | TLC configurations from `gen-cfgs.py`; the header says what to expect |
| `check.sh` | run one configuration (`TLA2TOOLS` must point at tla2tools.jar) |

## Switches

| Constant | Off means |
|----------|-----------|
| `FIX_PUT_MNT_NS_DISCONNECT` | put_mnt_ns() leaves the tree connected, as 0342482a4d15 does; the revert uses umount_tree(root, 0) |
| `FIX_DISCONNECT_PINNERS`, `PINNERS_ANCESTOR_ONLY`, `PINNERS_REEXAMINE` | the targeted alternative: umount_tree() disconnects a victim whose superblock pins a victim (all such victims, or only those pinning an ancestor that would own them), and with `PINNERS_REEXAMINE` also every mount an earlier umount_tree() left connected whose superblock pins a victim of this one; the last is the complete form, the others leak |
| `FIX_DISOWN` | the tombstone mechanism is absent, as upstream: a connected dead child is owned by its parent, so a child superblock that pins an ancestor holds the ancestor's count above zero for good; with the fix every victim keeps its own reference, the unmounted list is put in tree order, a mount that loses its last reference while attached becomes a tombstone owned by the parent |
| `FIX_INTERNAL_CLONE` | the rule of work.mount.private_clone: a kernel holder keeps its file on an internal clone of the mount, mnt_clone_internal()'s private MNT_INTERNAL mount in no namespace with no parent, no children and the file's single reference; so a pin is a reference on the superblock the file lives on (the clone's s_active) and never on a mount; the clone is folded into that superblock's active count and goes when the pinning superblock releases the file, cleanup_mnt() running synchronously for MNT_INTERNAL |
| `PIN_BUSY` | with the clone, a synchronous umount of a pinned mount still fails with EBUSY, the loop driver's busy fs_pin in that series; off, the mount goes and its filesystem lives on through the clone |
| `SELF_PIN` | `ANY_PIN` may place a holder's file on a mount of the holder's own filesystem; off for the residual witnesses, whose counterexample is then a cycle of two filesystems |

What is checked: `NoUAF` (nothing freed is still pointed at), `Reaped`
(once the namespace is gone and every holder has closed, every mount is
freed and every superblock is down), `OwnRef` (an attached unmounted mount
holds its own reference unless it is a tombstone), `TombOK`, `TombLeaf`
(a tombstone is a superblock-less leaf), `LeaksAreCycles` (whatever
survives once everything external is gone is rooted in a cycle of pins),
`MountsReaped` and `SbLeaksAreCycles` (with the clone: every mount is
freed and only cycles of superblocks survive).

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar
    ./check.sh mntown_disown 4        # seconds
    ./check.sh mntown_disown_anypin 8 # 343 pin configurations, minutes

## Results

### MntOwn (local runs, 2026-09-21)

Root 1; A (2) under it with the loop mount L (3) whose superblock pins A,
and N (6) under L, an image inside the image, pinning L; D (4) under the
root with M (5) under it pinning D.  A holder has a file on A.  Tasks
leave the namespace, holders close, and the model asks at the end
(`Reaped`) whether every mount is freed and every superblock down.

| Configuration | Result | Meaning |
|---------------|--------|---------|
| `mntown_connected_ns` | `Reaped` violated | 0342482a4d15: put_mnt_ns() leaves the tree connected; the root's final put unhashes A and puts it, but L's superblock still pins A, so A never reaches zero, never runs its cascade, L and N are never put and the two superblocks never die (Michael Vogt's report; the model finds it in 10 states) |
| `mntown_revert` | pass | with put_mnt_ns() disconnecting, L is put by namespace_unlock(), its superblock goes, the pin on A is released and everything is freed |
| `mntown_revert_locked` | `Reaped` violated | the same cycle with L locked: a lazy umount of A or the namespace's death keeps L connected and owned by A, so the revert does not help |
| `mntown_revert_detach` | `Reaped` violated | the same cycle through rmdir: __detach_mounts() keeps M connected under D, M's superblock pins D. Reproduced on a 7.3-rc2 kernel in a VM: a container mounts a tmpfs on a directory, puts a loop image on it and mounts the image below; the host removes the empty directory; after the container is gone the loop device keeps its backing file, `losetup -d` can only mark it for autoclear, and the two mounts, the ext4 superblock and the device are unreachable for good. The kselftest `loop_cycle_test` on the kernel branch `work.detach.cycle` fails on that kernel (exclusive open of the device refused, backing file kept after LOOP_CLR_FD) and passes with the tombstone series |
| `mntown_disown_anypin`, `mntown_disown_anypin_locked`, `mntown_disown_anypin_connected` | pass, 812k, 746k and 823k states | every way the three pinning superblocks can hold a file on a mount, 343 configurations, mutual pins included, with every entry point available: `LeaksAreCycles` holds: whatever survives once everything external is gone is rooted in a cycle of pins, a set of mounts each pinned by the superblock of a member, plus what those superblocks pin and the tombstones those mounts own, and a cycle of pins is something the VFS cannot see; `mntown_revert_anypin` shows the invariant is discriminating, the ownership rule leaks mounts that are on no such cycle |
| `mntown_disown_anypin_reaped` | `Reaped` violated, 499k states | the residual class, self-pins excluded: filesystems holding files on each other's mounts, a ring of three in the counterexample, survive with or without the series |
| `mntown_pinners_anypin`, `mntown_pinners_anypin_locked`, `mntown_pinners_anypin_connected`, `mntown_pinners_ancestor_anypin` | `LeaksAreCycles` violated | the targeted alternative to the tombstones, disconnecting at umount_tree() time the victims whose superblock pins a victim (any victim, or only an owner-ancestor), is not enough: a mount an earlier teardown left connected whose superblock pins a mount that dies later is not a victim of that later teardown and nothing examines it, so a cycle over two pins closes in two steps |
| `mntown_reexamine_anypin`, `mntown_reexamine_anypin_locked`, `mntown_reexamine_anypin_connected` | pass, 346k, 326k and 347k states | the same rule applied as well to every mount earlier teardowns left connected: with the dead connected mounts kept on a list and walked at the end of umount_tree(), the only survivors are cycles of pins, as with the tombstones; this is what the kernel branch `work.mount.pins` implements |
| `mntown_disown`, `mntown_disown_locked`, `mntown_disown_connected` | pass | the tombstone mechanism, with the revert or with put_mnt_ns() connected again, locked children or not: every mount holds its own reference until it is unhashed, A and L become tombstones when their filesystems are released while they are still attached, and the parents' cascades put the tombstones; 5,006, 4,766 and 4,538 states |
| `mntown_clone`, `mntown_clone_locked`, `mntown_clone_connected`, `mntown_clone_busy` | pass, 1980, 1884, 2001 and 1980 states | the internal-clone rule on the report's layout with every entry point available, the revert or put_mnt_ns() connected (which is also dissolve_on_fput()'s teardown), locked children or not, the loop driver's busy pin on or off: `Reaped` holds, every mount is freed and every superblock is down. No mount is ever pinned, so A's count reaches zero as soon as its namespace and its holder are gone, its cascade puts L, L's cleanup takes the loop superblock down, the loop device releases its file, the clone's final put deactivates A's superblock |
| `mntown_clone_anypin`, `mntown_clone_anypin_locked`, `mntown_clone_anypin_connected`, `mntown_clone_anypin_busy` | pass, 679140, 620830, 686343 and 679140 states | every way the three pinning superblocks can hold a file on a mount, self-pins and mutual pins included, every entry point: `MountsReaped` holds, every mount is freed whatever the pins, and `SbLeaksAreCycles` holds, a superblock that survives is kept by a cycle of superblocks each holding a file on another's filesystem, or by what such a cycle keeps |
| `mntown_clone_anypin_reaped` | `Reaped` violated, 427307 states | the residual class with the clone, self-pins excluded: two filesystems each holding a file on the other, the loop image inside the filesystem whose fuse server's backing file is on the loop mount; every mount is freed in the counterexample, only the two superblocks stay, and no mount teardown can see through a loop device or a fuse server to know that those files are pins |

Why the bounded runs generalise.  After the series the kernel-internal
references between these objects are: a mount holds its superblock, a
superblock holds the mounts its open files live on (the pins), and a
parent holds its tombstone children, the one ownership edge left.  A
tombstone is a superblock-less leaf: its superblock is the permanent
private nullfs, which pins nothing, and its children were unhashed when
it was made, so no path continues through a tombstone and it lies on no
cycle.  Every other mount holds its own reference until it is unhashed,
so once its namespace and its holders are gone its count is the number
of pins on it, and it lives only while a superblock that pins it lives,
which lives only while one of its mounts lives.  Following that chain,
a mount that never dies is pinned by a superblock of a mount that never
dies, and with finitely many mounts the chain closes: a cycle of pins.
That is `LeaksAreCycles`: every survivor is such a cycle, a mount one
of its superblocks pins, or a tombstone one of those owns.  The model
checks it on every pin configuration of the layout rather than on the
report's alone, self-pins and mutual pins included.  The first two
attempts stopped on my own transcription, a tombstone must unhash its
children and swap its superblock at conversion, not at the release, and
the invariant flagged both.

Why the internal-clone runs generalise.  With the rule of
work.mount.private_clone the kernel-internal references are: a mount
holds its superblock; a superblock holds, through the clone its file
lives on, the superblock of that file; a dead parent owns its connected
dead children.  Nothing points at a mount except its parent, and the
parent's ownership ends the moment the parent's own count reaches
zero, which now depends only on the namespace and the holders that
reference it directly.  So once everything external is gone every
mount is freed, the tree is always reclaimable, and that is
`MountsReaped`.  The active count of a superblock is then held by its
own mounts, all of which go, and by clones, each of which goes when
the superblock whose file it carries is torn down.  Following that
chain with finitely many superblocks, a superblock that never dies is
kept by a superblock that never dies, and the chain closes: a cycle of
superblocks, `SbLeaksAreCycles`.  Such a cycle is two devices or servers
whose files lie on each other's filesystems, and the VFS cannot tell
those files from any other open file.  The clone itself is not a mount
in the model: it has one reference, no namespace, no parent and no
children, so its whole effect is the active count it holds, and
cleanup_mnt() runs synchronously for it (mntput_no_expire_slowpath()
skips the task work for MNT_INTERNAL), so no ordering of its own
matters.  The mount-level `LeaksAreCycles` still holds with the clone
and reduces to `MountsReaped`, since no superblock keeps a mount.

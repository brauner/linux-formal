# shrink_submounts()

Status: mainline since vfs-7.3-rc7.fixes, as modelled.
shrink_submounts() in mainline is the walk with its restart, from
"namespace: check a submount for references right before unmounting
it" (32bf92416614).

A synchronous umount first takes down the shrinkable submounts below
the mount, the automounts, and then the mount itself. shrink_submounts()
used to check every shrinkable submount for references first and
unmount them afterwards. But an earlier umount_tree() can slide a
surviving overmount to where the propagated copy of a later victim is
looked up, and so a mount that is in use gets pulled out. "mount: more
bugfixes, the Oprah edition" checks one submount, unmounts it and walks
the tree again from the top, which is quadratic in the number of
submounts the walk passes. Before the series was applied that became a
single walk with an explicit cursor: a childless shrinkable mount is
unmounted where the walk finds it, a parent is checked on the way back
up once its children are gone, and the walk starts over only when the
parent of the mount it just unmounted went along with it, or when a
pass unmounted something.

The model is the propagation algebra of
[`kernel/mount/core/`](../core/) with shrink_submounts() as one of three
algorithms: "gather" for the code before the series, "rescan" for the
series as posted and "walk" for the series as applied, the restart of
the walk a switch of its own.

Tree: work.mount.fixes.3 at a3fe58f6edea on vfs-7.4.mount b4698e50d460.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `MountOps` with the three algorithms, two scripted layouts and the random layouts of `kernel/mount/core/` |

## Results

| Finding | Shown by | Outcome |
|---|---|---|
| Gathering first and unmounting afterwards takes a mount that is in use: the copy of B on P1 goes first, its cognate on P2 with it, R slides to P2@Fo, and B's umount pulls R out although it is a working directory. | `shrinkkres_gather` | mainline: the walk |
| The walk without its restart ascends through the links of a mount that is already gone when the parent of the mount it just unmounted went along with it. | `shrinkparent_walk_norestart` | mainline: the walk restarts |

The rescan and the walk keep R on the scripted layout
(`shrinkkres_rescan`, `shrinkkres_walk`). On the random layouts of
`kernel/mount/core/` at three operations all four variants pass every
invariant and reach the same states. Neither defect is reachable within
three free syscalls. The first needs the eleven steps of
`MC_shrinkkres`, the second the seven of `MC_shrinkparent`, which is
what the scripted layouts are for.

The scripted layouts finish in seconds, the random ones in minutes each
on a big machine.

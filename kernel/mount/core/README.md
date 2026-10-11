# The mount code

Status: mainline, modelled at v7.3-rc3. The fixes for F1, F2, F4 and F5
below are in mainline since vfs-7.3-rc7.fixes. The mount code has
changed since the models ran, most of all with "namespace: rework
connected mounts" (01cbebb42070), which isn't modelled.

Models of the mount code as it is in mainline. They come in two
families. The first is the propagation algebra: fs/pnode.c and the tree
surgery of fs/namespace.c transcribed as functions with the kernel's
traversal orders, every syscall one atomic step, and after every step
the result is compared with a declarative rule and with
Documentation/filesystems/sharedsubtree.rst. The second family is the
lockless protocols around the tree: the reference count of a mount
(`MntPut`), the RCU path walk against mount, umount and move
(`MountWalk`), do_lock_mount() against rmdir and d_invalidate()
(`LockMount`), WRITE_HOLD (`MntWriters`) and the lifetime of a mount
namespace (`MntNs`).

Every protection the code has is a switch. Turning one off makes TLC
find the bug it prevents, which is how the models were checked against
the history: the bugs that 0c56fe31420c, 570487d3faf2, 9ea0a46ca2c3,
48a066e72d97, 250cf3693060 and b37199e626b3 fixed all come back as
counterexamples when their switch is off.

Tree: master at 50d05c7c76c9 (v7.3-rc3) plus the revert of 0342482a4d15,
which went into mainline as 2e2142a35d80. The fixes for the findings
below are switches as well, and with them off the models describe
mainline as it was.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | the propagation algebra (`MountTree`, `Propagation`, `MountOps`) and the five lockless protocols, with the layouts, configurations and results |

## Findings

| Finding | Shown by | Outcome |
|---|---|---|
| **F1** clone_mnt() drops T_UNBINDABLE since 406fea799925, so a copied namespace can bind what the original could not. | `small_clone_unbindable` | mainline: "mount: keep a copied mount unbindable" (1ab8904ae61b) |
| **F2** mnt_get_count() sums one per-CPU counter CPU by CPU. A holder that migrates between two reads hides a reference, and a synchronous umount succeeds with a file still open on the mount. | `mntput_torn_sum` | mainline: "fs: don't let a migrating task hide its reference from do_umount()" (7eb84d54fac5), gets and puts in separate per-CPU counters, summed puts first, with an smp_wmb() before the put (`mntput_split_*`) |
| **F4** do_set_group() accepts an unbindable target. With a slave source the target ends up unbindable and a slave at once, reproduced on 7.1.12. | `locked_set_group_unbindable` | mainline: "mount: refuse MOVE_MOUNT_SET_GROUP on an unbindable mount" (a2b42babc912) |
| **F5** Since 99b19d16471e (v4.13) propagate_umount() pulls out copies that propagate_mount_busy() never checked, so a synchronous umount succeeds with such a copy still in use, reproduced on 7.1.12. | `locked_busy_victims`, `parentcand_busy_victims` | mainline: "fs: don't silently unmount busy mounts" (6857e209015f) |
| sharedsubtree.rst and the code disagree in five places: 5g is F1, 5f describes the umount rule from before the 2025 rewrite of propagate_umount() and a single mount only, and 5d and 5e don't cover a move onto the mount's own peer group and a recursive make-slave of a whole peer group. | the `*_doc` configurations | 5f is updated in mainline by "docs: update the unmount propagation rule" (3f5dc09141a7), 5g holds again with F1's fix, 5d and 5e are unchanged; the items are listed in [`tla/README.md`](tla/README.md) |

The other models of the mount code live next to this one:
[`kernel/mount/ownership/`](../ownership/),
[`kernel/mount/shrink-submounts/`](../shrink-submounts/),
[`kernel/mount/vacant/`](../vacant/),
[`kernel/mount/vacant-root-by-root/`](../vacant-root-by-root/),
[`kernel/mount/gp-on-demand/`](../gp-on-demand/) and
[`kernel/mount/gp-on-demand-proposal/`](../gp-on-demand-proposal/).
Several of them start from copies of these modules.

The lockless models finish in seconds to minutes. The propagation
algebra wants a big machine: `algebra_smoke` took eight and a half hours
there and `small_fixed` almost fifteen.

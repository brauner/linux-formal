# Formal models of Linux kernel and systemd code

Models and proofs that cannot live in the trees themselves: TLA+ models
checked with TLC, Linux-kernel-memory-model litmus tests for herd7 and
klitmus7 (the ones the kernel can carry go to Documentation/litmus-tests/
as well), Dartagnan and CBMC harnesses of the C functions, and TLA+ trace
validation of kernel execution traces. Written to check specific series
against the interleavings a reproducer cannot enumerate. Each directory
carries its own README with the mapping from model actions to functions,
the abstractions, the configurations and the results, and pins the tree it
was written against.

## Layout

`kernel/` and `systemd/` hold one directory per subject. Code that is
upstream sits under the name of the subject (`kernel/mount/`); a series
that is not sits under the name of its branch and worktree
(`kernel/work.mount.gp_on_demand.proposal/`), and never shares a directory
with the model of the mainline code it changes (a series directory may
carry its own copy of a mainline module with the series' change applied,
and says so). Inside a subject directory every method has a directory of
its own: `tla/`, `litmus/`, `dat3m/`, `cbmc/`, `trace/`; the subject's
README.md is the index. `tools/` is where the jars go (untracked).

## Kernel

| Directory | Protocol | Kernel base |
|-----------|----------|-------------|
| `kernel/work.coredump.close_files.fixes/` | the coredump rendezvous and the signal, exit, fork, exec and io-wq code around it; "coredump & signals: an impossible affair" | 938c2dd45269 on c7b1fa3db4a1 (vfs-7.4.coredump) |
| `kernel/work.file.close_range_except/` | close_range() with CLOSE_RANGE_EXCEPT and CLOSE_RANGE_CLOEXEC_ONLY and the clone dup_fd() makes for CLOSE_RANGE_UNSHARE; "files,close_range: add CLOSE_RANGE_{CLOEXEC_ONLY,EXCEPT}" | 93957f154604 on 5dd1818b15d9 (work.file.close_range_except) |
| `kernel/close-files/` | the order in which a dying descriptor table closes its files and the exit, exec and fork code around it; "files: make closing files synchronous for close_range(), exec, exit" and its fixes | c7b1fa3db4a1 plus the fixes in 938c2dd45269 |
| `kernel/mount/` | the mount code: the propagation algebra of fs/pnode.c and fs/namespace.c against the documentation, and the lockless protocols around a mount's reference count, do_lock_mount(), WRITE_HOLD, the namespace's lifetime and the RCU path walk; four toggles model fixes these models found that are queued on work.mount.fixes | mainline: master 50d05c7c76c9 (v7.3-rc3) plus the revert of 0342482a4d15 (2e2142a35d80 in vfs.fixes) |
| `kernel/work.mount.knullfs.4/` | the vacant-mount series "namespace: prevent UMOUNT_CONNECTED reference count cycles": the reference count protocol of attached unmounted mounts (own references dropped from task work, vacate_mount(), the handoff between the release of a vacant mount and its last put decided under mount_lock, the vacant children put right after a final put, the `disowned` list of __detach_mounts() and the carrier of the unmounted list, the put order of dissolve_on_fput() and unshare()), knullfs as a superblock that is never released, fsnotify's per-superblock accounting of mount marks, and the RCU path walk against vacate_mount(), with weakly ordered memory; `NOREF`: the stand-in without a reference of work.mount.knullfs.7 (the mark __legitimize_mnt() leaves, the parent and __detach_mounts() freeing an unmarked stand-in without a put) | 095b9753ac15 on vfs-7.4.mount b4698e50d460 (work.mount.knullfs.4); 7eeb6da1e4d7 (work.mount.knullfs.7) |
| `kernel/work.mount.knullfs.7.order/` | the vacant-mount series as work.mount.knullfs.7.order: the models of `kernel/work.mount.knullfs.4/` rerun on that tree, the mark and the increment of __legitimize_mnt()'s fast path as buffered stores against the parent's verdict on a stand-in (`MARK_STORES`, `FIX_LOCK_DOOMED`), and a copy of `kernel/mount/`'s propagation algebra with the branch's propagate_umount() ("namespace: let propagate_umount() hand the set back root by root": the set left linked, trim_one() skipping it, the committed copies handed back root by root in tree order) checked against the mainline rules and the claims of that prep | 5308f2ea619f on vfs-7.4.mount b4698e50d460 (work.mount.knullfs.7.order) |
| `kernel/work.mount.fixes.3/` | shrink_submounts() of "mount: more bugfixes, the Oprah edition": the propagation algebra of `kernel/mount/` with the shrinkable-submount take-down of a synchronous umount as mainline's gather-then-unmount, the series' one-at-a-time rescan and the proposed single walk with an explicit cursor, against the victims propagation pulls out; the finding, the stale cursor of the walk without its restart, and the random layouts | a3fe58f6edea on vfs-7.4.mount b4698e50d460 (work.mount.fixes.3) |
| `kernel/mount-ownership/` | who owns an unmounted mount: the reference count cycle a superblock's open file can close through a parent-owned attached child, and three unmerged answers compared on every pin configuration of one layout, the tombstones of work.put_mnt_ns.tombstone (the ancestor of the vacant-mount series), the pinner rule of work.mount.pins and the internal clones of work.mount.private_clone | master 50d05c7c76c9 plus the revert, the three answers as switches |
| `kernel/work.mount.gp_on_demand/` | the grace period on demand of work.mount.gp_on_demand ("fs: unmount without a grace period when nothing else holds the mount"): the reference count protocol with namespace_unlock() dropping a mount's own reference under mount_lock without a grace period when the count is one, against holders, migrating holders, walkers and weakly ordered stores | e9d8e1e39df1 on work.mount.knullfs.4 ba922416101e (the split counters of 7eb84d54fac5 on) |
| `kernel/work.mount.gp_on_demand.proposal/` | the grace period on demand as proposed on vfs-7.4.mount: the two-mount batch of mntput_unmounted() under one mount_lock hold, held mounts and their one grace period, umount(2), namespace death and kern_unmount_array(), against holders, walkers and weakly ordered stores (TLA+); the barrier pairings under LKMM, the AArch64 and POWER models and on x86 hardware (litmus, klitmus7); the C functions under Dartagnan and CBMC; kernel traces validated against the model | 4379d47fd314 on vfs-7.4.mount c947dc6ab4f4 (work.mount.gp_on_demand.proposal) |

## systemd

| Directory | Protocol | systemd base |
|-----------|----------|--------------|
| `systemd/executor/` | systemd-executor and the service manager: the exec_fd protocol of Type=exec, the (sd-pam) helper, the PrivatePIDs= pidref handoff, the priorities of the manager's event loop against SIGCHLD, and the kill logic | v262-rc2-60-ge96ff3b5b9 |
| `systemd/nsresourced/` | the user namespace registry of systemd-nsresourced: clients (nspawn, the executor), the worker, the BPF-LSM map and death ring buffer, PID 1's fd store, the kernel's inode reuse, the manager's release and startup sweep | v262-rc2-60-ge96ff3b5b9 |
| `systemd/mountfsd/` | dm-verity device sharing between systemd-mountfsd workers: the verity_partition() retry loop against the device-mapper's deferred removal and udev's symlinks | v262-rc2-60-ge96ff3b5b9 |
| `systemd/fiber/` | the fiber runtime of sd-future: fibers driven by their defer and exit event sources, futures resolving and resuming fibers, cancellation and cleanup unwinding, SD_FIBER_TIMEOUT() deadlines, against sd-event's dispatch order; six findings, every fix a switch | v262-rc3 (e96ff3b5b9) |

## Running

Every `tla/` directory expects `tla2tools.jar` from
https://github.com/tlaplus/tlaplus/releases (2.19 was used) and a Java 17
or newer runtime; see `tools/README.md`.

    export TLA2TOOLS=/path/to/tla2tools.jar
    cd kernel/work.coredump.close_files.fixes/tla && ./check.sh sqpoll_deadlock

The litmus tests run with herd7 against the kernel tree's
`tools/memory-model`; Dartagnan, CBMC and the trace validation have their
own run notes next to them.

The configurations that switch a fix off stop at their counterexample in
seconds to minutes; the green kernel proofs explore tens of millions of
states and want a large machine (`run-parallel.sh`).  The systemd models
are small and finish in seconds.

## License

MPL-2.0, see `LICENSE`.

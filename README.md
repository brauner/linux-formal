# TLA+ models of Linux kernel and systemd protocols

Formal models of concurrent protocols, one directory per protocol,
written to check specific series against the interleavings a reproducer
cannot enumerate.  Each directory carries its own README with the mapping
from model actions to functions, the abstractions, the configurations
and the results, and pins the tree it was written against.  Models of
mainline code and models of unmerged series live in separate directories:
a directory models one tree, named in the table below, and a model of a
series never shares a directory with the model of the mainline code it
changes (a series directory may carry its own copy of a mainline module
with the series' change applied, and says so).

## Kernel

| Directory | Protocol | Kernel base |
|-----------|----------|-------------|
| `kernel/coredump/` | the coredump rendezvous and the signal, exit, fork, exec and io-wq code around it; "coredump & signals: an impossible affair" | 938c2dd45269 on c7b1fa3db4a1 (vfs-7.4.coredump) |
| `kernel/close_range/` | close_range() with CLOSE_RANGE_EXCEPT and CLOSE_RANGE_CLOEXEC_ONLY and the clone dup_fd() makes for CLOSE_RANGE_UNSHARE; "files,close_range: add CLOSE_RANGE_{CLOEXEC_ONLY,EXCEPT}" | 93957f154604 on 5dd1818b15d9 (work.file.close_range_except) |
| `kernel/close-files/` | the order in which a dying descriptor table closes its files and the exit, exec and fork code around it; "files: make closing files synchronous for close_range(), exec, exit" and its fixes | c7b1fa3db4a1 plus the fixes in 938c2dd45269 |
| `kernel/mount/` | the mount code: the propagation algebra of fs/pnode.c and fs/namespace.c against the documentation, and the lockless protocols around a mount's reference count, do_lock_mount(), WRITE_HOLD, the namespace's lifetime and the RCU path walk; four toggles model fixes these models found that are queued on work.mount.fixes | mainline: master 50d05c7c76c9 (v7.3-rc3) plus the revert of 0342482a4d15 (2e2142a35d80 in vfs.fixes) |
| `kernel/mount-knullfs/` | the vacant-mount series "namespace: prevent UMOUNT_CONNECTED reference count cycles": the reference count protocol of attached unmounted mounts (own references, vacate_mount(), the handoff between the release of a vacant mount and its last put, __detach_mounts(), the put order of dissolve_on_fput() and unshare()) and the RCU path walk against vacate_mount(), with weakly ordered memory | 8a7c60fb32cb on vfs.fixes 2d2a2d7aa987 (work.mount.knullfs) |
| `kernel/mount-ownership/` | who owns an unmounted mount: the reference count cycle a superblock's open file can close through a parent-owned attached child, and three unmerged answers compared on every pin configuration of one layout, the tombstones of work.put_mnt_ns.tombstone (the ancestor of the vacant-mount series), the pinner rule of work.mount.pins and the internal clones of work.mount.private_clone | master 50d05c7c76c9 plus the revert, the three answers as switches |

## systemd

| Directory | Protocol | systemd base |
|-----------|----------|--------------|
| `systemd/executor/` | systemd-executor and the service manager: the exec_fd protocol of Type=exec, the (sd-pam) helper, the PrivatePIDs= pidref handoff, the priorities of the manager's event loop against SIGCHLD, and the kill logic | v262-rc2-60-ge96ff3b5b9 |
| `systemd/nsresourced/` | the user namespace registry of systemd-nsresourced: clients (nspawn, the executor), the worker, the BPF-LSM map and death ring buffer, PID 1's fd store, the kernel's inode reuse, the manager's release and startup sweep | v262-rc2-60-ge96ff3b5b9 |
| `systemd/mountfsd/` | dm-verity device sharing between systemd-mountfsd workers: the verity_partition() retry loop against the device-mapper's deferred removal and udev's symlinks | v262-rc2-60-ge96ff3b5b9 |
| `systemd/fiber/` | the fiber runtime of sd-future: fibers driven by their defer and exit event sources, futures resolving and resuming fibers, cancellation and cleanup unwinding, SD_FIBER_TIMEOUT() deadlines, against sd-event's dispatch order; six findings, every fix a switch | v262-rc3 (e96ff3b5b9) |

## Running

Every directory expects `tla2tools.jar` from
https://github.com/tlaplus/tlaplus/releases (2.19 was used) and a Java 17
or newer runtime.

    export TLA2TOOLS=/path/to/tla2tools.jar
    cd kernel/coredump && ./check.sh sqpoll_deadlock

The configurations that switch a fix off stop at their counterexample in
seconds to minutes; the green kernel proofs explore tens of millions of
states and want a large machine (`run-parallel.sh`).  The systemd models
are small and finish in seconds.

## License

MPL-2.0, see `LICENSE`.

# LKMM litmus tests of the reference count protocol

Linux kernel memory model tests (herd7 >= 7.58, run against the tree's
`tools/memory-model`: `cd tools/memory-model && herd7 -conf linux-kernel.cfg
<test>`) for the protocol of work.mount.gp_on_demand.proposal: holders on
the fast path of mntput_no_expire(), walkers in __legitimize_mnt(), and the
unmounter summing the split per-CPU counters under mount_lock in
mnt_get_count() before it finishes a mount off without a grace period.
`RESULTS-lkmm.txt` has the observations; `../BARRIERS.md` the argument they
back.

| group | tests | shape | expected |
|---|---|---|---|
| A0 | `MNT-A0-peek-can-miss-fastpath-put` | the peek misses a fast-path put even under sequential consistency: why the grace period branch exists | Sometimes |
| A1 | `MNT-A1-holder-get-before-put`, `MNT-A1m-{nowmb,nomb-in-sum,gets-first}` | holder get counted before its put: the fast path's smp_wmb() against the puts-first sum with the smp_mb() inside mnt_get_count() | Never / Sometimes for the three mutations |
| A2 | `MNT-A2-gp-fallback-sees-fastpath-put`, `MNT-A2k-gp-fallback-sync-rcu`, `MNT-A2m-nogp` | a put the peek missed is seen after synchronize_rcu(_expedited)(); an smp_mb() cannot replace the grace period | Never, Never / Sometimes |
| B1 | `MNT-B1-walker-inc-vs-peek`, `MNT-B1m-peek-no-outer-mb`, `MNT-B1m-walker-nomb` | walker increment against the seqcount write of the peek (store buffering); the peek without its outer smp_mb() (the shape of the tree) | Never, Never / Sometimes |
| B2 | `MNT-B2-walker-bail-sees-doomed-lazy`, `MNT-B2m-walker-flags-unlocked` | a bailing walker sees MNT_DOOMED under mount_lock | Never / Sometimes |
| C | `MNT-C1-kern-unmount-get-before-put`, `MNT-C2-kern-unmount-gp-fallback` | kern_unmount_array(): plain store of mnt_ns, no lock, no seqcount bump | Never |
| D | `MNT-D1-dekker-fastpath-recheck`, `MNT-D1m-holder-wmb-only` | the Dekker alternative (fast path re-reads mnt_ns after its put, no grace period); exploratory, not the tree | Never / Sometimes |
| E | `MNT-E1-slowpath-no-outer-mb`, `MNT-E2-busycheck-no-outer-mb` | mntput_no_expire_slowpath() and do_umount()'s busy check without their outer smp_mb() (the shape of the tree after "fs: drop the smp_mb()s that mnt_get_count() made redundant") | Never |

Modelling: LKMM has no seqlock, the tests spell write_seqlock() out as the
kernel does (lock, seqcount store, smp_wmb(), ..., smp_wmb(), seqcount store,
unlock) and the reader side as READ_ONCE() plus smp_rmb(); per-CPU counters
are one variable per CPU and counter with the sum unrolled over two CPUs;
migration is the same test with the put aimed at the other CPU's variable.

# Why the three outer smp_mb() calls can go (work.mount.gp_on_demand.proposal)

Tree: work.mount.gp_on_demand.proposal, patch "fs: drop the smp_mb()s that
mnt_get_count() made redundant" (e0d99540489b) plus the fold into "fs: unmount
without a grace period when nothing else holds the mounts" (9dd91d69033e).

## The barriers

| removed | where | added by | paired with |
|---|---|---|---|
| `smp_mb()` after `lock_mount_hash()` | `mntput_no_expire_slowpath()` | 119e1ef80ecf (2018) | `__legitimize_mnt()` |
| `smp_mb()` before `propagate_mount_busy(mnt, 2)` | `do_umount()` sync case | 65781e19dcfc (2025) | `__legitimize_mnt()` |
| `smp_mb()` after `lock_mount_hash()` | `mntput_unmounted()` (the series) | the series | `__legitimize_mnt()`, `mntput_no_expire()` |

Kept: `smp_mb()` inside `mnt_get_count()` between the puts pass and the gets
pass (7eb84d54fac5), `smp_mb()` in `__legitimize_mnt()` after the increment,
`smp_wmb()` in the fast path of `mntput_no_expire()` before the decrement.

## The orderings the code relies on

Three threads touch one mount's counters:

* W, the walker (`__legitimize_mnt()`): `inc gets; smp_mb(); re-read seqcount;`
  if unchanged it holds a reference; else it takes mount_lock and bails out
  when it finds MNT_SYNC_UMOUNT or MNT_DOOMED, decrementing under the lock.
* H, a holder (`mntput_no_expire()` fast path, under rcu_read_lock):
  `if (READ_ONCE(mnt_ns)) { smp_wmb(); inc puts; }`, else the slow path under
  mount_lock.
* U, the unmounter: under `write_seqlock(&mount_lock)` (a seqcount store,
  then the critical section) it reads the counters with `mnt_get_count()`:
  puts pass, `smp_mb()`, gets pass; count 1 means the own reference is the
  last and the mount is finished off without a grace period, anything else
  waits for `synchronize_rcu_expedited()`.

Two pairings carry the protocol:

1. **Holder get before put (MP shape).** H: store get (long ago), `smp_wmb()`,
   store put. U: load puts, `smp_mb()`, load gets. If U counts the put it
   counts the get. This is between H's `smp_wmb()` and U's *inner* barrier;
   the outer barrier takes no part (it is before the puts pass).
   Tests: MNT-A1 Never; without the wmb, without the inner mb, or with the
   gets summed first: Sometimes.
2. **Walker increment against the seqcount (SB shape).** W: store gets,
   `smp_mb()`, load seqcount. U: store seqcount (taking the lock), ..., load
   gets. Forbidden outcome: W sees the old seqcount (keeps the reference) and
   U misses the increment (finishes the mount off). Store buffering needs a
   full barrier between store and load on both sides. On U's side the inner
   `smp_mb()` of `mnt_get_count()` is in program order after the seqcount
   store and before the gets loads, so it is that barrier. The outer
   `smp_mb()` provided the same ordering one more time.
   Tests: MNT-B1 Never; MNT-B1m-peek-no-outer-mb (outer removed) Never;
   MNT-B1m-walker-nomb (walker's barrier removed) Sometimes;
   MNT-E1-slowpath-no-outer-mb (slow path shape with the own put before the
   sum) Never; MNT-E2-busycheck-no-outer-mb (do_umount()'s busy check shape)
   Never.

What the outer barrier ordered beyond that: the seqcount store and any
earlier store of U against the *puts* loads. No correctness property depends
on it:

* a fast-path put by H never looks at the seqcount; whether U's puts pass
  sees it or not is exactly what the grace-period fallback handles
  (MNT-A0 shows the peek can miss such a put even under sequential
  consistency; MNT-A2 shows the put is seen after the grace period; MNT-A2m
  shows a barrier cannot replace the grace period);
* every other put (W's bail-out, the slow path, do_umount()'s caller drop)
  happens under mount_lock and is ordered by the lock's release/acquire;
* the slow path's own decrement before its sum is a store of the running CPU
  (preemption is off under the lock), read back in program order.

## All architectures

The argument is made in the Linux kernel memory model (tools/memory-model),
which is the contract every architecture's implementation of `smp_mb()`,
`smp_wmb()`, `READ_ONCE()`/`WRITE_ONCE()`, spinlocks and RCU has to satisfy;
a "Never" there carries to every architecture the kernel runs on. `smp_mb()`
is a full barrier, store-to-load included, everywhere (mfence, dmb ish,
sync, fence rw,rw, bcr 14,0, ...), unlike `smp_wmb()`/`smp_rmb()`, which is
why the inner barrier can stand in for the outer one but not the other way
round (MNT-A1m-nomb-in-sum: Sometimes). The hardware-model runs under Arm's
official AArch64 model and the POWER model are the independent check for the
weakest architectures (research-weak-memory-2.md).

## Results (herd7 7.58, tools/memory-model of the tree)

See RESULTS-lkmm.txt next to the tests in litmus/.

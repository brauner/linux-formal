# LKMM litmus tests of the fs/super.c ordering protocols

Linux kernel memory model tests (herd7 7.58, run against the tree's
`tools/memory-model`) for the memory-ordering protocols of `fs/super.c`
and its partners: `super_wake()` against `super_lock()`/`grab_super()`
and the `wait_var_event()` machinery, the `super_cache_count()` SB_BORN
check, the device table (`fs_bdev_register()`, `setup_bdev_super()`,
cursors) against `bdev_freeze()`/`bdev_deny_freeze()`/`bdev_allow_freeze()`
in `block/bdev.c`, the passive reference against the `sb_lock` walkers,
the `s_writers.frozen` wake-ups, the `s_flags` writers and
`sb_init_dio_done_wq()`.  `RESULTS.md` has the table, the findings and the
`s_flags` writer enumeration.

Tree: work.super.fixes at `fc1c25014ff8` (v7.3-rc6-301).  Every test
quotes the code it encodes with line numbers of that commit.  The branch
has since gained "super: don't put the remount context under s_umount",
which only touches
`do_emergency_remount_callback()`/`do_emergency_remount()` and shifts
`fs/super.c` lines after 1158 by +8; no tested pairing changes.

## Running

    ./run-lkmm.sh            # all SUPER-*.litmus -> *.out, RESULTS-lkmm.txt
    ./run-lkmm.sh SUPER-C4-unregister-allow-vs-freeze
    ./run-hw.sh              # aarch64/ and ppc/ translations -> RESULTS-hw.txt

`run-lkmm.sh` needs `LKMM=<kernel tree>/tools/memory-model` (the runs
used work.super.fixes at fc1c25014ff8) and runs
`cd $LKMM && herd7 -conf linux-kernel.cfg <test>`; the whole suite takes
about 3 seconds.  Every test has an `Expected:` line in
its header; the summary flags a mismatch (there is none).  `run-hw.sh`
runs the hand translations under herdtools7's `aarch64.cat` and `ppc.cat`.

## Naming

`SUPER-<group><n>-<what>`: the test the kernel relies on.  Suffix `m`
(`A1m`, `C1m2`, ...) is a mutant with one barrier or lock removed, which
must come out Sometimes to show the test is sensitive to it.  Suffix `f`
is a fix candidate for a test that comes out Sometimes, `h` a half fix,
`p` the kernel's plain-access variant.  Groups follow the questions:

| group | item | protocol |
|---|---|---|
| A | 1 | `super_wake()` vs `super_lock()`/`grab_super()`: no lost wake-up, SB_BORN publishes `fill_super()` |
| B | 2 | `super_cache_count()` SB_BORN + `smp_rmb()`; `super_cache_scan()` under `s_umount` |
| C | 3 | device-table claims vs `bdev_freeze()`, including the deny/allow paths |
| D | 4 | `put_super()` vs `sb_lock` walkers, `grab_super()`'s `refcount_inc()` |
| E | 5 | `super_dev_put()` vs `super_dev_first()`/`super_dev_next()` cursors |
| F | 6 | `s_writers.frozen` wake-ups; `fserror_unmount()` and `cgroup_writeback_umount()` in `generic_shutdown_super()` |
| G | 7 | `s_flags` read-modify-writes, the RO remount protocol |
| H | 8 | `s_dio_done_wq` publication |
| Z | - | LKMM reference (control dependencies end at the if) |

## Encodings

- `wait_var_event()`: the waiter is the early check, then one round of
  `prepare_to_wait_event()` (wq lock, `__add_wait_queue()` as a store of 1
  to `wq`, `set_current_state()` as `smp_store_mb()`), unlock, re-check.
  The waker is the condition store, the barrier under test, and
  `waitqueue_active()` as a `READ_ONCE()` of `wq`, then the wake under the
  wq lock.  Lost wake-up = waiter re-checked false after queueing and the
  waker saw an empty queue.  The scheduler side of the wake is not
  modelled: a waker that sees the entry wakes the task, and the task's
  next `prepare_to_wait_event()` is ordered after the waker by the wq lock.
- `spinlock_t` is LKMM's lock.  `s_umount`, `bd_holder_lock` and mutexes
  are modelled as spinlocks where their exclusion matters (LKMM has no
  rwsem or mutex); `down_read_trylock()` is `spin_trylock()`.
- RCU: `rcu_read_lock()`/`rcu_read_unlock()`/`synchronize_rcu()`;
  `call_rcu()`/`kfree_rcu()` as `synchronize_rcu()` followed by the
  callback in the same process (litmus-tests.txt).
- `refcount_t` as implemented in this tree (`include/linux/refcount.h`):
  `refcount_inc()` = `atomic_fetch_add_relaxed()`;
  `refcount_inc_not_zero()` = relaxed `try_cmpxchg` loop, i.e.
  `atomic_cmpxchg_relaxed(r, 1, 2)` when the count can only be 0 or 1;
  `refcount_dec_and_test()` = `atomic_fetch_sub_release()` followed, on
  success, by `smp_acquire__after_ctrl_dep()` (`smp_rmb()`).
- `atomic_inc_unless_negative()`, `atomic_dec_unless_positive()`,
  `atomic_inc_not_zero()`, `try_cmpxchg()` are fully ordered on success:
  `atomic_cmpxchg()`/`cmpxchg()` with the matching expected value.
  `atomic_inc()` (`bdev_allow_freeze()`) is relaxed.
- rhltable: insertion is a release store (`rcu_assign_pointer()` or
  `rht_assign_unlock()` under the bucket bit lock, modelled as a
  spinlock), lookup an `rcu_dereference()` of the slot.  Resizing is
  assumed to keep "insert, full barrier, later lookup finds it".
- `s_flags` bits are small integers chosen per test (the header says
  which); `s_writers.frozen` uses the kernel's values (0..4).
- Marked accesses (`READ_ONCE()`/`WRITE_ONCE()`) stand in for the kernel's
  plain accesses unless a test is about plain accesses (`A2`, `B1`, `B1p`
  keep them plain and herd7 reports data races where they race).
- Registers that are only assigned on one branch start at -1 where the
  condition needs to tell "ran and read 0" from "did not run".

## Hardware translations

`aarch64/` and `ppc/` hold hand translations for the two results where
the architecture matters: the `fserror_unmount()` lost wake-up (`F3`,
allowed by LKMM, by the Arm model and by the POWER model; the fix is
forbidden by all three) and the `bdev_allow_freeze()` reorder (`C4`,
allowed by LKMM, forbidden by the Arm model because the compiled code
branches on the put's result; `C4m-no-branch` shows the branch is what
forbids it).  Mapping: `atomic_fetch_sub_release()` = NEG + `LDADDL` /
`lwsync; lwarx/stwcx.`, `smp_rmb()` = `DMB ISHLD` / `lwsync`,
`smp_mb()` = `DMB ISH` / `sync`, fully ordered cmpxchg = `CASAL`,
relaxed cmpxchg = `CAS`, `atomic_inc()` = `STADD`.

# LKMM litmus tests of file_ref against its users

Linux kernel memory model tests (herd7 7.58, run against the tree's
`tools/memory-model`) for the ordering file_ref provides and the ordering
its lockless users need: `__fget_files_rcu()` and `__get_file_rcu()`
against `close(2)`, `open(2)` and the SLAB_TYPESAFE_BY_RCU recycling of
the file, the cleared pointer of kvm's guest_memfd, the free after a
resurrecting get/put pair, and `file_ref_put_close()`.  The TLA+ model
in [`../tla/`](../tla/) treats every atomic as one step; these tests are
where the ordering of the counter against the other words is decided.

Tree: vfs/master at v7.4-rc1-132-g05441d697f7f.  Every test quotes the
code it encodes with the line numbers of that commit.

## Running

    ./run-lkmm.sh            # all FREF-*.litmus -> *.out, RESULTS-lkmm.txt
    ./run-lkmm.sh FREF-G2-same-slot-stale-field

`run-lkmm.sh` takes `LKMM=<kernel tree>/tools/memory-model` (default:
the vfs/master tree above) and runs `herd7 -conf linux-kernel.cfg` on
each test; the suite takes about a second.  Every test has an
`Expected:` line in its header; the summary flags a mismatch (there is
none).

## Naming

`FREF-<group><n>-<what>`.  A plain name is the kernel as it is or a
relaxation that holds; suffix `m` is a mutant with one ordering removed,
which must come out Sometimes to show the test is sensitive to it;
suffix `f` is the fix of a test that comes out Sometimes; `h` is a
different shape of the same question.

| group | question |
|---|---|
| G | the lookup: what `__fget_files_rcu()` and `__get_file_rcu()` need from `file_ref_get()`, and what they read after it |
| P | the put: what `file_ref_put()` has to order on the way to the free |
| C | `file_ref_put_close()`: the one-cmpxchg close |

## Encodings

- The counter is an `atomic_t` holding references - 1: ONEREF 0, NOREF
  -1, DEAD -4.  `file_ref_get()` is `atomic_fetch_add()` (fully ordered
  as `atomic_long_add_negative()` is; `_acquire` and `_relaxed` where the
  test says so), `file_ref_put()` is `atomic_fetch_sub()`, the slow path's
  `try_cmpxchg_release()` is `atomic_cmpxchg_release(cnt, -1, -4)`, and
  `smp_acquire__after_ctrl_dep()` is the `smp_rmb()` it expands to.
  LKMM returns the old value from the RMW, the kernel the new one; the
  ordering is the same.
- The descriptor slot is an int (1 the file, 0 NULL) where only its
  identity matters, and a pointer (`slot=fop`, then `q` for NULL) where
  the field read of the caller has to depend on it (G2).  `close(2)`
  clears it with `WRITE_ONCE()`: `rcu_assign_pointer()` of a constant
  NULL is a plain store.  `fd_install()` publishes it with
  `smp_store_release()`, as `rcu_assign_pointer()` does.
- Recycling: `init_file()` sets the counter with a plain `atomic_set()`,
  `do_dentry_open()` stores `f_op` after that, then `fd_install()`.  In
  G1h the freed object goes through the slab freelist to another CPU: a
  plain store on the freeing side, a load the allocating side's init
  store depends on by control.
- `0:r1 = -1` (the cmpxchg's old value) says the put was the last one and
  the file was freed and recycled, which is what makes a `0` read by the
  lookup's increment the recycled ONEREF rather than the initial one.
  Registers that are only assigned on one branch start at -9 so that
  "did not run" cannot read as a success.

## Results

| test | expected | observed | what it says |
|---|---|---|---|
| `FREF-G1-recheck-get-full` | Never | Never | the lookup as it is: the recycled file never passes the recheck in the old slot |
| `FREF-G1a-recheck-get-acquire` | Never | Never | **acquire is enough for `file_ref_get()`**: the address dependency orders the increment after the first load, the acquire orders the recheck after the increment |
| `FREF-G1m-recheck-get-relaxed` | Sometimes | Sometimes | a relaxed get lets the recheck read the old slot: the lookup returns a file the descriptor never named |
| `FREF-G1rm-recheck-release-put` | Sometimes | Sometimes | an acquire get against a release put: the release orders the cleared slot before the decrement, not before the counter's re-initialisation after the free |
| `FREF-G1h-handoff-release-put` | Sometimes | Sometimes | the same with the recycled object handed to another CPU through the slab freelist, the shape the kernel has: **the put has to stay fully ordered** on the synchronous free paths |
| `FREF-G1hf-handoff-full-put` | Never | Never | the fully ordered decrement orders the cleared slot before the freelist store |
| `FREF-G1hm-handoff-release-put-mb` | Never | Never | what a release put would need: an `smp_mb()` before the free |
| `FREF-G2-same-slot-stale-field` | Sometimes | Sometimes | **`__fget_files_rcu()` returns a recycled file whose fields the caller can read stale**: the field read is ordered after the increment, not after the reload that saw `fd_install()`'s store, and `f_op` is written after `f_ref` |
| `FREF-G2f-same-slot-reload-dep` | Never | Never | the fix: read through the reloaded pointer, as `__get_file_rcu()` does since 0ede61d8589c |
| `FREF-G2fa-same-slot-reload-dep-acquire` | Never | Never | the fix with an acquire get |
| `FREF-G2fm-same-slot-reload-dep-relaxed` | Sometimes | Sometimes | the fix with a relaxed get: the reload itself can be early |
| `FREF-G2h-same-slot-acquire-reload` | Never | Never | the other fix, `smp_load_acquire()` for the reload: correct, but an acquire load on every lookup where the dependency is free |
| `FREF-P1-cleared-slot-release-put` | Never | Never | kvm's pattern (pointer cleared, then the put; `__get_file_rcu()` sees NULL or fails the reload check) needs release on the put and acquire on the get |
| `FREF-P1m-cleared-slot-relaxed-put` | Sometimes | Sometimes | a relaxed put lets the decrement overtake the cleared pointer |
| `FREF-P1mm-cleared-slot-relaxed-get` | Sometimes | Sometimes | a relaxed get lets the reload overtake the increment |
| `FREF-P2-resurrect-free-acquire` | Never | Never | the free after a lost-and-won cmpxchg sees what the resurrecting get/put pair did: `smp_acquire__after_ctrl_dep()` does that, release decrements suffice for it |
| `FREF-P2m-resurrect-free-no-fence` | Sometimes | Sometimes | without the fence the free runs ahead of the pair's use |
| `FREF-P3-last-put-release` | Never | Never | two holders with release decrements: the last one's free sees the other's use through the fence |
| `FREF-P3m-last-put-no-fence` | Sometimes | Sometimes | without the fence it may not |
| `FREF-P3c-last-put-full-no-fence` | Never | Never | the kernel today: the fully ordered decrement covers this case by itself, the fence is for the resurrection case |
| `FREF-C1-put-close-full-cas` | Never | Never | `file_ref_put_close()`: the fully ordered cmpxchg orders the free after a lookup's get, use and put |
| `FREF-C1m-put-close-release-cas` | Sometimes | Sometimes | a release-only cmpxchg does not |
| `FREF-C1f-put-close-release-cas-fence` | Never | Never | release plus `smp_acquire__after_ctrl_dep()` would; nothing gained on any architecture, so the full cmpxchg stays |

## What follows

- `file_ref_get()` can be `atomic_long_add_negative_acquire()`.  Every
  user that reads anything after a successful get needs the increment
  ordered before those reads, and that is acquire; none needs the
  release half, a reference count's get never does.  x86 generates the
  same `lock add`; arm64 LSE drops from `ldaddal` to `ldadda`, arm64
  LL/SC from `ldxr/stlxr` plus `dmb ish` to `ldaxr/stxr`, POWER from
  `sync` before and after the `larx/stcx.` loop to an `isync` after it.
  RISC-V trades `amoadd.aqrl` for `amoadd` plus a `fence r,rw`, which is
  not an obvious win there.
  G1a, G2fa and P1 are the proof for the two lookup shapes.
- `file_ref_put()` keeps `atomic_long_dec_return()`.  Its full barrier
  is what orders the cleared descriptor slot before the slab handoff in
  `__fput_sync()` and in the fallback path of `fput_close_sync()` (G1h);
  the deferred `fput()` has the `try_cmpxchg()` of `task_work_add()`
  for that, the synchronous paths have nothing else.  The header's
  "release on the way in, acquire on success" describes the
  `__file_ref_put()` half (P2, P3), not the whole function.
- `__fget_files_rcu()` should carry the dependency of its second load
  into what it returns, the way `__get_file_rcu()` does (G2, G2f).  On
  x86 the full barrier of `file_ref_get()` plus TSO hides it; on arm64
  and POWER a caller of `fget()` can read `f_mode` or `f_op` of the
  previous incarnation of a file that was closed and reopened on the
  same descriptor by another thread.

# CBMC harness for the grace-period-on-demand mntput() protocol

Tree: work.mount.gp_on_demand.proposal at 4379d47fd314, fs/namespace.c.

The functions of the protocol are copied verbatim from fs/namespace.c
into a C harness with the per-CPU counters, the seqlock, the grace
period and task work modelled around them, and the invariants of the
TLA+ model become assertions. The model is the one in
`kernel/work.mount.gp_on_demand/tla/MntPut.tla`, which
`../tla/MntPut.tla` extends to the batch of the series. CBMC then checks
the assertions over every interleaving of the three threads up to the
unwinding bound.

## Status: no verdict yet

The harness compiles and CBMC 6.6.0 runs it in minutes, but nothing it
reported so far is evidence either way. Every configuration that
finished, the series as written included, reported the same family of
about thirty failures. The counterexamples show per-CPU counter slots
holding values no increment can produce: a slot that only ever held 0, 1
or 2 reads as 1275523073. That's CBMC's thread encoding, not the kernel.
Those runs updated the counters with a store under a nondeterministic
guard (`for (c) if (c == cpu) slot[c] += 1`), and a read in another
thread can pick up such a guarded write with the value of the path that
wasn't taken. The same traces also fail the pointer checks on
`mnt->mnt_pcp`, which points at a second weakness: CBMC doesn't resolve
the `mnt` that real_mount() derives from `&m->mnt` by pointer arithmetic
in the threaded encoding.

The current `mntput_harness.c` gives every thread one constant CPU, so
there are no guarded writes any more. Its first run was still in the
solver when the work stopped. If it reports nothing but the
`NoFastFinal` witness, the guarded writes were the whole story. If the
failures persist, the next step is to take the pointer arithmetic out of
the threaded harness: pass struct mount * everywhere so that every
shared access is `mounts[const].field`, then rerun `run.py` under
sequential consistency and with `-m tso`.

Never run: the TSO pass, the BATCH=2 and kern_unmount_array()
configurations, and the full set of `--pointer-check --bounds-check
--signed-overflow-check --unsigned-overflow-check` (one probe with all
of them did not finish in 900 seconds).

## Files

| file | what |
|---|---|
| `mntput_harness.c` | the harness: copied kernel functions + ghost state + threads U/H/W |
| `run.py`, `run.sh` | the configuration matrix (SC, `-m tso` for goto-instrument --mm tso), result parsing; writes `results/<name>.<mm>.log` and `results.md` |
| `measure.py` | wall time + peak RSS (no /usr/bin/time on the machine it ran on) |
| `trace2.py`, `trace_summary.py` | print the trace of one failed property from a log compactly, two variants |

## Function <-> copy mapping

| kernel (fs/namespace.c @ 4379d47fd314) | harness | status |
|---|---|---|
| `mnt_inc_count()`, `mnt_dec_count()` | same | verbatim; `this_cpu_inc()` -> `percpu_add()` (array slot of a nondet CPU, atomic, ghost ledger in the same step) |
| `mnt_get_count()` | same | verbatim (two passes, `smp_mb()` between, unsigned `gets - puts`); `for_each_possible_cpu`/`per_cpu_ptr` over the `mnt_pcp[NCPU]` array; `MUT_TORN_SUM` restores the pre-7eb84d54fac5 single counter |
| `__legitimize_mnt()`, `legitimize_mnt()` | same | verbatim (+ one `TOUCH`); `MUT_NO_MB_LEGIT`, `MUT_NO_DOOMED` |
| `mntput_no_expire()`, `mntput_no_expire_slowpath()` | same | verbatim (+ `TOUCH`); `MUT_PUT_RECHECK` adds the post-decrement re-read and `mntput_recheck_locked_look()` |
| `mntput_final_locked()` | same | flags/VFS_WARN_ON verbatim; `mnt_del_instance()` stub, `mnt_expire` list_del and the covers loop dropped (pointer lists, see below); ghost `DoomedIsLast` assertion |
| `mntput_queue_cleanup()` | same | verbatim; `task_work_add()` -> per-thread flag, `run_task_work()` at every "syscall return"; kthread path asserted unreachable |
| `cleanup_mnt()`, `__cleanup_mnt()`, `delayed_free_vfsmnt()`, `free_vfsmnt()` | same | verbatim shape; `deactivate_super()`/`dput()`/`mnt_free_id()`/`fsnotify` stubs; ghost cleaned/cleaner/sb_torn/freed; `call_rcu()` = grace-period assumption then the callback |
| `mntput_unheld()` | same | verbatim; `MUT_PEEK_LOOSE` (also at count 2); witness `NoFastFinal` = `assert(0)` after the fast finish |
| `mntput_unmounted()` | same | control flow verbatim (lock, smp_mb, pass 1 peek/move to held, unlock, pass 2 queue cleanup, one `synchronize_rcu_expedited()`, puts of held); the hlist operations are a flag model, see below; `MUT_NO_GP` |
| `mntput()`, `mntget()`, `mnt_make_shortterm()` | same | verbatim |
| `kern_unmount_array()` | same | verbatim except `hlist_add_head()` -> `unmounted_add()` |
| `do_umount()` lock-section core | same | verbatim from `namespace_lock()` to `return`; `__free(mntput_no_expire)` expanded by hand as `DROP_REF()` before each return (after `namespace_unlock()`, as the compiler orders it); pre-lock part reduced to `security_sb_umount()` (nondet 0/-EPERM); `propagate_mount_busy(mnt, 2)` -> `nr_children \|\| mnt_get_count(mnt) > 2` |
| `umount_tree()` | REDUCED | MNT_UMOUNT, `WRITE_ONCE(mnt_ns, NULL)`, MNT_SYNC_UMOUNT, unhash (ghost), onto `unmounted`; tree walk = `mounts[0], mounts[1]` |
| `namespace_unlock()` | REDUCED | move `unmounted` to a local head, `mntput_unmounted(&head)` |
| `lock_mount_hash()`/`unlock_mount_hash()` | `write_seqlock()`/`write_sequnlock()` | spinlock = atomic test-and-set with `__CPROVER_assume`, full fence after acquire, `sequence++` + wmb on both sides; `read_seqbegin()` assumes an even sequence (the reader spins otherwise) |

## Modelling decisions that could hide bugs

1. **The kernel's hlist/list pointer code is not in the threaded harness.**
   CBMC's threaded symex throws "pointer handling for concurrency is unsound"
   (goto_symex_state.cpp, `is_shared && lhs.type() == pointer`, issue #305)
   for every pointer-typed store to shared memory, which `*pprev = next` etc.
   are.  The `unmounted`/`held` hlists are membership-flag arrays with a
   compile-time traversal order (`INSERTED()`), the superblock mount list,
   `mnt_expire`, `mnt_covers`, `mnt_child`/`mnt_mounts` are ghost ints or
   dropped.  The two-pass bookkeeping ("every mount ends on exactly one of
   finished-now / held", "head empty afterwards") is checked only in the
   reduced form.  The real pointer code needs a single-threaded CBMC run
   (not done).
2. `mnt_ns` is an int id (0 = NULL), `mnt_parent` an index: same reason.
3. Per-CPU: every thread runs on one constant CPU (U on 0, H on `HCPU`, W on
   `WCPU`); with `MIGRATE=1` the holder moves to CPU 0 between its extra get
   and its puts, like the TLA+ model's `MIGRATE`.  The first version picked a
   nondeterministic CPU per `this_cpu_inc()`, which is what ran into the
   artefact described under Status.  Under `--mm tso` CBMC's store buffers are
   per thread, not per CPU; migration does not drain them (the kernel's does),
   which only adds behaviours.
4. RCU: `rcu_read_lock()` sets `in_rcu[tid]`; a grace period = for each other
   thread, an atomic `__CPROVER_assume(!in_rcu[t])` (sound for safety, says
   nothing about liveness); `call_rcu()` frees as early as legal, in the
   caller's thread (ghost `freed`, no real `free()`, so NoUAF is the `TOUCH`
   ghost check, not CBMC's pointer check).
5. `cleanup_mnt()` runs from `run_task_work()` at the end of each thread's
   syscall (TWA_RESUME); MNT_INTERNAL mounts (kern shape) clean up inline as
   in the kernel; no kthread/workqueue path.
6. Threads: one holder, one walker (fixed target `WALK`, CBMC cannot
   dereference a nondeterministic pointer), the umounter is the main thread.
   Spawned with `__CPROVER_ASYNC_n` (CBMC's own `pthread_create()` model trips
   the same pointer-store check); joins are assumptions on done flags.
7. `security_sb_umount()` may refuse (nondet) to exercise the early return;
   MNT_EXPIRE/MNT_FORCE/root paths of `do_umount()` are not in the harness.
8. The walker finds the mount while `ghost_hashed` or while the holder has a
   reference (fs->pwd route), both as racy reads.
9. Bounds: NCPU=2, BATCH<=2, GETS=1 extra get/put pair, `--unwind 4`
   with `--unwinding-assertions`; checks: `--pointer-check --bounds-check
   --signed-overflow-check --unsigned-overflow-check` (the last one guards the
   kernel's unsigned `gets - puts`).

## Assertions (one per TLA+ invariant)

NoUAF (`TOUCH` on every struct mount access, + sb_torn after legitimize),
DoomedIsLast (ghost ledger at `mntput_final_locked()`, transient walker
excluded; a non-transient get on a doomed mount), NoNegative (`WARN_ON(count
< 0)`), SyncClean (after a successful sync umount: holder/walker ledger 0,
cleaned by U before umount(2) returns, sb torn down), Freed/no leak (every
unmounted mount cleaned and freed exactly once; a refused umount leaves count
1), CallerPutOnce (the `__free` expansion), the witness NoFastFinal (MUST fail).

## Install (Debian, no root)

    apt-get download cbmc minisat && for d in *.deb; do dpkg -x $d ~/opt/fv; done
    export PATH=~/opt/fv/usr/bin:$PATH LD_LIBRARY_PATH=~/opt/fv/usr/lib/x86_64-linux-gnu:~/opt/fv/usr/lib
    cbmc --version   # 6.6.0

ESBMC was not tried.

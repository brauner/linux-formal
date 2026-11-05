# file_ref: the reference count of struct file

Status: mainline, modelled at v7.4-rc1-132-g05441d697f7f, as modelled.
Nothing proposed here is applied anywhere yet.

`file_ref_t` (include/linux/file_ref.h, the slow path in fs/file.c) is
the rcuref scheme on an `atomic_long_t`: an unconditional increment that
succeeds while the result is not negative, an unconditional decrement
whose negative result goes to a slow path that turns NOREF into DEAD
with a cmpxchg, saturation and dead zones wide enough that the races of
the unconditional operations can never leave them, and no reference on
RCU for the memory: files are SLAB_TYPESAFE_BY_RCU, so a freed file can
be reallocated at once and only its slab page waits for a grace period.
`file_ref_put_close()` tries ONEREF to DEAD in one cmpxchg for close(2).

Two models.  The TLA+ model is the counter protocol under every
interleaving of close(2), open(2) recycling the object, dup2(2), the
fget-rcu lookup with its retry loop, holders with get_file()/fput()
pairs and epoll's get under its mutex, with the page release after a
grace period and the use-after-free that a stale access is.  The litmus
tests are the ordering between the counter and the other words: the
descriptor slot the lookup rechecks, the fields of a recycled file, the
cleared pointer of kvm's guest_memfd, the free after a resurrecting
get/put pair.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | the counter protocol: 27 configurations, every protection a switch, the two races of the series as traces, the zone widths |
| LKMM litmus (herd7) | [`litmus/`](litmus/README.md) | 23 tests: what the lookups need from `file_ref_get()`, what `file_ref_put()` has to order on the way to the free, `file_ref_put_close()` |

## Findings

| Finding | Shown by | Outcome |
|---|---|---|
| **F1** `__fget_files_rcu()` returns a file whose fields its caller can read from the previous incarnation. When thread A closes a descriptor and open(2) gives it the same `struct file` and the same descriptor back, thread B's lookup increments the recycled counter, its recheck passes, and nothing orders B's later loads of `f_mode` or `f_op` after the reload that saw the new install: `file_ref_get()` orders them after the increment, but `init_file()` sets `f_ref` before `do_dentry_open()` sets `f_op`. The SLAB_TYPESAFE_BY_RCU conversion (0ede61d8589c) made every later load depend on the second load, as Jann Horn asked; the code-generation rewrite (253ca8678d30) inlined the lookup without that dependency. `__get_file_rcu()` still has it. x86 is covered by TSO; arm64 and POWER are not. | `FREF-G2-same-slot-stale-field` (Sometimes), `FREF-G2f-same-slot-reload-dep` (Never); the Arm model on the compiled arm64 lookup, `litmus/aarch64/`: Sometimes with LSE and on the LL/SC path, Never with the fix | proposed: carry the dependency of the reload into the returned pointer, the diff is below |
| **F2** `file_ref_get()` needs acquire ordering and provides full ordering. Every lockless user reads something after a successful get and needs that ordered after the increment; the first load is ordered before the increment by its address dependency; nobody needs the release half. `atomic_long_add_negative_acquire()` is the same `lock add` on x86, `ldadda` instead of `ldaddal` on arm64 LSE, no `dmb ish` after the LL/SC loop on arm64 without LSE, an `isync` instead of two `sync` on POWER. | `FREF-G1a`, `FREF-G2fa`, `FREF-P1` (Never), `FREF-G1m`, `FREF-G2fm`, `FREF-P1mm` (Sometimes) | proposed: the diff is below |
| **F3** `file_ref_put()` cannot be relaxed to release ordering, although its header says release on the way in and acquire on success. The full barrier of the decrement is what orders the cleared descriptor slot before the slab handoff that lets another CPU recycle the file, on the synchronous free paths (`__fput_sync()`, the fallback of `fput_close_sync()`); the deferred `fput()` has the `try_cmpxchg()` of `task_work_add()` for that. With a release decrement a lookup can increment the recycled counter and still pass its recheck in the old slot. | `FREF-G1h-handoff-release-put` (Sometimes), `FREF-G1hf`, `FREF-G1hm` (Never) | no change; the header comment overstates what the function may become |
| **F4** The protocol is correct for the configurations checked: no access to a released page, no reference used on a freed or recycled file, the counter is the references minus one on every live file, a put returns true exactly once per incarnation and only with no reference left, the lookup returns the file its descriptor named, none of the three warnings fires, nothing leaks. Every protection is load-bearing: with it off TLC finds the trace it prevents. The two races of the series (08ef26ea9ab3) come back with their switches off: the slow path that re-read the counter warns about a balanced put, the get slow path marks a recycled file dead for its new owner. | `fixed*` (pass), `no_*`, `get_slowpath` (violations) | as modelled |
| **F5** The dead zone has to be wider than the number of failed gets a dead file can collect before it is recycled: with DEAD + 1 = NOREF (a 4-bit counter) two lookups that lost against close(2) resurrect a freed file. The real gap is 2^61 (2^29 on 32-bit) and a failed get needs a pointer that was loaded before the close, so a lookup loop collects at most one per round. | `zone_escape` (violation), `zone_ok` (pass) | the design, quantified |
| **F6** Saturation through `file_ref_get()` leaks silently: at MAXREF a failed get wraps the counter to MIN, the next put wraps it back to MAXREF one too high, the file is never freed and nobody warns, because the get slow path that warned in rcuref was dropped. Through `get_file()` the second increment past MAXREF warns and the puts park the counter on SATURATED. 2^63 references on 64-bit; a note, not a bug. | `saturation_get`, `saturation_inc` (violations) | documentation |

## The proposals

F1, the dependency `__fget_files_rcu()` lost in 253ca8678d30, the shape
of `__get_file_rcu()`:

    --- a/fs/file.c
    +++ b/fs/file.c
    @@ static inline struct file *__fget_files_rcu(struct files_struct *files,
     	for (;;) {
     		struct file *file;
    +		struct file *file_reloaded;
    +		struct file *file_reloaded_cmp;
     		struct fdtable *fdt = rcu_dereference_raw(files->fdt);
    @@
    +		/*
    +		 * Make every load below depend on the reload: if the file was
    +		 * freed and reallocated into this slot, what open() wrote to it
    +		 * is published by fd_install() with that store, not by the
    +		 * increment above, which file_ref_init() precedes.
    +		 */
    +		file_reloaded = rcu_dereference_raw(*fdentry);
    +		file_reloaded_cmp = file_reloaded;
    +		OPTIMIZER_HIDE_VAR(file_reloaded_cmp);
    -		if (unlikely(file != rcu_dereference_raw(*fdentry)) ||
    +		if (unlikely(file != file_reloaded_cmp) ||
     		    unlikely(rcu_dereference_raw(files->fdt) != fdt)) {
     			fput(file);
     			continue;
     		}
    +		file = file_reloaded;

F2, the acquire get:

    --- a/include/linux/file_ref.h
    +++ b/include/linux/file_ref.h
    @@ bool __file_ref_put(file_ref_t *ref, unsigned long cnt);
    - * Provides full memory ordering.
    + * Provides acquire ordering: loads after a successful get are ordered
    + * after the increment, which is what the pointer recheck of the
    + * fget-rcu pattern needs. The load of the pointer the reference is
    + * taken through is ordered before the increment by its dependency.
    @@ static __always_inline __must_check bool file_ref_get(file_ref_t *ref)
    -	return !atomic_long_add_negative(1, &ref->refcnt);
    +	return !atomic_long_add_negative_acquire(1, &ref->refcnt);

and the comments in `__get_file_rcu()` and `__fget_files_rcu()` that
name the full barrier ("We only really need an 'acquire' one to protect
the loads below, but we don't have that": now we do), the one in
`virt/kvm/guest_memfd.c` already says acquire.  Neither diff was built
or run; `tla/` says what the counter does, `litmus/` what the ordering
does, and that is all they say.

## What the models leave out

- Table resizing: `__fget_files_rcu()` also rechecks `files->fdt`; the
  model has one table that never grows.
- `fdget()` on an unshared table takes no reference at all; it is the
  owner's own reference and never races with the owner's close, so it is
  the owner in the model.
- Task work: a put that returns true owes a `__fput()` that runs at any
  later point outside every read-side section, synchronous or deferred
  alike; the model does not distinguish the two.
- The saturation zone with real widths: the `saturation_*` runs use a
  5-bit counter, the zones are the real layout scaled down.
- Ordering in the TLA+ model is sequential consistency; the litmus
  tests cover the orderings between words, for the shapes they encode
  and no others.

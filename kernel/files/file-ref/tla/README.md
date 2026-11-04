# The TLA+ model of file_ref

`FileRef.tla` is the counter protocol of include/linux/file_ref.h and
the slow path `__file_ref_put()` of fs/file.c, with the files that are
SLAB_TYPESAFE_BY_RCU: a freed object keeps its contents and may be
allocated again at once, its slab page goes back to the page allocator
after a grace period that waits for every task that was inside a
read-side section (rcu_read_lock() of the lookup, guard(preempt)() of
the put) when the object was freed.  Every atomic is one step, so the
model is sequentially consistent; the ordering between the counter and
the other words is the business of [`../litmus/`](../litmus/).

The counter is scaled from 64 bits to `BITS` bits so that TLC reaches
every zone: with `BITS = 6` ONEREF is 0, MAXREF 31, MIN -32, SATURATED
-24, RELEASED -16, DEAD -8 and NOREF -1, the same bit layout as the
real constants.  `Add()` wraps in two's complement.

## Actions

| Action | Kernel |
|---|---|
| `PutDec(t)` | `file_ref_put()`: `guard(preempt)()`, `atomic_long_dec_return()`; a non-negative result returns false with the guard already left |
| `PutSlow(t)` | `__file_ref_put()` with the decrement's result (or a fresh read, `FIX_PASS_CNT` off): NOREF: `try_cmpxchg_release(NOREF, DEAD)` and true on success; dead zone: `WARN_ONCE("imbalanced put")`, DEAD, false; saturation zone: SATURATED, false; the guard ends |
| `PutCloseRead(t)`, `PutCloseCas(t)` | `file_ref_put_close()`: `atomic_long_read()`, `try_cmpxchg(ONEREF, DEAD)`, fall back to `file_ref_put()` |
| `Release(t)` | `__fput()` from task work or synchronously, outside every read-side section: `eventpoll_release_file()` under `ep->mtx`, `file_free()`; the object is free, its page is held for the tasks inside a read-side section right now |
| `Gone(o)` | the grace period ended with the object still free: the slab page is released |
| `Close(t)`, `Flush(t)` | close(2): `file_close_fd()` clears the slot under `file_lock`; `filp_flush()`'s `CHECK_DATA_CORRUPTION(file_count() == 0)`; `fput_close_sync()` (`CLOSE_PUT = "put_close"`) or `__fput_sync()` |
| `Open(t)`, `Install(t)` | open(2): `kmem_cache_alloc()` recycles a free object at once, `init_file()` sets ONEREF, `fd_install()` |
| `Dup(t)` | dup2(2): `get_file()` = `file_ref_inc()` with its `WARN_ONCE()`, the new slot |
| `GStart`, `GLoad`, `GGet`, `GRecheck`, `GUse`, `GRetry` | `__fget_files_rcu()`: `rcu_read_lock()`, `file = *fdentry`, `file_ref_get()`, `file != *fdentry` with `fput()` and `continue`, the caller's use and `fput()`; `GReturn` is the return without the recheck (`FIX_RECHECK` off); `GSlow1/2` the v2 `__file_ref_get()` slow path (`FIX_NO_GET_SLOWPATH` off): read, then DEAD for a dead zone value and false, else true |
| `HGet`, `HPut` | a holder's `get_file()` and `fput()` |
| `ELock`, `EGet`, `EUse`, `EUnlock` | `epi_fget()` under `ep->mtx` on the file the epitem points to; `Release` clears the epitem under the same mutex |

A getter's lookup takes effect at the reload (`GRecheck`): that is where
`gok` records whether the reference is on the incarnation the slot held
when it was loaded or on the one the slot holds now.

## Switches

| Constant | On | Off |
|---|---|---|
| `FIX_PREEMPT_GUARD` | `guard(preempt)()` around the decrement and the slow path | the slow path touches an object whose page a grace period released: `NoUAF` |
| `FIX_PASS_CNT` | `__file_ref_put()` gets the decrement's result | it re-reads the counter; a get/put pair in between makes it DEAD and the balanced put warns "imbalanced put": `NoWarn` (race 1 of 08ef26ea9ab3) |
| `FIX_NO_GET_SLOWPATH` | `file_ref_get()` is the bare `add_negative()` | the v2 slow path re-reads and parks a dead-zone value on DEAD, after the file was freed, recycled and installed for somebody else: `Ledger`, `DeadMeansNoRefs`, `NoStale`, `NoWarn` (race 2 of 08ef26ea9ab3) |
| `FIX_CMPXCHG_DEAD` | NOREF to DEAD by cmpxchg | by a plain store, which overwrites a resurrection: the file is freed with a reference on it: `OwedRelease` |
| `FIX_DEAD_MARK` | the last put marks DEAD before the free | it frees at NOREF: a get resurrects a freed file: `NoStale`, `NoUAF`, `DeadMeansNoRefs` |
| `FIX_RECHECK` | the lookup reloads and compares the slot | it returns the recycled file for a descriptor that never named it: `RightFile` |
| `FIX_GET_RCU` | the lookup is under `rcu_read_lock()` | its increment lands on a released page: `NoUAF` |
| `CLOSE_PUT` | `"put_close"`: close(2) uses `fput_close_sync()` | `"put"`: `__fput_sync()` |
| `BITS` | the width of the counter | |
| `TRACK_HIST` | record the witnesses (the `witness_*` configurations) | the `hist` flags never change, which keeps otherwise identical states apart no longer |

## Properties

| Property | Meaning |
|---|---|
| `NoUAF` | no access to an object whose slab page was released |
| `NoStale` | no reference is used on an object that was freed or recycled under it |
| `Ledger` | a live file that is not saturated has references - 1 in its counter, NOREF included |
| `DeadMeansNoRefs` | a file in the dead zone, on the free list or gone has no reference |
| `OwedRelease` | a put that returned true owes exactly one `__fput()` of a live file nobody references; no two tasks owe the same one |
| `RightFile` | a lookup that returned a file holds a reference on the incarnation its slot named |
| `NoWarn` | "imbalanced put on file reference count", "file_ref_inc() on a released file reference" and "VFS: Close: file count is 0" never fire |
| `FinalClean` | when every task is done every file has been freed |
| `Terminates` | every task finishes (liveness, the `*_live` configurations) |
| `NoResurrect`, `NoRecycledGet`, `NoCasLost`, `NoSameSlot`, `NoGetFail`, `NoPutCloseFallback`, `NoEpiFail` | witnesses, expected to fail: a get brought NOREF back; a get succeeded on a recycled file; the NOREF to DEAD cmpxchg lost to a get/put pair; the recheck passed on a recycled file in the same slot; a get failed; `file_ref_put_close()` fell back; `epi_fget()` found the file dead |

## Running

    ./gen-cfgs.py            # writes the 25 .cfg files
    ./check.sh fixed 8       # one configuration, 8 workers, logs/fixed.log
    ./check-all.sh 8         # all of them, logs/summary.txt
    ./extract-trace.sh logs/no_recheck.log

`check.sh` takes `TLA2TOOLS` (default `./tla2tools.jar`), `TLC_HEAP`
(default 6g), `TLC_METADIR`.  The whole suite takes a few minutes on a
laptop; the configurations that switch a protection off stop at their
counterexample within seconds.

## Layouts

The default layout is the owner, two lookups with two rounds each, one
holder with one `get_file()`, one object and two slots, two open(2) and
one dup2(2): every open(2) recycles the file that was closed, into the
same slot or the other one.  `fixed_two` and `no_recheck_two` have a
second object and one lookup, so that a slot can also get a different
file.  `fixed_epoll` has one lookup and one epoll task with two
attempts; the `*_live` configurations one lookup with one round and one
open(2); `zone_*` no holder and no open(2) with a 4- or 5-bit counter;
`saturation_*` a 5-bit counter and a holder with 15 or 16 `get_file()`
calls.

Per-task registers are cleared when a task returns to idle and the
witness flags only change with `TRACK_HIST`; without that the default
layout had more than 100 million states, with it 2.3 million.

## Results

Local runs, 2026-11-04, TLC 2.19 with 6 workers and a 4g heap; every
configuration as expected (`RESULTS.txt`, the counterexamples in
`traces/`).

| Configuration | Result | States | Meaning |
|---|---|---|---|
| `fixed`, `fixed_close` | pass | 2.35M, 2.33M | with every protection in place: no access to a released page, no reference used on a freed or recycled file, the counter is the references minus one, a put returns true once per incarnation and only with no reference left, the lookup returns the file its descriptor named, no warning fires, nothing leaks; close(2) through `__fput_sync()` and through `fput_close_sync()` |
| `fixed_two` | pass | 340k | the same with a second object, so a slot can get a different file |
| `fixed_epoll` | pass | 342k | the same with `epi_fget()` under `ep->mtx` |
| `fixed_live`, `fixed_live_close` | pass | 2.0k, 2.1k | plus `Terminates`: every task finishes |
| `no_preempt_guard`, `no_preempt_guard_close` | `NoUAF` | 99k, 123k | rcuref's deconstruction race: the holder's decrement reaches NOREF, a lookup resurrects the file and drops it again, marks it DEAD and frees it, the grace period ends with nobody inside a read-side section and the slab page goes; the holder's slow path then does its cmpxchg on it |
| `no_get_rcu` | `NoUAF` | 22k | the lookup loaded the pointer before close(2); the file is put, freed and its page released before the increment lands |
| `no_pass_cnt` | `NoWarn` | 33k | race 1 of 08ef26ea9ab3: the holder's decrement reaches NOREF, a lookup resurrects the file, its recheck fails, its put marks the file DEAD; the holder's slow path re-reads DEAD and warns "imbalanced put" for a balanced one |
| `get_slowpath` | `Ledger` | 46k | race 2 of 08ef26ea9ab3: a lookup's increment lands on a DEAD file, the v2 slow path reads the dead-zone value, meanwhile the file is freed, recycled and its counter set to ONEREF for the new owner, and the slow path either parks it on DEAD or returns true for a reference it does not hold |
| `no_cmpxchg_dead`, `no_cmpxchg_dead_close` | `OwedRelease` | 9.6k, 16k | a plain store of DEAD overwrites a lookup's resurrection: the file is freed with a reference on it |
| `no_dead_mark` | `NoStale` | 17k | freeing at NOREF without marking: a later get succeeds on the freed file |
| `no_recheck`, `no_recheck_two` | `RightFile` | 27k, 11k | the file is closed, freed and recycled by open(2); the lookup's increment lands on the new incarnation and it is returned for a descriptor that never named it |
| `zone_escape` | `OwedRelease` | 964 | 4-bit counter, DEAD + 1 = NOREF: two lookups that loaded the pointer before close(2) fail their gets after the DEAD transition, the second failure makes NOREF, the next get resurrects a file whose `__fput()` is owed |
| `zone_ok` | pass | 1.4k | 5-bit counter, DEAD + 3 = NOREF: the same two lookups cannot escape |
| `saturation_get` | `Ledger` | 6.6k | 5-bit counter: 16 references, a failed get at MAXREF wraps the counter to MIN, the next put wraps it back to MAXREF one too high: the file leaks, silently |
| `saturation_inc` | `NoWarn` | 1.1k | 5-bit counter: the second `get_file()` past MAXREF warns, the puts park the counter on SATURATED and the file leaks |
| `witness_resurrect`, `witness_recycled_get`, `witness_cas_lost`, `witness_same_slot`, `witness_get_fail`, `witness_pc_fallback`, `witness_epi_fail` | fire | 127 to 47k | a get brings NOREF back; a get succeeds on a recycled file; the NOREF to DEAD cmpxchg loses to a get/put pair; the recheck passes on a recycled file in the same slot; a get fails; `file_ref_put_close()` falls back; `epi_fget()` finds the file dead: the green runs cover all of these |

A note on TLA+: `uaf' = uaf \/ X` parses as `(uaf' = uaf) \/ X` and leaves
`uaf'` unassigned when `X` holds; the three use-after-free configurations
ran into that before the disjunctions were parenthesised.

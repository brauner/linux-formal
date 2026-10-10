# CBMC harness for the unborn-wait device table cursor

Tree: `vfs/work.super.fixes.core.claims` @ **587d78169911**, `fs/super.c`.
The cursor is eca07e8969d8 ("super: don't act on superblocks that dropped
their device claim"): the unborn-wait `super_dev_get()`
(work.super.fixes.core.claims, rejected in favour of the sd_claims fix).  It
was not merged; the sd_claims fix was kept instead and is not modelled here.

`devtable.c` is a copy of the device table harness written for the review of
work.super.fixes (fc1c25014ff8), extended with SB_BORN and the unborn-wait
cursor.  The rest of the table code it copies (`super_dev_alloc()`,
`super_dev_put()`, `super_dev_insert()`, `super_dev_register()`,
`kill_super_notify()`, `super_dev_lookup()`, `fs_bdev_register()`,
`fs_bdev_unregister()`, `user_get_super()`, `put_super()`) is the same at
fc1c25014ff8 and 587d78169911.

CBMC 6.6.0 (`~/opt/fv`), CaDiCaL backend, every run under
`systemd-run --user --scope -p MemoryMax=6G`, one at a time (`run.sh`).

| file | what |
|---|---|
| `devtable.c` | the harness: copied `fs/super.c` table code, stubs, ghost state, step loop |
| `run.sh` | configurations and the exact cbmc command lines (`./run.sh -l`) |
| `trace_ops.py` | condenses a `--trace` log into the step sequence |
| `results/` | one log per run, `<config>.<property>.log` |

## The switch

| `CFG_UNBORN_WAIT` | cursor |
|---|---|
| 1 (default) | eca07e8969d8: a row of a superblock that is born or dying is pinned (`refcount_inc_not_zero(&sd_ref)`); for a row of an unborn superblock the cursor takes a passive reference (`refcount_inc_not_zero(&s_passive)`), sleeps in `wait_var_event()` until SB_BORN or SB_DYING, drops the reference and looks again from `@prev` (still pinned) or from the head of the chain |
| 0 | fc1c25014ff8: the first row with `sd_ref > 0` is pinned whatever its superblock's state; the walker waits for SB_BORN in `super_lock()`/`get_active_super()` with the pin held |

## What the copy adds to the model

- SB_BORN: an `OP_BORN` step is `vfs_get_tree()`'s `super_wake(sb, SB_BORN)`
  once `fill_super()` returned (no register/unregister of that superblock
  in flight).  The filesystem registers and unregisters devices before it
  (`btrfs_open_devices()`, `btrfs_free_extra_devids()`, the `-EBUSY`
  rollback in `fs_bdev_register()`, error paths) and after it.
- `user_get_super()`'s `super_lock()` (`OP_CUR_TAKE`) needs SB_BORN and not
  SB_DYING.
- The cursor's sleep is a resume point.  `super_dev_get()` leaves its step
  holding the passive reference (`cursor_wait[]`) and, called from
  `super_dev_next()`, the pin on `@prev` (`cursor_prev[]`).  An
  `OP_CUR_WAKE` step resumes it once that superblock has SB_BORN or
  SB_DYING: `put_super()`, look again, then `super_dev_next()`'s
  `super_dev_put(prev)`.  Everything else (the filesystem's unregister,
  SB_BORN, the kill, other walks' puts) interleaves with the sleep.
- Ghost `unborn_drop[sb][dev]`: the pair's last claim (fs_bdev claims,
  `sget_fc()`'s, a row inserted by a `fs_bdev_register()` that has not passed
  its `bd_fsfreeze_count` test yet) went away while the superblock was
  neither born nor dying, and the pair has not claimed the device since.

## Properties added

Checked after every step unless noted.  Ids are the CBMC property names.

| id | property |
|---|---|
| `check_pin.assertion.1` | a pinned row (the cursor's, or a sleeping `super_dev_next()`'s `@prev`) is allocated, linked and has `sd_ref > 0` |
| `check_pin.assertion.2` | no cursor pins the row of a born, not dying superblock whose pair dropped its last claim before SB_BORN.  The walkers act on a pinned row's superblock as soon as `super_lock()`/`get_active_super()` succeeds, which needs exactly that, so this is "the walk acts on a superblock that no longer uses the device" |
| `check_pin.assertion.3` | (`CFG_UNBORN_WAIT=1` only) no cursor pins the row of a superblock that is neither born nor dying |
| `check_invariants.assertion.5` | `s_passive == base + rows + user_get_super() refs + sleeping cursors` |
| `check_invariants.assertion.6` | a freed superblock has no passive refs, rows or sleeping cursors |
| `put_super.assertion.3` | no superblock is freed under a sleeping cursor's passive reference (at the put) |
| `super_flags.assertion.1` | `super_flags()` never reads a freed superblock (at the read) |
| `super_dev_get.assertion.1` | a cursor resumes only after SB_BORN or SB_DYING (at the resume) |
| `super_dev_get.assertion.2` | `super_dev_get()` walks on only from a pinned, linked `@prev` (at the walk) |
| `main.assertion.3`..`7` with `CHECK_REACH=1` | reach probes, each must FAIL: `super_dev_first()` resumes after the unborn superblock dropped its claim; `super_dev_next()` does; `super_dev_next()` resumes and pins a later row; the resumed cursor drops the superblock's last passive reference; the resumed cursor sleeps again |

The claims invariant (`check_invariants.assertion.7`, refs of a pair's rows
== claims + pins + pending registers) counts a sleeping `super_dev_next()`'s
`@prev` as a pin.  The other properties are the ones of the harness it was
copied from: no `refcount_inc()` on 0, no `refcount_dec_and_test()` below 0,
rows drop their passive reference once, no superblock freed while a row or a
`user_get_super()` reference points to it, `fs_bdev_unregister()` finds the
claimed row, and in a quiescent end state the table is empty, every row is
freed and every released superblock has `s_passive == 0`.

## Results

CBMC 6.6.0, CaDiCaL, `--unwinding-assertions --bounds-check`, `NDEV=2`,
step loop bound NSTEPS+1, one property per run (`--property`), sliced
(`--slice-formula`) except the traced counterexample.  "PASS" = no
counterexample within the bound.  Logs: `results/<config>.<property>.log`.

| config | `CFG_UNBORN_WAIT` | steps | property | result | wall |
|---|---|---|---|---|---|
| devtable-pin | 0 | 8 | `check_pin.assertion.2` walk acts on a superblock that dropped its claim before SB_BORN | **FAIL** (trace below) | 11 s (unsliced) |
| devtable-wait | 1 | 8 | `check_pin.assertion.2` walk acts on a superblock that dropped its claim before SB_BORN | PASS | 261 s |
| devtable-wait | 1 | 8 | `check_pin.assertion.3` pins only rows of born or dying superblocks | PASS | 111 s |
| devtable-wait | 1 | 8 | `check_pin.assertion.1` pinned row allocated, linked, `sd_ref > 0` | PASS | 468 s |
| devtable-wait | 1 | 8 | `check_invariants.assertion.5` `s_passive` ledger incl. sleeping cursors | PASS | 791 s |
| devtable-wait | 1 | 8 | `check_invariants.assertion.6` freed superblock unreferenced | PASS | 207 s |
| devtable-wait | 1 | 8 | `put_super.assertion.3` no free under a sleeping cursor's reference | PASS | 154 s |
| devtable-wait | 1 | 8 | `super_flags.assertion.1` no read of a freed superblock | PASS | 218 s |
| devtable-wait | 1 | 8 | `super_dev_get.assertion.2` walks on only from a pinned `@prev` | PASS | 89 s |
| devtable-wait | 1 | 8 | `super_dev_get.assertion.1` resumes only after SB_BORN/SB_DYING | PASS | 12 s |
| devtable-wait | 1 | 8 | `main.assertion.3` quiescent: table empty | PASS | 59 s |
| devtable-wait | 1 | 8 | `main.assertion.4` quiescent: rows freed | PASS | 56 s |
| devtable-wait | 1 | 8 | `main.assertion.5` quiescent: superblocks freed | PASS | 112 s |
| devtable-wait | 1 | 8 | `refcount_dec_and_test.assertion.1` no underflow (`sd_ref`, `s_passive`) | PASS | 462 s |
| devtable-wait-reach | 1 | 10 | `main.assertion.3` reach: `super_dev_first()` resumes after the claim drop | FAIL = reachable | 19 s |
| devtable-wait-reach | 1 | 10 | `main.assertion.4` reach: `super_dev_next()` resumes after the claim drop | FAIL = reachable | 65 s |
| devtable-wait-reach | 1 | 10 | `main.assertion.5` reach: `super_dev_next()` resumes and pins a later row | FAIL = reachable | 35 s |
| devtable-wait-reach | 1 | 10 | `main.assertion.6` reach: the resumed cursor drops the last passive ref | FAIL = reachable | 20 s |
| devtable-wait-reach | 1 | 10 | `main.assertion.7` reach: the resumed cursor sleeps again | FAIL = reachable | 21 s |

Counterexample with `CFG_UNBORN_WAIT=0` (`trace_ops.py`, condensed):

    0 SGET_SET       S0 set() on dev 1: row E0
    1 REGISTER       S0 claims dev 2: row E2 inserted, bd_fsfreeze_count test pending
    2 CUR_FIRST      walk on dev 2 pins E2 (sd_ref 2) while S0 is unborn
    3 SGET_SET       S1 set() on dev 2 (filler)
    4 REGISTER       S1 claims dev 1, -ENOMEM (filler)
    5 REGISTER_STEP  S0/dev 2: bd_fsfreeze_count > 0, -EBUSY, super_dev_put(E2):
                     sd_ref 1, E2 stays linked, S0 no longer claims dev 2
    6 BORN           S0 gets SB_BORN with E2 still pinned: the walk acts on S0

This is the `-o degraded` case of eca07e8969d8's commit message: a thaw
walk pins the new row between the insertion and the rollback and then
thaws a superblock that was never frozen.  With `CFG_UNBORN_WAIT=1` step 2
sleeps on S0 instead of pinning, the rollback unlinks E2, and the resumed
walk doesn't find it.

No counterexample with `CFG_UNBORN_WAIT=1`.

## Reproduce

    ./run.sh -l                                        # configurations
    PROP=check_pin.assertion.2 ./run.sh devtable-pin   # the fc1c25014ff8 counterexample
    python3 trace_ops.py devtable results/devtable-pin.check_pin.assertion.2.log
    SLICE=1 PROP=check_pin.assertion.2 ./run.sh devtable-wait

`run.sh` writes `results/<config>.<property>.log`; the first line of every
log is the exact cbmc command.  The runs above were, each under
`systemd-run --user --scope -q -p MemoryMax=6G -- timeout 1200`
(`CBMC="env LD_LIBRARY_PATH=$HOME/opt/fv/usr/lib $HOME/opt/fv/usr/bin/cbmc"`):

    # devtable-pin, the counterexample (unsliced so the trace keeps log_op[])
    $CBMC devtable.c -DNSTEPS=8 -DNDEV=2 -DCFG_UNBORN_WAIT=0 --unwind 9 \
        --unwinding-assertions --bounds-check --sat-solver cadical \
        --trace --property check_pin.assertion.2
    # devtable-wait, one run per property id in the table
    $CBMC devtable.c -DNSTEPS=8 -DNDEV=2 --unwind 9 \
        --unwinding-assertions --bounds-check --sat-solver cadical \
        --trace --property <id> --slice-formula
    # devtable-wait-reach, main.assertion.3 .. main.assertion.7
    $CBMC devtable.c -DNSTEPS=10 -DNDEV=2 -DCHECK_REACH=1 --unwind 11 \
        --unwinding-assertions --bounds-check --sat-solver cadical \
        --trace --property main.assertion.<n> --slice-formula

## Limits

- One cursor (`NCUR=1`), two superblocks, two devices, five rows.
- SB_DYING and `kill_super_notify()` are one step (`OP_KILL_NOTIFY`), so a
  cursor cannot wake between them; the filesystem's own unregisters can
  still run after that step.
- `bdev_deny_freeze()` is not modelled.  Claims dropped after SB_BORN are
  not flagged: `check_pin.assertion.2` is about claims dropped before
  SB_BORN only.
- Steps are atomic and sequentially consistent.  The release/acquire pair
  of `super_wake()`/`super_flags()` that orders the mount's unlink before
  the woken cursor's second look is assumed, not checked.
- Not run: `devtable-wait-n10` (`check_pin.assertion.2` at 10 steps).  A
  `super_dev_next()` that resumes after the claim drop needs 9 steps (S1
  claims dev 2, S0 set() on dev 2, SB_BORN on S0, first, next sleeps on S1,
  the drop, SB_BORN on S1, wake), so the 8-step property runs don't cover
  it; only the reach probe at 10 steps shows it happening.
- Not run with `CFG_UNBORN_WAIT=1`: `check_invariants.assertion.7` (the claims
  invariant; no result in 900 s at 8 steps in the harness this is a copy
  of), `refcount_inc.assertion.1`, `put_super.assertion.1`/`2`,
  `main.assertion.2`, `check_invariants.assertion.1`..`4`,
  `super_dev_get.assertion.3` and the local assertions of `kfree()`,
  `rhltable_insert()`/`rhltable_remove()`, `super_dev_put()`,
  `super_dev_put_finish()`, `super_dev_register()`, `super_dev_lookup()`
  and `kill_super_notify()`.  With `CFG_UNBORN_WAIT=0`
  only `check_pin.assertion.2` was run.

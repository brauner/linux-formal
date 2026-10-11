# TLA+ model of the device table as a hashtable

Tree: work.super.dev_hash at de417b144a46, on 587d78169911
(work.super.fixes.core.claims) on fc1c25014ff8 (v7.3-rc6-301). Line
numbers below are fs/super.c and block/bdev.c at de417b144a46.

`SuperDevHash.tla` is a new module, not a copy with switches: the table
mechanics of [`kernel/super/unborn-wait/tla/`](../../unborn-wait/tla/README.md)
(rhltable, RCU readers, pins, kfree_rcu()) are gone on this branch. The
filesystem task, the freezers, user_get_super() and the second
registrations are the programs of that model; the layouts are its layouts
plus two with an erofs blob shared by two superblocks.

## The branch

"super: turn the device table into a plain hashtable" replaces the rhltable
with `DEFINE_HASHTABLE(super_dev_hash, SUPER_DEV_HASH_BITS)` under
`super_dev_lock`; every lookup takes the lock. The walks of the
fs_holder_ops callbacks and user_get_super() keep their place with a
cursor, a `struct super_dev` without a superblock on the walker's stack,
that sits right behind the last claim the walk returned. Entries are
unhashed and freed the moment their last claim goes. fs_bdev_register()
checks bd_fsfreeze_count under the lock before it hashes a new claim.
"super: embed the superblock's claim on s_dev" embeds the entry for s_dev
in struct super_block and hashes it from sget_fc().

## Abstractions

* Every access to the table happens under super_dev_lock and nothing in a
  locked section sleeps, so each locked section is one step. The model is
  sequentially consistent; the orderings the branch relies on are lock
  orderings (super_dev_lock against bdev_freeze() raising the count before
  its walk takes the lock) and SB_BORN/SB_DYING's release/acquire pair.
* The hash is one chain per device. Lookups and walks skip the entries of
  other devices and hash_add()/hash_del() never move an entry, so the other
  devices' entries in a bucket change nothing. hash_add() adds at the head.
* A cursor is a node of the chain that is not an entry (`CurOf[p]`).

| Action | Kernel |
|--------|--------|
| `W0` | the walker's `struct super_dev cursor = { .sd_dev = dev }` |
| `W1` | super_dev_next() L472 under super_dev_lock L481-501: hash_add() of the cursor on the first call L484, the first claim behind the cursor L485-489 or, none, hash_del() of the cursor L490-493; refcount_inc(&sb->s_passive) L496; SB_BORN or SB_DYING: hash_del() + hlist_add_behind() of the cursor L497-499 and return the superblock |
| `WW` | wait_var_event() for SB_BORN \| SB_DYING L503, put_super() L504, look again from the cursor |
| `W3` | the body of for_each_dev_super() L515 (get_active_super() of fs_bdev_freeze() L1522 / fs_bdev_thaw() L1576, super_lock() of user_get_super() L1016) or the end of the walk |
| `WN` | the next super_dev_next(): put_super(prev) L478 |
| `C_end` | super_dev_walk_end() L509 when user_get_super() returns |
| `R0` | fs_bdev_register() L1630: kzalloc_obj() L1635 outside the lock |
| `R1` | under super_dev_lock L1637: super_dev_find() L1638, another claim of a hashed pair L1640, else the frozen check L1644 and super_dev_add() L1648 |
| `U1`, `U2` | fs_bdev_unregister() L1731: super_dev_find() under the lock L1736, then super_dev_put() L1739 |
| `P1`, `P2` | super_dev_put() L453: the claim dropped and the last one hash_del()ed under the lock L458-462; kfree() unless embedded and put_super() L463-465 |
| `fs_hash` | sget_fc() L873-874: super_dev_add(&s->s_super_dev) |
| `fs_bdevchk` | setup_bdev_super() L1783: the frozen check of the main device |
| `fs_notify` | kill_super_notify() L527: super_dev_put(&sb->s_super_dev) |

Every other action (`fs_*`, `F_*`, `T_*`, `C_*`, `D_*`) is the program of
the earlier models. `T_end` takes a thaw that finds a superblock unfrozen
as success (587d78169911's "fs: don't keep a device frozen when its freeze
is already gone") and flags it instead, since no task in the model drops a
freeze behind the device's back.

## Files

| File | What it is |
|------|------------|
| `SuperDevHash.tla` | the model |
| `MC_dt*.tla`, `dt*.cfg` | the layouts and TLC configurations, generated; `<layout>_<what>.cfg` runs `MC_<layout>.tla`, the header line says what to expect |
| `gen-cfgs.py` | writes the two above |
| `check.sh` | run one configuration (deadlock checking on) |
| `run-parallel.sh`, `summarize.sh` | run them all on a big machine, summarize `logs/` into `logs/summary.txt` |
| `RESULTS.txt` | that summary for the run below |
| `show-trace.py` | print a counterexample compactly |
| `traces/*.txt` | every counterexample of the table below, printed by `show-trace.py` |

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar          # or the tla2tools.jar symlink here
    ./check.sh dtdrop_tree 4
    MAXJOBS=10 ./run-parallel.sh 16 16g              # everything, on a big machine
    ./show-trace.py logs/dtwalk_no_cursor.log

Everything finishes in under half a minute.

## Switches

| Constant | Meaning |
|----------|---------|
| `FsCfg[s]` | per superblock: `main` device, member device `xdev` registered during the mount (`xmode "mount"`) or on the live superblock (`"live"`), `onfail` (`"fail"`/`"degraded"`), `dropx` (`"early"`: released before SB_BORN, `"live"`: removed from the live superblock), `umount`, `mayfail` |
| `Freezers`, `Cursors`, `Dups` | the bdev_freeze()/bdev_thaw() tasks per device, the user_get_super() tasks per device, the second registrations |
| `EmbOf`, `Alloc`, `CurOf` | the ids of the embedded entries, of the entries fs_bdev_register() can allocate, of the walkers' cursors |
| `FIX_RELOOK` | off: the walk commits to the claim of a superblock that is not born yet and waits for SB_BORN after that (the fc1c25014ff8 shape without the pin) |
| `FIX_CURSOR` | off: no cursor; the walk resumes behind the entry it returned last, which nothing keeps hashed |
| `FIX_CHECK_LOCKED` | off: fs_bdev_register() reads bd_fsfreeze_count before it takes super_dev_lock |
| `FIX_ATOMIC_CLAIM` | off: fs_bdev_register() drops the lock between the lookup and the insert |
| `FIX_DENY` | off: btrfs device add/remove without bdev_deny_freeze() |

## Invariants

* `NoErr`: the actions' checks. The walk returns every claim that stays
  hashed through it and no superblock twice; it never resumes behind an
  entry that is gone; no hashed claim belongs to a freed superblock;
  fs_bdev_unregister() finds its claim; super_dev_put() only puts hashed
  entries; the freeze balance: after bdev_thaw() no freeze taken through
  the device is left, no thaw takes another device's freeze and no thaw
  walk reaches a superblock it did not freeze.
* `ChainOK`: a chain holds each node once, exactly the hashed entries of
  its device and the cursors of walks on it.
* `UniquePair`: one entry per (device, superblock).
* `ClaimsOK`: an entry is hashed exactly while it has claims.
* `PassLedger`: s_passive is alloc_super()'s reference, one per entry and
  one per walk holding the superblock.
* `EntryKeepsSb`, `NoFreedReach`: entries keep their superblock; what a
  task holds outside the lock is alive.
* `FrozenCovers`: while a freezer has the device frozen, every live
  superblock using it is frozen.
* `NoLeak`: at the end, unmounted superblocks and their entries are freed
  and no cursor is left in a chain.

`NoUnbornWait` and `NoCursorCrossed` are witnesses, expected to be
violated: a walk waits for an unborn superblock, and a claim the cursor
sits right behind is dropped while the walk sleeps, so both paths are
reachable in those layouts.

## Layouts

The fifteen layouts of the earlier models (`dtbase`, `dtshare`,
`dtsharefz`, `dtdeg`, `dtdrop`, `dtlive`, `dtdegc`, `dtdropc`, `dtmulti`,
`dtmultideg`, `dtwalk`, `dtdropfz`, `dtdegfz`, `dtdup`, `dtreadd`; their
descriptions are in `gen-cfgs.py` and the header of each `MC_*.tla`) and
two for erofs:

| Layout | What |
|--------|------|
| `dtblob` | s1 on d1 and s2 on d2 both claim the blob d3 during the mount, both unmounted, s2's mount may fail; a freezer on d3 |
| `dtblobc` | as `dtblob` with both mounts succeeding; a freezer and a user_get_super() cursor on d3 |

## Results (jens, 2026-10-11)

    config                         expected   result     states       time
    dtbase_tree                    pass       pass       17586        01s
    dtblob_tree                    pass       pass       128176       02s
    dtblobc_tree                   pass       pass       3177641      23s
    dtdeg_tree                     pass       pass       304          00s
    dtdegc_tree                    pass       pass       48020        01s
    dtdegfz_tree                   pass       pass       22352        01s
    dtdrop_tree                    pass       pass       513          00s
    dtdropc_tree                   pass       pass       26048        01s
    dtdropfz_tree                  pass       pass       29210        01s
    dtdup_tree                     pass       pass       239          00s
    dtlive_tree                    pass       pass       757          00s
    dtmulti_tree                   pass       pass       12618        01s
    dtmultideg_tree                pass       pass       7686         01s
    dtreadd_tree                   pass       pass       144          00s
    dtshare_tree                   pass       pass       3895526      27s
    dtsharefz_tree                 pass       pass       30020        01s
    dtwalk_tree                    pass       pass       2286312      16s
    dtdeg_no_relook                pass       pass       300          00s
    dtmultideg_no_relook           pass       pass       7322         01s
    dtdrop_no_relook               violation  violation  553          00s
    dtdropfz_no_relook             violation  violation  16779        01s
    dtwalk_no_cursor               violation  violation  103615       02s
    dtblob_no_cursor               violation  violation  12488        01s
    dtsharefz_no_check_locked      violation  violation  3214         00s
    dtdeg_no_check_locked          violation  violation  338          00s
    dtdup_no_atomic_claim          violation  violation  121          00s
    dtlive_no_deny                 violation  violation  928          00s
    dtdrop_reachwait               violation  violation  262          00s
    dtwalk_reachcross              violation  violation  28138        01s
    dtblob_reachcross              violation  violation  5187         01s

* Every layout passes with the branch's code, the btrfs drop and rollback
  layouts and the two erofs blob layouts among them.
* `dtdup_tree` passes. The rhltable models flag it (two concurrent
  registrations of one pair insert two entries); here the lookup and the
  insert happen under one hold of the lock, and `dtdup_no_atomic_claim`
  shows the duplicate as soon as the lock is dropped in between.
* The second look after the wait for an unborn superblock is needed for
  claims dropped during the mount (`dtdrop_no_relook`,
  `dtdropfz_no_relook`) but not for refused ones
  (`dtdeg_no_relook`, `dtmultideg_no_relook` pass): a refused claim is
  never hashed, so no walk can come across it. On the rhltable a refused
  claim was briefly visible (`dtdeg_no_unborn_wait` there).
* Without the cursor a walk resumes behind an entry an unmount dropped
  while it slept (`dtwalk_no_cursor`, `dtblob_no_cursor`); the witnesses
  show that the cursor does get crossed like that.
* The frozen check needs the lock (`dtsharefz_no_check_locked`,
  `dtdeg_no_check_locked`): a claim that reads the count before the lock
  and hashes after the freeze walk uses a frozen device unfrozen.
* `dtlive_no_deny`: a claim dropped from a live superblock outside
  bdev_deny_freeze() still breaks the freeze balance; the cursor doesn't
  change that.

## Not modelled

The memory model is sequentially consistent. mark_dead and sync walk the
table like user_get_super() does and are not modelled separately. The
cursor of a walk that returns early is deleted by super_dev_walk_end(); only
user_get_super() returns early.

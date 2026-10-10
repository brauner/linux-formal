# TLA+ model of the device table with the unborn-wait cursor

Tree: work.super.fixes.core.claims at 587d78169911, on fc1c25014ff8
(v7.3-rc6-301). Line numbers below are fs/super.c at 587d78169911.

`SuperDevTable.tla` is a copy of the device table model written for the
review of work.super.fixes at fc1c25014ff8, with the cursor of this branch
behind `FIX_UNBORN_WAIT`. With the switch off the model is the
fc1c25014ff8 code. The table entries, the claims of filesystems, the
freezers and user_get_super() are modelled exactly as there. Only the
cursor (super_dev_first(), super_dev_get(), super_dev_next()) is new.

## The problem the branch addresses

sd_ref of a struct super_dev counts the claims of the superblock on the
device and the pins of the table cursors. An entry is unlinked only once
its count hits zero ("Unlink only once unpinned, so a cursor never resumes
from a removed node", L468). At fc1c25014ff8 the cursor pins an entry and
the fs_holder_ops walks then wait for SB_BORN with the pin held. A claim
dropped while the superblock is still being set up therefore leaves the
entry linked and the walk acts on a superblock that no longer uses the
device:

* btrfs_free_extra_devids() releases a stale member during open_ctree()
  while a freeze walk sleeps on the pinned entry. The walk freezes btrfs
  through that device and the matching bdev_thaw() never finds a holder
  (`dtdrop_no_unborn_wait`).
* fs_bdev_register() rolls back the entry of a frozen member and btrfs
  mounts with -o degraded while a thaw walk sleeps on it. The walk thaws a
  superblock that was never frozen and bd_fsfreeze_count stays up
  (`dtdeg_no_unborn_wait`).

## The cursor of this branch

super_dev_get() (L516) never pins the entry of a superblock that is
neither SB_BORN nor SB_DYING. It takes a passive reference to the
superblock instead, waits for it without a pin and looks again from where
the walk stands: the head of the device's list for super_dev_first() or
prev's `->next` for super_dev_next(), prev still pinned. No cursor pins the
entry of a superblock being set up, so the last claim dropped during the
mount unlinks the entry at once and the walk does not find it again. The
ordering is SB_BORN/SB_DYING's release in super_wake() against the acquire
in super_flags(); the model is sequentially consistent and takes that as
given.

| Action | Kernel |
|--------|--------|
| `W0` | super_dev_first() L552 -> super_dev_get(dev, NULL): scoped_guard(rcu) L524, rhltable_lookup() L528 |
| `W1` | the loop of super_dev_get(): super_flags(sb, SB_BORN \| SB_DYING) L533, refcount_inc_not_zero(&sd_ref) L534 (pin) or, for an unborn superblock, refcount_inc_not_zero(&sb->s_passive) L536 and leave the read section; `->next` otherwise |
| `WW` | wait_var_event() for SB_BORN \| SB_DYING L543, put_super() L545, look again from the head or from prev's `->next` L526 |
| `W2` | super_dev_next() L557: super_dev_put(prev) L561 once the next entry is pinned |
| `W3` | the walk's loop body (get_active_super() of fs_bdev_freeze()/fs_bdev_thaw(), super_lock() of user_get_super()) or the end of the walk |
| `WN`, `WN2` | super_dev_next(): prev->sd_node.next under RCU (`FIX_NEXT_PIN` off: prev put first) |

Every other action (`fs_*`, `R*`, `U*`, `P*`, `F_*`, `T_*`, `C_*`, `D_*`)
is the fc1c25014ff8 model unchanged; their kernel lines refer to
fs/super.c at fc1c25014ff8, where only the cursor differs from this
branch.

## Files

| File | What it is |
|------|------------|
| `SuperDevTable.tla` | the model |
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
    MAXJOBS=12 ./run-parallel.sh 24 16g              # everything, on a big machine
    ./show-trace.py logs/dtdrop_no_unborn_wait.log

Everything but `dtshare_tree` (56M states) and `dtwalk_tree` (14M)
finishes in seconds.

## Switches

| Constant | Meaning |
|----------|---------|
| `FsCfg[s]` | per superblock: `main` device, member device `xdev` registered during the mount (`xmode "mount"`) or on the live superblock (`"live"`), `onfail` (`"fail"`/`"degraded"`), `dropx` (`"early"`: released before SB_BORN, `"live"`: removed from the live superblock), `umount`, `mayfail` |
| `Freezers`, `Cursors`, `Dups` | the bdev_freeze()/bdev_thaw() tasks per device, the user_get_super() tasks per device, the second registrations |
| `FIX_UNBORN_WAIT` | on: the cursor of this branch; off: the fc1c25014ff8 cursor, which pins the entry and waits for SB_BORN with the pin held |
| `FIX_RCU_FREE` | off: super_dev_put() frees with kfree() right at removal |
| `FIX_NEXT_PIN` | off: super_dev_next() drops prev before it reads prev->sd_node.next |
| `FIX_PUBLISH_FIRST` | off: fs_bdev_register() reads bd_fsfreeze_count before it inserts |
| `FIX_DENY` | off: btrfs device add/remove without bdev_deny_freeze() |
| `FIX_FIRST_MATCH` | off: super_dev_lookup() returns the last (dev, sb) match |

## Invariants

The invariants of the fc1c25014ff8 model, `NoErr` (refcount and RCU
defects, the walk's coverage, and the freeze balance: after bdev_thaw()
the device is thawed, no freeze taken through it is left and no thaw took
another device's freeze), `ListOK`, `RefLinked`, `NoFreedReach`,
`EntryKeepsSb`, `FrozenCovers`, `NoLeak`, with two changes for the cursor:

* `NoErr` also flags a cursor that pins the entry of an unborn superblock
  with `FIX_UNBORN_WAIT` on, and a read of prev's `->next` after the wait
  when prev is freed or no longer linked.
* `PassLedger` counts the passive reference of every walk waiting for a
  superblock.

`NoUnbornWait` and `NoUnbornWaitFromPrev` are witnesses, expected to be
violated: a walk waits for an unborn superblock, and does so with prev
pinned, so the wait and the second look from prev are reachable in those
layouts.

## Layouts

The thirteen layouts of the fc1c25014ff8 model (`dtbase`, `dtshare`,
`dtsharefz`, `dtdeg`, `dtdrop`, `dtlive`, `dtdegc`, `dtdropc`, `dtmulti`,
`dtmultideg`, `dtwalk`, `dtdup`, `dtreadd`; their descriptions are in
`gen-cfgs.py` and the header of each `MC_*.tla`) and two for the cursor's
second look from prev:

| Layout | What |
|--------|------|
| `dtdropfz` | s1 on d1 with member d2 accepted and released before SB_BORN, s2 on d2, nobody unmounts; a freezer on d2. The walk can pin s2's entry and then come across unborn s1 |
| `dtdegfz` | as `dtdropfz` with d2 refused and the mount going on (btrfs -o degraded) |

## Results (jens, 2026-10-10)

    config                         expected   result     states       time
    dtbase_tree                    pass       pass       21872        01s
    dtdeg_tree                     pass       pass       687          00s
    dtdegc_tree                    pass       pass       364114       04s
    dtdegfz_tree                   pass       pass       206725       01s
    dtdrop_tree                    pass       pass       1556         00s
    dtdropc_tree                   pass       pass       230167       02s
    dtdropfz_tree                  pass       pass       546026       05s
    dtlive_tree                    pass       pass       2103         00s
    dtmulti_tree                   pass       pass       40364        01s
    dtmultideg_tree                pass       pass       15792        01s
    dtreadd_tree                   pass       pass       501          00s
    dtshare_tree                   pass       pass       55871214     05min50s
    dtsharefz_tree                 pass       pass       473707       05s
    dtwalk_tree                    pass       pass       14226702     01min34s
    dtdeg_no_unborn_wait           violation  violation  835          00s
    dtdegfz_no_unborn_wait         violation  violation  76798        01s
    dtdrop_no_unborn_wait          violation  violation  2219         00s
    dtdropfz_no_unborn_wait        violation  violation  165377       02s
    dtmultideg_no_unborn_wait      violation  violation  10374        01s
    dtdrop_reachwait               violation  violation  326          00s
    dtdropfz_reachprev             violation  violation  44743        01s
    dtdegfz_reachprev              violation  violation  21303        01s
    dtlive_no_deny                 violation  violation  2389         00s
    dtsharefz_no_publish_first     violation  violation  13016        01s
    dtwalk_no_next_pin             violation  violation  273046       03s
    dtwalk_no_rcu_free             violation  violation  86977        01s
    dtreadd_no_first_match         violation  violation  523          00s
    dtdup_tree                     violation  violation  771          00s
    dtdup_underflow                violation  violation  1524         00s

* With the cursor of this branch every layout passes, the btrfs drop and
  rollback layouts among them, also with a second superblock sharing the
  device (`dtdropfz_tree`, `dtdegfz_tree`).
* With `FIX_UNBORN_WAIT` off the same layouts reproduce the defect: a
  freeze taken through the device outlives its thaw (`dtdrop`, `dtdeg`,
  `dtdropfz`, `dtdegfz`) or a thaw through d2 takes d1's freeze
  (`dtmultideg`).
* `dtlive_no_deny` still fails with the new cursor: a claim dropped from a
  live superblock outside bdev_deny_freeze() is not covered by the cursor
  and needs the deny.
* `dtdup_tree` and `dtdup_underflow` are the caller contract witnesses of
  the fc1c25014ff8 model (two concurrent registrations of one (device,
  superblock) pair; no in-tree caller does that) and fail as they do
  there.

## Not modelled

The memory model is sequentially consistent. mark_dead and sync walk the
table like user_get_super() does and are not modelled separately.

---------------------------- MODULE SuperHolder ----------------------------
(***************************************************************************)
(* Block device freezes and the superblocks on the device: block/bdev.c    *)
(* and fs/super.c at fc1c25014ff8.                                         *)
(*                                                                         *)
(* bdev_freeze()/bdev_thaw() (bd_fsfreeze_mutex, bd_fsfreeze_count with    *)
(* its sign-encoded denies, the holder ops looked up under                 *)
(* bd_holder_lock), fs_bdev_freeze()/fs_bdev_thaw() walking the device     *)
(* table for the device (get_active_super(), fs_super_freeze()/            *)
(* fs_super_thaw() with FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE,         *)
(* deactivate_super(), the per-superblock errors swallowed on a shared     *)
(* device, the final sync_blockdev()), bdev_deny_freeze()/                 *)
(* bdev_allow_freeze(); against them the mount of a block device           *)
(* superblock (sget_dev() publishing the device-table entry,               *)
(* setup_bdev_super() claiming the device and refusing a frozen one,       *)
(* fs_bdev_file_open_by_path() for an extra device: the entry published,   *)
(* then the same refusal, which fails the mount or, for a btrfs degraded   *)
(* mount, only drops the device),                                          *)
(* the umount (kill_block_super(): generic_shutdown_super(),               *)
(* fs_bdev_file_release() of every device, kill_super_notify()),           *)
(* device-mapper suspend/resume (lock_fs()/unlock_fs()), the shutdown      *)
(* ioctls of ext4, xfs, f2fs, exfat and ntfs3 (bdev_freeze() + bdev_thaw() *)
(* of s_bdev), FIFREEZE/FITHAW, the emergency thaw (do_thaw_all_callback():*)
(* the bdev_thaw() loop on s_bdev, then thaw_super_locked(USERSPACE)), and *)
(* a btrfs-like device add/remove under bdev_deny_freeze().                *)
(*                                                                         *)
(* A superblock's freeze state is abstracted to SB_UNFROZEN/                *)
(* SB_FREEZE_COMPLETE with freeze_kcount/freeze_ucount: freeze_super() and *)
(* thaw_super_locked() are single steps under s_umount (SuperFreeze checks *)
(* what happens inside them).  bd_holder_lock is never held across a wait  *)
(* (fs_holder_ops drop it first), so its sections are single steps.  The   *)
(* device table is the set of (device, superblock) entries; a walk sees    *)
(* the entries present when it starts (new entries are inserted at the     *)
(* head of the rhlist chain, behind any cursor) that are still present     *)
(* when it gets to them.  Memory is sequentially consistent: the           *)
(* publish-then-smp_mb()-then-read-the-count pairing of setup_bdev_super() *)
(* and fs_bdev_register() with bdev_freeze()'s atomic_inc_unless_negative()*)
(* is taken as correct (it is the store-buffering pattern with a full      *)
(* barrier on both sides).                                                 *)
(***************************************************************************)
EXTENDS Naturals, Integers, FiniteSets, TLC

CONSTANTS
    Devs, Sbs,
    Main,        \* [Sbs -> Devs]: s_dev, opened by setup_bdev_super() (holder: the sb)
    XDev,        \* [Sbs -> Devs \cup {"none"}]: an extra device opened in ->fill_super()
    After,       \* [Sbs -> Sbs \cup {"none"}]: a second superblock of the same device
                 \* mounts only once the first is dead (sget_dev() waits for SB_DEAD)
    RO,          \* [Sbs -> BOOLEAN]: read-only (freeze_super()'s shortcut cannot fail)
    XDegraded,   \* [Sbs -> BOOLEAN]: a refused extra device does not fail the mount
                 \* (btrfs open_fs_devices() goes on without it, -o degraded)
    Procs,
    Role,        \* [Procs -> {"mount", "umount", "dm", "shut", "user", "rogue", "ethaw", "add", "rm"}]
    Tgt,         \* [Procs -> Sbs \cup Devs \cup {"none"}]: the superblock, or the device for "dm"
    XTgt,        \* [Procs -> Devs \cup {"none"}]: the device of "add" and "rm"
    FREEZE_FAIL, \* a per-superblock freeze of an unfrozen read-write superblock may fail
    SYNC_FAIL,   \* sync_blockdev() at the end of bdev_freeze() may fail
    ADD_ABORT,   \* a device add may abort after publishing its claim
    FIX_SETUP_CHECK,       \* setup_bdev_super() refuses a frozen device
    FIX_REGISTER_CHECK,    \* fs_bdev_register() refuses a frozen device
    FIX_NESTED_THAW_RET,   \* fe967191e585
    FIX_THAW_ALL_UNLOCKED, \* 749d7aa0377a: no s_umount across the emergency bdev_thaw() loop
    FIX_SWALLOW,           \* 7a7ef107b449: per-superblock errors swallowed on a shared device
    FIX_DENY,              \* the btrfs add/remove deny freezing the device
    FIX_UNREGISTER_FIRST,  \* btrfs_release_device_allow_freeze(): unregister, then allow
    FIX_SYNC_ROLLBACK,     \* proposed: a sync_blockdev() failure thaws what was frozen
    FIX_THAW_EINVAL_OK     \* proposed: fs_bdev_thaw() counts a superblock that no longer
                           \* holds a userspace freeze (-EINVAL) as thawed

NoOne == "none"
\* the bdev_freeze()/bdev_thaw() callers that believe they hold a freeze
BCallers == {p \in Procs : Role[p] \in {"dm", "shut"}}
BDev(p) == IF Role[p] = "dm" THEN Tgt[p] ELSE Main[Tgt[p]]

VARIABLES
    dev,    \* [Devs -> [cnt: bd_fsfreeze_count, fm: bd_fsfreeze_mutex holder,
            \*           cl: superblocks holding a claim with fs_holder_ops]]
    tab,    \* the device table: a set of <<device, superblock>>
    sbs,    \* [Sbs -> superblock record]
    pc, pv,
    gc,     \* [Devs -> Nat]: increments of bd_fsfreeze_count whose callers have not
            \* yet returned from the bdev_thaw() that ends them (ghost)
    dn,     \* [Devs -> Nat]: denies held (ghost)
    err

vars == <<dev, tab, sbs, pc, pv, gc, dn, err>>

Hops(d) == dev[d].cl # {}     \* bd_holder_ops == &fs_holder_ops

PvInit(p) == [ret |-> "ok", dv |-> IF p \in BCallers THEN BDev(p) ELSE NoOne,
              k |-> "done", todo |-> {}, cur |-> NoOne, e |-> "ok", n |-> 0,
              froze |-> {}, it |-> {}]

StartPc(p) ==
    CASE Role[p] = "mount"  -> "m_sget"
      [] Role[p] = "umount" -> "u_go"
      [] Role[p] = "dm"     -> "d_start"
      [] Role[p] = "shut"   -> "s_start"
      [] Role[p] = "user"   -> "f_frz"
      [] Role[p] = "rogue"  -> "r_thaw"
      [] Role[p] = "ethaw"  -> "e_start"
      [] Role[p] = "add"    -> "a_deny"
      [] Role[p] = "rm"     -> "x_deny"

Init ==
    /\ dev = [d \in Devs |-> [cnt |-> 0, fm |-> NoOne, cl |-> {}]]
    /\ tab = {}
    /\ sbs = [s \in Sbs |-> [st |-> "none", um |-> NoOne, act |-> 0, mnt |-> FALSE,
                             frz |-> FALSE, kc |-> 0, uc |-> 0, mem |-> {}]]
    /\ pc = [p \in Procs |-> StartPc(p)]
    /\ pv = [p \in Procs |-> PvInit(p)]
    /\ gc = [d \in Devs |-> 0]
    /\ dn = [d \in Devs |-> 0]
    /\ err = ""

Live(s) == sbs[s].st = "born"
Gone(s) == sbs[s].st = "dead"

(* ---- the superblock ------------------------------------------------------ *)

\* the last active reference: kill_block_super() and kill_super_notify():
\* SB_DYING, every claim released (fs_bdev_file_release()), the entries
\* gone, SB_DEAD.  Taken as one step (s_umount held, then the device
\* sections, none of which waits on a freeze).
KillSb(s) ==
    /\ dev' = [d \in Devs |-> [dev[d] EXCEPT !.cl = @ \ {s}]]
    /\ tab' = {e \in tab : e[2] # s}
    /\ sbs' = [sbs EXCEPT ![s] = [@ EXCEPT !.st = "dead", !.um = NoOne, !.act = 0,
                                           !.mnt = FALSE, !.mem = {}]]
    /\ err' = IF sbs[s].frz THEN "killed a frozen superblock" ELSE err

\* freeze_super(s, who) under s_umount, as one step: [ok, new record]
Freeze(s, nest) ==
    LET r == sbs[s] IN
    IF r.frz
    THEN IF nest \/ r.uc = 0 THEN {[ok |-> "ok", r |-> [r EXCEPT !.uc = @ + 1]]}
         ELSE {[ok |-> "EBUSY", r |-> r]}
    ELSE {[ok |-> "ok", r |-> [r EXCEPT !.frz = TRUE, !.uc = 1, !.act = @ + 1]]}
         \cup (IF FREEZE_FAIL /\ ~RO[s] THEN {[ok |-> "EIO", r |-> r]} ELSE {})

\* thaw_super_locked(s, FREEZE_HOLDER_USERSPACE [| FREEZE_MAY_NEST])
Thaw(s) ==
    LET r == sbs[s] IN
    IF ~r.frz \/ r.uc = 0 THEN [ok |-> "EINVAL", r |-> r]
    ELSE IF r.kc + r.uc > 1
    THEN [ok |-> IF FIX_NESTED_THAW_RET THEN "ok" ELSE "EINVAL", r |-> [r EXCEPT !.uc = @ - 1]]
    ELSE [ok |-> "ok", r |-> [r EXCEPT !.uc = 0, !.frz = FALSE, !.act = @ - 1]]

First(e, x) == IF e = "ok" THEN x ELSE e

(* ---- bdev_freeze() ----------------------------------------------------------- *)

\* mutex_lock(&bd_fsfreeze_mutex); atomic_inc_unless_negative(); a nested
\* freeze returns at once
BfLock(p) ==
    LET d == pv[p].dv IN
    /\ pc[p] = "bf_lock"
    /\ dev[d].fm = NoOne
    /\ CASE dev[d].cnt < 0 ->
              /\ pc' = [pc EXCEPT ![p] = pv[p].k]
              /\ pv' = [pv EXCEPT ![p].ret = "EBUSY"]
              /\ UNCHANGED <<dev, gc>>
         [] dev[d].cnt > 0 ->
              /\ dev' = [dev EXCEPT ![d].cnt = @ + 1]
              /\ gc' = [gc EXCEPT ![d] = @ + 1]
              /\ pc' = [pc EXCEPT ![p] = pv[p].k]
              /\ pv' = [pv EXCEPT ![p].ret = "ok"]
         [] dev[d].cnt = 0 ->
              /\ dev' = [dev EXCEPT ![d].cnt = 1, ![d].fm = p]
              /\ gc' = [gc EXCEPT ![d] = @ + 1]
              /\ pc' = [pc EXCEPT ![p] = "bf_hops"]
              /\ UNCHANGED pv
    /\ UNCHANGED <<tab, sbs, dn, err>>

\* mutex_lock(&bd_holder_lock): fs_holder_ops, or a plain sync_blockdev()
BfHops(p) ==
    LET d == pv[p].dv IN
    /\ pc[p] = "bf_hops"
    /\ IF Hops(d)
       THEN /\ pv' = [pv EXCEPT ![p].todo = {s \in Sbs : <<d, s>> \in tab}, ![p].e = "ok",
                                ![p].n = 0, ![p].froze = {}]
            /\ pc' = [pc EXCEPT ![p] = "bf_walk"]
       ELSE /\ pv' = [pv EXCEPT ![p].e = "ok"]
            /\ pc' = [pc EXCEPT ![p] = "bf_bsync"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>

\* no holder: sync_blockdev()
BfBsync(p) ==
    /\ pc[p] = "bf_bsync"
    /\ \/ pc' = [pc EXCEPT ![p] = "bf_end"] /\ UNCHANGED pv
       \/ /\ SYNC_FAIL
          /\ pv' = [pv EXCEPT ![p].e = "EIO"]
          /\ pc' = [pc EXCEPT ![p] = "bf_end"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>

\* super_dev_first()/super_dev_next()
Walk(p, from, gas, done) ==
    LET d == pv[p].dv IN
    /\ pc[p] = from
    /\ IF pv[p].todo = {}
       THEN /\ pc' = [pc EXCEPT ![p] = done]
            /\ UNCHANGED pv
       ELSE \E s \in pv[p].todo :
              /\ pv' = [pv EXCEPT ![p].todo = @ \ {s}, ![p].cur = s]
              /\ pc' = [pc EXCEPT ![p] = IF <<d, s>> \in tab THEN gas ELSE from]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>

\* get_active_super(): super_lock_excl() waits for SB_BORN or SB_DYING,
\* fails on SB_DYING; atomic_inc_not_zero(&s_active)
Gas(p, from, to, skip) ==
    LET s == pv[p].cur IN
    /\ pc[p] = from
    /\ sbs[s].st # "new"
    /\ IF Gone(s)
       THEN pc' = [pc EXCEPT ![p] = skip] /\ UNCHANGED sbs
       ELSE /\ sbs[s].um = NoOne
            /\ sbs' = [sbs EXCEPT ![s].act = @ + 1]
            /\ pc' = [pc EXCEPT ![p] = to]
    /\ UNCHANGED <<dev, tab, pv, gc, dn, err>>

\* deactivate_super(): the last reference kills the superblock
Put(p, from, to) ==
    LET s == pv[p].cur IN
    /\ pc[p] = from
    /\ IF sbs[s].act > 1
       THEN /\ sbs' = [sbs EXCEPT ![s].act = @ - 1]
            /\ UNCHANGED <<dev, tab, err>>
       ELSE /\ sbs[s].um = NoOne
            /\ KillSb(s)
    /\ pc' = [pc EXCEPT ![p] = to]
    /\ UNCHANGED <<pv, gc, dn>>

BfWalk(p) == Walk(p, "bf_walk", "bf_gas", "bf_sync")
BfGas(p) == Gas(p, "bf_gas", "bf_frz", "bf_walk")

\* fs_super_freeze(): freeze_super(FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE)
BfFrz(p) ==
    LET s == pv[p].cur IN
    /\ pc[p] = "bf_frz"
    /\ sbs[s].um = NoOne
    /\ \E o \in Freeze(s, TRUE) :
          /\ sbs' = [sbs EXCEPT ![s] = o.r]
          /\ pv' = [pv EXCEPT ![p].e = First(@, o.ok), ![p].n = @ + 1,
                              ![p].froze = IF o.ok = "ok" THEN @ \cup {s} ELSE @]
    /\ pc' = [pc EXCEPT ![p] = "bf_put"]
    /\ UNCHANGED <<dev, tab, gc, dn, err>>
BfPut(p) == Put(p, "bf_put", "bf_walk")

\* count > 1 swallows per-superblock errors; then sync_blockdev(), whose
\* failure is reported (with FIX_SYNC_ROLLBACK the frozen ones are thawed)
BfSync(p) ==
    LET e1 == IF pv[p].e # "ok" /\ pv[p].n > 1 /\ FIX_SWALLOW THEN "ok" ELSE pv[p].e IN
    /\ pc[p] = "bf_sync"
    /\ IF e1 # "ok"
       THEN /\ pv' = [pv EXCEPT ![p].e = e1]
            /\ pc' = [pc EXCEPT ![p] = "bf_end"]
       ELSE \/ /\ pv' = [pv EXCEPT ![p].e = "ok"]
               /\ pc' = [pc EXCEPT ![p] = "bf_end"]
            \/ /\ SYNC_FAIL
               /\ pv' = [pv EXCEPT ![p].e = "EIO"]
               /\ pc' = [pc EXCEPT ![p] = IF FIX_SYNC_ROLLBACK THEN "bf_rb" ELSE "bf_end"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>

\* proposed: thaw the superblocks this walk froze (they hold the shared
\* active reference, so they are alive)
BfRollback(p) ==
    /\ pc[p] = "bf_rb"
    /\ IF pv[p].froze = {}
       THEN pc' = [pc EXCEPT ![p] = "bf_end"] /\ UNCHANGED <<sbs, pv>>
       ELSE \E s \in pv[p].froze :
              /\ sbs[s].um = NoOne
              /\ sbs' = [sbs EXCEPT ![s] = Thaw(s).r]
              /\ pv' = [pv EXCEPT ![p].froze = @ \ {s}]
              /\ UNCHANGED pc
    /\ UNCHANGED <<dev, tab, gc, dn, err>>

\* on error atomic_dec(&bd_fsfreeze_count); mutex_unlock()
BfEnd(p) ==
    LET d == pv[p].dv  ok == pv[p].e = "ok" IN
    /\ pc[p] = "bf_end"
    /\ dev' = [dev EXCEPT ![d].cnt = IF ok THEN @ ELSE @ - 1, ![d].fm = NoOne]
    /\ gc' = [gc EXCEPT ![d] = IF ok THEN @ ELSE @ - 1]
    /\ pv' = [pv EXCEPT ![p].ret = pv[p].e]
    /\ pc' = [pc EXCEPT ![p] = pv[p].k]
    /\ UNCHANGED <<tab, sbs, dn, err>>

BdevFreeze(p) == BfLock(p) \/ BfHops(p) \/ BfBsync(p) \/ BfWalk(p) \/ BfGas(p) \/ BfFrz(p)
                 \/ BfPut(p) \/ BfSync(p) \/ BfRollback(p) \/ BfEnd(p)

(* ---- bdev_thaw() --------------------------------------------------------------- *)

\* gc counts the caller's increment until its bdev_thaw() returns; the
\* emergency thaw holds none
Owes(p) == p \in BCallers

\* nr_freeze <= 0: -EINVAL; > 1: atomic_dec()
BtLock(p) ==
    LET d == pv[p].dv  n == dev[d].cnt IN
    /\ pc[p] = "bt_lock"
    /\ dev[d].fm = NoOne
    /\ CASE n <= 0 ->
              /\ pc' = [pc EXCEPT ![p] = pv[p].k]
              /\ pv' = [pv EXCEPT ![p].ret = "EINVAL"]
              /\ gc' = [gc EXCEPT ![d] = IF Owes(p) THEN @ - 1 ELSE @]
              /\ UNCHANGED dev
         [] n > 1 ->
              /\ dev' = [dev EXCEPT ![d].cnt = @ - 1]
              /\ pc' = [pc EXCEPT ![p] = pv[p].k]
              /\ pv' = [pv EXCEPT ![p].ret = "ok"]
              /\ gc' = [gc EXCEPT ![d] = IF Owes(p) THEN @ - 1 ELSE @]
         [] n = 1 ->
              /\ dev' = [dev EXCEPT ![d].fm = p]
              /\ pc' = [pc EXCEPT ![p] = "bt_hops"]
              /\ UNCHANGED <<pv, gc>>
    /\ UNCHANGED <<tab, sbs, dn, err>>

BtHops(p) ==
    LET d == pv[p].dv IN
    /\ pc[p] = "bt_hops"
    /\ pv' = [pv EXCEPT ![p].todo = IF Hops(d) THEN {s \in Sbs : <<d, s>> \in tab} ELSE {},
                        ![p].e = "ok", ![p].n = 0]
    /\ pc' = [pc EXCEPT ![p] = IF Hops(d) THEN "bt_walk" ELSE "bt_end"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>

BtWalk(p) == Walk(p, "bt_walk", "bt_gas", "bt_end")
BtGas(p) == Gas(p, "bt_gas", "bt_thw", "bt_walk")

\* fs_super_thaw(): thaw_super(FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE)
BtThw(p) ==
    LET s == pv[p].cur  o == Thaw(s) IN
    /\ pc[p] = "bt_thw"
    /\ sbs[s].um = NoOne
    /\ sbs' = [sbs EXCEPT ![s] = o.r]
    /\ pv' = [pv EXCEPT ![p].e = First(@, IF FIX_THAW_EINVAL_OK /\ o.ok = "EINVAL" THEN "ok" ELSE o.ok),
                        ![p].n = @ + 1]
    /\ pc' = [pc EXCEPT ![p] = "bt_put"]
    /\ UNCHANGED <<dev, tab, gc, dn, err>>
BtPut(p) == Put(p, "bt_put", "bt_walk")

\* count > 1 swallows per-superblock errors; atomic_dec() only on success
BtEnd(p) ==
    LET d == pv[p].dv
        e1 == IF pv[p].e # "ok" /\ pv[p].n > 1 /\ FIX_SWALLOW THEN "ok" ELSE pv[p].e
    IN
    /\ pc[p] = "bt_end"
    /\ dev' = [dev EXCEPT ![d].cnt = IF e1 = "ok" THEN @ - 1 ELSE @, ![d].fm = NoOne]
    /\ gc' = [gc EXCEPT ![d] = IF Owes(p) THEN @ - 1 ELSE @]
    /\ pv' = [pv EXCEPT ![p].ret = e1]
    /\ pc' = [pc EXCEPT ![p] = pv[p].k]
    /\ UNCHANGED <<tab, sbs, dn, err>>

BdevThaw(p) == BtLock(p) \/ BtHops(p) \/ BtWalk(p) \/ BtGas(p) \/ BtThw(p) \/ BtPut(p) \/ BtEnd(p)

(* ---- device-mapper suspend/resume, the shutdown ioctls ---------------------------- *)

\* lock_fs(): bdev_freeze(md->disk->part0)
DStart(p) ==
    /\ pc[p] = "d_start"
    /\ pv' = [pv EXCEPT ![p].k = "d_frzret"]
    /\ pc' = [pc EXCEPT ![p] = "bf_lock"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>
\* DMF_FROZEN on success; on failure the suspend fails and unlock_fs() never runs
DFrzRet(p) ==
    /\ pc[p] = "d_frzret"
    /\ pc' = [pc EXCEPT ![p] = IF pv[p].ret = "ok" THEN "d_hold" ELSE "done"]
    /\ UNCHANGED <<dev, tab, sbs, pv, gc, dn, err>>
\* unlock_fs(): bdev_thaw(), its result ignored, DMF_FROZEN cleared
DHold(p) ==
    /\ pc[p] = "d_hold"
    /\ pv' = [pv EXCEPT ![p].k = "done"]
    /\ pc' = [pc EXCEPT ![p] = "bt_lock"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>
Dm(p) == DStart(p) \/ DFrzRet(p) \/ DHold(p)

\* ext4_force_shutdown(), xfs_fs_goingdown(), f2fs_do_shutdown(),
\* exfat_force_shutdown(), ntfs_force_shutdown(): an ioctl on an open file
\* of the mounted filesystem, bdev_freeze(sb->s_bdev), the shutdown flag,
\* bdev_thaw(sb->s_bdev)
SStart(p) ==
    /\ pc[p] = "s_start"
    /\ Live(Tgt[p]) /\ sbs[Tgt[p]].mnt
    /\ pv' = [pv EXCEPT ![p].k = "s_frzret"]
    /\ pc' = [pc EXCEPT ![p] = "bf_lock"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>
SFrzRet(p) ==
    /\ pc[p] = "s_frzret"
    /\ pc' = [pc EXCEPT ![p] = IF pv[p].ret = "ok" THEN "s_hold" ELSE "done"]
    /\ UNCHANGED <<dev, tab, sbs, pv, gc, dn, err>>
SHold(p) ==
    /\ pc[p] = "s_hold"
    /\ pv' = [pv EXCEPT ![p].k = "done"]
    /\ pc' = [pc EXCEPT ![p] = "bt_lock"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>
Shut(p) == SStart(p) \/ SFrzRet(p) \/ SHold(p)

(* ---- FIFREEZE/FITHAW ------------------------------------------------------------- *)

\* ioctl_fsfreeze(): freeze_super(FREEZE_HOLDER_USERSPACE) on a mounted
\* filesystem the task has open
FFrz(p) ==
    LET s == Tgt[p] IN
    /\ pc[p] = "f_frz"
    /\ Live(s) /\ sbs[s].mnt /\ sbs[s].um = NoOne
    /\ \E o \in Freeze(s, FALSE) :
          /\ sbs' = [sbs EXCEPT ![s] = o.r]
          /\ pc' = [pc EXCEPT ![p] = IF o.ok = "ok" THEN "f_hold" ELSE "done"]
          /\ pv' = [pv EXCEPT ![p].ret = o.ok]
    /\ UNCHANGED <<dev, tab, gc, dn, err>>
\* ioctl_fsthaw()
FThaw(p) ==
    LET s == Tgt[p]  o == Thaw(s) IN
    /\ pc[p] = "f_hold"
    /\ sbs[s].um = NoOne
    /\ sbs' = [sbs EXCEPT ![s] = o.r]
    /\ pv' = [pv EXCEPT ![p].ret = o.ok]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<dev, tab, gc, dn, err>>
User(p) == FFrz(p) \/ FThaw(p)

\* FITHAW from a task that did not freeze
Rogue(p) ==
    LET s == Tgt[p]  o == Thaw(s) IN
    /\ pc[p] = "r_thaw"
    /\ Live(s) /\ sbs[s].mnt /\ sbs[s].um = NoOne
    /\ sbs' = [sbs EXCEPT ![s] = o.r]
    /\ pv' = [pv EXCEPT ![p].ret = o.ok]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<dev, tab, gc, dn, err>>

(* ---- the emergency thaw ------------------------------------------------------------- *)

\* do_thaw_all() -> __iterate_supers(SUPER_ITER_UNLOCKED): every superblock
\* not SB_DYING
EStart(p) ==
    /\ pc[p] = "e_start"
    /\ pv' = [pv EXCEPT ![p].it = Sbs]
    /\ pc' = [pc EXCEPT ![p] = "e_next"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>
ENext(p) ==
    /\ pc[p] = "e_next"
    /\ IF pv[p].it = {}
       THEN pc' = [pc EXCEPT ![p] = "done"] /\ UNCHANGED pv
       ELSE \E s \in pv[p].it :
              /\ pv' = [pv EXCEPT ![p].it = @ \ {s}, ![p].cur = s]
              /\ pc' = [pc EXCEPT ![p] = IF sbs[s].st \in {"new", "born"} THEN "e_gas" ELSE "e_next"]
    /\ UNCHANGED <<dev, tab, sbs, gc, dn, err>>
\* do_thaw_all_callback(): get_active_super(); before 749d7aa0377a the
\* iterator held s_umount across the whole callback
EGas(p) ==
    LET s == pv[p].cur IN
    /\ pc[p] = "e_gas"
    /\ sbs[s].st # "new"
    /\ IF Gone(s)
       THEN pc' = [pc EXCEPT ![p] = "e_next"] /\ UNCHANGED <<sbs, pv>>
       ELSE /\ sbs[s].um = NoOne
            /\ sbs' = [sbs EXCEPT ![s].act = @ + 1,
                                  ![s].um = IF FIX_THAW_ALL_UNLOCKED THEN NoOne ELSE p]
            /\ pv' = [pv EXCEPT ![p].dv = Main[s], ![p].k = "e_btret"]
            /\ pc' = [pc EXCEPT ![p] = "bt_lock"]
    /\ UNCHANGED <<dev, tab, gc, dn, err>>
\* while (sb->s_bdev && !bdev_thaw(sb->s_bdev))
EBtRet(p) ==
    /\ pc[p] = "e_btret"
    /\ pc' = [pc EXCEPT ![p] = IF pv[p].ret = "ok" THEN "bt_lock" ELSE "e_lock"]
    /\ UNCHANGED <<dev, tab, sbs, pv, gc, dn, err>>
\* super_lock_excl() + thaw_super_locked(FREEZE_HOLDER_USERSPACE)
ELock(p) ==
    LET s == pv[p].cur  o == Thaw(s) IN
    /\ pc[p] = "e_lock"
    /\ IF FIX_THAW_ALL_UNLOCKED THEN sbs[s].um = NoOne ELSE sbs[s].um = p
    /\ sbs' = [sbs EXCEPT ![s] = [o.r EXCEPT !.um = NoOne]]
    /\ pc' = [pc EXCEPT ![p] = "e_put"]
    /\ UNCHANGED <<dev, tab, pv, gc, dn, err>>
EPut(p) == Put(p, "e_put", "e_next")
Emergency(p) == EStart(p) \/ ENext(p) \/ EGas(p) \/ EBtRet(p) \/ ELock(p) \/ EPut(p)

(* ---- mount and umount ---------------------------------------------------------------- *)

\* sget_dev(): the superblock with its device-table entry published,
\* s_umount held, SB_BORN not yet set
MSget(p) ==
    LET s == Tgt[p] IN
    /\ pc[p] = "m_sget"
    /\ IF After[s] = NoOne THEN TRUE ELSE Gone(After[s])
    /\ sbs' = [sbs EXCEPT ![s] = [@ EXCEPT !.st = "new", !.um = p, !.act = 1]]
    /\ tab' = tab \cup {<<Main[s], s>>}
    /\ pc' = [pc EXCEPT ![p] = "m_claim"]
    /\ UNCHANGED <<dev, pv, gc, dn, err>>
\* setup_bdev_super(): bdev_file_open_by_dev() -> bd_finish_claiming() sets
\* bd_holder_ops under bd_holder_lock; fs_bdev_register() shares the entry
MClaim(p) ==
    LET s == Tgt[p]  d == Main[s] IN
    /\ pc[p] = "m_claim"
    /\ dev' = [dev EXCEPT ![d].cl = @ \cup {s}]
    /\ sbs' = [sbs EXCEPT ![s].mem = @ \cup {d}]
    /\ pc' = [pc EXCEPT ![p] = "m_check"]
    /\ UNCHANGED <<tab, pv, gc, dn, err>>
\* smp_mb(); bd_fsfreeze_count > 0: -EBUSY, deactivate_locked_super()
MCheck(p) ==
    LET s == Tgt[p] IN
    /\ pc[p] = "m_check"
    /\ IF FIX_SETUP_CHECK /\ dev[Main[s]].cnt > 0
       THEN /\ KillSb(s)
            /\ pc' = [pc EXCEPT ![p] = "done"]
            /\ pv' = [pv EXCEPT ![p].ret = "EBUSY"]
       ELSE /\ pc' = [pc EXCEPT ![p] = IF XDev[s] = NoOne THEN "m_born" ELSE "m_xclaim"]
            /\ UNCHANGED <<dev, tab, sbs, pv, err>>
    /\ UNCHANGED <<gc, dn>>
\* ->fill_super(): fs_bdev_file_open_by_path() of the extra device: the claim
MXClaim(p) ==
    LET s == Tgt[p]  d == XDev[s] IN
    /\ pc[p] = "m_xclaim"
    /\ dev' = [dev EXCEPT ![d].cl = @ \cup {s}]
    /\ sbs' = [sbs EXCEPT ![s].mem = @ \cup {d}]
    /\ pc' = [pc EXCEPT ![p] = "m_xreg"]
    /\ UNCHANGED <<tab, pv, gc, dn, err>>
\* fs_bdev_register(): super_dev_insert() publishes the entry (L1664) ...
MXReg(p) ==
    LET s == Tgt[p]  d == XDev[s] IN
    /\ pc[p] = "m_xreg"
    /\ tab' = tab \cup {<<d, s>>}
    /\ pc' = [pc EXCEPT ![p] = "m_xchk"]
    /\ UNCHANGED <<dev, sbs, pv, gc, dn, err>>
\* ... smp_mb(), a frozen device: super_dev_put(), bdev_fput() (L1668-1673,
\* L1703-1706); the mount fails, or (XDegraded) goes on without the device
MXChk(p) ==
    LET s == Tgt[p]  d == XDev[s] IN
    /\ pc[p] = "m_xchk"
    /\ IF FIX_REGISTER_CHECK /\ dev[d].cnt > 0
       THEN IF XDegraded[s]
            THEN /\ tab' = tab \ {<<d, s>>}
                 /\ dev' = [dev EXCEPT ![d].cl = @ \ {s}]
                 /\ sbs' = [sbs EXCEPT ![s].mem = @ \ {d}]
                 /\ pc' = [pc EXCEPT ![p] = "m_born"]
                 /\ UNCHANGED <<pv, err>>
            ELSE /\ KillSb(s)
                 /\ pc' = [pc EXCEPT ![p] = "done"]
                 /\ pv' = [pv EXCEPT ![p].ret = "EBUSY"]
       ELSE /\ pc' = [pc EXCEPT ![p] = "m_born"]
            /\ UNCHANGED <<dev, tab, sbs, pv, err>>
    /\ UNCHANGED <<gc, dn>>
\* SB_ACTIVE, super_wake(SB_BORN), fc_mount()'s up_write(&s_umount)
MBorn(p) ==
    LET s == Tgt[p] IN
    /\ pc[p] = "m_born"
    /\ sbs' = [sbs EXCEPT ![s].st = "born", ![s].um = NoOne, ![s].mnt = TRUE]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<dev, tab, pv, gc, dn, err>>
Mount(p) == MSget(p) \/ MClaim(p) \/ MCheck(p) \/ MXClaim(p) \/ MXReg(p) \/ MXChk(p) \/ MBorn(p)

\* the mount's reference, once nobody uses the mount: deactivate_super()
SbUsers(s) == {q \in Procs : Role[q] \in {"user", "rogue", "shut", "add", "rm"} /\ Tgt[q] = s}
Umount(p) ==
    LET s == Tgt[p] IN
    /\ pc[p] = "u_go"
    /\ Live(s) /\ sbs[s].mnt
    /\ \A q \in SbUsers(s) : pc[q] = "done"
    /\ IF sbs[s].act > 1
       THEN /\ sbs' = [sbs EXCEPT ![s].act = @ - 1, ![s].mnt = FALSE]
            /\ UNCHANGED <<dev, tab, err>>
       ELSE /\ sbs[s].um = NoOne
            /\ KillSb(s)
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<pv, gc, dn>>

(* ---- btrfs-like device add and remove ------------------------------------------------ *)

\* btrfs_open_device_deny_freeze(): bdev_deny_freeze() on a probe open
ADeny(p) ==
    LET s == Tgt[p]  d == XTgt[p] IN
    /\ pc[p] = "a_deny"
    /\ Live(s) /\ sbs[s].mnt
    /\ IF ~FIX_DENY
       THEN pc' = [pc EXCEPT ![p] = "a_claim"] /\ UNCHANGED <<dev, dn, pv>>
       ELSE IF dev[d].cnt > 0
       THEN /\ pc' = [pc EXCEPT ![p] = "done"]
            /\ pv' = [pv EXCEPT ![p].ret = "EBUSY"]
            /\ UNCHANGED <<dev, dn>>
       ELSE /\ dev' = [dev EXCEPT ![d].cnt = @ - 1]
            /\ dn' = [dn EXCEPT ![d] = @ + 1]
            /\ pc' = [pc EXCEPT ![p] = "a_claim"]
            /\ UNCHANGED pv
    /\ UNCHANGED <<tab, sbs, gc, err>>
\* fs_bdev_file_open_by_dev(): claim
AClaim(p) ==
    LET s == Tgt[p]  d == XTgt[p] IN
    /\ pc[p] = "a_claim"
    /\ dev' = [dev EXCEPT ![d].cl = @ \cup {s}]
    /\ sbs' = [sbs EXCEPT ![s].mem = @ \cup {d}]
    /\ pc' = [pc EXCEPT ![p] = "a_reg"]
    /\ UNCHANGED <<tab, pv, gc, dn, err>>
Allowed(d) == IF FIX_DENY THEN [dev EXCEPT ![d].cnt = @ + 1] ELSE dev
AllowDn(d) == IF FIX_DENY THEN [dn EXCEPT ![d] = @ - 1] ELSE dn
\* fs_bdev_register(): publish and check; a refused open re-allows
AReg(p) ==
    LET s == Tgt[p]  d == XTgt[p] IN
    /\ pc[p] = "a_reg"
    /\ IF FIX_REGISTER_CHECK /\ dev[d].cnt > 0
       THEN /\ dev' = [Allowed(d) EXCEPT ![d].cl = @ \ {s}]
            /\ dn' = AllowDn(d)
            /\ sbs' = [sbs EXCEPT ![s].mem = @ \ {d}]
            /\ pc' = [pc EXCEPT ![p] = "done"]
            /\ pv' = [pv EXCEPT ![p].ret = "EBUSY"]
            /\ UNCHANGED tab
       ELSE /\ tab' = tab \cup {<<d, s>>}
            /\ pc' = [pc EXCEPT ![p] = "a_join"]
            /\ UNCHANGED <<dev, dn, sbs, pv>>
    /\ UNCHANGED <<gc, err>>
\* the add completes (bdev_allow_freeze()) or aborts
\* (btrfs_release_device_allow_freeze(): unregister, allow, bdev_fput())
AJoin(p) ==
    LET s == Tgt[p]  d == XTgt[p] IN
    /\ pc[p] = "a_join"
    /\ \/ /\ dev' = Allowed(d)
          /\ dn' = AllowDn(d)
          /\ UNCHANGED <<tab, sbs>>
       \/ /\ ADD_ABORT
          /\ tab' = tab \ {<<d, s>>}
          /\ dev' = [Allowed(d) EXCEPT ![d].cl = @ \ {s}]
          /\ dn' = AllowDn(d)
          /\ sbs' = [sbs EXCEPT ![s].mem = @ \ {d}]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<pv, gc, err>>
Add(p) == ADeny(p) \/ AClaim(p) \/ AReg(p) \/ AJoin(p)

\* btrfs_rm_device(): bdev_deny_freeze(device->bdev) or -EBUSY
XDeny(p) ==
    LET s == Tgt[p]  d == XTgt[p] IN
    /\ pc[p] = "x_deny"
    /\ Live(s) /\ sbs[s].mnt
    /\ IF d \notin sbs[s].mem
       THEN pc' = [pc EXCEPT ![p] = "done"] /\ UNCHANGED <<dev, dn, pv>>
       ELSE IF ~FIX_DENY
       THEN pc' = [pc EXCEPT ![p] = "x_unreg"] /\ UNCHANGED <<dev, dn, pv>>
       ELSE IF dev[d].cnt > 0
       THEN /\ pc' = [pc EXCEPT ![p] = "done"]
            /\ pv' = [pv EXCEPT ![p].ret = "EBUSY"]
            /\ UNCHANGED <<dev, dn>>
       ELSE /\ dev' = [dev EXCEPT ![d].cnt = @ - 1]
            /\ dn' = [dn EXCEPT ![d] = @ + 1]
            /\ pc' = [pc EXCEPT ![p] = IF FIX_UNREGISTER_FIRST THEN "x_unreg" ELSE "x_allow"]
            /\ UNCHANGED pv
    /\ UNCHANGED <<tab, sbs, gc, err>>
\* btrfs_release_device_allow_freeze(): fs_bdev_unregister() ...
XUnreg(p) ==
    LET s == Tgt[p]  d == XTgt[p] IN
    /\ pc[p] = "x_unreg"
    /\ tab' = tab \ {<<d, s>>}
    /\ pc' = [pc EXCEPT ![p] = IF FIX_UNREGISTER_FIRST THEN "x_allow" ELSE "x_put"]
    /\ UNCHANGED <<dev, sbs, pv, gc, dn, err>>
\* ... bdev_allow_freeze() ...
XAllow(p) ==
    /\ pc[p] = "x_allow"
    /\ dev' = Allowed(XTgt[p])
    /\ dn' = AllowDn(XTgt[p])
    /\ pc' = [pc EXCEPT ![p] = IF FIX_UNREGISTER_FIRST THEN "x_put" ELSE "x_unreg"]
    /\ UNCHANGED <<tab, sbs, pv, gc, err>>
\* ... bdev_fput(): the claim goes
XPut(p) ==
    LET s == Tgt[p]  d == XTgt[p] IN
    /\ pc[p] = "x_put"
    /\ dev' = [dev EXCEPT ![d].cl = @ \ {s}]
    /\ sbs' = [sbs EXCEPT ![s].mem = @ \ {d}]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<tab, pv, gc, dn, err>>
Rm(p) == XDeny(p) \/ XUnreg(p) \/ XAllow(p) \/ XPut(p)

\* a task that needs the filesystem mounted gives up once the superblock
\* is gone (its mount failed); the umount of a failed mount has nothing to do
StartLabels == {"s_start", "f_frz", "r_thaw", "a_deny", "x_deny", "u_go"}
Abandon(p) ==
    /\ Role[p] \in {"shut", "user", "rogue", "add", "rm", "umount"}
    /\ pc[p] \in StartLabels
    /\ Gone(Tgt[p])
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<dev, tab, sbs, pv, gc, dn, err>>

(* ---- the specification ------------------------------------------------------------------ *)

Done == \A p \in Procs : pc[p] = "done"

Next ==
    \/ \E p \in Procs : BfLock(p)
    \/ \E p \in Procs : BfHops(p)
    \/ \E p \in Procs : BfBsync(p)
    \/ \E p \in Procs : BfWalk(p)
    \/ \E p \in Procs : BfGas(p)
    \/ \E p \in Procs : BfFrz(p)
    \/ \E p \in Procs : BfPut(p)
    \/ \E p \in Procs : BfSync(p)
    \/ \E p \in Procs : BfRollback(p)
    \/ \E p \in Procs : BfEnd(p)
    \/ \E p \in Procs : BtLock(p)
    \/ \E p \in Procs : BtHops(p)
    \/ \E p \in Procs : BtWalk(p)
    \/ \E p \in Procs : BtGas(p)
    \/ \E p \in Procs : BtThw(p)
    \/ \E p \in Procs : BtPut(p)
    \/ \E p \in Procs : BtEnd(p)
    \/ \E p \in Procs : DStart(p)
    \/ \E p \in Procs : DFrzRet(p)
    \/ \E p \in Procs : DHold(p)
    \/ \E p \in Procs : SStart(p)
    \/ \E p \in Procs : SFrzRet(p)
    \/ \E p \in Procs : SHold(p)
    \/ \E p \in Procs : FFrz(p)
    \/ \E p \in Procs : FThaw(p)
    \/ \E p \in Procs : Rogue(p)
    \/ \E p \in Procs : EStart(p)
    \/ \E p \in Procs : ENext(p)
    \/ \E p \in Procs : EGas(p)
    \/ \E p \in Procs : EBtRet(p)
    \/ \E p \in Procs : ELock(p)
    \/ \E p \in Procs : EPut(p)
    \/ \E p \in Procs : MSget(p)
    \/ \E p \in Procs : MClaim(p)
    \/ \E p \in Procs : MCheck(p)
    \/ \E p \in Procs : MXClaim(p)
    \/ \E p \in Procs : MXReg(p)
    \/ \E p \in Procs : MXChk(p)
    \/ \E p \in Procs : MBorn(p)
    \/ \E p \in Procs : Umount(p)
    \/ \E p \in Procs : ADeny(p)
    \/ \E p \in Procs : AClaim(p)
    \/ \E p \in Procs : AReg(p)
    \/ \E p \in Procs : AJoin(p)
    \/ \E p \in Procs : XDeny(p)
    \/ \E p \in Procs : XUnreg(p)
    \/ \E p \in Procs : XAllow(p)
    \/ \E p \in Procs : XPut(p)
    \/ \E p \in Procs : Abandon(p)
    \/ (Done /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* ---- invariants ---------------------------------------------------------------------------- *)

NoErr == err = ""

\* freeze state and counters agree
SbOK == \A s \in Sbs : sbs[s].frz <=> (sbs[s].kc + sbs[s].uc > 0)

\* a bdev_freeze() caller between its successful return and its bdev_thaw():
\* every live superblock on the device is frozen
Holding(p) == pc[p] \in {"d_hold", "s_hold"}
FrozenWhileHeld ==
    \A p \in BCallers : Holding(p) =>
        \A s \in Sbs : (<<BDev(p), s>> \in tab /\ Live(s)) => sbs[s].frz

\* a FIFREEZE caller holding its freeze finds the filesystem frozen
UserOK == \A p \in Procs : (Role[p] = "user" /\ pc[p] = "f_hold") => sbs[Tgt[p]].frz

\* bd_fsfreeze_count is the freezes whose callers have not finished their
\* bdev_thaw(), minus the denies (when no freeze or thaw holds the mutex)
CountOK == \A d \in Devs : dev[d].fm = NoOne => dev[d].cnt = gc[d] - dn[d]

\* at the end nothing is frozen and no count is left
Clean ==
    /\ \A s \in Sbs : ~sbs[s].frz /\ sbs[s].kc + sbs[s].uc = 0
    /\ \A d \in Devs : dev[d].cnt = 0
FinalOK == Done => Clean

=============================================================================

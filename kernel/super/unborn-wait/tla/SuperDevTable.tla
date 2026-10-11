---------------------------- MODULE SuperDevTable ----------------------------
(***************************************************************************)
(* The device-to-superblock table of fs/super.c (work.super.fixes at      *)
(* fc1c25014ff8): struct super_dev entries {sd_dev, sd_sb, sd_ref,         *)
(* sd_node, sd_rcu} in an rhltable keyed by dev_t, the claims that keep    *)
(* them, the cursors that walk them, and the block layer's freeze counter  *)
(* the registration checks against.                                        *)
(*                                                                         *)
(* The rhltable is abstracted to one RCU list per device: rhltable_insert() *)
(* of a key already present links the new node in FRONT of the duplicates *)
(* (include/linux/rhashtable.h __rhashtable_insert_fast(), list->next =    *)
(* plist, the new node replaces the old head in the bucket chain);         *)
(* rhltable_remove() unlinks a node by storing its ->next into its         *)
(* predecessor (or into the bucket chain when it is the head) and leaves   *)
(* the removed node's ->next alone; a resize moves a key's duplicate list  *)
(* as one unit (rhashtable_rehash_one() relinks the bucket-chain node      *)
(* only), so the list order is never changed by anything but insert and   *)
(* remove.  Writers are serialized (the bucket bit lock); a reader under   *)
(* rcu_read_lock() reads the head once and then follows ->next pointers   *)
(* one step at a time, so it can stand on a removed node and follow its   *)
(* stale ->next.  kfree_rcu() frees an entry once every reader that was   *)
(* inside a read section when it was called has left it.                 *)
(*                                                                         *)
(* Tasks:                                                                  *)
(*   one filesystem task per superblock (the name of the superblock):     *)
(*     alloc_super() (the entry preallocated unregistered), set() ->       *)
(*     super_dev_register() (sget_fc()'s claim), setup_bdev_super() ->     *)
(*     fs_bdev_file_open_by_dev() -> fs_bdev_register() of the main       *)
(*     device and the frozen check of setup_bdev_super(), optionally an   *)
(*     extra member device registered during the mount (xmode "mount":    *)
(*     xfs log/rt, ext4 journal, f2fs, erofs, btrfs) or after it under    *)
(*     bdev_deny_freeze() (xmode "live": btrfs device add), optionally    *)
(*     released again before SB_BORN while the mount goes on (dropx       *)
(*     "early": btrfs __btrfs_free_extra_devids(), a devid mismatch in    *)
(*     btrfs_open_one_device()) or from the live superblock under the    *)
(*     deny (dropx "live": btrfs device remove), SB_BORN, and the unmount: *)
(*     ->put_super() closing the member device, SB_DYING, kill_block_super *)
(*     releasing the main device, kill_super_notify() dropping sget_fc()'s *)
(*     claim, SB_DEAD, put_super()                                         *)
(*   freezers: bdev_freeze() -> fs_bdev_freeze(), then bdev_thaw() ->      *)
(*     fs_bdev_thaw() on one device                                       *)
(*   cursors: user_get_super() on one device                              *)
(*   dups: a second fs_bdev_register()/fs_bdev_unregister() of a         *)
(*     superblock's extra device, either concurrent with the filesystem's *)
(*     own (a caller contract witness, no in-tree caller does this) or    *)
(*     once the filesystem started dropping its claim (a re-add)          *)
(*                                                                         *)
(* Mutations (each FIX_* off is a known-bad shape, for the red witnesses): *)
(*   FIX_RCU_FREE      off: super_dev_put() frees with kfree() at removal  *)
(*   FIX_NEXT_PIN      off: super_dev_next() drops prev before it reads    *)
(*                     prev->sd_node.next                                  *)
(*   FIX_PUBLISH_FIRST off: fs_bdev_register() reads bd_fsfreeze_count     *)
(*                     before it inserts the entry                        *)
(*   FIX_DENY          off: live membership changes do not deny freezes    *)
(*   FIX_FIRST_MATCH   off: super_dev_lookup() returns the last match      *)
(*   FIX_UNBORN_WAIT   off: the shape at fc1c25014ff8: super_dev_get()     *)
(*                     pins the entry of a superblock that is not born yet *)
(*                     and the walk waits for SB_BORN with the pin held;   *)
(*                     on: it takes a passive reference instead, waits     *)
(*                     unpinned and looks again from the head or from prev *)
(*                     (work.super.fixes.core, "super: don't act on        *)
(*                     superblocks that dropped their device claim")       *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Devs,            \* block devices
    Sbs,             \* superblocks; each one also names its filesystem task
    NSlots,          \* struct super_dev allocations available (a fresh one per kzalloc)
    FsCfg,           \* [Sbs -> [main, xmode, xdev, onfail, dropx, umount, mayfail]]
    Freezers,        \* [freezer task -> Devs]
    Cursors,         \* [cursor task -> Devs]
    Dups,            \* [dup task -> [sb, after]]: after: start once the filesystem dropped its claim
    FIX_RCU_FREE,
    FIX_NEXT_PIN,
    FIX_PUBLISH_FIRST,
    FIX_DENY,
    FIX_FIRST_MATCH,
    FIX_UNBORN_WAIT

NIL == 0
NoDev == "nodev"
NoSb == "nosb"
Slots == 1..NSlots
FsP == Sbs
FrP == DOMAIN Freezers
CuP == DOMAIN Cursors
DuP == DOMAIN Dups
Procs == FsP \cup FrP \cup CuP \cup DuP
Main(s) == FsCfg[s].main
Xdev(s) == FsCfg[s].xdev
HasX(s) == FsCfg[s].xmode # "none"

ASSUME /\ \A s \in Sbs : /\ FsCfg[s].main \in Devs
                         /\ FsCfg[s].xmode \in {"none", "mount", "live"}
                         /\ FsCfg[s].xmode # "none" => FsCfg[s].xdev \in Devs \ {FsCfg[s].main}
                         /\ FsCfg[s].onfail \in {"fail", "degraded"}
                         /\ FsCfg[s].dropx \in {"no", "early", "live"}
                         /\ FsCfg[s].dropx = "early" => FsCfg[s].xmode = "mount"
                         /\ FsCfg[s].dropx = "live" => FsCfg[s].xmode # "none"
                         /\ FsCfg[s].umount \in BOOLEAN
                         /\ FsCfg[s].mayfail \in BOOLEAN
       /\ \A f \in FrP : Freezers[f] \in Devs
       /\ \A c \in CuP : Cursors[c] \in Devs
       /\ \A x \in DuP : Dups[x].sb \in Sbs /\ HasX(Dups[x].sb) /\ Dups[x].after \in BOOLEAN
       /\ \A f, g \in FrP : f # g => Freezers[f] # Freezers[g]   \* bd_fsfreeze_mutex: one freezer per device
       /\ FsP \cap (FrP \cup CuP \cup DuP) = {} /\ FrP \cap CuP = {} /\ FrP \cap DuP = {} /\ CuP \cap DuP = {}

VARIABLES
    L,        \* [Procs -> locals]: pc, ret (return of register/unregister/walk), pret (return of
              \* super_dev_put()), dev, sb (arguments), res, pos (reader position), fnd (lookup
              \* result), pin (the entry a cursor holds), nxt, frm (super_dev_next() pending put),
              \* ne (the entry being inserted), pe (the entry being put), ph (walk phase), cnt,
              \* perr, rdc (bd_fsfreeze_count read early), vis, stab (ghosts of the walk)
    E,        \* [Slots -> entry]: st ("free", "alloc", "linked", "unlinked", "rcu", "freed"),
              \* dev, sb, ref (sd_ref), next (sd_node.next), gp (readers kfree_rcu waits for),
              \* pass (0: passive reference not taken, 1: held, 2: dropped)
    head,     \* [Devs -> Slots \cup {NIL}]: the first node of the device's duplicate list
    S,        \* [Sbs -> sb]: ph ("none", "nascent", "born", "dying", "dead", "freed"), pass
              \* (s_passive), act (s_active), um (s_umount owner: "free", "fs" or a cursor),
              \* sget (s_super_dev), own (the alloc_super() passive reference not yet put)
    use,      \* [Sbs -> [Devs -> BOOLEAN]]: the filesystem uses the device (a claim it kept)
    bdOpen,   \* [Devs -> Nat]: open holders with fs_holder_ops (bd_holder_ops != NULL)
    bdc,      \* [Devs -> Int]: bd_fsfreeze_count (negative: deniers)
    ucount,   \* [Sbs -> Nat]: s_writers.freeze_ucount, the bdev freezes are userspace holders
    fvia,     \* [Sbs -> [Devs -> Nat]]: ghost, freezes of the superblock taken through each device
    xst,      \* [Sbs -> 0..2]: the filesystem started registering its extra device (1), started
              \* dropping it (2); the dups wait for it
    rcu,      \* tasks inside rcu_read_lock()
    err       \* violations found by the actions

vars == <<L, E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

-----------------------------------------------------------------------------
(* Helpers *)

FreshE == [st |-> "free", dev |-> NoDev, sb |-> NoSb, ref |-> 0, next |-> NIL, gp |-> {}, pass |-> 0]
FreshL(lbl) == [pc |-> lbl, ret |-> "none", pret |-> "none", dev |-> NoDev, sb |-> NoSb,
                res |-> "none", pos |-> NIL, fnd |-> NIL, pin |-> NIL, nxt |-> NIL, frm |-> FALSE,
                ne |-> NIL, pe |-> NIL, ph |-> "none", cnt |-> 0, perr |-> FALSE, rdc |-> 0,
                vis |-> {}, stab |-> {}, hold |-> FALSE, wsb |-> NoSb, wfrom |-> NIL]

FreeSlots == {e \in Slots : E[e].st = "free"}
NewSlot == CHOOSE e \in FreeSlots : \A x \in FreeSlots : e <= x

RECURSIVE Chain(_, _)
Chain(x, n) == IF x = NIL \/ n = 0 THEN <<>> ELSE <<x>> \o Chain(E[x].next, n - 1)
Listed(d) == LET c == Chain(head[d], NSlots + 1) IN {c[i] : i \in 1..Len(c)}
ChainLen(d) == Len(Chain(head[d], NSlots + 1))

\* the linked predecessor of e in its device's list (the store rhltable_remove() makes)
Preds(e) == {q \in Slots : E[q].st = "linked" /\ E[q].next = e}

\* leave an RCU read section: no longer holds up any pending kfree_rcu()
ExitRcu(p, e0) == [e \in Slots |-> [e0[e] EXCEPT !.gp = @ \ {p}]]

Goto(p, lbl) == L' = [L EXCEPT ![p].pc = lbl]

Kind(p) == IF p \in FsP THEN "fs" ELSE IF p \in FrP THEN "frz" ELSE IF p \in CuP THEN "cur" ELSE "dup"

\* the superblock the cursor holds s_umount and its own passive reference on
\* passive references taken by cursors after the pinned entry kept the superblock (user_get_super())
CurPass(s) == Cardinality({c \in CuP : L[c].hold /\ L[c].sb = s})
\* passive references taken by walks waiting for an unborn superblock (FIX_UNBORN_WAIT)
WaitPass(s) == Cardinality({c \in Procs : L[c].wsb = s})

Flag(msg) == err' = err \cup {msg}

-----------------------------------------------------------------------------
Init ==
    /\ L = [p \in Procs |-> FreshL(CASE p \in FsP -> "fs_alloc"
                                     [] p \in FrP -> "F_bdf"
                                     [] p \in CuP -> "C_start"
                                     [] OTHER -> "D_start")]
    /\ E = [e \in Slots |-> FreshE]
    /\ head = [d \in Devs |-> NIL]
    /\ S = [s \in Sbs |-> [ph |-> "none", pass |-> 0, act |-> 0, um |-> "free", sget |-> NIL, own |-> 0]]
    /\ use = [s \in Sbs |-> [d \in Devs |-> FALSE]]
    /\ bdOpen = [d \in Devs |-> 0]
    /\ bdc = [d \in Devs |-> 0]
    /\ ucount = [s \in Sbs |-> 0]
    /\ fvia = [s \in Sbs |-> [d \in Devs |-> 0]]
    /\ xst = [s \in Sbs |-> 0]
    /\ rcu = {}
    /\ err = {}

-----------------------------------------------------------------------------
(***************************************************************************)
(* super_dev_put() (fs/super.c L466): P1 refcount_dec_and_test() L469,    *)
(* P2 rhltable_remove() L470, P3 put_super(sd_sb) L471 + kfree_rcu() L472. *)
(* The caller sets pe and pret.                                            *)
(***************************************************************************)
P1(p) ==
    /\ L[p].pc = "P1"
    /\ LET e == L[p].pe IN
       IF e = NIL
       THEN /\ L' = [L EXCEPT ![p].pc = L[p].pret]      \* super_dev_put(NULL)
            /\ UNCHANGED <<E, head, S, err>>
       ELSE IF E[e].st = "freed"
       THEN /\ Flag("UAF: super_dev_put() on a freed entry")
            /\ L' = [L EXCEPT ![p].pc = L[p].pret, ![p].pe = NIL]
            /\ UNCHANGED <<E, head, S>>
       ELSE IF E[e].ref = 0
       THEN /\ Flag("refcount underflow: super_dev_put() of an entry at zero")
            /\ L' = [L EXCEPT ![p].pc = L[p].pret, ![p].pe = NIL]  \* refcount_t saturates
            /\ UNCHANGED <<E, head, S>>
       ELSE /\ E' = [E EXCEPT ![e].ref = @ - 1]
            /\ L' = [q \in Procs |->
                       IF q = p THEN [L[p] EXCEPT !.pc = IF E[e].ref = 1 THEN "P2" ELSE L[p].pret,
                                                  !.pe = IF E[e].ref = 1 THEN e ELSE NIL]
                       ELSE IF E[e].ref = 1 THEN [L[q] EXCEPT !.stab = @ \ {e}] ELSE L[q]]
            /\ UNCHANGED <<head, S, err>>
    /\ UNCHANGED <<use, bdOpen, bdc, ucount, fvia, xst, rcu>>

P2(p) ==
    /\ L[p].pc = "P2"
    /\ LET e == L[p].pe
           d == E[e].dev IN
       IF head[d] = e
       THEN /\ head' = [head EXCEPT ![d] = E[e].next]
            /\ E' = [E EXCEPT ![e].st = "unlinked"]
            /\ UNCHANGED err
       ELSE IF Preds(e) = {}
       THEN /\ Flag("rhltable_remove(): entry not in its list")
            /\ E' = [E EXCEPT ![e].st = "unlinked"]
            /\ UNCHANGED head
       ELSE LET q == CHOOSE q \in Preds(e) : TRUE IN
            /\ E' = [E EXCEPT ![q].next = E[e].next, ![e].st = "unlinked"]
            /\ UNCHANGED <<head, err>>
    /\ Goto(p, "P3")
    /\ UNCHANGED <<S, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

P3(p) ==
    /\ L[p].pc = "P3"
    /\ LET e == L[p].pe
           s == E[e].sb IN
       /\ S' = [S EXCEPT ![s].pass = @ - 1,
                         ![s].ph = IF S[s].pass = 1 THEN "freed" ELSE @]
       /\ E' = [E EXCEPT ![e].pass = 2,
                         ![e].st = IF FIX_RCU_FREE THEN "rcu" ELSE "freed",
                         ![e].gp = IF FIX_RCU_FREE THEN rcu ELSE {}]
       /\ IF E[e].pass # 1 THEN Flag("passive reference of an entry dropped twice or never taken")
          ELSE IF S[s].pass < 1 THEN Flag("s_passive underflow")
          ELSE UNCHANGED err
    /\ L' = [L EXCEPT ![p].pc = L[p].pret, ![p].pe = NIL]
    /\ UNCHANGED <<head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

\* kfree_rcu() callback: every reader that was inside a read section at kfree_rcu() has left
RcuFree(e) ==
    /\ E[e].st = "rcu"
    /\ E[e].gp = {}
    /\ E' = [E EXCEPT ![e].st = "freed"]
    /\ UNCHANGED <<L, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* super_dev_lookup() (L1636): rhltable_lookup() L1645, then              *)
(* rhl_for_each_entry_rcu() L1646 for the first entry with sd_sb == sb.    *)
(* Shared by fs_bdev_register() (R) and fs_bdev_unregister() (U).          *)
(* Reads the entry's sd_sb under RCU: the entry must not be freed.         *)
(***************************************************************************)
LookStep(p, next_lbl) ==
    LET x == L[p].pos IN
    IF x = NIL
    THEN /\ Goto(p, next_lbl)
         /\ UNCHANGED err
    ELSE IF E[x].st = "freed"
    THEN /\ Flag("UAF: super_dev_lookup() reads a freed entry")
         /\ Goto(p, next_lbl)
    ELSE IF E[x].sb = L[p].sb
    THEN IF FIX_FIRST_MATCH
         THEN /\ L' = [L EXCEPT ![p].fnd = x, ![p].pc = next_lbl]
              /\ UNCHANGED err
         ELSE /\ L' = [L EXCEPT ![p].fnd = x, ![p].pos = E[x].next]   \* keep the last match
              /\ UNCHANGED err
    ELSE /\ L' = [L EXCEPT ![p].pos = E[x].next]
         /\ UNCHANGED err

(***************************************************************************)
(* fs_bdev_register() (L1654); called with dev, sb, ret.                   *)
(*   R0  scoped_guard(rcu) L1660, rhltable_lookup() reads the head         *)
(*   R1  super_dev_lookup() L1661                                          *)
(*   R2  refcount_inc_not_zero() L1662: share the entry, return 0          *)
(*   R3  super_dev_alloc() L1668 (FIX_PUBLISH_FIRST off: the count is read *)
(*       here, before the insert)                                          *)
(*   R4  super_dev_insert() -> rhltable_insert() L486: in front            *)
(*   R5  refcount_inc(&sd_sb->s_passive) L488                              *)
(*   R6  smp_mb() L1677, atomic_read(bd_fsfreeze_count) > 0 L1678:         *)
(*       -EBUSY and super_dev_put() L1680                                  *)
(***************************************************************************)
R0(p) ==
    /\ L[p].pc = "R0"
    /\ rcu' = rcu \cup {p}
    /\ L' = [L EXCEPT ![p].pos = head[L[p].dev], ![p].fnd = NIL, ![p].pc = "R1"]
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, err>>

R1(p) ==
    /\ L[p].pc = "R1"
    /\ LookStep(p, "R2")
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

R2(p) ==
    /\ L[p].pc = "R2"
    /\ rcu' = rcu \ {p}
    /\ LET f == L[p].fnd IN
       IF f # NIL /\ E[f].ref > 0
       THEN /\ E' = ExitRcu(p, [E EXCEPT ![f].ref = @ + 1])
            /\ L' = [L EXCEPT ![p].res = "ok", ![p].pos = NIL, ![p].fnd = NIL, ![p].pc = L[p].ret]
       ELSE /\ E' = ExitRcu(p, E)
            /\ L' = [L EXCEPT ![p].pos = NIL, ![p].fnd = NIL, ![p].pc = "R3"]
    /\ UNCHANGED <<head, S, use, bdOpen, bdc, ucount, fvia, xst, err>>

R3(p) ==
    /\ L[p].pc = "R3"
    /\ IF FreeSlots = {}
       THEN /\ Flag("model: out of entry slots")
            /\ Goto(p, "Done")
            /\ UNCHANGED E
       ELSE LET e == NewSlot IN
            /\ E' = [E EXCEPT ![e] = [FreshE EXCEPT !.st = "alloc", !.dev = L[p].dev,
                                                    !.sb = L[p].sb, !.ref = 1]]
            /\ L' = [L EXCEPT ![p].ne = e, ![p].pc = "R4",
                              ![p].rdc = IF FIX_PUBLISH_FIRST THEN 0 ELSE bdc[L[p].dev]]
            /\ UNCHANGED err
    /\ UNCHANGED <<head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

R4(p) ==
    /\ L[p].pc = "R4"
    /\ LET e == L[p].ne
           d == L[p].dev IN
       /\ E' = [E EXCEPT ![e].next = head[d], ![e].st = "linked"]
       /\ head' = [head EXCEPT ![d] = e]
    /\ Goto(p, "R5")
    /\ UNCHANGED <<S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

R5(p) ==
    /\ L[p].pc = "R5"
    /\ LET e == L[p].ne
           s == L[p].sb IN
       /\ S' = [S EXCEPT ![s].pass = @ + 1]
       /\ E' = [E EXCEPT ![e].pass = 1]
       /\ IF S[s].pass < 1 \/ S[s].ph = "freed"
          THEN Flag("refcount_inc(s_passive) from zero in super_dev_insert()")
          ELSE UNCHANGED err
    /\ Goto(p, "R6")
    /\ UNCHANGED <<head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

R6(p) ==
    /\ L[p].pc = "R6"
    /\ LET c == IF FIX_PUBLISH_FIRST THEN bdc[L[p].dev] ELSE L[p].rdc IN
       IF c > 0
       THEN L' = [L EXCEPT ![p].res = "busy", ![p].pe = L[p].ne, ![p].ne = NIL,
                           ![p].pret = L[p].ret, ![p].pc = "P1"]
       ELSE L' = [L EXCEPT ![p].res = "ok", ![p].ne = NIL, ![p].pc = L[p].ret]
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

(***************************************************************************)
(* fs_bdev_unregister() (L1766); called with dev, sb, ret.                 *)
(*   U0  rcu_read_lock() L1771, rhltable_lookup() reads the head           *)
(*   U1  super_dev_lookup() L1772, no reference taken                      *)
(*   U2  rcu_read_unlock() L1773, then super_dev_put() L1774               *)
(***************************************************************************)
U0(p) ==
    /\ L[p].pc = "U0"
    /\ rcu' = rcu \cup {p}
    /\ L' = [L EXCEPT ![p].pos = head[L[p].dev], ![p].fnd = NIL, ![p].pc = "U1"]
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, err>>

U1(p) ==
    /\ L[p].pc = "U1"
    /\ LookStep(p, "U2")
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

U2(p) ==
    /\ L[p].pc = "U2"
    /\ rcu' = rcu \ {p}
    /\ E' = ExitRcu(p, E)
    /\ L' = [L EXCEPT ![p].pe = L[p].fnd, ![p].pret = L[p].ret, ![p].pos = NIL,
                      ![p].fnd = NIL, ![p].pc = "P1"]
    /\ IF L[p].fnd = NIL THEN Flag("fs_bdev_unregister() found no entry for a claim")
       ELSE UNCHANGED err
    /\ UNCHANGED <<head, S, use, bdOpen, bdc, ucount, fvia, xst>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* The cursor: super_dev_first() L521 / super_dev_next() L531 with         *)
(* super_dev_get() L509.  Called with dev, ph, ret.                        *)
(*   W0  rcu_read_lock() L525, rhltable_lookup() reads the head            *)
(*   W1  super_dev_get(): refcount_inc_not_zero() L515 or ->next L513;     *)
(*       rcu_read_unlock() L527/L537 once found or at the end             *)
(*   W2  super_dev_next(): super_dev_put(prev) L539 after the next is     *)
(*       pinned                                                            *)
(*   W3  the loop body of the caller, or the end of the loop               *)
(*   WN  super_dev_next(): rcu_read_lock() L535, prev->sd_node.next L536   *)
(*       (FIX_NEXT_PIN off: super_dev_put(prev) first, WN2 reads ->next)   *)
(* Ghosts: vis (entries visited), stab (entries live, i.e. linked with a  *)
(* non-zero count, from the start of the walk on; P1 removes an entry the *)
(* moment its count hits zero) -- the walk must visit all of stab once.   *)
(***************************************************************************)
W0(p) ==
    /\ L[p].pc = "W0"
    /\ rcu' = rcu \cup {p}
    /\ L' = [L EXCEPT ![p].pos = head[L[p].dev], ![p].pin = NIL, ![p].nxt = NIL,
                      ![p].frm = FALSE, ![p].wfrom = NIL, ![p].vis = {}, ![p].pc = "W1",
                      ![p].stab = {e \in Slots : E[e].st = "linked" /\ E[e].dev = L[p].dev
                                                 /\ E[e].ref > 0}]
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, err>>

\* FIX_UNBORN_WAIT: the entry of a superblock that is neither SB_BORN nor SB_DYING is not pinned;
\* super_dev_get() takes a passive reference (refcount_inc_not_zero(s_passive)), leaves the read
\* section and waits in WW
W1(p) ==
    /\ L[p].pc = "W1"
    /\ LET x == L[p].pos IN
       IF x = NIL
       THEN /\ rcu' = rcu \ {p}
            /\ E' = ExitRcu(p, E)
            /\ L' = [L EXCEPT ![p].nxt = NIL, ![p].pc = "W2"]
            /\ UNCHANGED <<S, err>>
       ELSE IF E[x].st = "freed"
       THEN /\ Flag("UAF: cursor reads a freed entry")
            /\ rcu' = rcu \ {p}
            /\ E' = ExitRcu(p, E)
            /\ L' = [L EXCEPT ![p].nxt = NIL, ![p].pos = NIL, ![p].pc = "W2"]
            /\ UNCHANGED S
       ELSE IF FIX_UNBORN_WAIT /\ S[E[x].sb].ph = "nascent"
       THEN IF S[E[x].sb].pass > 0
            THEN /\ rcu' = rcu \ {p}
                 /\ E' = ExitRcu(p, E)
                 /\ S' = [S EXCEPT ![E[x].sb].pass = @ + 1]
                 /\ L' = [L EXCEPT ![p].wsb = E[x].sb, ![p].pos = NIL, ![p].pc = "WW"]
                 /\ UNCHANGED err
            ELSE /\ L' = [L EXCEPT ![p].pos = E[x].next]
                 /\ UNCHANGED <<E, S, rcu, err>>
       ELSE IF E[x].ref > 0
       THEN /\ rcu' = rcu \ {p}
            /\ E' = ExitRcu(p, [E EXCEPT ![x].ref = @ + 1])
            /\ L' = [L EXCEPT ![p].nxt = x, ![p].pos = NIL, ![p].pc = "W2"]
            /\ UNCHANGED <<S, err>>
       ELSE /\ L' = [L EXCEPT ![p].pos = E[x].next]
            /\ UNCHANGED <<E, S, rcu, err>>
    /\ UNCHANGED <<head, use, bdOpen, bdc, ucount, fvia, xst>>

\* FIX_UNBORN_WAIT: wait_var_event() for SB_BORN|SB_DYING without a pin, put_super(), then look
\* again from where the walk stands: the head (super_dev_first()) or prev's ->next
\* (super_dev_next(); prev is still pinned unless FIX_NEXT_PIN is off)
WW(p) ==
    /\ L[p].pc = "WW"
    /\ LET s == L[p].wsb
           w == L[p].wfrom IN
       /\ S[s].ph # "nascent"
       /\ S' = [S EXCEPT ![s].pass = @ - 1, ![s].ph = IF S[s].pass = 1 THEN "freed" ELSE @]
       /\ rcu' = rcu \cup {p}
       /\ L' = [L EXCEPT ![p].wsb = NoSb, ![p].pc = "W1",
                         ![p].pos = IF w = NIL THEN head[L[p].dev]
                                    ELSE IF E[w].st = "freed" THEN NIL ELSE E[w].next]
       /\ IF S[s].pass < 1 THEN Flag("s_passive underflow")
          ELSE IF w # NIL /\ E[w].st = "freed"
          THEN Flag("UAF: super_dev_get() reads ->next of a freed prev after the wait")
          ELSE IF w # NIL /\ FIX_NEXT_PIN /\ E[w].st # "linked"
          THEN Flag("super_dev_get(): prev is not linked while pinned")
          ELSE UNCHANGED err
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst>>

W2(p) ==
    /\ L[p].pc = "W2"
    /\ IF L[p].frm
       THEN L' = [L EXCEPT ![p].pe = L[p].pin, ![p].pin = NIL, ![p].pret = "W3",
                           ![p].frm = FALSE, ![p].pc = "P1"]
       ELSE Goto(p, "W3")
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

W3(p) ==
    /\ L[p].pc = "W3"
    /\ LET n == L[p].nxt IN
       IF n = NIL
       THEN /\ L' = [L EXCEPT ![p].pin = NIL, ![p].pc = L[p].ret]
            /\ IF ~(L[p].stab \subseteq L[p].vis)
               THEN Flag("cursor skipped an entry that stayed live through the walk")
               ELSE UNCHANGED err
       ELSE /\ L' = [L EXCEPT ![p].pin = n, ![p].nxt = NIL, ![p].vis = @ \cup {n},
                              ![p].sb = E[n].sb,
                              ![p].pc = CASE L[p].ph = "frz" -> "F_gas"
                                          [] L[p].ph = "thw" -> "T_gas"
                                          [] OTHER -> "C_lock"]
            /\ IF n \in L[p].vis THEN Flag("cursor visited an entry twice")
               ELSE IF E[n].st # "linked" THEN Flag("cursor pinned an unlinked entry")
               ELSE IF FIX_UNBORN_WAIT /\ S[E[n].sb].ph = "nascent"
               THEN Flag("cursor pinned the entry of an unborn superblock")
               ELSE UNCHANGED err
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

WN(p) ==
    /\ L[p].pc = "WN"
    /\ IF FIX_NEXT_PIN
       THEN LET x == L[p].pin IN
            /\ rcu' = rcu \cup {p}
            /\ L' = [L EXCEPT ![p].pos = E[x].next, ![p].frm = TRUE, ![p].wfrom = x, ![p].pc = "W1"]
            /\ IF E[x].st # "linked" THEN Flag("super_dev_next(): prev is not linked while pinned")
               ELSE UNCHANGED err
       ELSE /\ L' = [L EXCEPT ![p].pe = L[p].pin, ![p].pret = "WN2", ![p].pc = "P1"]
            /\ UNCHANGED <<rcu, err>>
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst>>

WN2(p) ==
    /\ L[p].pc = "WN2"
    /\ LET x == L[p].pin IN
       /\ rcu' = rcu \cup {p}
       /\ L' = [L EXCEPT ![p].pos = IF E[x].st = "freed" THEN NIL ELSE E[x].next,
                         ![p].frm = FALSE, ![p].wfrom = x, ![p].pc = "W1"]
       /\ IF E[x].st = "freed" THEN Flag("UAF: super_dev_next() reads ->next of a freed prev")
          ELSE UNCHANGED err
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* get_active_super() (L1201) on the pinned entry's superblock:           *)
(* super_lock_excl() waits for SB_BORN|SB_DYING (wait_var_event L118),    *)
(* fails on SB_DYING, down_write() waits for s_umount; then               *)
(* atomic_inc_not_zero(s_active) L1206 and up_write().                    *)
(***************************************************************************)
GasReady(s) == /\ S[s].ph # "nascent"
               /\ S[s].ph = "born" => S[s].um = "free"

GasStep(p, ok_lbl) ==
    LET s == L[p].sb IN
    /\ GasReady(s)
    /\ IF S[s].ph = "freed" THEN Flag("UAF: get_active_super() on a freed superblock")
       ELSE UNCHANGED err
    /\ IF S[s].ph = "born" /\ S[s].act > 0
       THEN /\ S' = [S EXCEPT ![s].act = @ + 1]
            /\ Goto(p, ok_lbl)
       ELSE /\ Goto(p, "WN")                              \* continue
            /\ UNCHANGED S

(***************************************************************************)
(* bdev_freeze() -> fs_bdev_freeze() and bdev_thaw() -> fs_bdev_thaw()     *)
(* (block/bdev.c L300 and L341; fs/super.c L1557 and L1602).               *)
(***************************************************************************)
F_bdf(p) ==
    /\ L[p].pc = "F_bdf"
    /\ LET d == Freezers[p] IN
       IF bdc[d] < 0                                       \* L307: denied, -EBUSY
       THEN /\ Goto(p, "Done")
            /\ UNCHANGED bdc
       ELSE /\ bdc' = [bdc EXCEPT ![d] = @ + 1]            \* atomic_inc_unless_negative(), a full barrier
            /\ Goto(p, IF bdc[d] + 1 > 1 THEN "F_frozen" ELSE "F_hold")
    /\ UNCHANGED <<E, head, S, use, bdOpen, ucount, fvia, xst, rcu, err>>

\* L316-318: under bd_holder_lock, call ->freeze only if a holder with fs_holder_ops has it open
F_hold(p) ==
    /\ L[p].pc = "F_hold"
    /\ LET d == Freezers[p] IN
       IF bdOpen[d] > 0
       THEN L' = [L EXCEPT ![p].dev = d, ![p].ph = "frz", ![p].cnt = 0, ![p].perr = FALSE,
                           ![p].ret = "F_fend", ![p].pc = "W0"]
       ELSE Goto(p, "F_frozen")                          \* sync_blockdev() only
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

F_gas(p) ==
    /\ L[p].pc = "F_gas"
    /\ GasStep(p, "F_frz")
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

\* fs_super_freeze() -> freeze_super(sb, FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE) L1571:
\* the first freeze keeps an active reference for all freezers; deactivate_super() L1574
\* drops get_active_super()'s; count++ L1575
F_frz(p) ==
    /\ L[p].pc = "F_frz"
    /\ LET s == L[p].sb
           d == L[p].dev IN
       /\ ucount' = [ucount EXCEPT ![s] = @ + 1]
       /\ fvia' = [fvia EXCEPT ![s][d] = @ + 1]
       /\ S' = [S EXCEPT ![s].act = @ - 1 + (IF ucount[s] = 0 THEN 1 ELSE 0)]
       /\ L' = [L EXCEPT ![p].cnt = @ + 1, ![p].pc = "WN"]
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, xst, rcu, err>>

\* L1584-1588: no per-superblock freeze errors are modelled; the device stays frozen
F_fend(p) ==
    /\ L[p].pc = "F_fend"
    /\ Goto(p, "F_frozen")
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* the device is frozen (a dm suspend, a shutdown ioctl); then bdev_thaw()
F_frozen(p) ==
    /\ L[p].pc = "F_frozen"
    /\ Goto(p, "F_bdt")
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

F_bdt(p) ==
    /\ L[p].pc = "F_bdt"
    /\ LET d == Freezers[p] IN
       CASE bdc[d] <= 0 -> /\ Goto(p, "Done")                  \* L349: -EINVAL
                           /\ UNCHANGED bdc
         [] bdc[d] > 1 -> /\ bdc' = [bdc EXCEPT ![d] = @ - 1]   \* L353-355
                          /\ Goto(p, "Done")
         [] OTHER -> /\ IF bdOpen[d] > 0                         \* L359-365
                         THEN L' = [L EXCEPT ![p].dev = d, ![p].ph = "thw", ![p].cnt = 0,
                                             ![p].perr = FALSE, ![p].ret = "T_end", ![p].pc = "W0"]
                         ELSE Goto(p, "T_end")
                     /\ UNCHANGED bdc
    /\ UNCHANGED <<E, head, S, use, bdOpen, ucount, fvia, xst, rcu, err>>

T_gas(p) ==
    /\ L[p].pc = "T_gas"
    /\ GasStep(p, "T_thw")
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

\* fs_super_thaw() -> thaw_super(sb, FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE) L1616:
\* may_unfreeze() needs freeze_ucount > 0, else -EINVAL; the last thaw drops the freezers'
\* active reference (thaw_super_locked() -> deactivate_locked_super()); deactivate_super()
\* L1619; count++ L1620.  A thaw through a device that never froze this superblock takes
\* another device's freeze (fvia ghost).
T_thw(p) ==
    /\ L[p].pc = "T_thw"
    /\ LET s == L[p].sb
           d == L[p].dev IN
       IF ucount[s] > 0
       THEN /\ ucount' = [ucount EXCEPT ![s] = @ - 1]
            /\ IF fvia[s][d] > 0
               THEN /\ fvia' = [fvia EXCEPT ![s][d] = @ - 1]
                    /\ UNCHANGED err
               ELSE LET o == CHOOSE o \in Devs : fvia[s][o] > 0 IN
                    /\ fvia' = [fvia EXCEPT ![s][o] = @ - 1]
                    /\ Flag("thaw through a device took another device's freeze")
            /\ S' = [S EXCEPT ![s].act = @ - 1 - (IF ucount[s] = 1 THEN 1 ELSE 0)]
            /\ L' = [L EXCEPT ![p].cnt = @ + 1, ![p].pc = "WN"]
       ELSE /\ S' = [S EXCEPT ![s].act = @ - 1]
            /\ L' = [L EXCEPT ![p].cnt = @ + 1, ![p].perr = TRUE, ![p].pc = "WN"]
            /\ UNCHANGED <<ucount, fvia, err>>
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, xst, rcu>>

\* L1624-1625 (a shared device swallows the error), bdev_thaw() L367-368; then the balance:
\* the device is thawed and no superblock keeps a freeze taken through it
T_end(p) ==
    /\ L[p].pc = "T_end"
    /\ LET d == Freezers[p]
           e == L[p].perr /\ L[p].cnt <= 1
           nb == IF e THEN bdc[d] ELSE bdc[d] - 1 IN
       /\ bdc' = [bdc EXCEPT ![d] = nb]
       /\ err' = err \cup (IF nb # 0 THEN {"bdev_thaw() failed: the device stays frozen for good"} ELSE {})
                     \cup (IF \E s \in Sbs : fvia[s][d] > 0
                           THEN {"a freeze taken through the device outlives its thaw"} ELSE {})
       /\ Goto(p, "Done")
    /\ UNCHANGED <<E, head, S, use, bdOpen, ucount, fvia, xst, rcu>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* user_get_super() (L1043): the walk; super_lock() L1050 (wait for        *)
(* SB_BORN|SB_DYING, fail on SB_DYING, take s_umount); refcount_inc(       *)
(* s_passive) L1054; super_dev_put() L1055; the caller uses the sb and     *)
(* drop_super() L923 / drop_super_exclusive() L931.                         *)
(***************************************************************************)
C_start(p) ==
    /\ L[p].pc = "C_start"
    /\ L' = [L EXCEPT ![p].dev = Cursors[p], ![p].ph = "ugs", ![p].ret = "Done", ![p].pc = "W0"]
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

C_lock(p) ==
    /\ L[p].pc = "C_lock"
    /\ LET s == L[p].sb IN
       /\ GasReady(s)
       /\ IF S[s].ph = "freed" THEN Flag("UAF: super_lock() on a freed superblock")
          ELSE UNCHANGED err
       /\ IF S[s].ph = "born"
          THEN /\ S' = [S EXCEPT ![s].um = p]
               /\ Goto(p, "C_inc")
          ELSE /\ Goto(p, "WN")
               /\ UNCHANGED S
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

C_inc(p) ==
    /\ L[p].pc = "C_inc"
    /\ LET s == L[p].sb IN
       /\ S' = [S EXCEPT ![s].pass = @ + 1]
       /\ IF S[s].pass < 1 THEN Flag("refcount_inc(s_passive) from zero in user_get_super()")
          ELSE UNCHANGED err
    /\ L' = [L EXCEPT ![p].pc = "C_put", ![p].hold = TRUE]
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

C_put(p) ==
    /\ L[p].pc = "C_put"
    /\ L' = [L EXCEPT ![p].pe = L[p].pin, ![p].pin = NIL, ![p].pret = "C_use", ![p].pc = "P1"]
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

C_use(p) ==
    /\ L[p].pc = "C_use"
    /\ LET s == L[p].sb IN
       IF S[s].ph \in {"dying", "dead", "freed"} \/ S[s].um # p
       THEN Flag("user_get_super() returned a superblock that is going away under s_umount")
       ELSE UNCHANGED err
    /\ Goto(p, "C_drop")
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

C_drop(p) ==
    /\ L[p].pc = "C_drop"
    /\ LET s == L[p].sb IN
       S' = [S EXCEPT ![s].um = "free", ![s].pass = @ - 1,
                      ![s].ph = IF S[s].pass = 1 THEN "freed" ELSE @]
    /\ L' = [L EXCEPT ![p].pc = "Done", ![p].hold = FALSE]
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* The filesystem task of superblock s.                                    *)
(***************************************************************************)
CallReg(p, d, s, r) == L' = [L EXCEPT ![p].dev = d, ![p].sb = s, ![p].ret = r, ![p].pc = "R0"]
CallUnreg(p, d, s, r) == L' = [L EXCEPT ![p].dev = d, ![p].sb = s, ![p].ret = r, ![p].pc = "U0"]
DupsOf(s) == {x \in DuP : Dups[x].sb = s}

\* alloc_super() L323: s_umount held (down_write_nested L351), s_passive 1 L376, s_active 1
\* L377, s_super_dev = super_dev_alloc(0, s) L401 (unregistered)
fs_alloc(p) ==
    /\ L[p].pc = "fs_alloc"
    /\ FreeSlots # {}
    /\ LET e == NewSlot IN
       /\ E' = [E EXCEPT ![e] = [FreshE EXCEPT !.st = "alloc", !.dev = Main(p), !.sb = p, !.ref = 1]]
       /\ S' = [S EXCEPT ![p] = [ph |-> "nascent", pass |-> 1, act |-> 1, um |-> "fs", sget |-> e, own |-> 1]]
    /\ Goto(p, "fs_set")
    /\ UNCHANGED <<head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* set() -> super_dev_register() L493 -> super_dev_insert(): rhltable_insert() L486 (under sb_lock)
fs_set(p) ==
    /\ L[p].pc = "fs_set"
    /\ LET e == S[p].sget
           d == Main(p) IN
       /\ E' = [E EXCEPT ![e].next = head[d], ![e].st = "linked"]
       /\ head' = [head EXCEPT ![d] = e]
    /\ Goto(p, "fs_setpass")
    /\ UNCHANGED <<S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* L488 refcount_inc(&sb->s_passive); sget_fc() publishes the sb and returns it locked
fs_setpass(p) ==
    /\ L[p].pc = "fs_setpass"
    /\ S' = [S EXCEPT ![p].pass = @ + 1]
    /\ E' = [E EXCEPT ![S[p].sget].pass = 1]
    /\ Goto(p, "fs_open")
    /\ UNCHANGED <<head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* setup_bdev_super() L1799 -> fs_bdev_file_open_by_dev(): bdev_file_open_by_dev() with
\* fs_holder_ops, then fs_bdev_register()
fs_open(p) ==
    /\ L[p].pc = "fs_open"
    /\ bdOpen' = [bdOpen EXCEPT ![Main(p)] = @ + 1]
    /\ CallReg(p, Main(p), p, "fs_bdevchk")
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, xst, rcu, err>>

\* fs_bdev_file_open_by_dev() fails -> bdev_fput(); else L1818-1823: smp_mb(), the frozen
\* check, fs_bdev_file_release() -> -EBUSY; else the superblock uses the device
fs_bdevchk(p) ==
    /\ L[p].pc = "fs_bdevchk"
    /\ IF L[p].res = "busy"
       THEN /\ bdOpen' = [bdOpen EXCEPT ![Main(p)] = @ - 1]
            /\ Goto(p, "fs_fail")
            /\ UNCHANGED use
       ELSE IF bdc[Main(p)] > 0
       THEN /\ CallUnreg(p, Main(p), p, "fs_mfput")
            /\ UNCHANGED <<bdOpen, use>>
       ELSE /\ use' = [use EXCEPT ![p][Main(p)] = TRUE]
            /\ Goto(p, "fs_x")
            /\ UNCHANGED bdOpen
    /\ UNCHANGED <<E, head, S, bdc, ucount, fvia, xst, rcu, err>>

\* fs_bdev_file_release(): bdev_fput() after the unregister; the mount fails with -EBUSY
fs_mfput(p) ==
    /\ L[p].pc = "fs_mfput"
    /\ bdOpen' = [bdOpen EXCEPT ![Main(p)] = @ - 1]
    /\ Goto(p, "fs_fail")
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, xst, rcu, err>>

\* fill_super(): an extra member device opened during the mount (xmode "mount")
fs_x(p) ==
    /\ L[p].pc = "fs_x"
    /\ IF FsCfg[p].xmode = "mount"
       THEN /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ + 1]
            /\ xst' = [xst EXCEPT ![p] = 1]
            /\ CallReg(p, Xdev(p), p, "fs_xchk")
       ELSE /\ Goto(p, "fs_born")
            /\ UNCHANGED <<bdOpen, xst>>
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, rcu, err>>

\* the extra device was refused (-EBUSY, the entry rolled back): bdev_fput(); the mount fails
\* (onfail "fail": xfs, ext4, f2fs, erofs) or goes on without it (onfail "degraded": btrfs
\* open_fs_devices() with -o degraded).  Accepted: kept, or dropped again before SB_BORN.
\* mayfail: fill_super() may fail afterwards anyway.
fs_xchk(p) ==
    /\ L[p].pc = "fs_xchk"
    /\ IF L[p].res = "busy"
       THEN /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
            /\ Goto(p, IF FsCfg[p].onfail = "fail" THEN "fs_fail" ELSE "fs_born")
            /\ UNCHANGED use
       ELSE /\ use' = [use EXCEPT ![p][Xdev(p)] = TRUE]
            /\ Goto(p, IF FsCfg[p].dropx = "early" THEN "fs_xdrop" ELSE "fs_born")
            /\ UNCHANGED bdOpen
    /\ UNCHANGED <<E, head, S, bdc, ucount, fvia, xst, rcu, err>>

fs_xdrop(p) ==
    /\ L[p].pc = "fs_xdrop"
    /\ use' = [use EXCEPT ![p][Xdev(p)] = FALSE]
    /\ xst' = [xst EXCEPT ![p] = 2]
    /\ CallUnreg(p, Xdev(p), p, "fs_xdfput")
    /\ UNCHANGED <<E, head, S, bdOpen, bdc, ucount, fvia, rcu, err>>

fs_xdfput(p) ==
    /\ L[p].pc = "fs_xdfput"
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
    /\ Goto(p, "fs_born")
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, xst, rcu, err>>

\* vfs_get_tree() L1963 super_wake(SB_BORN), fc_mount() up_write(s_umount)
\* (fs/namespace.c L1280); or fill_super() fails (mayfail)
fs_born(p) ==
    /\ L[p].pc = "fs_born"
    /\ \/ /\ S' = [S EXCEPT ![p].ph = "born", ![p].um = "free"]
          /\ Goto(p, "fs_live")
       \/ /\ FsCfg[p].mayfail
          /\ Goto(p, "fs_fail")
          /\ UNCHANGED S
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* the live superblock: btrfs device add (xmode "live") under bdev_deny_freeze() via
\* btrfs_open_device_deny_freeze(), then btrfs device remove (dropx "live") under the deny,
\* released by btrfs_release_device_allow_freeze(); then the unmount
fs_live(p) ==
    /\ L[p].pc = "fs_live"
    /\ IF FsCfg[p].xmode = "live" /\ xst[p] = 0
       THEN /\ xst' = [xst EXCEPT ![p] = 1]
            /\ IF FIX_DENY
               THEN IF bdc[Xdev(p)] > 0                     \* atomic_dec_unless_positive() fails
                    THEN /\ Goto(p, "fs_live2")
                         /\ UNCHANGED <<bdc, bdOpen>>
                    ELSE /\ bdc' = [bdc EXCEPT ![Xdev(p)] = @ - 1]
                         /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ + 1]
                         /\ CallReg(p, Xdev(p), p, "fs_addchk")
               ELSE /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ + 1]
                    /\ CallReg(p, Xdev(p), p, "fs_addchk")
                    /\ UNCHANGED bdc
       ELSE /\ Goto(p, "fs_live2")
            /\ UNCHANGED <<xst, bdc, bdOpen>>
    /\ UNCHANGED <<E, head, S, use, ucount, fvia, rcu, err>>

\* the add went through (the freeze count was negative or zero: no -EBUSY) or was refused;
\* bdev_allow_freeze() once the membership change is done
fs_addchk(p) ==
    /\ L[p].pc = "fs_addchk"
    /\ IF L[p].res = "ok"
       THEN /\ use' = [use EXCEPT ![p][Xdev(p)] = TRUE]
            /\ UNCHANGED bdOpen
       ELSE /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
            /\ UNCHANGED use
    /\ bdc' = IF FIX_DENY THEN [bdc EXCEPT ![Xdev(p)] = @ + 1] ELSE bdc
    /\ Goto(p, "fs_live2")
    /\ UNCHANGED <<E, head, S, ucount, fvia, xst, rcu, err>>

fs_live2(p) ==
    /\ L[p].pc = "fs_live2"
    /\ IF FsCfg[p].dropx = "live" /\ use[p][Xdev(p)]
       THEN IF FIX_DENY
            THEN IF bdc[Xdev(p)] > 0                        \* btrfs_rm_device(): deny fails, -EBUSY
                 THEN /\ Goto(p, "fs_live3")
                      /\ UNCHANGED <<bdc, use>>
                 ELSE /\ bdc' = [bdc EXCEPT ![Xdev(p)] = @ - 1]
                      /\ use' = [use EXCEPT ![p][Xdev(p)] = FALSE]
                      /\ CallUnreg(p, Xdev(p), p, "fs_rmallow")
            ELSE /\ use' = [use EXCEPT ![p][Xdev(p)] = FALSE]
                 /\ CallUnreg(p, Xdev(p), p, "fs_rmallow")
                 /\ UNCHANGED bdc
       ELSE /\ Goto(p, "fs_live3")
            /\ UNCHANGED <<bdc, use>>
    /\ xst' = IF FsCfg[p].dropx = "live" /\ use[p][Xdev(p)] /\ (~FIX_DENY \/ bdc[Xdev(p)] <= 0)
              THEN [xst EXCEPT ![p] = 2] ELSE xst
    /\ UNCHANGED <<E, head, S, bdOpen, ucount, fvia, rcu, err>>

\* btrfs_release_device_allow_freeze(): unregister, bdev_allow_freeze(), bdev_fput()
fs_rmallow(p) ==
    /\ L[p].pc = "fs_rmallow"
    /\ bdc' = IF FIX_DENY THEN [bdc EXCEPT ![Xdev(p)] = @ + 1] ELSE bdc
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
    /\ Goto(p, "fs_live3")
    /\ UNCHANGED <<E, head, S, use, ucount, fvia, xst, rcu, err>>

\* umount: deactivate_super() L610 for the last active reference: s_umount, s_active -> 0
\* L584 (a freezer's or the freeze's active reference keeps the superblock alive instead;
\* the model lets the filesystem task wait for them, the kill is the same whoever runs it);
\* the dups finish before ->put_super() closes the devices
fs_live3(p) ==
    /\ L[p].pc = "fs_live3"
    /\ IF FsCfg[p].umount
       THEN /\ S[p].act = 1
            /\ S[p].um = "free"
            /\ \A x \in DupsOf(p) : L[x].pc = "Done"
            /\ S' = [S EXCEPT ![p].act = 0, ![p].um = "fs"]
            /\ Goto(p, "fs_relx")
       ELSE /\ Goto(p, "Done")
            /\ UNCHANGED S
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* a failed mount: deactivate_locked_super() with s_umount still held, s_active -> 0
fs_fail(p) ==
    /\ L[p].pc = "fs_fail"
    /\ \A x \in DupsOf(p) : L[x].pc = "Done"
    /\ S' = [S EXCEPT ![p].act = 0]
    /\ Goto(p, "fs_relx")
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* ->kill_sb() -> generic_shutdown_super() -> ->put_super(): the member device is closed
\* (fs_bdev_file_release(): xfs_free_buftarg(), btrfs_close_bdev(), ext4 journal, ...)
fs_relx(p) ==
    /\ L[p].pc = "fs_relx"
    /\ IF HasX(p) /\ use[p][Xdev(p)]
       THEN /\ use' = [use EXCEPT ![p][Xdev(p)] = FALSE]
            /\ CallUnreg(p, Xdev(p), p, "fs_relxput")
       ELSE /\ Goto(p, "fs_dying")
            /\ UNCHANGED use
    /\ UNCHANGED <<E, head, S, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

fs_relxput(p) ==
    /\ L[p].pc = "fs_relxput"
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
    /\ Goto(p, "fs_dying")
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, xst, rcu, err>>

\* generic_shutdown_super() L787-788: super_wake(SB_DYING), super_unlock_excl()
fs_dying(p) ==
    /\ L[p].pc = "fs_dying"
    /\ S' = [S EXCEPT ![p].ph = "dying", ![p].um = "free"]
    /\ Goto(p, "fs_relm")
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* kill_block_super() L1912-1914: fs_bdev_file_release(sb->s_bdev_file) if s_bdev was set
fs_relm(p) ==
    /\ L[p].pc = "fs_relm"
    /\ IF use[p][Main(p)]
       THEN /\ use' = [use EXCEPT ![p][Main(p)] = FALSE]
            /\ CallUnreg(p, Main(p), p, "fs_relmput")
       ELSE /\ Goto(p, "fs_notify")
            /\ UNCHANGED use
    /\ UNCHANGED <<E, head, S, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

fs_relmput(p) ==
    /\ L[p].pc = "fs_relmput"
    /\ bdOpen' = [bdOpen EXCEPT ![Main(p)] = @ - 1]
    /\ Goto(p, "fs_notify")
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, xst, rcu, err>>

\* deactivate_locked_super() L588 -> kill_super_notify() L551-554: super_dev_put(s_super_dev)
fs_notify(p) ==
    /\ L[p].pc = "fs_notify"
    /\ L' = [L EXCEPT ![p].pe = S[p].sget, ![p].pret = "fs_dead", ![p].pc = "P1"]
    /\ S' = [S EXCEPT ![p].sget = NIL]
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

\* L565-567: super_wake(SB_DEAD) under sb_lock
fs_dead(p) ==
    /\ L[p].pc = "fs_dead"
    /\ S' = [S EXCEPT ![p].ph = IF S[p].ph = "freed" THEN "freed" ELSE "dead"]
    /\ IF S[p].ph = "freed" THEN Flag("superblock freed before SB_DEAD")
       ELSE UNCHANGED err
    /\ Goto(p, "fs_put")
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

\* L594 put_super(): the alloc_super() reference
fs_put(p) ==
    /\ L[p].pc = "fs_put"
    /\ S' = [S EXCEPT ![p].pass = @ - 1, ![p].own = 0,
                      ![p].ph = IF S[p].pass = 1 THEN "freed" ELSE @]
    /\ IF S[p].pass < 1 THEN Flag("s_passive underflow") ELSE UNCHANGED err
    /\ Goto(p, "Done")
    /\ UNCHANGED <<E, head, use, bdOpen, bdc, ucount, fvia, xst, rcu>>

-----------------------------------------------------------------------------
(* A second registration of the same (device, superblock). *)
D_start(p) ==
    /\ L[p].pc = "D_start"
    /\ LET s == Dups[p].sb IN
       /\ xst[s] >= (IF Dups[p].after THEN 2 ELSE 1)
       /\ S[s].ph \in {"nascent", "born"}
       /\ bdOpen' = [bdOpen EXCEPT ![Xdev(s)] = @ + 1]
       /\ CallReg(p, Xdev(s), s, "D_reg")
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, xst, rcu, err>>

D_reg(p) ==
    /\ L[p].pc = "D_reg"
    /\ IF L[p].res = "ok"
       THEN CallUnreg(p, Xdev(Dups[p].sb), Dups[p].sb, "D_fput")
       ELSE Goto(p, "D_fput")
    /\ UNCHANGED <<E, head, S, use, bdOpen, bdc, ucount, fvia, xst, rcu, err>>

D_fput(p) ==
    /\ L[p].pc = "D_fput"
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(Dups[p].sb)] = @ - 1]
    /\ Goto(p, "Done")
    /\ UNCHANGED <<E, head, S, use, bdc, ucount, fvia, xst, rcu, err>>

-----------------------------------------------------------------------------
AllDone == \A p \in Procs : L[p].pc = "Done"
Quiet == AllDone /\ \A e \in Slots : E[e].st # "rcu"

\* the end: every task finished and every kfree_rcu() ran; stutter
Finished ==
    /\ Quiet
    /\ UNCHANGED vars

Step(p) ==
    \/ P1(p) \/ P2(p) \/ P3(p)
    \/ R0(p) \/ R1(p) \/ R2(p) \/ R3(p) \/ R4(p) \/ R5(p) \/ R6(p)
    \/ U0(p) \/ U1(p) \/ U2(p)
    \/ W0(p) \/ W1(p) \/ W2(p) \/ W3(p) \/ WN(p) \/ WN2(p) \/ WW(p)
    \/ F_bdf(p) \/ F_hold(p) \/ F_gas(p) \/ F_frz(p) \/ F_fend(p) \/ F_frozen(p) \/ F_bdt(p)
    \/ T_gas(p) \/ T_thw(p) \/ T_end(p)
    \/ C_start(p) \/ C_lock(p) \/ C_inc(p) \/ C_put(p) \/ C_use(p) \/ C_drop(p)
    \/ fs_alloc(p) \/ fs_set(p) \/ fs_setpass(p) \/ fs_open(p) \/ fs_bdevchk(p) \/ fs_mfput(p)
    \/ fs_x(p) \/ fs_xchk(p) \/ fs_xdrop(p) \/ fs_xdfput(p) \/ fs_born(p) \/ fs_live(p)
    \/ fs_addchk(p) \/ fs_live2(p) \/ fs_rmallow(p) \/ fs_live3(p) \/ fs_fail(p)
    \/ fs_relx(p) \/ fs_relxput(p) \/ fs_dying(p) \/ fs_relm(p) \/ fs_relmput(p)
    \/ fs_notify(p) \/ fs_dead(p) \/ fs_put(p)
    \/ D_start(p) \/ D_reg(p) \/ D_fput(p)

Next ==
    \/ \E p \in Procs : Step(p)
    \/ \E e \in Slots : RcuFree(e)
    \/ Finished

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

TypeOK ==
    /\ \A e \in Slots : /\ E[e].st \in {"free", "alloc", "linked", "unlinked", "rcu", "freed"}
                        /\ E[e].ref \in Nat /\ E[e].pass \in 0..2
                        /\ E[e].next \in Slots \cup {NIL}
    /\ \A d \in Devs : head[d] \in Slots \cup {NIL}
    /\ \A s \in Sbs : S[s].ph \in {"none", "nascent", "born", "dying", "dead", "freed"}

NoErr == err = {}

\* only the refcount underflow (to get its trace past other errors of the same run)
NoUnderflow == "refcount underflow: super_dev_put() of an entry at zero" \notin err

\* the lists are what rhltable_insert()/rhltable_remove() made them: acyclic, exactly the
\* linked entries of the device
ListOK == \A d \in Devs : /\ ChainLen(d) <= NSlots
                          /\ Listed(d) = {e \in Slots : E[e].st = "linked" /\ E[e].dev = d}

\* "Unlink only once unpinned": a counted entry is linked (or being inserted)
RefLinked == \A e \in Slots : E[e].ref > 0 => E[e].st \in {"alloc", "linked"}

\* no task can reach a freed entry: a reader's position or a pinned/found entry is not freed
NoFreedReach ==
    \A p \in Procs : \A x \in {L[p].pos, L[p].pin, L[p].fnd, L[p].pe, L[p].ne} \ {NIL} :
        E[x].st # "freed" \/ L[p].pc = "Done"

\* the passive reference count adds up: alloc_super()'s own, one per registered entry, one per
\* cursor between user_get_super()'s refcount_inc() and drop_super(), one per walk waiting for
\* the superblock to be born
PassLedger == \A s \in Sbs : S[s].ph \notin {"none", "freed"} =>
    S[s].pass = S[s].own + Cardinality({e \in Slots : E[e].sb = s /\ E[e].pass = 1}) + CurPass(s)
                + WaitPass(s)

\* an entry holding a passive reference keeps its superblock
EntryKeepsSb == \A e \in Slots : E[e].pass = 1 => S[E[e].sb].ph # "freed"

\* while a freezer has the device frozen (its walk done), every live superblock that uses the
\* device is frozen: nobody writes to a frozen device
FrozenCovers == \A f \in FrP : L[f].pc = "F_frozen" /\ bdc[Freezers[f]] > 0 =>
    \A s \in Sbs : (S[s].ph = "born" /\ use[s][Freezers[f]]) => ucount[s] > 0

\* reachability witnesses, expected to be violated: a walk waits for an unborn superblock
\* (FIX_UNBORN_WAIT), and does so with prev pinned (it looks again from prev)
NoUnbornWait == \A p \in Procs : L[p].pc # "WW"
NoUnbornWaitFromPrev == \A p \in Procs : ~(L[p].pc = "WW" /\ L[p].wfrom # NIL)

\* the end: no entry or superblock leaked by an unmounted filesystem
NoLeak == Quiet => /\ \A s \in Sbs : FsCfg[s].umount => S[s].ph \in {"freed", "none"}
                   /\ \A e \in Slots : E[e].st # "free" =>
                          (FsCfg[E[e].sb].umount => E[e].st = "freed")
=============================================================================

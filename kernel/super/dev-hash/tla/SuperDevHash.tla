---------------------------- MODULE SuperDevHash ----------------------------
(***************************************************************************)
(* The device-to-superblock table of work.super.dev_hash (de417b144a46 on *)
(* 587d78169911): struct super_dev entries {sd_hash, sd_sb, sd_dev,       *)
(* sd_claims} in DEFINE_HASHTABLE(super_dev_hash) under super_dev_lock,   *)
(* the entry for s_dev embedded in struct super_block, the cursors the     *)
(* walks keep their place with, and the block layer's freeze counter.     *)
(*                                                                         *)
(* Every access to the table happens under super_dev_lock and nothing in   *)
(* a locked section sleeps, so each locked section is one step.  The hash  *)
(* is abstracted to one chain per device: lookups and walks skip the       *)
(* entries of other devices and hash_add()/hash_del() never move an entry. *)
(* hash_add() adds at the head.  A cursor is an entry without a           *)
(* superblock: super_dev_next() adds it at the head on its first call,     *)
(* keeps it right behind the claim it returned last and deletes it when    *)
(* the walk ends.                                                          *)
(*                                                                         *)
(* Tasks:                                                                  *)
(*   one filesystem task per superblock (the name of the superblock):     *)
(*     alloc_super(), sget_fc() hashing the embedded entry for s_dev,      *)
(*     setup_bdev_super() -> fs_bdev_file_open_by_dev() ->                 *)
(*     fs_bdev_register() of the main device and the frozen check of       *)
(*     setup_bdev_super(), optionally an extra member device registered    *)
(*     during the mount (xmode "mount": xfs log/rt, ext4 journal, f2fs,    *)
(*     erofs blobs, btrfs) or after it under bdev_deny_freeze() (xmode     *)
(*     "live": btrfs device add), optionally released again before SB_BORN *)
(*     while the mount goes on (dropx "early": btrfs                       *)
(*     __btrfs_free_extra_devids()) or from the live superblock under the  *)
(*     deny (dropx "live": btrfs device remove), SB_BORN, and the unmount: *)
(*     ->put_super() closing the member device, SB_DYING, kill_block_super *)
(*     releasing the main device, kill_super_notify() dropping sget_fc()'s *)
(*     claim, SB_DEAD, put_super()                                         *)
(*   freezers: bdev_freeze() -> fs_bdev_freeze(), then bdev_thaw() ->      *)
(*     fs_bdev_thaw() on one device                                       *)
(*   cursors: user_get_super() on one device                              *)
(*   dups: a second fs_bdev_register()/fs_bdev_unregister() of a         *)
(*     superblock's extra device, concurrent with the filesystem's own or  *)
(*     once the filesystem started dropping its claim (a re-add)          *)
(*                                                                         *)
(* Mutations (each FIX_* off is a known-bad shape, for the red witnesses): *)
(*   FIX_RELOOK        off: the walk commits to the claim of a superblock  *)
(*                     that is not born yet and waits for SB_BORN after    *)
(*                     that (the fc1c25014ff8 shape, minus the pin)       *)
(*   FIX_CURSOR        off: no cursor; the walk resumes behind the entry   *)
(*                     it returned last, which nothing keeps hashed       *)
(*   FIX_CHECK_LOCKED  off: fs_bdev_register() reads bd_fsfreeze_count    *)
(*                     before it takes super_dev_lock                     *)
(*   FIX_ATOMIC_CLAIM  off: fs_bdev_register() drops the lock between the  *)
(*                     lookup and the insert                              *)
(*   FIX_DENY          off: live membership changes do not deny freezes    *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Devs,            \* block devices
    Sbs,             \* superblocks; each one also names its filesystem task
    EmbOf,           \* [Sbs -> Nat]: the id of the entry embedded in the superblock (s_super_dev)
    Alloc,           \* ids of the entries fs_bdev_register() can kzalloc()
    CurOf,           \* [walking tasks -> Nat]: the id of the cursor of each freezer and cursor task
    FsCfg,           \* [Sbs -> [main, xmode, xdev, onfail, dropx, umount, mayfail]]
    Freezers,        \* [freezer task -> Devs]
    Cursors,         \* [cursor task -> Devs]
    Dups,            \* [dup task -> [sb, after]]: after: start once the filesystem dropped its claim
    FIX_RELOOK,
    FIX_CURSOR,
    FIX_CHECK_LOCKED,
    FIX_ATOMIC_CLAIM,
    FIX_DENY

NIL == 0
NoDev == "nodev"
NoSb == "nosb"
FsP == Sbs
FrP == DOMAIN Freezers
CuP == DOMAIN Cursors
DuP == DOMAIN Dups
Procs == FsP \cup FrP \cup CuP \cup DuP
WalkP == FrP \cup CuP
EmbIds == {EmbOf[s] : s \in Sbs}
Ids == EmbIds \cup Alloc
CurIds == {CurOf[p] : p \in WalkP}
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
       /\ DOMAIN EmbOf = Sbs /\ DOMAIN CurOf = WalkP
       /\ \A s, t \in Sbs : s # t => EmbOf[s] # EmbOf[t]
       /\ \A p, q \in WalkP : p # q => CurOf[p] # CurOf[q]
       /\ EmbIds \cap Alloc = {} /\ CurIds \cap Ids = {} /\ NIL \notin Ids \cup CurIds

VARIABLES
    L,        \* [Procs -> locals]: pc, ret (return label of register/unregister/walk), pret (of
              \* super_dev_put()), dev, sb (arguments; the walk's superblock), res, ne (the entry
              \* kzalloc()ed by fs_bdev_register()), fnd (lookup result), pe (the entry being put),
              \* ph (walk phase), cnt, perr, rdc (bd_fsfreeze_count read early), at (the entry
              \* the walk returned), last (FIX_CURSOR off: where the walk resumes), ref (the
              \* superblock the walk holds a passive reference on), hold (user_get_super()
              \* returned the superblock locked), vis, vsb, stab (ghosts of the walk)
    E,        \* [Ids -> entry]: st ("idle": the embedded entry, not hashed; "free": a free
              \* allocation; "alloc": kzalloc()ed, not hashed; "hashed"; "unhashed": hash_del()
              \* done, kfree()/put_super() pending), dev, sb, claims (sd_claims), pass (the
              \* entry's passive reference: 0 not taken, 1 held)
    chain,    \* [Devs -> Seq(ids)]: the device's entries and the cursors of walks on it, head first
    S,        \* [Sbs -> sb]: ph ("none", "nascent", "born", "dying", "dead", "freed"), pass
              \* (s_passive), act (s_active), um (s_umount owner: "free", "fs" or a cursor task),
              \* own (the alloc_super() passive reference not yet put)
    use,      \* [Sbs -> [Devs -> BOOLEAN]]: the filesystem uses the device (a claim it kept)
    bdOpen,   \* [Devs -> Nat]: open holders with fs_holder_ops (bd_holder_ops != NULL)
    bdc,      \* [Devs -> Int]: bd_fsfreeze_count (negative: deniers)
    ucount,   \* [Sbs -> Nat]: s_writers.freeze_ucount, the bdev freezes are userspace holders
    fvia,     \* [Sbs -> [Devs -> Nat]]: ghost, freezes of the superblock taken through each device
    xst,      \* [Sbs -> 0..2]: the filesystem started registering its extra device (1), started
              \* dropping it (2); the dups wait for it
    crossed,  \* ghost: a claim a cursor sat right behind was dropped while the cursor was hashed
    err       \* violations found by the actions

vars == <<L, E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

-----------------------------------------------------------------------------
(* Helpers *)

FreshL(lbl) == [pc |-> lbl, ret |-> "none", pret |-> "none", dev |-> NoDev, sb |-> NoSb,
                res |-> "none", ne |-> NIL, fnd |-> NIL, pe |-> NIL, ph |-> "none", cnt |-> 0,
                perr |-> FALSE, rdc |-> 0, at |-> NIL, last |-> NIL, ref |-> NoSb,
                hold |-> FALSE, vis |-> {}, vsb |-> {}, stab |-> {}]

FreeE == [st |-> "free", dev |-> NoDev, sb |-> NoSb, claims |-> 0, pass |-> 0]
IdleE(s) == [st |-> "idle", dev |-> NoDev, sb |-> s, claims |-> 0, pass |-> 0]

FreeAlloc == {e \in Alloc : E[e].st = "free"}
NewAlloc == CHOOSE e \in FreeAlloc : \A x \in FreeAlloc : e <= x

Goto(p, lbl) == L' = [L EXCEPT ![p].pc = lbl]
Flag(msg) == err' = err \cup {msg}

Min(X) == CHOOSE i \in X : \A j \in X : i <= j
InCh(d, n) == \E i \in 1..Len(chain[d]) : chain[d][i] = n
Drop(sq, n) == SelectSeq(sq, LAMBDA x : x # n)
IdxOf(sq, n) == CHOOSE i \in 1..Len(sq) : sq[i] = n
\* the nodes behind n
After(sq, n) == SubSeq(sq, IdxOf(sq, n) + 1, Len(sq))
\* hlist_add_behind(n, a)
Behind(sq, a, n) == LET i == IdxOf(sq, a) IN SubSeq(sq, 1, i) \o <<n>> \o SubSeq(sq, i + 1, Len(sq))
\* the first entry (not a cursor) of sq
FirstEntry(sq) == LET is == {i \in 1..Len(sq) : sq[i] \notin CurIds} IN
                  IF is = {} THEN NIL ELSE sq[Min(is)]
EntriesOf(d) == {chain[d][i] : i \in 1..Len(chain[d])} \ CurIds
\* super_dev_find(): the hashed entries of (d, s)
Pairs(d, s) == {e \in EntriesOf(d) : E[e].sb = s}

\* passive references of walks: the superblock returned or waited for
WalkPass(s) == Cardinality({p \in Procs : L[p].ref = s})

\* put_super() of a passive reference
PutSb(s, s0) == [s0 EXCEPT ![s].pass = @ - 1, ![s].ph = IF s0[s].pass = 1 THEN "freed" ELSE @]

-----------------------------------------------------------------------------
Init ==
    /\ L = [p \in Procs |-> FreshL(CASE p \in FsP -> "fs_alloc"
                                     [] p \in FrP -> "F_bdf"
                                     [] p \in CuP -> "C_start"
                                     [] OTHER -> "D_start")]
    /\ E = [e \in Ids |-> IF e \in EmbIds THEN IdleE(CHOOSE s \in Sbs : EmbOf[s] = e) ELSE FreeE]
    /\ chain = [d \in Devs |-> <<>>]
    /\ S = [s \in Sbs |-> [ph |-> "none", pass |-> 0, act |-> 0, um |-> "free", own |-> 0]]
    /\ use = [s \in Sbs |-> [d \in Devs |-> FALSE]]
    /\ bdOpen = [d \in Devs |-> 0]
    /\ bdc = [d \in Devs |-> 0]
    /\ ucount = [s \in Sbs |-> 0]
    /\ fvia = [s \in Sbs |-> [d \in Devs |-> 0]]
    /\ xst = [s \in Sbs |-> 0]
    /\ crossed = FALSE
    /\ err = {}

-----------------------------------------------------------------------------
(***************************************************************************)
(* super_dev_put() (fs/super.c L453); the caller sets pe and pret.         *)
(*   P1  under super_dev_lock L458-462: --sd_claims, the last claim        *)
(*       hash_del()s the entry                                            *)
(*   P2  L463-465: kfree() unless it's the embedded entry, put_super()     *)
(***************************************************************************)
P1(p) ==
    /\ L[p].pc = "P1"
    /\ LET e == L[p].pe
           d == E[e].dev IN
       IF E[e].st # "hashed"
       THEN /\ Flag("super_dev_put() of an entry that is not hashed")
            /\ L' = [L EXCEPT ![p].pc = L[p].pret, ![p].pe = NIL]
            /\ UNCHANGED <<E, chain, crossed>>
       ELSE IF E[e].claims > 1
       THEN /\ E' = [E EXCEPT ![e].claims = @ - 1]
            /\ L' = [L EXCEPT ![p].pc = L[p].pret, ![p].pe = NIL]
            /\ UNCHANGED <<chain, crossed, err>>
       ELSE /\ E' = [E EXCEPT ![e].claims = 0, ![e].st = "unhashed"]
            /\ chain' = [chain EXCEPT ![d] = Drop(@, e)]
            /\ crossed' = (crossed \/ \E i \in 1..(Len(chain[d]) - 1) :
                                          chain[d][i] = e /\ chain[d][i + 1] \in CurIds)
            /\ L' = [q \in Procs |-> IF q = p THEN [L[p] EXCEPT !.pc = "P2", !.stab = @ \ {e}]
                                     ELSE [L[q] EXCEPT !.stab = @ \ {e}]]
            /\ UNCHANGED err
    /\ UNCHANGED <<S, use, bdOpen, bdc, ucount, fvia, xst>>

P2(p) ==
    /\ L[p].pc = "P2"
    /\ LET e == L[p].pe
           s == E[e].sb IN
       /\ E' = [E EXCEPT ![e] = IF e \in EmbIds THEN IdleE(s) ELSE FreeE]
       /\ S' = PutSb(s, S)
       /\ IF E[e].pass # 1 THEN Flag("passive reference of an entry dropped twice or never taken")
          ELSE IF S[s].pass < 1 THEN Flag("s_passive underflow")
          ELSE UNCHANGED err
    /\ L' = [L EXCEPT ![p].pc = L[p].pret, ![p].pe = NIL]
    /\ UNCHANGED <<chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* fs_bdev_register() (L1630); called with dev, sb, ret.                   *)
(*   R0  kzalloc_obj() L1635 outside the lock (FIX_CHECK_LOCKED off: the   *)
(*       count is read here)                                              *)
(*   R1  under super_dev_lock L1637: super_dev_find() L1638; a hashed      *)
(*       pair takes one more claim L1640, else the frozen check L1644 and  *)
(*       super_dev_add() L1648 (FIX_ATOMIC_CLAIM off: the lock is dropped  *)
(*       after the lookup and R2 checks and inserts)                      *)
(***************************************************************************)
InsertOrRefuse(p) ==
    LET d == L[p].dev
        s == L[p].sb
        n == L[p].ne
        c == IF FIX_CHECK_LOCKED THEN bdc[d] ELSE L[p].rdc IN
    IF c > 0
    THEN /\ E' = [E EXCEPT ![n] = FreeE]                  \* -EBUSY, __free(kfree)
         /\ L' = [L EXCEPT ![p].res = "busy", ![p].ne = NIL, ![p].pc = L[p].ret]
         /\ UNCHANGED <<chain, S, err>>
    ELSE /\ E' = [E EXCEPT ![n] = [st |-> "hashed", dev |-> d, sb |-> s, claims |-> 1, pass |-> 1]]
         /\ chain' = [chain EXCEPT ![d] = <<n>> \o @]
         /\ S' = [S EXCEPT ![s].pass = @ + 1]
         /\ L' = [L EXCEPT ![p].res = "ok", ![p].ne = NIL, ![p].pc = L[p].ret]
         /\ IF S[s].pass < 1 \/ S[s].ph = "freed"
            THEN Flag("refcount_inc(s_passive) from zero in super_dev_add()")
            ELSE UNCHANGED err

R0(p) ==
    /\ L[p].pc = "R0"
    /\ IF FreeAlloc = {}
       THEN /\ Flag("model: out of entry slots")
            /\ Goto(p, "Done")
            /\ UNCHANGED E
       ELSE LET e == NewAlloc IN
            /\ E' = [E EXCEPT ![e] = [FreeE EXCEPT !.st = "alloc"]]
            /\ L' = [L EXCEPT ![p].ne = e, ![p].pc = "R1",
                              ![p].rdc = IF FIX_CHECK_LOCKED THEN 0 ELSE bdc[L[p].dev]]
            /\ UNCHANGED err
    /\ UNCHANGED <<chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

R1(p) ==
    /\ L[p].pc = "R1"
    /\ LET d == L[p].dev
           F == Pairs(d, L[p].sb) IN
       IF F # {}
       THEN LET f == CHOOSE f \in F : TRUE IN
            /\ E' = [E EXCEPT ![f].claims = @ + 1, ![L[p].ne] = FreeE]
            /\ L' = [L EXCEPT ![p].res = "ok", ![p].ne = NIL, ![p].pc = L[p].ret]
            /\ IF Cardinality(F) > 1 THEN Flag("two hashed entries for one (device, superblock)")
               ELSE UNCHANGED err
            /\ UNCHANGED <<chain, S>>
       ELSE IF FIX_ATOMIC_CLAIM
       THEN InsertOrRefuse(p)
       ELSE /\ Goto(p, "R2")
            /\ UNCHANGED <<E, chain, S, err>>
    /\ UNCHANGED <<use, bdOpen, bdc, ucount, fvia, xst, crossed>>

R2(p) ==
    /\ L[p].pc = "R2"
    /\ InsertOrRefuse(p)
    /\ UNCHANGED <<use, bdOpen, bdc, ucount, fvia, xst, crossed>>

(***************************************************************************)
(* fs_bdev_unregister() (L1731); called with dev, sb, ret.                 *)
(*   U1  super_dev_find() under super_dev_lock L1736-1737, then            *)
(*       super_dev_put() L1739; the claim being dropped keeps it hashed    *)
(***************************************************************************)
U1(p) ==
    /\ L[p].pc = "U1"
    /\ LET F == Pairs(L[p].dev, L[p].sb) IN
       IF F = {}
       THEN /\ Flag("fs_bdev_unregister() found no entry for a claim")
            /\ Goto(p, L[p].ret)
       ELSE LET f == CHOOSE f \in F : TRUE IN
            /\ L' = [L EXCEPT ![p].fnd = f, ![p].pe = f, ![p].pret = L[p].ret, ![p].pc = "U2"]
            /\ IF Cardinality(F) > 1 THEN Flag("two hashed entries for one (device, superblock)")
               ELSE UNCHANGED err
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* the unlocked gap between the lookup and super_dev_put()
U2(p) ==
    /\ L[p].pc = "U2"
    /\ L' = [L EXCEPT ![p].fnd = NIL, ![p].pc = "P1"]
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* The walk: for_each_dev_super() L515 -> super_dev_next() L472 with the   *)
(* cursor on the caller's stack.  Called with dev, ph, ret.               *)
(*   W0  the cursor { .sd_dev = dev } (ghosts: the claims hashed now)     *)
(*   W1  under super_dev_lock L481-501: hash_add() the cursor on the       *)
(*       first call L484, the first claim behind it L485-489, none: delete *)
(*       the cursor L490-493; refcount_inc(s_passive) L496; SB_BORN or     *)
(*       SB_DYING: move the cursor behind the claim L497-499 and return    *)
(*       the superblock; else WW                                          *)
(*   WW  wait_var_event() for SB_BORN | SB_DYING L503, put_super() L504,   *)
(*       look again from the cursor                                       *)
(*   W3  the caller's loop body, or the end of the walk                   *)
(*   WN  the next super_dev_next(): put_super(prev) L478                  *)
(* Ghosts: vis/vsb (claims/superblocks returned), stab (claims hashed from *)
(* the start of the walk on; P1 removes a claim the moment it's dropped)  *)
(* -- the walk must return each of stab, and no superblock twice.        *)
(***************************************************************************)
W0(p) ==
    /\ L[p].pc = "W0"
    /\ L' = [L EXCEPT ![p].sb = NoSb, ![p].at = NIL, ![p].last = NIL, ![p].vis = {},
                      ![p].vsb = {}, ![p].stab = EntriesOf(L[p].dev), ![p].pc = "W1"]
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* commit to (or, unborn and FIX_RELOOK, wait for) the superblock of claim e
WTake(p, e, ch) ==
    LET d == L[p].dev
        s == E[e].sb
        c == CurOf[p] IN
    /\ S' = [S EXCEPT ![s].pass = @ + 1]
    /\ IF S[s].ph = "freed" THEN Flag("UAF: a hashed claim of a freed superblock")
       ELSE IF S[s].pass < 1 THEN Flag("refcount_inc(s_passive) from zero in super_dev_next()")
       ELSE UNCHANGED err
    /\ IF S[s].ph = "nascent" /\ FIX_RELOOK
       THEN /\ chain' = [chain EXCEPT ![d] = ch]
            /\ L' = [L EXCEPT ![p].ref = s, ![p].pc = "WW"]
       ELSE /\ chain' = IF FIX_CURSOR THEN [chain EXCEPT ![d] = Behind(Drop(ch, c), e, c)] ELSE chain
            /\ L' = [L EXCEPT ![p].ref = s, ![p].sb = s, ![p].at = e,
                              ![p].last = IF FIX_CURSOR THEN NIL ELSE e,
                              ![p].pc = IF S[s].ph = "nascent" THEN "WX" ELSE "W3"]

W1(p) ==
    /\ L[p].pc = "W1"
    /\ LET d == L[p].dev
           c == CurOf[p] IN
       IF FIX_CURSOR
       THEN LET ch == IF InCh(d, c) THEN chain[d] ELSE <<c>> \o chain[d]
                e == FirstEntry(After(ch, c)) IN
            IF e = NIL
            THEN /\ chain' = [chain EXCEPT ![d] = Drop(ch, c)]
                 /\ L' = [L EXCEPT ![p].sb = NoSb, ![p].at = NIL, ![p].pc = "W3"]
                 /\ UNCHANGED <<S, err>>
            ELSE WTake(p, e, ch)
       ELSE LET w == L[p].last IN
            IF w # NIL /\ ~InCh(d, w)
            THEN /\ Flag("the walk resumes behind an entry that is not hashed anymore")
                 /\ L' = [L EXCEPT ![p].sb = NoSb, ![p].at = NIL, ![p].pc = "W3"]
                 /\ UNCHANGED <<chain, S>>
            ELSE LET e == FirstEntry(IF w = NIL THEN chain[d] ELSE After(chain[d], w)) IN
                 IF e = NIL
                 THEN /\ L' = [L EXCEPT ![p].sb = NoSb, ![p].at = NIL, ![p].pc = "W3"]
                      /\ UNCHANGED <<chain, S, err>>
                 ELSE WTake(p, e, chain[d])
    /\ UNCHANGED <<E, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* FIX_RELOOK: the superblock was not born yet; wait without committing, then look again
WW(p) ==
    /\ L[p].pc = "WW"
    /\ LET s == L[p].ref IN
       /\ S[s].ph # "nascent"
       /\ S' = PutSb(s, S)
       /\ IF S[s].pass < 1 THEN Flag("s_passive underflow") ELSE UNCHANGED err
    /\ L' = [L EXCEPT ![p].ref = NoSb, ![p].pc = "W1"]
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* FIX_RELOOK off: committed to the claim of an unborn superblock; wait for SB_BORN | SB_DYING
WX(p) ==
    /\ L[p].pc = "WX"
    /\ S[L[p].sb].ph # "nascent"
    /\ Goto(p, "W3")
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

W3(p) ==
    /\ L[p].pc = "W3"
    /\ LET s == L[p].sb IN
       IF s = NoSb
       THEN /\ Goto(p, L[p].ret)
            /\ IF ~(L[p].stab \subseteq L[p].vis)
               THEN Flag("the walk skipped a claim that stayed hashed through the walk")
               ELSE UNCHANGED err
       ELSE /\ L' = [L EXCEPT ![p].vis = @ \cup {L[p].at}, ![p].vsb = @ \cup {s},
                              ![p].pc = CASE L[p].ph = "frz" -> "F_gas"
                                          [] L[p].ph = "thw" -> "T_gas"
                                          [] OTHER -> "C_lock"]
            /\ IF s \in L[p].vsb THEN Flag("the walk returned a superblock twice")
               ELSE UNCHANGED err
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* the next super_dev_next() call: put_super(prev) L478 first
WN(p) ==
    /\ L[p].pc = "WN"
    /\ LET s == L[p].sb IN
       /\ S' = PutSb(s, S)
       /\ IF S[s].pass < 1 THEN Flag("s_passive underflow") ELSE UNCHANGED err
    /\ L' = [L EXCEPT ![p].ref = NoSb, ![p].sb = NoSb, ![p].pc = "W1"]
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* get_active_super() (L1178) on the walk's superblock:                   *)
(* super_lock_excl() waits for SB_BORN|SB_DYING (wait_var_event L118),    *)
(* fails on SB_DYING, down_write() waits for s_umount; then               *)
(* atomic_inc_not_zero(s_active) and up_write().                          *)
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
(* (block/bdev.c L300 and L341; fs/super.c L1522 and L1576).               *)
(***************************************************************************)
F_bdf(p) ==
    /\ L[p].pc = "F_bdf"
    /\ LET d == Freezers[p] IN
       IF bdc[d] < 0                                       \* L307: denied, -EBUSY
       THEN /\ Goto(p, "Done")
            /\ UNCHANGED bdc
       ELSE /\ bdc' = [bdc EXCEPT ![d] = @ + 1]            \* atomic_inc_unless_negative(), a full barrier
            /\ Goto(p, IF bdc[d] + 1 > 1 THEN "F_frozen" ELSE "F_hold")
    /\ UNCHANGED <<E, chain, S, use, bdOpen, ucount, fvia, xst, crossed, err>>

\* L316-318: under bd_holder_lock, call ->freeze only if a holder with fs_holder_ops has it open
F_hold(p) ==
    /\ L[p].pc = "F_hold"
    /\ LET d == Freezers[p] IN
       IF bdOpen[d] > 0
       THEN L' = [L EXCEPT ![p].dev = d, ![p].ph = "frz", ![p].cnt = 0, ![p].perr = FALSE,
                           ![p].ret = "F_fend", ![p].pc = "W0"]
       ELSE Goto(p, "F_frozen")                          \* sync_blockdev() only
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

F_gas(p) ==
    /\ L[p].pc = "F_gas"
    /\ GasStep(p, "F_frz")
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* fs_super_freeze() -> freeze_super(sb, FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE) L1536:
\* the first freeze keeps an active reference for all freezers; deactivate_super() drops
\* get_active_super()'s; count++
F_frz(p) ==
    /\ L[p].pc = "F_frz"
    /\ LET s == L[p].sb
           d == L[p].dev IN
       /\ ucount' = [ucount EXCEPT ![s] = @ + 1]
       /\ fvia' = [fvia EXCEPT ![s][d] = @ + 1]
       /\ S' = [S EXCEPT ![s].act = @ - 1 + (IF ucount[s] = 0 THEN 1 ELSE 0)]
       /\ L' = [L EXCEPT ![p].cnt = @ + 1, ![p].pc = "WN"]
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, xst, crossed, err>>

\* no per-superblock freeze errors are modelled; the device stays frozen
F_fend(p) ==
    /\ L[p].pc = "F_fend"
    /\ Goto(p, "F_frozen")
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* the device is frozen (a dm suspend, a shutdown ioctl); then bdev_thaw()
F_frozen(p) ==
    /\ L[p].pc = "F_frozen"
    /\ Goto(p, "F_bdt")
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

F_bdt(p) ==
    /\ L[p].pc = "F_bdt"
    /\ LET d == Freezers[p] IN
       CASE bdc[d] <= 0 -> /\ Goto(p, "Done")                  \* -EINVAL
                           /\ UNCHANGED bdc
         [] bdc[d] > 1 -> /\ bdc' = [bdc EXCEPT ![d] = @ - 1]
                          /\ Goto(p, "Done")
         [] OTHER -> /\ IF bdOpen[d] > 0
                         THEN L' = [L EXCEPT ![p].dev = d, ![p].ph = "thw", ![p].cnt = 0,
                                             ![p].perr = FALSE, ![p].ret = "T_end", ![p].pc = "W0"]
                         ELSE Goto(p, "T_end")
                     /\ UNCHANGED bdc
    /\ UNCHANGED <<E, chain, S, use, bdOpen, ucount, fvia, xst, crossed, err>>

T_gas(p) ==
    /\ L[p].pc = "T_gas"
    /\ GasStep(p, "T_thw")
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* fs_super_thaw() -> thaw_super(sb, FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE) L1590:
\* may_unfreeze() needs freeze_ucount > 0, else -EINVAL (taken as success, the freeze is
\* gone); the last thaw drops the freezers' active reference.  A thaw through a device that
\* never froze this superblock takes another device's freeze (fvia ghost).
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
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, xst, crossed>>

\* bdev_thaw() L367-368; then the balance: the device is thawed and no superblock keeps a
\* freeze taken through it; a thaw of a superblock that was never frozen through the device
\* ("a thaw walk reached a superblock it never froze") is flagged as well
T_end(p) ==
    /\ L[p].pc = "T_end"
    /\ LET d == Freezers[p] IN
       /\ bdc' = [bdc EXCEPT ![d] = @ - 1]
       /\ err' = err \cup (IF \E s \in Sbs : fvia[s][d] > 0
                           THEN {"a freeze taken through the device outlives its thaw"} ELSE {})
                     \cup (IF L[p].perr THEN {"a thaw walk reached a superblock that was not frozen"}
                           ELSE {})
       /\ Goto(p, "Done")
    /\ UNCHANGED <<E, chain, S, use, bdOpen, ucount, fvia, xst, crossed>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* user_get_super() (L1016): the walk; super_lock() (wait for              *)
(* SB_BORN|SB_DYING, fail on SB_DYING, take s_umount), super_dev_walk_end()*)
(* L509 for the cursor and return the superblock with the walk's passive   *)
(* reference; the caller uses it and drop_super() puts it.                 *)
(***************************************************************************)
C_start(p) ==
    /\ L[p].pc = "C_start"
    /\ L' = [L EXCEPT ![p].dev = Cursors[p], ![p].ph = "ugs", ![p].ret = "Done", ![p].pc = "W0"]
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

C_lock(p) ==
    /\ L[p].pc = "C_lock"
    /\ LET s == L[p].sb IN
       /\ GasReady(s)
       /\ IF S[s].ph = "freed" THEN Flag("UAF: super_lock() on a freed superblock")
          ELSE UNCHANGED err
       /\ IF S[s].ph = "born"
          THEN /\ S' = [S EXCEPT ![s].um = p]
               /\ L' = [L EXCEPT ![p].hold = TRUE, ![p].pc = "C_end"]
          ELSE /\ Goto(p, "WN")
               /\ UNCHANGED S
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* super_dev_walk_end(): delete the cursor under super_dev_lock
C_end(p) ==
    /\ L[p].pc = "C_end"
    /\ chain' = [chain EXCEPT ![L[p].dev] = Drop(@, CurOf[p])]
    /\ Goto(p, "C_use")
    /\ UNCHANGED <<E, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

C_use(p) ==
    /\ L[p].pc = "C_use"
    /\ LET s == L[p].sb IN
       IF S[s].ph \in {"dying", "dead", "freed"} \/ S[s].um # p
       THEN Flag("user_get_super() returned a superblock that is going away under s_umount")
       ELSE UNCHANGED err
    /\ Goto(p, "C_drop")
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* drop_super(): up_read()/up_write() and put_super() of the walk's passive reference
C_drop(p) ==
    /\ L[p].pc = "C_drop"
    /\ LET s == L[p].sb IN
       /\ S' = [PutSb(s, S) EXCEPT ![s].um = "free"]
       /\ IF S[s].pass < 1 THEN Flag("s_passive underflow") ELSE UNCHANGED err
    /\ L' = [L EXCEPT ![p].pc = "Done", ![p].hold = FALSE, ![p].ref = NoSb]
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* The filesystem task of superblock s.                                    *)
(***************************************************************************)
CallReg(p, d, s, r) == L' = [L EXCEPT ![p].dev = d, ![p].sb = s, ![p].ret = r, ![p].pc = "R0"]
CallUnreg(p, d, s, r) == L' = [L EXCEPT ![p].dev = d, ![p].sb = s, ![p].ret = r, ![p].pc = "U1"]
DupsOf(s) == {x \in DuP : Dups[x].sb = s}

\* alloc_super() L319: s_umount held, s_passive 1, s_active 1; the entry embedded in the
\* superblock is not hashed yet
fs_alloc(p) ==
    /\ L[p].pc = "fs_alloc"
    /\ S' = [S EXCEPT ![p] = [ph |-> "nascent", pass |-> 1, act |-> 1, um |-> "fs", own |-> 1]]
    /\ Goto(p, "fs_hash")
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* sget_fc() L873-874 after set() assigned s_dev: super_dev_add(&s->s_super_dev) under
\* super_dev_lock; the superblock is published and returned locked
fs_hash(p) ==
    /\ L[p].pc = "fs_hash"
    /\ LET e == EmbOf[p]
           d == Main(p) IN
       /\ E' = [E EXCEPT ![e] = [st |-> "hashed", dev |-> d, sb |-> p, claims |-> 1, pass |-> 1]]
       /\ chain' = [chain EXCEPT ![d] = <<e>> \o @]
       /\ S' = [S EXCEPT ![p].pass = @ + 1]
    /\ Goto(p, "fs_open")
    /\ UNCHANGED <<use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* setup_bdev_super() L1757 -> fs_bdev_file_open_by_dev(): bdev_file_open_by_dev() with
\* fs_holder_ops, then fs_bdev_register(): finds the embedded entry and takes one more claim
fs_open(p) ==
    /\ L[p].pc = "fs_open"
    /\ bdOpen' = [bdOpen EXCEPT ![Main(p)] = @ + 1]
    /\ CallReg(p, Main(p), p, "fs_bdevchk")
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, xst, crossed, err>>

\* fs_bdev_file_open_by_dev() fails -> bdev_fput(); else L1783: the frozen check (ordered by
\* super_dev_lock against bdev_freeze(): sget_fc() hashed the superblock under it before),
\* fs_bdev_file_release() -> -EBUSY; else the superblock uses the device
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
    /\ UNCHANGED <<E, chain, S, bdc, ucount, fvia, xst, crossed, err>>

\* fs_bdev_file_release(): bdev_fput() after the unregister; the mount fails with -EBUSY
fs_mfput(p) ==
    /\ L[p].pc = "fs_mfput"
    /\ bdOpen' = [bdOpen EXCEPT ![Main(p)] = @ - 1]
    /\ Goto(p, "fs_fail")
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, xst, crossed, err>>

\* fill_super(): an extra member device opened during the mount (xmode "mount")
fs_x(p) ==
    /\ L[p].pc = "fs_x"
    /\ IF FsCfg[p].xmode = "mount"
       THEN /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ + 1]
            /\ xst' = [xst EXCEPT ![p] = 1]
            /\ CallReg(p, Xdev(p), p, "fs_xchk")
       ELSE /\ Goto(p, "fs_born")
            /\ UNCHANGED <<bdOpen, xst>>
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, crossed, err>>

\* the extra device was refused (-EBUSY): bdev_fput(); the mount fails (onfail "fail": xfs,
\* ext4, f2fs, erofs) or goes on without it (onfail "degraded": btrfs -o degraded).
\* Accepted: kept, or dropped again before SB_BORN.  mayfail: fill_super() may fail anyway.
fs_xchk(p) ==
    /\ L[p].pc = "fs_xchk"
    /\ IF L[p].res = "busy"
       THEN /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
            /\ Goto(p, IF FsCfg[p].onfail = "fail" THEN "fs_fail" ELSE "fs_born")
            /\ UNCHANGED use
       ELSE /\ use' = [use EXCEPT ![p][Xdev(p)] = TRUE]
            /\ Goto(p, IF FsCfg[p].dropx = "early" THEN "fs_xdrop" ELSE "fs_born")
            /\ UNCHANGED bdOpen
    /\ UNCHANGED <<E, chain, S, bdc, ucount, fvia, xst, crossed, err>>

fs_xdrop(p) ==
    /\ L[p].pc = "fs_xdrop"
    /\ use' = [use EXCEPT ![p][Xdev(p)] = FALSE]
    /\ xst' = [xst EXCEPT ![p] = 2]
    /\ CallUnreg(p, Xdev(p), p, "fs_xdfput")
    /\ UNCHANGED <<E, chain, S, bdOpen, bdc, ucount, fvia, crossed, err>>

fs_xdfput(p) ==
    /\ L[p].pc = "fs_xdfput"
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
    /\ Goto(p, "fs_born")
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, xst, crossed, err>>

\* vfs_get_tree() L1927 super_wake(SB_BORN), fc_mount() up_write(s_umount); or fill_super()
\* fails (mayfail)
fs_born(p) ==
    /\ L[p].pc = "fs_born"
    /\ \/ /\ S' = [S EXCEPT ![p].ph = "born", ![p].um = "free"]
          /\ Goto(p, "fs_live")
       \/ /\ FsCfg[p].mayfail
          /\ Goto(p, "fs_fail")
          /\ UNCHANGED S
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* the live superblock: btrfs device add (xmode "live") under bdev_deny_freeze(), then btrfs
\* device remove (dropx "live") under the deny; then the unmount
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
    /\ UNCHANGED <<E, chain, S, use, ucount, fvia, crossed, err>>

\* the add went through or was refused; bdev_allow_freeze() once the membership change is done
fs_addchk(p) ==
    /\ L[p].pc = "fs_addchk"
    /\ IF L[p].res = "ok"
       THEN /\ use' = [use EXCEPT ![p][Xdev(p)] = TRUE]
            /\ UNCHANGED bdOpen
       ELSE /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
            /\ UNCHANGED use
    /\ bdc' = IF FIX_DENY THEN [bdc EXCEPT ![Xdev(p)] = @ + 1] ELSE bdc
    /\ Goto(p, "fs_live2")
    /\ UNCHANGED <<E, chain, S, ucount, fvia, xst, crossed, err>>

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
    /\ UNCHANGED <<E, chain, S, bdOpen, ucount, fvia, crossed, err>>

\* btrfs_release_device_allow_freeze(): unregister, bdev_allow_freeze(), bdev_fput()
fs_rmallow(p) ==
    /\ L[p].pc = "fs_rmallow"
    /\ bdc' = IF FIX_DENY THEN [bdc EXCEPT ![Xdev(p)] = @ + 1] ELSE bdc
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
    /\ Goto(p, "fs_live3")
    /\ UNCHANGED <<E, chain, S, use, ucount, fvia, xst, crossed, err>>

\* umount: deactivate_super() for the last active reference: s_umount, s_active -> 0 (a
\* freezer's or the freeze's active reference keeps the superblock alive instead; the model
\* lets the filesystem task wait for them); the dups finish before ->put_super()
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
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* a failed mount: deactivate_locked_super() with s_umount still held, s_active -> 0
fs_fail(p) ==
    /\ L[p].pc = "fs_fail"
    /\ \A x \in DupsOf(p) : L[x].pc = "Done"
    /\ S' = [S EXCEPT ![p].act = 0]
    /\ Goto(p, "fs_relx")
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* ->kill_sb() -> generic_shutdown_super() -> ->put_super(): the member device is closed
fs_relx(p) ==
    /\ L[p].pc = "fs_relx"
    /\ IF HasX(p) /\ use[p][Xdev(p)]
       THEN /\ use' = [use EXCEPT ![p][Xdev(p)] = FALSE]
            /\ CallUnreg(p, Xdev(p), p, "fs_relxput")
       ELSE /\ Goto(p, "fs_dying")
            /\ UNCHANGED use
    /\ UNCHANGED <<E, chain, S, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

fs_relxput(p) ==
    /\ L[p].pc = "fs_relxput"
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(p)] = @ - 1]
    /\ Goto(p, "fs_dying")
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, xst, crossed, err>>

\* generic_shutdown_super() L759: super_wake(SB_DYING), super_unlock_excl()
fs_dying(p) ==
    /\ L[p].pc = "fs_dying"
    /\ S' = [S EXCEPT ![p].ph = "dying", ![p].um = "free"]
    /\ Goto(p, "fs_relm")
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* kill_block_super() L1878: fs_bdev_file_release(sb->s_bdev_file) if s_bdev was set
fs_relm(p) ==
    /\ L[p].pc = "fs_relm"
    /\ IF use[p][Main(p)]
       THEN /\ use' = [use EXCEPT ![p][Main(p)] = FALSE]
            /\ CallUnreg(p, Main(p), p, "fs_relmput")
       ELSE /\ Goto(p, "fs_notify")
            /\ UNCHANGED use
    /\ UNCHANGED <<E, chain, S, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

fs_relmput(p) ==
    /\ L[p].pc = "fs_relmput"
    /\ bdOpen' = [bdOpen EXCEPT ![Main(p)] = @ - 1]
    /\ Goto(p, "fs_notify")
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, xst, crossed, err>>

\* deactivate_locked_super() -> kill_super_notify() L527: super_dev_put(&sb->s_super_dev)
fs_notify(p) ==
    /\ L[p].pc = "fs_notify"
    /\ L' = [L EXCEPT ![p].pe = EmbOf[p], ![p].pret = "fs_dead", ![p].pc = "P1"]
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

\* L538: super_wake(SB_DEAD) under sb_lock
fs_dead(p) ==
    /\ L[p].pc = "fs_dead"
    /\ S' = [S EXCEPT ![p].ph = IF S[p].ph = "freed" THEN "freed" ELSE "dead"]
    /\ IF S[p].ph = "freed" THEN Flag("superblock freed before SB_DEAD")
       ELSE UNCHANGED err
    /\ Goto(p, "fs_put")
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

\* put_super(): the alloc_super() reference
fs_put(p) ==
    /\ L[p].pc = "fs_put"
    /\ S' = [PutSb(p, S) EXCEPT ![p].own = 0]
    /\ IF S[p].pass < 1 THEN Flag("s_passive underflow") ELSE UNCHANGED err
    /\ Goto(p, "Done")
    /\ UNCHANGED <<E, chain, use, bdOpen, bdc, ucount, fvia, xst, crossed>>

-----------------------------------------------------------------------------
(* A second registration of the same (device, superblock). *)
D_start(p) ==
    /\ L[p].pc = "D_start"
    /\ LET s == Dups[p].sb IN
       /\ xst[s] >= (IF Dups[p].after THEN 2 ELSE 1)
       /\ S[s].ph \in {"nascent", "born"}
       /\ bdOpen' = [bdOpen EXCEPT ![Xdev(s)] = @ + 1]
       /\ CallReg(p, Xdev(s), s, "D_reg")
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, xst, crossed, err>>

D_reg(p) ==
    /\ L[p].pc = "D_reg"
    /\ IF L[p].res = "ok"
       THEN CallUnreg(p, Xdev(Dups[p].sb), Dups[p].sb, "D_fput")
       ELSE Goto(p, "D_fput")
    /\ UNCHANGED <<E, chain, S, use, bdOpen, bdc, ucount, fvia, xst, crossed, err>>

D_fput(p) ==
    /\ L[p].pc = "D_fput"
    /\ bdOpen' = [bdOpen EXCEPT ![Xdev(Dups[p].sb)] = @ - 1]
    /\ Goto(p, "Done")
    /\ UNCHANGED <<E, chain, S, use, bdc, ucount, fvia, xst, crossed, err>>

-----------------------------------------------------------------------------
AllDone == \A p \in Procs : L[p].pc = "Done"

\* the end: every task finished; stutter
Finished ==
    /\ AllDone
    /\ UNCHANGED vars

Step(p) ==
    \/ P1(p) \/ P2(p)
    \/ R0(p) \/ R1(p) \/ R2(p)
    \/ U1(p) \/ U2(p)
    \/ W0(p) \/ W1(p) \/ WW(p) \/ WX(p) \/ W3(p) \/ WN(p)
    \/ F_bdf(p) \/ F_hold(p) \/ F_gas(p) \/ F_frz(p) \/ F_fend(p) \/ F_frozen(p) \/ F_bdt(p)
    \/ T_gas(p) \/ T_thw(p) \/ T_end(p)
    \/ C_start(p) \/ C_lock(p) \/ C_end(p) \/ C_use(p) \/ C_drop(p)
    \/ fs_alloc(p) \/ fs_hash(p) \/ fs_open(p) \/ fs_bdevchk(p) \/ fs_mfput(p)
    \/ fs_x(p) \/ fs_xchk(p) \/ fs_xdrop(p) \/ fs_xdfput(p) \/ fs_born(p) \/ fs_live(p)
    \/ fs_addchk(p) \/ fs_live2(p) \/ fs_rmallow(p) \/ fs_live3(p) \/ fs_fail(p)
    \/ fs_relx(p) \/ fs_relxput(p) \/ fs_dying(p) \/ fs_relm(p) \/ fs_relmput(p)
    \/ fs_notify(p) \/ fs_dead(p) \/ fs_put(p)
    \/ D_start(p) \/ D_reg(p) \/ D_fput(p)

Next ==
    \/ \E p \in Procs : Step(p)
    \/ Finished

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

TypeOK ==
    /\ \A e \in Ids : /\ E[e].st \in {"idle", "free", "alloc", "hashed", "unhashed"}
                      /\ E[e].claims \in Nat /\ E[e].pass \in 0..1
    /\ \A d \in Devs : \A i \in 1..Len(chain[d]) : chain[d][i] \in Ids \cup CurIds
    /\ \A s \in Sbs : S[s].ph \in {"none", "nascent", "born", "dying", "dead", "freed"}

NoErr == err = {}

\* the chain of a device is what hash_add()/hash_del() made of it: no node twice, exactly the
\* hashed entries of the device, and the cursors of walks on the device
ChainOK == \A d \in Devs :
    LET sq == chain[d] IN
    /\ \A i, j \in 1..Len(sq) : i # j => sq[i] # sq[j]
    /\ {sq[i] : i \in 1..Len(sq)} \ CurIds = {e \in Ids : E[e].st = "hashed" /\ E[e].dev = d}
    /\ \A i \in 1..Len(sq) : sq[i] \in CurIds => \E p \in WalkP : CurOf[p] = sq[i] /\ L[p].dev = d

\* one entry per (device, superblock) pair
UniquePair == \A d \in Devs, s \in Sbs : Cardinality(Pairs(d, s)) <= 1

\* an entry is hashed exactly while it has claims
ClaimsOK == \A e \in Ids : (E[e].st = "hashed") <=> (E[e].claims > 0)

\* the passive reference count adds up: alloc_super()'s own, one per entry, one per walk that
\* holds the superblock (returned it or waits for it)
PassLedger == \A s \in Sbs : S[s].ph \notin {"none", "freed"} =>
    S[s].pass = S[s].own + Cardinality({e \in Ids : E[e].sb = s /\ E[e].pass = 1}) + WalkPass(s)

\* an entry holding a passive reference keeps its superblock
EntryKeepsSb == \A e \in Ids : E[e].pass = 1 => S[E[e].sb].ph # "freed"

\* the entries a task holds outside the lock are alive: the one fs_bdev_unregister() found
\* (kept hashed by the claim it drops), the one super_dev_put() works on, the new allocation
NoFreedReach == \A p \in Procs :
    /\ L[p].fnd # NIL => E[L[p].fnd].st = "hashed"
    /\ L[p].pe # NIL /\ L[p].pc \in {"P1", "U2"} => E[L[p].pe].st = "hashed"
    /\ L[p].pe # NIL /\ L[p].pc = "P2" => E[L[p].pe].st = "unhashed"
    /\ L[p].ne # NIL => E[L[p].ne].st = "alloc"

\* while a freezer has the device frozen (its walk done), every live superblock that uses the
\* device is frozen: nobody writes to a frozen device
FrozenCovers == \A f \in FrP : L[f].pc = "F_frozen" /\ bdc[Freezers[f]] > 0 =>
    \A s \in Sbs : (S[s].ph = "born" /\ use[s][Freezers[f]]) => ucount[s] > 0

\* the end: no superblock or entry leaked by an unmounted filesystem, no cursor left behind
NoLeak == AllDone =>
    /\ \A s \in Sbs : FsCfg[s].umount => S[s].ph \in {"freed", "none"}
    /\ \A e \in Alloc : E[e].st # "alloc"
    /\ \A e \in Ids : E[e].st \in {"hashed", "unhashed"} => ~FsCfg[E[e].sb].umount
    /\ \A d \in Devs : \A i \in 1..Len(chain[d]) : chain[d][i] \notin CurIds

\* reachability witnesses, expected to be violated: a walk waits for an unborn superblock; a
\* claim the cursor sits right behind is dropped while the walk sleeps
NoUnbornWait == \A p \in Procs : L[p].pc # "WW"
NoCursorCrossed == ~crossed
=============================================================================

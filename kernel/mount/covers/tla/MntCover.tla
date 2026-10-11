------------------------------- MODULE MntCover -------------------------------
(***************************************************************************)
(* The covers of "namespace: rework connected mounts" (01cbebb42070) and   *)
(* "namespace: simplify disconnect_mount()" (3d3992244255), in mainline    *)
(* since vfs-7.3-rc7.fixes.                                                *)
(*                                                                         *)
(* A victim of umount_tree() whose parent is unmounted with it used to     *)
(* stay attached to that parent when the umount asked for it               *)
(* (UMOUNT_CONNECTED) or when it was locked (MNT_LOCKED), so that a        *)
(* lookup on the dead parent kept finding it instead of what it covered.   *)
(* Now every victim is detached, and one that needs_cover() first leaves   *)
(* the struct mnt_cover it allocated with the mount behind:                *)
(* leave_cover() hangs it on the parent's mnt_covers and pins the          *)
(* mountpoint through m_covers.  __lookup_mnt() on an unmounted mount      *)
(* that misses the mount hash looks at the covers and returns a stand-in,  *)
(* knullfs for a directory and knullfs_file for anything else.  The        *)
(* parent's final mntput() and __detach_mounts() on the covered dentry     *)
(* drop the cover under mount_lock (drop_cover()) and free it with         *)
(* kfree_rcu().                                                            *)
(*                                                                         *)
(* The model is one namespace with a small tree of mounts, holders that    *)
(* keep a file open on a mount, walkers that look a mountpoint dentry up   *)
(* from a holder's file, and one task that runs umount_tree() for the      *)
(* operations of the layout: umount2(MNT_DETACH), rmdir of a mountpoint    *)
(* (__detach_mounts(), UMOUNT_COVER) and the death of the namespace        *)
(* (put_mnt_ns(), no flags).  A synchronous umount needs a mount nobody    *)
(* holds and without children, so it never leaves a cover and is left out. *)
(*                                                                         *)
(* A walker borrows its holder's file for the walk.  In RCU mode it        *)
(* samples mount_lock once no writer holds it, reads DCACHE_MOUNTED, and   *)
(* runs __lookup_mnt(): the hash, the racy test of MNT_UMOUNT, the covers  *)
(* list, then the covers it found.  Every read is a step of its own.       *)
(* __follow_mount_rcu() and complete_walk() recheck mount_lock: if any     *)
(* writer took it since the sample the walk drops to ref mode, which runs  *)
(* lookup_mnt() against a quiescent mount_lock.  Every section that takes  *)
(* mount_lock for writing invalidates the samples of the walkers in RCU    *)
(* mode: umount_tree() with the cover drops of __detach_mounts(), and      *)
(* mntput_no_expire_slowpath().                                            *)
(*                                                                         *)
(* Switches, all TRUE for mainline:                                        *)
(*   FIX_COVER     leave_cover() for a victim that needs_cover()           *)
(*   MP_PIN        the cover pins the mountpoint (m_covers), so the        *)
(*                 mountpoint and DCACHE_MOUNTED stay while it is there    *)
(*   COVER_FIRST   leave_cover() before umount_mnt(), not after            *)
(*   PUT_DROPS     the final mntput() drops the covers on the mount        *)
(*   DETACH_DROPS  __detach_mounts() drops the covers on the dentry        *)
(*   RCU_FREE      drop_cover() frees the cover with kfree_rcu()           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Mnts,          \* the mounts of the layout, the stand-ins are not among them
    Root,          \* the root of the namespace
    ParentOf,      \* [Mnts -> Mnts \cup {NoMnt}]: the tree at the start
    MpOf,          \* [Mnts -> Dentries \cup {NoDentry}]: the dentry each mount sits on
    Dentries,      \* the mountpoint dentries
    DirDentries,   \* the ones that are directories, the others are files
    Locked,        \* the mounts with MNT_LOCKED
    Holders,       \* tasks keeping a file open on a mount
    HolderMnt,     \* [Holders -> Mnts]
    Walkers,       \* path walks, each runs once
    WalkFrom,      \* [Walkers -> Holders]: the file the walk starts from
    WalkAt,        \* [Walkers -> Dentries]: the dentry it looks up in that mount
    Ops,           \* operations of the unmounting task, each at most once
    FIX_COVER, MP_PIN, COVER_FIRST, PUT_DROPS, DETACH_DROPS, RCU_FREE

NoMnt == "none"
NoDentry == "none"
Knullfs == "knullfs"
KnullfsFile == "knullfs_file"
Dent == "dentry"          \* a lookup that found no mount: the walk stays on the dentry
NoOp == [kind |-> "none", mnt |-> NoMnt, d |-> NoDentry]
NoDec == [res |-> "none", req |-> FALSE, linked |-> FALSE, unmounted |-> FALSE]
RcuPcs == {"mounted", "hash", "flag", "covers", "deref", "check"}

VARIABLES
    m,        \* [Mnts -> [hashed, parent, umount, ns, count, doomed, st, covers, waiters]]
    cov,      \* [Mnts -> {"own", "listed", "dropped", "freed"}]: the cover each mount allocated
    covwait,  \* [Mnts -> SUBSET Walkers]: the RCU readers a dropped cover waits for
    mpa,      \* [Dentries -> BOOLEAN]: the struct mountpoint exists
    mounted,  \* [Dentries -> BOOLEAN]: DCACHE_MOUNTED
    mlist,    \* [Dentries -> SUBSET Mnts]: mp->m_list, the mounts on it
    mcov,     \* [Dentries -> SUBSET Mnts]: mp->m_covers, the covers pinning it
    linked,   \* [Dentries -> BOOLEAN]: not removed by rmdir or unlink
    lock,     \* "free" or "U": who holds mount_lock for writing across steps
    u,        \* the unmounting task
    held,     \* [Holders -> BOOLEAN]: the file is still open
    w,        \* [Walkers -> [pc, stale, res, seen, dec]]
    covreq,   \* ghost: the victims that were unmounted with a required cover
    ev,       \* ghost: what happened, for the witnesses
    bad       \* ghost: what went wrong, for NoBad
vars == <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, w, covreq, ev, bad>>

(* ---- helpers ------------------------------------------------------------ *)

RECURSIVE Depth(_)
Depth(x) == IF ParentOf[x] = NoMnt THEN 0 ELSE 1 + Depth(ParentOf[x])
\* the order umount_tree() collects a tree in: a parent before its children
RECURSIVE Ordered(_)
Ordered(S) == IF S = {} THEN <<>>
              ELSE LET x == CHOOSE x \in S : \A y \in S : Depth(x) <= Depth(y)
                   IN <<x>> \o Ordered(S \ {x})
RECURSIVE Subtree(_, _)
Subtree(t, x) == {x} \cup UNION {Subtree(t, y) : y \in {z \in Mnts : t[z].hashed /\ t[z].parent = x}}

ActiveRcu == {v \in Walkers : w[v].pc \in RcuPcs}
\* a writer took mount_lock: every sample taken before is stale
StaleAll == [v \in Walkers |-> IF w[v].pc \in RcuPcs THEN [w[v] EXCEPT !.stale = TRUE] ELSE w[v]]

StandIn(d) == IF d \in DirDentries THEN Knullfs ELSE KnullfsFile
\* the mount of the layout that sat on d under p
ChildAt(p, d) == LET X == {x \in Mnts : ParentOf[x] = p /\ MpOf[x] = d}
                 IN IF X = {} THEN NoMnt ELSE CHOOSE x \in X : TRUE

(* ---- what the code does, on a state record ----------------------------- *)

SOf == [m |-> m, cov |-> cov, covwait |-> covwait, mpa |-> mpa, mounted |-> mounted,
        mlist |-> mlist, mcov |-> mcov, ev |-> ev, bad |-> bad]
Apply(S) == /\ m' = S.m /\ cov' = S.cov /\ covwait' = S.covwait /\ mpa' = S.mpa
            /\ mounted' = S.mounted /\ mlist' = S.mlist /\ mcov' = S.mcov /\ ev' = S.ev /\ bad' = S.bad

\* maybe_free_mountpoint(): the last mount and the last cover gone, the
\* mountpoint is freed and the dentry loses DCACHE_MOUNTED
MaybeFreeMp(S, d) ==
    IF ~S.mpa[d] THEN [S EXCEPT !.bad = @ \cup {"mp_uaf"}]
    ELSE IF S.mlist[d] = {} /\ S.mcov[d] = {} THEN [S EXCEPT !.mpa[d] = FALSE, !.mounted[d] = FALSE]
    ELSE S

\* leave_cover(): the cover v allocated goes on its parent p and, with
\* MP_PIN, pins the mountpoint once v lets go of it
LeaveCover(S, v, p) ==
    LET d == MpOf[v]
    IN [S EXCEPT !.bad = (IF S.cov[v] # "own" THEN @ \cup {"double_leave"} ELSE @)
                         \cup (IF MP_PIN /\ ~S.mpa[d] THEN {"mp_uaf"} ELSE {}),
                 !.cov[v] = "listed",
                 !.m[p].covers = @ \cup {v},
                 !.mcov[d] = IF MP_PIN THEN @ \cup {v} ELSE @,
                 !.ev = @ \cup {"leave"}]

\* umount_mnt(): out of the hash and off the mountpoint
UmountMnt(S, v) ==
    LET d == MpOf[v]
    IN MaybeFreeMp([S EXCEPT !.m[v].hashed = FALSE, !.m[v].parent = NoMnt, !.mlist[d] = @ \ {v}], d)

\* drop_cover(), under mount_lock: off the parent and the mountpoint, freed
\* after the RCU readers of the moment are done
DropCover(S, c, why) ==
    LET d == MpOf[c]
        p == ParentOf[c]
        S1 == [S EXCEPT !.bad = IF S.cov[c] # "listed" THEN @ \cup {"double_drop"} ELSE @,
                        !.cov[c] = IF RCU_FREE THEN "dropped" ELSE "freed",
                        !.covwait[c] = ActiveRcu,
                        !.m[p].covers = @ \ {c},
                        !.mcov[d] = @ \ {c},
                        !.ev = @ \cup {why}]
    IN MaybeFreeMp(S1, d)
RECURSIVE DropAll(_, _, _)
DropAll(S, C, why) == IF C = {} THEN S
                      ELSE LET c == CHOOSE c \in C : TRUE IN DropAll(DropCover(S, c, why), C \ {c}, why)

\* needs_cover(): not for a synchronous umount, only below an unmounted
\* parent, when the umount asks for it or the mount is locked
NeedsCover(t, v, how) ==
    /\ ~how.sync /\ t[v].hashed /\ t[v].parent # NoMnt /\ t[t[v].parent].umount
    /\ (how.cover \/ v \in Locked)

\* one victim of umount_tree(): leave the cover if it needs one, detach it
Victim(S, v, how) ==
    IF ~(S.m[v].hashed /\ S.m[v].parent # NoMnt) THEN S
    ELSE LET p == S.m[v].parent
             need == FIX_COVER /\ NeedsCover(S.m, v, how)
         IN IF COVER_FIRST
            THEN UmountMnt(IF need THEN LeaveCover(S, v, p) ELSE S, v)
            ELSE LET S1 == UmountMnt(S, v) IN IF need THEN LeaveCover(S1, v, p) ELSE S1

\* mntput(): the fast path while the mount is in a namespace, else
\* mntput_no_expire_slowpath() under mount_lock: the last reference dooms
\* the mount and drops the covers its children left on it
Put(S, x) ==
    IF S.m[x].ns THEN [S EXCEPT !.m[x].count = @ - 1]
    ELSE LET c == S.m[x].count - 1
         IN IF c > 0 \/ S.m[x].doomed THEN [S EXCEPT !.m[x].count = c]
            ELSE LET S1 == [S EXCEPT !.m[x].count = 0, !.m[x].doomed = TRUE, !.m[x].st = "cleanup",
                                     !.bad = IF \E y \in Mnts : S.m[y].hashed /\ S.m[y].parent = x
                                             THEN @ \cup {"attached_child"} ELSE @]
                 IN IF PUT_DROPS THEN DropAll(S1, S1.m[x].covers, "put_drop") ELSE S1
\* a put that takes mount_lock invalidates the RCU samples
SlowPut(x) == ~m[x].ns

\* what a lookup at d on p finds against a quiescent mount_lock
SeqLookup(p, d) ==
    IF ~mounted[d] THEN Dent
    ELSE LET X == {x \in Mnts : m[x].hashed /\ m[x].parent = p /\ MpOf[x] = d}
         IN IF X # {} THEN CHOOSE x \in X : TRUE
            ELSE IF m[p].umount /\ \E c \in m[p].covers : MpOf[c] = d THEN StandIn(d)
            ELSE Dent

\* a lookup at d on p must not show what the child there covered while the
\* child is still mounted or was unmounted with a required cover
Required(p, d) == LET x == ChildAt(p, d)
                  IN x # NoMnt /\ ((m[x].hashed /\ m[x].parent = p) \/ x \in covreq)
Unmounted(p, d) == LET x == ChildAt(p, d) IN x # NoMnt /\ m[x].umount

(* ---- the unmounting task ------------------------------------------------ *)

\* namespace_lock(), lock_mount_hash(), umount_tree(): MNT_UMOUNT on the
\* whole set first; rmdir drops the name first
UStart(op) ==
    /\ u.pc = "idle" /\ op \notin u.done /\ lock = "free"
    /\ CASE op.kind = "lazy"    -> m[op.mnt].ns /\ m[op.mnt].hashed
         [] op.kind = "nsdeath" -> m[Root].ns
         [] op.kind = "detach"  -> linked[op.d]
    /\ LET targets == CASE op.kind = "detach"  -> {x \in Mnts : m[x].hashed /\ MpOf[x] = op.d}
                        [] op.kind = "lazy"    -> {op.mnt}
                        [] op.kind = "nsdeath" -> {Root}
           victims == UNION {Subtree(m, x) : x \in targets}
       IN /\ m' = [x \in Mnts |-> IF x \in victims THEN [m[x] EXCEPT !.umount = TRUE, !.ns = FALSE] ELSE m[x]]
          /\ u' = [u EXCEPT !.pc = "ut", !.op = op, !.todo = Ordered(victims), !.unm = <<>>,
                            !.how = [sync |-> FALSE, cover |-> op.kind = "detach"]]
    /\ lock' = "U"
    /\ w' = StaleAll
    /\ linked' = IF op.kind = "detach" THEN [linked EXCEPT ![op.d] = FALSE] ELSE linked
    /\ UNCHANGED <<cov, covwait, mpa, mounted, mlist, mcov, held, covreq, ev, bad>>

UVictim ==
    /\ u.pc = "ut" /\ u.todo # <<>>
    /\ LET v == Head(u.todo)
       IN /\ Apply(Victim(SOf, v, u.how))
          /\ covreq' = IF NeedsCover(m, v, u.how) THEN covreq \cup {v} ELSE covreq
          /\ u' = [u EXCEPT !.todo = Tail(@), !.unm = <<v>> \o @]
    /\ UNCHANGED <<linked, lock, held, w>>

\* __detach_mounts(): the covers left on the removed dentry go as well
UEndTree ==
    /\ u.pc = "ut" /\ u.todo = <<>>
    /\ u' = [u EXCEPT !.pc = IF u.op.kind = "detach" THEN "drops" ELSE "unlock",
                      !.drops = IF u.op.kind = "detach" /\ DETACH_DROPS /\ mpa[u.op.d] THEN mcov[u.op.d] ELSE {}]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, held, w, covreq, ev, bad>>

UDrop ==
    /\ u.pc = "drops" /\ u.drops # {}
    /\ \E c \in u.drops :
        /\ Apply(DropCover(SOf, c, "detach_drop"))
        /\ u' = [u EXCEPT !.drops = @ \ {c}]
    /\ UNCHANGED <<linked, lock, held, w, covreq>>

UEndDrops ==
    /\ u.pc = "drops" /\ u.drops = {}
    /\ u' = [u EXCEPT !.pc = "unlock"]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, held, w, covreq, ev, bad>>

\* unlock_mount_hash(), then namespace_unlock(): a grace period before the
\* references of the unmounted list are dropped, if there are any
UUnlock ==
    /\ u.pc = "unlock"
    /\ lock' = "free"
    /\ u' = [u EXCEPT !.pc = "gp", !.gpw = ActiveRcu]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, held, w, covreq, ev, bad>>

UGp ==
    /\ u.pc = "gp" /\ u.gpw \cap ActiveRcu = {}
    /\ u' = [u EXCEPT !.pc = IF u.unm = <<>> THEN "idle" ELSE "puts",
                      !.done = IF u.unm = <<>> THEN @ \cup {u.op} ELSE @]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, held, w, covreq, ev, bad>>

UPut ==
    /\ u.pc = "puts" /\ u.unm # <<>> /\ lock = "free"
    /\ LET x == Head(u.unm)
       IN /\ Apply(Put(SOf, x))
          /\ w' = IF SlowPut(x) THEN StaleAll ELSE w
          /\ u' = [u EXCEPT !.unm = Tail(@),
                            !.pc = IF Tail(u.unm) = <<>> THEN "idle" ELSE "puts",
                            !.done = IF Tail(u.unm) = <<>> THEN @ \cup {u.op} ELSE @]
    /\ UNCHANGED <<linked, lock, held, covreq>>

(* ---- holders, cleanup and RCU ------------------------------------------- *)

Close(h) ==
    /\ held[h] /\ lock = "free"
    /\ Apply(Put(SOf, HolderMnt[h]))
    /\ w' = IF SlowPut(HolderMnt[h]) THEN StaleAll ELSE w
    /\ held' = [held EXCEPT ![h] = FALSE]
    /\ UNCHANGED <<linked, lock, u, covreq>>

\* cleanup_mnt() from task work, then delayed_free_vfsmnt() after a grace
\* period; free_vfsmnt() frees the cover the mount did not leave behind
Cleanup(x) ==
    /\ m[x].st = "cleanup"
    /\ m' = [m EXCEPT ![x].st = "rcu", ![x].waiters = ActiveRcu]
    /\ UNCHANGED <<cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, w, covreq, ev, bad>>

ReclaimMnt(x) ==
    /\ m[x].st = "rcu" /\ m[x].waiters \cap ActiveRcu = {}
    /\ m' = [m EXCEPT ![x].st = "freed"]
    /\ cov' = IF cov[x] = "own" THEN [cov EXCEPT ![x] = "freed"] ELSE cov
    /\ UNCHANGED <<covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, w, covreq, ev, bad>>

ReclaimCover(c) ==
    /\ cov[c] = "dropped" /\ covwait[c] \cap ActiveRcu = {}
    /\ cov' = [cov EXCEPT ![c] = "freed"]
    /\ UNCHANGED <<m, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, w, covreq, ev, bad>>

(* ---- the walkers ---------------------------------------------------------- *)

From(v) == HolderMnt[WalkFrom[v]]
At(v) == WalkAt[v]
\* the stand-ins a walk found, for the witnesses
Found(r) == CASE r = Knullfs -> {"standin"} [] r = KnullfsFile -> {"standin_file"} [] OTHER -> {}
Decide(v, r) == [res |-> r, req |-> Required(From(v), At(v)), linked |-> linked[At(v)],
                 unmounted |-> Unmounted(From(v), At(v))]

\* the walk borrows its holder's file and samples mount_lock (read_seqbegin())
WStart(v) ==
    /\ w[v].pc = "idle" /\ held[WalkFrom[v]] /\ lock = "free"
    /\ m' = [m EXCEPT ![From(v)].count = @ + 1]
    /\ w' = [w EXCEPT ![v].pc = "mounted", ![v].stale = FALSE]
    /\ UNCHANGED <<cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, ev, bad>>

\* __follow_mount_rcu(): without DCACHE_MOUNTED the walk stays on the dentry
WMounted(v) ==
    /\ w[v].pc = "mounted"
    /\ w' = [w EXCEPT ![v].pc = IF mounted[At(v)] THEN "hash" ELSE "check",
                      ![v].res = IF mounted[At(v)] THEN @ ELSE Dent]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, ev, bad>>

\* __lookup_mnt(): the hash
WHash(v) ==
    /\ w[v].pc = "hash"
    /\ LET X == {x \in Mnts : m[x].hashed /\ m[x].parent = From(v) /\ MpOf[x] = At(v)}
       IN /\ w' = [w EXCEPT ![v].pc = IF X # {} THEN "check" ELSE "flag",
                            ![v].res = IF X # {} THEN CHOOSE x \in X : TRUE ELSE @]
          /\ bad' = IF \E x \in X : m[x].st = "freed" THEN bad \cup {"mnt_uaf"} ELSE bad
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, ev>>

\* __lookup_mnt(): data_race(mnt->mnt_flags) & MNT_UMOUNT
WFlag(v) ==
    /\ w[v].pc = "flag"
    /\ w' = [w EXCEPT ![v].pc = IF m[From(v)].umount THEN "covers" ELSE "check",
                      ![v].res = IF m[From(v)].umount THEN @ ELSE Dent]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, ev, bad>>

\* __lookup_mnt(): hlist_for_each_entry_rcu() over mnt_covers takes the
\* pointers, the next step dereferences them
WCovers(v) ==
    /\ w[v].pc = "covers"
    /\ w' = [w EXCEPT ![v].pc = "deref", ![v].seen = m[From(v)].covers]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, ev, bad>>

WDeref(v) ==
    /\ w[v].pc = "deref"
    /\ bad' = IF \E c \in w[v].seen : cov[c] = "freed" THEN bad \cup {"cover_uaf"} ELSE bad
    /\ w' = [w EXCEPT ![v].pc = "check",
                      ![v].res = IF \E c \in w[v].seen : MpOf[c] = At(v) THEN StandIn(At(v)) ELSE Dent]
    /\ UNCHANGED <<m, cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, ev>>

\* read_seqretry(): an unchanged sample keeps the result, legitimized
\* (a reference on the mount found); a stale one drops to ref mode
WCheck(v) ==
    /\ w[v].pc = "check"
    /\ IF w[v].stale
       THEN /\ w' = [w EXCEPT ![v].pc = "ref"]
            /\ UNCHANGED <<m, ev>>
       ELSE /\ w' = [w EXCEPT ![v].pc = "done", ![v].dec = Decide(v, w[v].res)]
            /\ m' = IF w[v].res \in Mnts THEN [m EXCEPT ![w[v].res].count = @ + 1] ELSE m
            /\ ev' = ev \cup Found(w[v].res)
    /\ UNCHANGED <<cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, bad>>

\* ref mode: lookup_mnt() retries until legitimize_mnt() succeeds, which is
\* a lookup against a quiescent mount_lock
WRef(v) ==
    /\ w[v].pc = "ref" /\ lock = "free"
    /\ LET r == SeqLookup(From(v), At(v))
       IN /\ w' = [w EXCEPT ![v].pc = "done", ![v].res = r, ![v].dec = Decide(v, r)]
          /\ m' = IF r \in Mnts THEN [m EXCEPT ![r].count = @ + 1] ELSE m
          /\ ev' = ev \cup Found(r)
    /\ UNCHANGED <<cov, covwait, mpa, mounted, mlist, mcov, linked, lock, u, held, covreq, bad>>

\* path_put() at the end of the walk, and the borrowed file goes back
WDone(v) ==
    /\ w[v].pc = "done" /\ lock = "free"
    /\ LET r == w[v].res
           S1 == IF r \in Mnts THEN Put(SOf, r) ELSE SOf
           ws == IF (r \in Mnts /\ SlowPut(r)) \/ SlowPut(From(v)) THEN StaleAll ELSE w
       IN /\ Apply(Put(S1, From(v)))
          /\ w' = [ws EXCEPT ![v].pc = "fin"]
    /\ UNCHANGED <<linked, lock, u, held, covreq>>

(* ---- the specification -------------------------------------------------- *)

Settled ==
    /\ u.pc = "idle" /\ \A h \in Holders : ~held[h]
    /\ \A v \in Walkers : w[v].pc \in {"idle", "fin"}
    /\ \A x \in Mnts : m[x].st \in {"live", "freed"}
    /\ \A c \in Mnts : cov[c] # "dropped"

Init ==
    /\ m = [x \in Mnts |-> [hashed |-> ParentOf[x] # NoMnt, parent |-> ParentOf[x], umount |-> FALSE,
                            ns |-> TRUE, count |-> 1 + Cardinality({h \in Holders : HolderMnt[h] = x}),
                            doomed |-> FALSE, st |-> "live", covers |-> {}, waiters |-> {}]]
    /\ cov = [x \in Mnts |-> "own"]
    /\ covwait = [x \in Mnts |-> {}]
    /\ mlist = [d \in Dentries |-> {x \in Mnts : MpOf[x] = d /\ ParentOf[x] # NoMnt}]
    /\ mpa = [d \in Dentries |-> mlist[d] # {}]
    /\ mounted = mpa
    /\ mcov = [d \in Dentries |-> {}]
    /\ linked = [d \in Dentries |-> TRUE]
    /\ lock = "free"
    /\ u = [pc |-> "idle", op |-> NoOp, how |-> [sync |-> FALSE, cover |-> FALSE], todo |-> <<>>,
            unm |-> <<>>, drops |-> {}, gpw |-> {}, done |-> {}]
    /\ held = [h \in Holders |-> TRUE]
    /\ w = [v \in Walkers |-> [pc |-> "idle", stale |-> FALSE, res |-> Dent, seen |-> {}, dec |-> NoDec]]
    /\ covreq = {}
    /\ ev = {}
    /\ bad = {}

Next ==
    \/ \E op \in Ops : UStart(op)
    \/ UVictim \/ UEndTree \/ UDrop \/ UEndDrops \/ UUnlock \/ UGp \/ UPut
    \/ \E h \in Holders : Close(h)
    \/ \E x \in Mnts : Cleanup(x) \/ ReclaimMnt(x) \/ ReclaimCover(x)
    \/ \E v \in Walkers : \/ WStart(v) \/ WMounted(v) \/ WHash(v) \/ WFlag(v) \/ WCovers(v)
                          \/ WDeref(v) \/ WCheck(v) \/ WRef(v) \/ WDone(v)
    \/ (Settled /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* ---- what is checked ---------------------------------------------------- *)

TypeOK == \A x \in Mnts : m[x].count >= 0

\* no use after free of a mount, a cover or a mountpoint, no cover left or
\* dropped twice, nothing attached to a mount at its final put
NoBad == bad = {}

\* no lookup on an unmounted parent shows what a child that had to stay
\* covered was covering, while that dentry is still there
NoReveal == \A v \in Walkers : w[v].dec.res = Dent => ~(w[v].dec.req /\ w[v].dec.linked)

\* a listed cover sits on its unmounted, living parent and keeps its
\* mountpoint and DCACHE_MOUNTED
CoversOK ==
    /\ \A c \in Mnts : cov[c] = "listed" =>
          /\ c \in m[ParentOf[c]].covers /\ m[ParentOf[c]].umount /\ m[ParentOf[c]].st = "live"
          /\ (MP_PIN => (mpa[MpOf[c]] /\ mounted[MpOf[c]] /\ c \in mcov[MpOf[c]]))
    /\ \A x \in Mnts : m[x].covers \subseteq {c \in Mnts : cov[c] = "listed"}

\* a mountpoint exists while a mount or a cover is on it, and DCACHE_MOUNTED
\* with it
MountpointOK == \A d \in Dentries : /\ mpa[d] = (mlist[d] # {} \/ mcov[d] # {})
                                    /\ mounted[d] = mpa[d]

\* once nothing is going on anymore, every unmounted mount is freed, every
\* cover is freed or still with a mounted mount, and only the dentries
\* mounts sit on are mountpoints
Reaped == Settled =>
    /\ \A x \in Mnts : m[x].umount => m[x].st = "freed"
    /\ \A c \in Mnts : cov[c] \in {"own", "freed"}
    /\ \A d \in Dentries : mpa[d] = (mlist[d] # {})

\* witnesses
NoStandIn == "standin" \notin ev
NoFileStandIn == "standin_file" \notin ev
NoDetachDrop == "detach_drop" \notin ev
NoPutDrop == "put_drop" \notin ev
\* a lookup lands on the dentry of a child unmounted without a required
\* cover: what a lazy umount of an unlocked mount always allowed
NoAllowedReveal == \A v \in Walkers : ~(w[v].dec.res = Dent /\ w[v].dec.linked /\ w[v].dec.unmounted /\ ~w[v].dec.req)
=============================================================================

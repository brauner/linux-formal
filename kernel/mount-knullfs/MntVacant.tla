----------------------------- MODULE MntVacant -----------------------------
(***************************************************************************)
(* The lifetime of an unmounted mount that stays attached to its unmounted *)
(* parent, as work.mount.knullfs makes it (namespace: prevent              *)
(* UMOUNT_CONNECTED reference count cycles):                               *)
(*   - every victim of umount_tree() keeps its own reference, attached or  *)
(*     not, and namespace_unlock() drops those references in tree order;   *)
(*   - a mount that loses its last reference while still attached is       *)
(*     vacated in place by mntput_no_expire_slowpath(): its children are   *)
(*     unhashed (the vacant ones become its stuck children), it is pointed *)
(*     at knullfs (mnt_sb, mnt_root, the instance list), it gets one       *)
(*     reference owned by the parent, and the release of the filesystem it *)
(*     carried is left to cleanup_mnt()'s release visit (task work);       *)
(*   - the parent's final put unhashes its children and puts only the      *)
(*     vacant ones from cleanup_mnt(); __detach_mounts() puts a vacant      *)
(*     mount it unhashes from namespace_unlock();                          *)
(*   - the release visit (vacant_mount_released()) and the last put of a   *)
(*     vacant mount (vacant_mount_put()) each leave their mark under        *)
(*     mount_lock -- mnt_old_root cleared, MNT_DOOMED set -- and whoever    *)
(*     finds the other's mark frees the mount.                              *)
(*                                                                         *)
(* Layout: P, the root of a lazily unmounted subtree, disconnected from    *)
(* its mounted parent; M attached to P; G attached to M, all MNT_UMOUNT    *)
(* with mnt_ns NULL (UMOUNT_CONNECTED, or M and G locked).  The initial    *)
(* state is namespace_unlock() right after up_write(&namespace_sem).  A    *)
(* superblock may pin a mount through a file its filesystem keeps open (M's *)
(* loop device's backing file on P, G's on M: Michael Vogt's cycle), a     *)
(* reference dropped when the superblock is deactivated.                   *)
(*                                                                         *)
(* Tasks: U runs namespace_unlock()'s synchronize_rcu_expedited() and puts;*)
(* holders close their files on P or M; walkers do RCU path walks from a   *)
(* holder's file into the mount below it (__lookup_mnt(),                  *)
(* __legitimize_mnt(), mntput(), or the REF walk after -ECHILD); D removes *)
(* a mountpoint directory (vfs_rmdir() -> __detach_mounts(), then          *)
(* namespace_unlock()); the pin drops are the fput() of a released          *)
(* filesystem's file; cleanup_mnt() items run as task work, in any order   *)
(* and at any time, a superset of the kernel's per-task LIFO order.        *)
(*                                                                         *)
(* Every mount_lock section is one step: seq goes up by one per write      *)
(* section, a mount_locked_reader section leaves it alone.  Memory is      *)
(* sequentially consistent; the one lockless pair, __legitimize_mnt()'s    *)
(* increment against the slow path's sum, is proven in MntPut.tla and       *)
(* taken as given here.  RCU: a walker is a reader from path_init() to the  *)
(* end of its RCU walk; call_rcu() frees once every reader present at the   *)
(* call has left, synchronize_rcu_expedited() waits for the same.          *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets

CONSTANTS
    MntIds,          \* the mounts
    Parent,          \* [MntIds -> MntIds \cup {NoMnt}]: the tree after umount_tree(); the subtree root has none
    SbIds,           \* the superblocks, one mount each
    Sb,              \* [MntIds -> SbIds]
    Pin,             \* [SbIds -> MntIds \cup {NoMnt}]: the mount a superblock's file pins
    Holders,         \* holder tasks, one file each
    HolderMnt,       \* [Holders -> MntIds]: the mount the holder's file is on
    Walkers,         \* walker tasks
    WalkBudget,      \* walks per walker
    DetachTargets,   \* mounts whose mountpoint directory may be removed
    HOLDER_ORDER,    \* "any"; "early": the subtree root's holder closes before U puts
                     \* (dissolve_on_fput() dropping the file's reference under namespace_sem,
                     \* ksys_unshare() freeing the old fs_struct first); "late": after U is done
    FIX_OWN_REF,     \* attached victims keep their own reference, put by namespace_unlock()
                     \* (off: owned by the parent and put by its cleanup_mnt(), as upstream)
    VACATE_MODE,     \* "vacate": the series; "doom": the last put of an attached mount dooms
                     \* it in place, as the upstream slow path would; "unhash": it disconnects it
    FIX_STUCK_VACANT_ONLY,    \* the parent's final put owns only its vacant children (off: every unhashed child)
    FIX_TREE_ORDER,           \* namespace_unlock() puts parents first (off: children first, the hlist order)
    FIX_DETACH_PUTS_VACANT,   \* __detach_mounts() puts a vacant mount it unhashes (off: never)
    DETACH_PUTS_ALL,          \* mutation: __detach_mounts() puts every unmounted mount it unhashes
    FIX_HANDOFF_LOCKED,       \* release and last put decide under mount_lock (off: after dropping it)
    FIX_STUCK_BEFORE_HANDOFF, \* the release visit puts the stuck children before its handoff (off: after)
    RELEASE_PUTS              \* the earlier design: vacate takes two references, the release visit ends in mntput()

NoMnt == 0
ASSUME VACATE_MODE \in {"vacate", "doom", "unhash"}
ASSUME HOLDER_ORDER \in {"any", "early", "late"}
ASSUME \A h \in Holders : HolderMnt[h] \in MntIds

VARIABLES
    mt,        \* [MntIds -> record]: hashed, parent, count, doomed, vacant, oldroot (release pending),
               \*   inst ("fs", "null", "none": which instance list), stuck, freed, rcufree, mpgone
    sbact,     \* [SbIds -> BOOLEAN]: the superblock is active
    seq,       \* mount_lock's sequence count
    uhead,     \* the mounts namespace_unlock() still has to put, in order
    upc,       \* U: "gp", "wait", "put", "done"
    ugp,       \* the readers U's synchronize_rcu_expedited() waits for
    ext,       \* [MntIds -> Nat]: holders' references
    hdone,     \* [Holders -> BOOLEAN]
    wpc, wsrc, wtgt, wseq, wroot, wres, wn,   \* the walkers
    rcu,       \* the readers
    dpc, dhead, dgp, dtargets,   \* D: "idle", "gp", "put"; its unmounted list; its grace period; targets left
    tw,        \* pending cleanup_mnt() items: [m, kind ("cleanup" | "release"), step]
    pchk, rchk,    \* the unlocked handoff checks still to run (FIX_HANDOFF_LOCKED off)
    pins,      \* mounts whose pin reference is being dropped
    freewait,  \* [MntIds -> SUBSET Walkers]: the readers the RCU free of a mount waits for
    hist

vars == <<mt, sbact, seq, uhead, upc, ugp, ext, hdone, wpc, wsrc, wtgt, wseq, wroot, wres, wn,
          rcu, dpc, dhead, dgp, dtargets, tw, pchk, rchk, pins, freewait, hist>>

(* ---- helpers ------------------------------------------------------------ *)

InSeq(x, s) == \E i \in 1..Len(s) : s[i] = x
RECURSIVE Depth(_)
Depth(m) == IF Parent[m] = NoMnt THEN 0 ELSE 1 + Depth(Parent[m])
Before(x, y) == Depth(x) < Depth(y) \/ (Depth(x) = Depth(y) /\ x <= y)
RECURSIVE Ordered(_)
Ordered(S) == IF S = {} THEN <<>>
              ELSE LET x == CHOOSE x \in S : \A y \in S : Before(x, y)
                   IN <<x>> \o Ordered(S \ {x})
Reverse(s) == [i \in 1..Len(s) |-> s[Len(s) + 1 - i]]
Kids(t, m) == {c \in MntIds : ~t[c].freed /\ t[c].hashed /\ t[c].parent = m}
Ext0(m) == Cardinality({h \in Holders : HolderMnt[h] = m})
Pinned0(m) == Cardinality({s \in SbIds : Pin[s] = m})
RootHolders == {h \in Holders : Parent[HolderMnt[h]] = NoMnt}

\* the whole state as a record, so that a step can be composed of the
\* kernel's pieces (a put may vacate, free, queue task work, ...)
St == [mt |-> mt, sbact |-> sbact, seq |-> seq, uhead |-> uhead, upc |-> upc, ugp |-> ugp,
       ext |-> ext, hdone |-> hdone, wpc |-> wpc, wsrc |-> wsrc, wtgt |-> wtgt, wseq |-> wseq,
       wroot |-> wroot, wres |-> wres, wn |-> wn, rcu |-> rcu, dpc |-> dpc, dhead |-> dhead,
       dgp |-> dgp, dtargets |-> dtargets, tw |-> tw, pchk |-> pchk, rchk |-> rchk, pins |-> pins,
       freewait |-> freewait, hist |-> hist]
Apply(s) ==
    /\ mt' = s.mt /\ sbact' = s.sbact /\ seq' = s.seq /\ uhead' = s.uhead /\ upc' = s.upc
    /\ ugp' = s.ugp /\ ext' = s.ext /\ hdone' = s.hdone /\ wpc' = s.wpc /\ wsrc' = s.wsrc
    /\ wtgt' = s.wtgt /\ wseq' = s.wseq /\ wroot' = s.wroot /\ wres' = s.wres /\ wn' = s.wn
    /\ rcu' = s.rcu /\ dpc' = s.dpc /\ dhead' = s.dhead /\ dgp' = s.dgp /\ dtargets' = s.dtargets
    /\ tw' = s.tw /\ pchk' = s.pchk /\ rchk' = s.rchk /\ pins' = s.pins
    /\ freewait' = s.freewait /\ hist' = s.hist

\* rcu_read_unlock() of walker w: the grace periods and RCU frees waiting for it stop waiting
RcuOut(s, w) == [s EXCEPT !.rcu = @ \ {w}, !.ugp = @ \ {w}, !.dgp = @ \ {w},
                          !.freewait = [m \in MntIds |-> @[m] \ {w}]]
Warn(s, w) == [s EXCEPT !.hist.warn = @ \cup {w}]

(* ---- freeing ------------------------------------------------------------ *)

\* mnt_free_id() + call_rcu(delayed_free_vfsmnt): the memory goes once the
\* readers present now have left.  The VFS_WARN_ON_ONCEs of
\* free_vacant_mount() and the sanity of freeing a hashed or listed mount
\* are recorded as warnings
Free(s, m) ==
    LET t == s.mt[m]
        w == (IF t.stuck # {} THEN {"free_stuck"} ELSE {})
             \cup (IF t.inst # "none" THEN {"free_instance"} ELSE {})
             \cup (IF t.hashed THEN {"free_hashed"} ELSE {})
             \cup (IF t.rcufree THEN {"double_free"} ELSE {})
    IN [s EXCEPT !.mt[m].rcufree = TRUE, !.freewait[m] = s.rcu,
                 !.hist.frees[m] = @ + 1, !.hist.warn = @ \cup w]

(* ---- the slow path of mntput() ------------------------------------------ *)

\* vacant_mount_put(): the last put of a vacant mount, under mount_lock;
\* MNT_DOOMED, off knullfs' instance list, and the mount is freed unless the
\* release visit is still pending (mnt_old_root set), in which case the
\* release frees it
VacantPut(s, m, who) ==
    LET t == s.mt[m]
        w == (IF t.hashed THEN {"vacant_put_attached"} ELSE {})
             \cup (IF t.inst # "null" THEN {"instance"} ELSE {})
             \cup (IF RELEASE_PUTS /\ t.oldroot THEN {"release_pending_at_free"} ELSE {})
        s1 == [s EXCEPT !.mt[m].doomed = TRUE, !.mt[m].inst = "none",
                        !.hist.warn = @ \cup w, !.hist.doomby = @ \cup {who}]
    IN IF RELEASE_PUTS THEN Free(s1, m)
       ELSE IF ~FIX_HANDOFF_LOCKED THEN [s1 EXCEPT !.pchk = @ \cup {m}]   \* decided after unlock_mount_hash()
       ELSE IF t.oldroot THEN [s1 EXCEPT !.hist.putfirst = @ + 1]
       ELSE Free(s1, m)

\* the rest of mntput_no_expire_slowpath() once the count reached zero and
\* the mount is neither doomed nor vacant: unhash the children (the vacant
\* ones, or with the mutation every one, become stuck children put by
\* cleanup_mnt()); then either vacate_mount() while still attached, or
\* MNT_DOOMED and cleanup_mnt() as task work
LastPut(s, m, who) ==
    LET t == s.mt[m]
        connected == t.hashed /\ t.parent # NoMnt
        kids == Kids(s.mt, m)
        stuck == IF FIX_OWN_REF /\ FIX_STUCK_VACANT_ONLY THEN {c \in kids : s.mt[c].vacant} ELSE kids
        vac == FIX_OWN_REF /\ connected /\ VACATE_MODE = "vacate"
        unh == FIX_OWN_REF /\ connected /\ VACATE_MODE = "unhash"
        self == IF vac
                THEN [t EXCEPT !.vacant = TRUE, !.oldroot = TRUE, !.inst = "null", !.stuck = stuck,
                               !.count = IF RELEASE_PUTS THEN 2 ELSE 1]
                ELSE [t EXCEPT !.doomed = TRUE, !.inst = "none", !.stuck = stuck,
                               !.hashed = IF unh THEN FALSE ELSE t.hashed,
                               !.parent = IF unh THEN NoMnt ELSE t.parent]
        mt1 == [x \in MntIds |-> IF x = m THEN self
                                 ELSE IF x \in kids THEN [s.mt[x] EXCEPT !.hashed = FALSE, !.parent = NoMnt]
                                 ELSE s.mt[x]]
        item == [m |-> m, kind |-> IF vac THEN "release" ELSE "cleanup",
                 step |-> IF vac /\ ~FIX_STUCK_BEFORE_HANDOFF THEN "sb" ELSE "stuck"]
        \* a vacate the put order alone caused: the parent lives on the
        \* reference U has not dropped yet and on nothing else
        needless == vac /\ s.mt[t.parent].count = 1 /\ InSeq(t.parent, s.uhead)
        w == IF connected /\ ~vac /\ ~unh THEN {"doomed_attached"} ELSE {}
    IN [s EXCEPT !.mt = mt1, !.tw = @ \cup {item},
                 !.hist.vacates = @ + (IF vac THEN 1 ELSE 0),
                 !.hist.needless = @ + (IF needless THEN 1 ELSE 0),
                 !.hist.vacby = @ \cup (IF vac THEN {who} ELSE {}),
                 !.hist.doomby = @ \cup (IF vac THEN {} ELSE {who}),
                 !.hist.warn = @ \cup w]

\* mntput() on a mount with mnt_ns NULL: lock_mount_hash(), the decrement,
\* mnt_get_count(); not the last, a second final put on a doomed mount
\* (returns), the last put of a vacant mount, or the last put
Put(s, m, who) ==
    LET t == s.mt[m]
        c == t.count - 1
        s0 == [s EXCEPT !.mt[m].count = c, !.seq = @ + 1]
    IN IF c < 0 THEN [s0 EXCEPT !.hist.negative = TRUE]
       ELSE IF c > 0 THEN s0
       ELSE IF t.doomed THEN Warn(s0, "put_doomed")
       ELSE IF t.vacant THEN VacantPut(s0, m, who)
       ELSE LastPut(s0, m, who)

(* ---- cleanup_mnt() as task work ------------------------------------------ *)

\* the steps of an item: a doomed mount's cleanup puts its stuck children,
\* releases its filesystem and frees itself; the release visit of a vacant
\* mount puts its stuck children, releases the filesystem it carried and
\* hands off (the mutation hands off before the stuck children are put)
NextStep(it) ==
    IF it.kind = "cleanup"
    THEN (IF it.step = "stuck" THEN "sb" ELSE IF it.step = "sb" THEN "free" ELSE "done")
    ELSE IF FIX_STUCK_BEFORE_HANDOFF
         THEN (IF it.step = "stuck" THEN "sb" ELSE IF it.step = "sb" THEN "handoff" ELSE "done")
         ELSE (IF it.step = "sb" THEN "handoff" ELSE IF it.step = "handoff" THEN "stuck" ELSE "done")
Advance(s, it) ==
    LET nxt == NextStep(it)
    IN [s EXCEPT !.tw = IF nxt = "done" THEN @ \ {it} ELSE (@ \ {it}) \cup {[it EXCEPT !.step = nxt]}]

\* hlist_del(&m->mnt_umount); mntput(&m->mnt) for one stuck child
TwStuck(it) ==
    /\ it.step = "stuck"
    /\ IF mt[it.m].stuck = {}
       THEN Apply(Advance(St, it))
       ELSE \E c \in mt[it.m].stuck :
                Apply(Put([St EXCEPT !.mt[it.m].stuck = @ \ {c}], c, "C"))

\* fsnotify_vfsmount_delete(), dput(root), deactivate_super(sb): the
\* filesystem the mount carried goes, and its file lets go of what it
\* pinned; a walker that crossed into the mount and is still inside in
\* RCU mode sees the teardown (NoRcuTeardown)
TwSb(it) ==
    /\ it.step = "sb"
    /\ LET sb == Sb[it.m]
           inside == \E w \in Walkers : wtgt[w] = it.m /\ wpc[w] \in {"legit1", "legit2", "lock"}
           s1 == [St EXCEPT !.sbact[sb] = FALSE,
                            !.pins = @ \cup (IF Pin[sb] # NoMnt THEN {Pin[sb]} ELSE {}),
                            !.hist.releases[it.m] = @ + 1,
                            !.hist.rcuteardown = @ \/ inside,
                            !.hist.warn = @ \cup (IF sbact[sb] THEN {} ELSE {"double_release"})]
       IN Apply(Advance(s1, it))

\* the final mnt_free_id() + call_rcu() of a doomed mount
TwFree(it) ==
    /\ it.step = "free"
    /\ Apply(Advance(Free(St, it.m), it))

\* vacant_mount_released(): under mount_locked_reader, mnt_old_root is
\* cleared and the mount is freed if its last put came first; with
\* RELEASE_PUTS the release visit's own mntput() instead; with the handoff
\* unlocked the read of MNT_DOOMED happens after the lock is dropped
TwHandoff(it) ==
    /\ it.step = "handoff"
    /\ LET m == it.m
           s1 == [St EXCEPT !.mt[m].oldroot = FALSE]
       IN IF RELEASE_PUTS THEN Apply(Advance(Put(s1, m, "R"), it))
          ELSE IF ~FIX_HANDOFF_LOCKED THEN Apply(Advance([s1 EXCEPT !.rchk = @ \cup {m}], it))
          ELSE IF mt[m].doomed THEN Apply(Advance(Free(s1, m), it))
          ELSE Apply(Advance([s1 EXCEPT !.hist.relfirst = @ + 1], it))

TaskWork == \E it \in tw : TwStuck(it) \/ TwSb(it) \/ TwFree(it) \/ TwHandoff(it)

\* the unlocked checks of the mutation: the put side reads mnt_old_root and
\* the release side reads MNT_DOOMED after dropping mount_lock; the mount
\* may be gone by then
PutCheck(m) ==
    /\ m \in pchk
    /\ LET s1 == [St EXCEPT !.pchk = @ \ {m}]
           s2 == IF mt[m].rcufree THEN Warn(s1, "use_after_free") ELSE s1
       IN Apply(IF ~mt[m].oldroot THEN Free(s2, m) ELSE s2)
ReleaseCheck(m) ==
    /\ m \in rchk
    /\ LET s1 == [St EXCEPT !.rchk = @ \ {m}]
           s2 == IF mt[m].rcufree THEN Warn(s1, "use_after_free") ELSE s1
       IN Apply(IF mt[m].doomed THEN Free(s2, m) ELSE s2)

\* delayed_free_vfsmnt(): the RCU callback
RcuFree(m) ==
    /\ mt[m].rcufree /\ ~mt[m].freed /\ freewait[m] = {}
    /\ Apply([St EXCEPT !.mt[m].freed = TRUE])

(* ---- U: namespace_unlock() ----------------------------------------------- *)

UGp == upc = "gp" /\ Apply([St EXCEPT !.ugp = rcu, !.upc = "wait"])
UWait == upc = "wait" /\ ugp = {} /\ Apply([St EXCEPT !.upc = "put"])
UPut ==
    /\ upc = "put"
    /\ HOLDER_ORDER = "early" => \A h \in RootHolders : hdone[h]
    /\ IF uhead = <<>> THEN Apply([St EXCEPT !.upc = "done"])
       ELSE Apply(Put([St EXCEPT !.uhead = Tail(uhead)], Head(uhead), "U"))
Unlocker == UGp \/ UWait \/ UPut

(* ---- holders: close a file ----------------------------------------------- *)

HClose(h) ==
    /\ ~hdone[h]
    /\ HOLDER_ORDER = "late" /\ h \in RootHolders => upc = "done"
    /\ LET m == HolderMnt[h]
       IN Apply(Put([St EXCEPT !.hdone[h] = TRUE, !.ext[m] = @ - 1], m, "H"))

(* ---- the pin drop: fput() of a released filesystem's file --------------- *)

PinPut(m) == m \in pins /\ Apply(Put([St EXCEPT !.pins = @ \ {m}], m, "K"))

(* ---- walkers: an RCU walk from a holder's file into the mount below ----- *)

\* path_init(): rcu_read_lock(), nd->m_seq = read_seqbegin(&mount_lock),
\* the start is a holder's file on s (no reference of its own), the next
\* component is the mountpoint of t
WStart(w) ==
    /\ wpc[w] = "idle" /\ wn[w] < WalkBudget
    /\ \E s \in MntIds, t \in MntIds :
        /\ ext[s] > 0 /\ Parent[t] = s
        /\ Apply([St EXCEPT !.wpc[w] = "lookup", !.wsrc[w] = s, !.wtgt[w] = t, !.wseq[w] = seq,
                            !.wroot[w] = "", !.wres[w] = "", !.wn[w] = @ + 1, !.rcu = @ \cup {w}])

\* __d_lookup_rcu() of the mountpoint, then __follow_mount_rcu(): a hit
\* reads the mount's root; a miss validated by read_seqretry(m_seq) means
\* the walk continues in the directory the mount used to cover (the
\* reveal); an unvalidated miss falls back to the REF walk
WLookup(w) ==
    /\ wpc[w] = "lookup"
    /\ LET s == wsrc[w]
           t == wtgt[w]
           found == mt[t].hashed /\ mt[t].parent = s
       IN IF mt[t].mpgone
          THEN Apply(RcuOut([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "enoent"], w))
          ELSE IF found
          THEN Apply([St EXCEPT !.wpc[w] = "legit1", !.wroot[w] = IF mt[t].vacant THEN "null" ELSE "fs"])
          ELSE IF seq = wseq[w]
          THEN Apply(RcuOut([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "beneath"], w))
          ELSE Apply(RcuOut([St EXCEPT !.wpc[w] = "ref"], w))

\* __legitimize_mnt(): read_seqretry(m_seq) then mnt_add_count(+1)
WLegit1(w) ==
    /\ wpc[w] = "legit1"
    /\ IF seq # wseq[w]
       THEN Apply(RcuOut([St EXCEPT !.wpc[w] = "ref"], w))
       ELSE Apply([St EXCEPT !.mt[wtgt[w]].count = @ + 1, !.wpc[w] = "legit2"])

\* smp_mb(); read_seqretry(m_seq) again: legitimized, or on to lock_mount_hash()
WLegit2(w) ==
    /\ wpc[w] = "legit2"
    /\ IF seq = wseq[w]
       THEN Apply(RcuOut([St EXCEPT !.wpc[w] = "use"], w))
       ELSE Apply([St EXCEPT !.wpc[w] = "lock"])

\* under mount_lock: MNT_DOOMED drops the count and returns 1 (-ECHILD,
\* REF walk), else -1 and the caller's mntput()
WLock(w) ==
    /\ wpc[w] = "lock"
    /\ LET t == wtgt[w]
       IN IF mt[t].doomed
          THEN Apply(RcuOut([St EXCEPT !.mt[t].count = @ - 1, !.seq = @ + 1, !.wpc[w] = "ref"], w))
          ELSE Apply(RcuOut([St EXCEPT !.seq = @ + 1, !.wpc[w] = "put"], w))

\* the mntput() after __legitimize_mnt() returned -1; the walk then restarts in REF mode
WPut(w) ==
    /\ wpc[w] = "put"
    /\ Apply(Put([St EXCEPT !.wpc[w] = "ref"], wtgt[w], "W"))

\* the legitimized walk used the mount and puts it
WUse(w) ==
    /\ wpc[w] = "use"
    /\ Apply(Put([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "into"], wtgt[w], "W"))

\* the REF walk after -ECHILD: the file must still be open; the mountpoint
\* may be gone; lookup_mnt() finds the mount if it is hashed there and
\* spins for good if that mount is doomed (legitimize_mnt() never succeeds);
\* otherwise the walk lands in the covered directory
WRef(w) ==
    /\ wpc[w] = "ref"
    /\ LET s == wsrc[w]
           t == wtgt[w]
           found == mt[t].hashed /\ mt[t].parent = s
       IN IF ext[s] = 0 THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "ebadf"])
          ELSE IF mt[t].mpgone THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "enoent"])
          ELSE IF ~found THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "beneath"])
          ELSE IF mt[t].doomed THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "hang"])
          ELSE Apply([St EXCEPT !.mt[t].count = @ + 1, !.seq = @ + 1, !.wpc[w] = "use"])

Walk(w) == WStart(w) \/ WLookup(w) \/ WLegit1(w) \/ WLegit2(w) \/ WLock(w) \/ WPut(w) \/ WUse(w) \/ WRef(w)

(* ---- D: rmdir of a mountpoint -> __detach_mounts() ---------------------- *)

\* under namespace_sem and mount_lock: the mount at the removed directory
\* (MNT_UMOUNT) is unhashed with umount_mnt(); a vacant one goes on
\* `unmounted` for namespace_unlock()'s put (the mutation lists every one,
\* upstream lists every one since it owns none)
DDetach ==
    /\ dpc = "idle"
    /\ \E t \in dtargets :
        /\ ~mt[t].mpgone /\ sbact[Sb[Parent[t]]]
        /\ LET attached == mt[t].hashed /\ mt[t].parent = Parent[t]
               listed == attached /\ (IF ~FIX_OWN_REF THEN TRUE
                                      ELSE IF mt[t].vacant THEN FIX_DETACH_PUTS_VACANT
                                      ELSE DETACH_PUTS_ALL)
               s1 == [St EXCEPT !.mt[t].mpgone = TRUE, !.seq = @ + 1, !.dtargets = @ \ {t},
                                !.dpc = "gp", !.dgp = rcu,
                                !.dhead = IF listed THEN <<t>> ELSE <<>>,
                                !.hist.detachputs = @ + (IF listed THEN 1 ELSE 0)]
           IN Apply(IF attached THEN [s1 EXCEPT !.mt[t].hashed = FALSE, !.mt[t].parent = NoMnt] ELSE s1)
DGp == dpc = "gp" /\ dgp = {} /\ Apply([St EXCEPT !.dpc = "put"])
DPut ==
    /\ dpc = "put"
    /\ IF dhead = <<>> THEN Apply([St EXCEPT !.dpc = "idle"])
       ELSE Apply(Put([St EXCEPT !.dhead = Tail(dhead)], Head(dhead), "D"))
Detach == DDetach \/ DGp \/ DPut

(* ---- the specification --------------------------------------------------- *)

Settled ==
    /\ upc = "done" /\ \A h \in Holders : hdone[h]
    /\ \A w \in Walkers : wpc[w] = "idle"
    /\ dpc = "idle" /\ tw = {} /\ pins = {} /\ pchk = {} /\ rchk = {}
    /\ \A m \in MntIds : mt[m].rcufree => mt[m].freed

Victims == IF FIX_OWN_REF THEN MntIds ELSE {m \in MntIds : Parent[m] = NoMnt}
Init ==
    /\ mt = [m \in MntIds |->
              [hashed |-> Parent[m] # NoMnt, parent |-> Parent[m],
               count |-> 1 + Ext0(m) + Pinned0(m),
               doomed |-> FALSE, vacant |-> FALSE, oldroot |-> FALSE, inst |-> "fs",
               stuck |-> {}, freed |-> FALSE, rcufree |-> FALSE, mpgone |-> FALSE]]
    /\ sbact = [s \in SbIds |-> TRUE]
    /\ seq = 0
    /\ uhead = IF FIX_TREE_ORDER THEN Ordered(Victims) ELSE Reverse(Ordered(Victims))
    /\ upc = "gp" /\ ugp = {}
    /\ ext = [m \in MntIds |-> Ext0(m)]
    /\ hdone = [h \in Holders |-> FALSE]
    /\ wpc = [w \in Walkers |-> "idle"] /\ wsrc = [w \in Walkers |-> NoMnt] /\ wtgt = [w \in Walkers |-> NoMnt]
    /\ wseq = [w \in Walkers |-> 0] /\ wroot = [w \in Walkers |-> ""] /\ wres = [w \in Walkers |-> ""]
    /\ wn = [w \in Walkers |-> 0]
    /\ rcu = {}
    /\ dpc = "idle" /\ dhead = <<>> /\ dgp = {} /\ dtargets = DetachTargets
    /\ tw = {} /\ pchk = {} /\ rchk = {} /\ pins = {}
    /\ freewait = [m \in MntIds |-> {}]
    /\ hist = [vacates |-> 0, needless |-> 0, negative |-> FALSE, warn |-> {},
               frees |-> [m \in MntIds |-> 0], releases |-> [m \in MntIds |-> 0],
               vacby |-> {}, doomby |-> {}, putfirst |-> 0, relfirst |-> 0, detachputs |-> 0,
               rcuteardown |-> FALSE]

Next ==
    \/ Unlocker
    \/ \E h \in Holders : HClose(h)
    \/ \E w \in Walkers : Walk(w)
    \/ Detach
    \/ TaskWork
    \/ \E m \in MntIds : PinPut(m) \/ PutCheck(m) \/ ReleaseCheck(m) \/ RcuFree(m)
    \/ (Settled /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* ---- what is checked ----------------------------------------------------- *)

TypeOK ==
    /\ \A m \in MntIds : mt[m].count \in Int /\ mt[m].inst \in {"fs", "null", "none"}
                         /\ mt[m].stuck \subseteq MntIds /\ mt[m].parent \in MntIds \cup {NoMnt}
    /\ upc \in {"gp", "wait", "put", "done"} /\ dpc \in {"idle", "gp", "put"}
    /\ \A w \in Walkers : wpc[w] \in {"idle", "lookup", "legit1", "legit2", "lock", "put", "use", "ref"}
                          /\ wres[w] \in {"", "into", "ebadf", "enoent", "beneath", "hang"}
    /\ \A it \in tw : it.m \in MntIds /\ it.kind \in {"cleanup", "release"}
                      /\ it.step \in {"stuck", "sb", "free", "handoff"}

\* the WARN_ON(count < 0) of mntput_no_expire_slowpath()
NoNegative == ~hist.negative

\* none of the kernel's warnings and none of the model's sanity marks: a
\* vacant mount put while attached, freed with stuck children, on an
\* instance list or hashed, freed twice, used after call_rcu(), doomed while
\* attached, a filesystem released twice, a put at zero on a doomed mount
NoWarn == hist.warn = {}

\* every mount is freed at most once and releases its filesystem at most once
ExactlyOnce == \A m \in MntIds : hist.frees[m] <= 1 /\ hist.releases[m] <= 1

\* nothing refers to a freed mount: not the hash, no instance list, no
\* parent pointer, no stuck list, no put list, no pin, no task work, no
\* holder, no walker that found it or started from it and is still in RCU
\* (a walker that only names its mountpoint misses in the hash)
NoDangling ==
    \A m \in MntIds : mt[m].freed =>
        /\ ~mt[m].hashed /\ mt[m].inst = "none" /\ mt[m].stuck = {} /\ ext[m] = 0
        /\ \A x \in MntIds : mt[x].parent # m /\ m \notin mt[x].stuck
        /\ ~InSeq(m, uhead) /\ ~InSeq(m, dhead) /\ m \notin pins /\ m \notin pchk /\ m \notin rchk
        /\ \A it \in tw : it.m # m
        /\ \A w \in Walkers : /\ wpc[w] \in {"legit1", "legit2", "lock", "put", "use"} => wtgt[w] # m
                              /\ wpc[w] \in {"lookup", "legit1", "legit2", "lock"} => wsrc[w] # m

\* a hashed mount is referenced (its own reference, or the parent's once it
\* is vacant) and never doomed: what keeps the covered directory covered
HashedHasRef == \A m \in MntIds : (~mt[m].freed /\ mt[m].hashed) => (mt[m].count >= 1 /\ ~mt[m].doomed)

\* MNT_DOOMED means the last reference is gone, but for a walker's
\* increment that its lock_mount_hash() path is about to take back
DoomedIsLast == \A m \in MntIds : mt[m].doomed =>
    mt[m].count = Cardinality({w \in Walkers : wtgt[w] = m /\ wpc[w] \in {"legit2", "lock"}})

\* a vacant mount stands on knullfs' instance list until its last put, and
\* the release of what it carried is pending until its release visit ran
VacantOK == \A m \in MntIds : mt[m].vacant /\ ~mt[m].doomed => mt[m].inst = "null"

\* no walk ever lands in a directory a mount covered: the mount stays
\* hashed until nobody can reach its parent any more
NoReveal == \A w \in Walkers : wres[w] # "beneath"

\* lookup_mnt() never spins on a hashed doomed mount
NoHang == \A w \in Walkers : wres[w] # "hang"

\* once every reference from outside is gone and every deferred piece of
\* work has run, every mount is freed and every filesystem is down: no
\* cycle kept anything alive
Reaped == Settled => (\A m \in MntIds : mt[m].freed) /\ (\A s \in SbIds : ~sbact[s])

\* witnesses and the claims of the prep patches
NoVacate == hist.vacates = 0
NoNeedlessVacate == hist.needless = 0
NoWalkerVacate == "W" \notin hist.vacby
NoPinDoom == "K" \notin hist.doomby
NoPutFirst == hist.putfirst = 0
NoReleaseFirst == hist.relfirst = 0
NoDetachPut == hist.detachputs = 0
\* an RCU walker that crossed into a mount is still inside it (on its
\* dentries, before legitimizing) when the filesystem it carried is torn
\* down: the series through the release visit of a vacated mount, upstream
\* through the stuck children a parent's final put unhashes and puts with
\* no grace period in between; the RCU-pathwalk contract covers both
NoRcuTeardown == ~hist.rcuteardown
=============================================================================

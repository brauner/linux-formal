------------------------------- MODULE MntOwn -------------------------------
(***************************************************************************)
(* Who owns an unmounted mount, and whether a tree of them can ever be     *)
(* freed: the reference counting behind umount_tree() and mntput().        *)
(*                                                                         *)
(* One mount namespace with a tree of mounts, each on a superblock.  A     *)
(* superblock may pin a mount through a file its filesystem keeps open (a  *)
(* loop device's backing file opened inside the namespace, an ecryptfs    *)
(* lower path, a fuse passthrough file): the pin is a reference on that   *)
(* mount that goes away only when the superblock is torn down, and the    *)
(* superblock is torn down only when its last mount is cleaned up.        *)
(*                                                                         *)
(* The rules of fs/namespace.c since 493a4bebf515 (children do not pin    *)
(* their parents):                                                         *)
(*   - a mounted mount holds one reference for being mounted;             *)
(*   - umount_tree() decides per victim whether it is disconnected        *)
(*     (unhashed) or stays connected to its unmounted parent              *)
(*     (disconnect_mount(): a synchronous umount, a missing parent or a   *)
(*     parent that is not unmounted disconnect; UMOUNT_CONNECTED and      *)
(*     MNT_LOCKED keep it connected);                                     *)
(*   - a disconnected victim goes on the unmounted list and              *)
(*     namespace_unlock() drops its reference;                            *)
(*   - a connected victim is owned by its parent: the parent's final      *)
(*     mntput() unhashes it (mntput_no_expire_slowpath()) and             *)
(*     cleanup_mnt() drops its reference afterwards.                      *)
(* So a connected child whose superblock pins an ancestor keeps that      *)
(* ancestor's count above zero, the ancestor never runs its cascade, the  *)
(* child is never put, its superblock never dies and the pin never goes:  *)
(* the cycle Michael Vogt ran into with put_mnt_ns() after 0342482a4d15.  *)
(*                                                                         *)
(* Entry points: umount(2) with MNT_DETACH (locked children stay          *)
(* connected), a synchronous umount of a leaf, put_mnt_ns() when the last *)
(* task leaves (UMOUNT_CONNECTED since 0342482a4d15, plain before), and   *)
(* __detach_mounts() after rmdir of a mountpoint (UMOUNT_CONNECTED).      *)
(* Holders close their files in any order; the model ends when nothing   *)
(* is left to do and asks whether every mount and superblock is gone.     *)
(*                                                                         *)
(* Switches:                                                               *)
(*   FIX_PUT_MNT_NS_DISCONNECT  put_mnt_ns() uses umount_tree(root, 0)    *)
(*                              (the revert of 0342482a4d15)              *)
(*   FIX_DISOWN                 the tombstone mechanism of                 *)
(*                              work.put_mnt_ns.tombstone: every victim    *)
(*                              keeps its own reference and goes on the    *)
(*                              unmounted list in tree order; a mount that *)
(*                              loses its last reference while attached    *)
(*                              becomes a tombstone (its filesystem is     *)
(*                              released, the slot stays filled with an    *)
(*                              empty nullfs root owned by the parent);    *)
(*                              a parent's final put unhashes its children *)
(*                              and puts only tombstones                    *)
(*   FIX_INTERNAL_CLONE         the rule of work.mount.private_clone: a     *)
(*                              holder keeps its file on an internal clone  *)
(*                              of the mount (mnt_clone_internal(): a       *)
(*                              private MNT_INTERNAL mount in no namespace, *)
(*                              no parent, no children, one reference held  *)
(*                              by the file), so the pin is a reference on  *)
(*                              the superblock the file lives on and never  *)
(*                              on a mount; the clone is folded into that   *)
(*                              superblock's active count and goes when the *)
(*                              pinning superblock releases the file        *)
(*   PIN_BUSY                   with the clone, a synchronous umount of a   *)
(*                              pinned mount still fails with EBUSY (the    *)
(*                              loop driver's busy fs_pin in that series)   *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets
CONSTANTS
    MntIds,         \* the mounts
    Root,           \* the namespace root
    Parent,      \* [MntIds -> MntIds \cup {NoMnt}]: the tree
    SbIds,          \* the superblocks
    Sb,          \* [MntIds -> SbIds]: the superblock of each mount
    Pin,         \* [SbIds -> MntIds \cup {NoMnt}]: the mount a superblock's file pins
    Locked,      \* the locked mounts (MNT_LOCKED)
    ExtRefs,         \* [MntIds -> Nat]: files or cwds holders keep on each mount
    NsUsers,        \* tasks in the namespace at the start
    LAZY,           \* umount(2) with MNT_DETACH is available
    SYNC,           \* a synchronous umount of a leaf is available
    DETACH,         \* rmdir of a mountpoint (__detach_mounts()) is available
    FIX_PUT_MNT_NS_DISCONNECT,
    FIX_DISOWN,
    FIX_DISCONNECT_PINNERS,   \* umount_tree() disconnects a victim whose superblock pins a victim
    PINNERS_ANCESTOR_ONLY,    \* ... only when the pinned victim is an ancestor that would own it
    PINNERS_REEXAMINE,        \* ... and also every mount left connected by an earlier umount_tree()
    FIX_INTERNAL_CLONE,       \* holders keep their files on internal clones: pins are on superblocks
    PIN_BUSY,                 \* ... and a synchronous umount of a pinned mount is still busy
    ANY_PIN,        \* let the pinning superblocks pin any mount, or none: every configuration
    SELF_PIN,       \* ... including a mount of the pinning superblock's own filesystem
    PinnerSbs       \* the superblocks that can pin a mount when ANY_PIN
NoMnt == 0
NullSb == "null"    \* the private nullfs instance a tombstone points at

VARIABLES
    mt,        \* [MntIds -> record]
    sbs,       \* [SbIds -> [active: Nat, pin: MntIds \cup {NoMnt}]]
    ext,       \* [MntIds -> Nat]: holders' references still open
    nsusers,   \* tasks in the namespace
    nsalive,   \* the namespace has not been torn down
    unm,       \* the unmounted list of the namespace_unlock() in progress, in put order
    cleanq     \* mounts whose cleanup_mnt() is pending
vars == <<mt, sbs, ext, nsusers, nsalive, unm, cleanq>>

(* ---- helpers ------------------------------------------------------------ *)

Alive == {m \in MntIds : ~mt[m].freed}
Children(m) == {c \in Alive : mt[c].parent = m /\ mt[c].attached}
HasParent(m) == mt[m].parent # NoMnt /\ mt[m].attached
RECURSIVE Subtree(_)
Subtree(m) == {m} \cup UNION {Subtree(c) : c \in Children(m)}
\* the tree in the order umount_tree() collects it (a parent before its children)
RECURSIVE Depth(_)
Depth(m) == IF Parent[m] = NoMnt THEN 0 ELSE 1 + Depth(Parent[m])
Before(x, y) == Depth(x) < Depth(y) \/ (Depth(x) = Depth(y) /\ x <= y)
RECURSIVE Ordered(_)
Ordered(S) == IF S = {} THEN <<>>
              ELSE LET x == CHOOSE x \in S : \A y \in S : Before(x, y)
                   IN <<x>> \o Ordered(S \ {x})
Reverse(s) == [i \in 1..Len(s) |-> s[Len(s) + 1 - i]]

(* ---- mntput() ------------------------------------------------------------ *)

\* mntput_no_expire(): the fast path while the mount is in a namespace, the
\* slowpath when the count reaches zero: doom the mount, unhash its still
\* attached children (the parent-owned ones become stuck children to be put
\* by cleanup_mnt()), and queue cleanup_mnt().  With FIX_DISOWN a mount
\* that reaches zero while attached becomes a tombstone instead: it keeps
\* its slot, gets one reference for the parent that owns it now and one
\* for the pending release of its filesystem, and only tombstones are put
\* by the parent's cleanup.
Put(st, m) ==
    LET t == st.mt
        c == t[m].count - 1
    IN IF c > 0 \/ t[m].ns
       THEN [st EXCEPT !.mt[m].count = c]
       ELSE IF t[m].doomed THEN [st EXCEPT !.mt[m].count = c]     \* not reached: a second final put
       ELSE LET kids == {k \in MntIds : ~t[k].freed /\ t[k].parent = m /\ t[k].attached}
                stuck == IF FIX_DISOWN THEN {k \in kids : t[k].tomb} ELSE kids
                tomb == FIX_DISOWN /\ t[m].parent # NoMnt /\ t[m].attached /\ ~t[m].tomb
                \* the slowpath unhashes the children either way; make_tombstone()
                \* then keeps the slot filled instead of dooming the mount
                t1 == [x \in MntIds |->
                        IF x = m
                        THEN IF tomb THEN [t[x] EXCEPT !.count = 2, !.tomb = TRUE, !.release = TRUE, !.stuck = stuck,
                                                       !.sb = NullSb, !.oldsb = t[x].sb]
                             ELSE [t[x] EXCEPT !.count = 0, !.doomed = TRUE, !.stuck = stuck]
                        ELSE IF x \in kids THEN [t[x] EXCEPT !.attached = FALSE, !.parent = NoMnt]
                        ELSE t[x]]
            IN [st EXCEPT !.mt = t1, !.cleanq = st.cleanq \cup {m}]

\* the superblock a pinning superblock's file lives on: with the clone the
\* file holds that superblock's active count, not the mount's
PinnedSb(st, s) == Sb[st.sbs[s].pin]
\* deactivate_super(): the last mount of a superblock takes it down, and
\* the file it kept open lets go of what it pinned: the mount, or with
\* the clone the clone, whose own final put deactivates the superblock
\* the file lives on (mntput_no_expire_slowpath() runs cleanup_mnt()
\* synchronously for MNT_INTERNAL)
RECURSIVE PutAll(_, _)
PutAll(st, s) == IF s = <<>> THEN st ELSE PutAll(Put(st, Head(s)), Tail(s))
RECURSIVE DropSb(_, _)
DropSb(st, s) ==
    LET a == st.sbs[s].active - 1
        st1 == [st EXCEPT !.sbs[s].active = a]
    IN IF a = 0 /\ st.sbs[s].pin # NoMnt
       THEN IF FIX_INTERNAL_CLONE THEN DropSb(st1, PinnedSb(st, s)) ELSE Put(st1, st.sbs[s].pin)
       ELSE st1

\* cleanup_mnt(): put the stuck children, release the filesystem, free
Cleanup(st, m) ==
    LET t == st.mt
    IN IF FIX_DISOWN /\ t[m].release
       THEN \* the release visit of a tombstone: the stuck tombstone children are
            \* put, the old filesystem goes, then the pending reference
            LET st0 == PutAll([st EXCEPT !.mt[m].stuck = {}, !.mt[m].release = FALSE,
                                         !.cleanq = st.cleanq \ {m}], Ordered(t[m].stuck))
                st1 == DropSb(st0, t[m].oldsb)
            IN Put(st1, m)
       ELSE LET st1 == PutAll([st EXCEPT !.mt[m].stuck = {}, !.cleanq = st.cleanq \ {m}], Ordered(t[m].stuck))
                st2 == IF t[m].sb = NullSb THEN st1 ELSE DropSb(st1, t[m].sb)
            IN [st2 EXCEPT !.mt[m].freed = TRUE, !.mt[m].attached = FALSE, !.mt[m].parent = NoMnt]

(* ---- umount_tree() ------------------------------------------------------- *)

How(sync, connected) == [sync |-> sync, connected |-> connected]
\* the ancestors of p that would own it: the chain of attached unmounted parents
RECURSIVE OwnerChain(_, _)
OwnerChain(t, p) ==
    IF t[p].parent = NoMnt \/ ~t[p].attached \/ ~t[t[p].parent].umount THEN {}
    ELSE {t[p].parent} \cup OwnerChain(t, t[p].parent)
\* the superblock of p keeps a file on a victim of this umount_tree()
PinsVictim(t, sbs0, p) ==
    LET x == sbs0[t[p].sb].pin
    IN /\ x # NoMnt /\ t[x].umount /\ ~t[x].freed
       /\ (~PINNERS_ANCESTOR_ONLY \/ x \in OwnerChain(t, p))
\* disconnect_mount()
Disconnect(t, sbs0, p, how) ==
    IF how.sync THEN TRUE
    ELSE IF t[p].parent = NoMnt \/ ~t[p].attached THEN TRUE
    ELSE IF ~t[t[p].parent].umount THEN TRUE
    ELSE IF FIX_DISCONNECT_PINNERS /\ PinsVictim(t, sbs0, p) THEN TRUE
    ELSE IF how.connected THEN FALSE
    ELSE IF t[p].locked THEN FALSE
    ELSE TRUE
\* one victim: out of the namespace, disconnected or left attached; the
\* unmounted list gets the disconnected ones (LIFO, as hlist_add_head()
\* builds it), or every victim in tree order with FIX_DISOWN
UmountOne(st, p, how) ==
    LET t == st.mt
        disc == Disconnect(t, st.sbs, p, how)
        t1 == [t EXCEPT ![p].umount = TRUE, ![p].ns = FALSE,
                        ![p].attached = IF disc THEN FALSE ELSE t[p].attached,
                        ![p].parent = IF disc THEN NoMnt ELSE t[p].parent]
        listed == IF FIX_DISOWN THEN TRUE ELSE disc
    IN [st EXCEPT !.mt = t1, !.unm = IF listed THEN st.unm \o <<p>> ELSE st.unm]
RECURSIVE UmountEach(_, _, _)
UmountEach(st, s, how) == IF s = <<>> THEN st ELSE UmountEach(UmountOne(st, Head(s), how), Tail(s), how)
\* a mount an earlier umount_tree() left connected under its dead parent
\* whose superblock pins one of this umount_tree()'s victims: unhash it and
\* let namespace_unlock() drop the reference its parent was going to drop
Reexamine(st, victims) ==
    LET t == st.mt
        late == {c \in MntIds : ~t[c].freed /\ t[c].umount /\ t[c].attached /\ c \notin victims
                                /\ t[c].parent # NoMnt /\ t[t[c].parent].umount
                                /\ PinsVictim(t, st.sbs, c)}
        t1 == [x \in MntIds |-> IF x \in late THEN [t[x] EXCEPT !.attached = FALSE, !.parent = NoMnt] ELSE t[x]]
    IN [st EXCEPT !.mt = t1, !.unm = st.unm \o Ordered(late)]
UmountTree(st, m, how) ==
    LET victims == Ordered(Subtree(m))
        \* MNT_UMOUNT on the whole set first: disconnect_mount() looks at the parent's flag
        t0 == [x \in MntIds |-> IF x \in Subtree(m) THEN [st.mt[x] EXCEPT !.umount = TRUE] ELSE st.mt[x]]
        st1 == UmountEach([st EXCEPT !.mt = t0], victims, how)
        st2 == IF FIX_DISCONNECT_PINNERS /\ PINNERS_REEXAMINE THEN Reexamine(st1, Subtree(m)) ELSE st1
    IN IF FIX_DISOWN THEN st2 ELSE [st2 EXCEPT !.unm = Reverse(st2.unm)]

State == [mt |-> mt, sbs |-> sbs, cleanq |-> cleanq, unm |-> unm]
Apply(st) == /\ mt' = st.mt /\ sbs' = st.sbs /\ cleanq' = st.cleanq /\ unm' = st.unm

(* ---- the actions --------------------------------------------------------- *)

Idle == unm = <<>>        \* namespace_sem: no namespace_unlock() in progress

\* umount(2) with MNT_DETACH on an attached mount below the root
LazyUmount(m) ==
    /\ LAZY /\ Idle /\ nsalive /\ nsusers > 0
    /\ m # Root /\ mt[m].ns /\ mt[m].attached /\ ~mt[m].locked
    /\ Apply(UmountTree(State, m, How(FALSE, FALSE)))
    /\ UNCHANGED <<ext, nsusers, nsalive>>

\* a synchronous umount of a leaf nobody else holds (propagate_mount_busy())
SyncUmount(m) ==
    /\ SYNC /\ Idle /\ nsalive /\ nsusers > 0
    /\ m # Root /\ mt[m].ns /\ mt[m].attached /\ ~mt[m].locked
    /\ Children(m) = {} /\ mt[m].count = 1
    /\ ~(PIN_BUSY /\ \E s \in SbIds : sbs[s].active > 0 /\ sbs[s].pin = m)
    /\ Apply(UmountTree(State, m, How(TRUE, FALSE)))
    /\ UNCHANGED <<ext, nsusers, nsalive>>

\* rmdir of the mountpoint under a mounted parent: __detach_mounts()
DetachMounts(m) ==
    /\ DETACH /\ Idle /\ nsalive /\ nsusers > 0
    /\ m # Root /\ mt[m].ns /\ mt[m].attached
    /\ Apply(UmountTree(State, m, How(FALSE, TRUE)))
    /\ UNCHANGED <<ext, nsusers, nsalive>>

\* a task leaves the namespace
Leave ==
    /\ nsusers > 0
    /\ nsusers' = nsusers - 1
    /\ UNCHANGED <<mt, sbs, ext, nsalive, unm, cleanq>>

\* put_mnt_ns(): the last task is gone
PutMntNs ==
    /\ nsalive /\ nsusers = 0 /\ Idle
    /\ nsalive' = FALSE
    /\ Apply(UmountTree(State, Root, How(FALSE, ~FIX_PUT_MNT_NS_DISCONNECT)))
    /\ UNCHANGED <<ext, nsusers>>

\* namespace_unlock(): one mntput() from the unmounted list
NsUnlockPut ==
    /\ unm # <<>>
    /\ Apply(Put([State EXCEPT !.unm = Tail(unm)], Head(unm)))
    /\ UNCHANGED <<ext, nsusers, nsalive>>

\* a holder closes a file or moves its cwd away
Close(m) ==
    /\ ext[m] > 0
    /\ ext' = [ext EXCEPT ![m] = ext[m] - 1]
    /\ Apply(Put(State, m))
    /\ UNCHANGED <<nsusers, nsalive>>

\* the deferred cleanup_mnt() (task work) of a doomed mount or a tombstone's release
CleanupMnt(m) ==
    /\ m \in cleanq
    /\ Apply(Cleanup(State, m))
    /\ UNCHANGED <<ext, nsusers, nsalive>>

Settled == /\ ~nsalive /\ nsusers = 0 /\ unm = <<>> /\ cleanq = {}
           /\ \A m \in MntIds : ext[m] = 0

\* the pin configurations to explore: the given one, or with ANY_PIN every way
\* the pinning superblocks can hold a file on a mount
PinChoices == IF ANY_PIN
              THEN {[s \in SbIds |-> IF s \in PinnerSbs THEN f[s] ELSE NoMnt] :
                      f \in {g \in [PinnerSbs -> MntIds \cup {NoMnt}] :
                             SELF_PIN \/ \A s \in PinnerSbs : g[s] = NoMnt \/ Sb[g[s]] # s}}
              ELSE {Pin}
Init ==
    \E pin \in PinChoices :
    /\ mt = [m \in MntIds |->
              [parent |-> Parent[m], attached |-> TRUE, umount |-> FALSE, ns |-> TRUE,
               count |-> 1 + ExtRefs[m] + (IF FIX_INTERNAL_CLONE THEN 0 ELSE Cardinality({s \in SbIds : pin[s] = m})),
               doomed |-> FALSE, tomb |-> FALSE, release |-> FALSE, sb |-> Sb[m], oldsb |-> NullSb,
               locked |-> m \in Locked, stuck |-> {}, freed |-> FALSE]]
    /\ sbs = [s \in SbIds |-> [active |-> Cardinality({m \in MntIds : Sb[m] = s})
                                          + (IF FIX_INTERNAL_CLONE
                                             THEN Cardinality({t \in SbIds : pin[t] # NoMnt /\ Sb[pin[t]] = s})
                                             ELSE 0),
                                pin |-> pin[s]]]
    /\ ext = ExtRefs
    /\ nsusers = NsUsers
    /\ nsalive = TRUE
    /\ unm = <<>>
    /\ cleanq = {}

Next ==
    \/ \E m \in MntIds : LazyUmount(m) \/ SyncUmount(m) \/ DetachMounts(m) \/ Close(m) \/ CleanupMnt(m)
    \/ Leave \/ PutMntNs \/ NsUnlockPut
    \/ (Settled /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* ---- what is checked ----------------------------------------------------- *)

TypeOK ==
    /\ \A m \in MntIds : mt[m].count >= 0
    /\ \A s \in SbIds : sbs[s].active >= 0
    /\ nsusers >= 0

\* nothing freed is still pointed at
NoUAF ==
    /\ \A m \in Alive : mt[m].parent # NoMnt => ~mt[mt[m].parent].freed
    /\ \A m \in Alive : mt[m].stuck \subseteq Alive
    /\ \A s \in SbIds : sbs[s].active > 0 /\ sbs[s].pin # NoMnt =>
            IF FIX_INTERNAL_CLONE THEN sbs[Sb[sbs[s].pin]].active > 0 ELSE ~mt[sbs[s].pin].freed
    /\ \A m \in MntIds : mt[m].freed => ext[m] = 0 /\ m \notin cleanq /\ ~(\E i \in 1..Len(unm) : unm[i] = m)

\* once the namespace is gone and every holder has closed, every mount is
\* freed and every superblock is down: no cycle kept anything alive
Reaped == Settled => (\A m \in MntIds : mt[m].freed) /\ (\A s \in SbIds : sbs[s].active = 0)

\* the invariant of the tombstone series: an attached unmounted mount holds
\* its own reference unless it is a tombstone
OwnRef == FIX_DISOWN =>
    \A m \in Alive : (mt[m].umount /\ mt[m].attached /\ ~mt[m].tomb) => mt[m].count >= 1

\* a mount that lost its filesystem is a tombstone or freed, never in between
TombOK == \A m \in Alive : mt[m].sb = NullSb => mt[m].tomb

\* a tombstone is a superblock-less leaf: it pins nothing and owns nothing
TombLeaf == \A m \in Alive : mt[m].tomb => (mt[m].sb = NullSb /\ Children(m) = {})

\* y keeps x alive: y's superblock holds a file on x, or y owns x as an
\* attached unmounted child (any such child today, only a tombstone with
\* the series)
Keeps(y, x) ==
    \/ ~FIX_INTERNAL_CLONE /\ sbs[mt[y].sb].pin = x /\ sbs[mt[y].sb].active > 0
    \/ mt[x].attached /\ mt[x].parent = y /\ (~FIX_DISOWN \/ mt[x].tomb)
\* a set of mounts a cycle of superblock pins keeps alive on its own: every
\* member is pinned by the superblock of a member.  The kernel cannot see
\* through a loop device or a fuse server to know that such a file is a pin
PinCycle(S) == S # {} /\ \A y \in S : \E x \in S : sbs[mt[x].sb].pin = y /\ sbs[mt[x].sb].active > 0
RECURSIVE KeptFrom(_)
KeptFrom(S) == LET N == S \cup {x \in Alive : \E y \in S : Keeps(y, x)}
               IN IF N = S THEN S ELSE KeptFrom(N)
\* once everything external is gone, whatever survives is rooted in a cycle
\* of pins alone: a pin cycle, what its members' superblocks pin, and what
\* those own.  Nothing survives through the ownership of an attached
\* unmounted mount by itself
LeaksAreCycles == Settled => \A m \in Alive : \E S \in SUBSET Alive : PinCycle(S) /\ m \in KeptFrom(S)

\* with the clone nothing in the kernel holds a mount's count once its
\* namespace and its holders are gone: every mount is freed, whatever the
\* pins, and only superblocks can survive
MountsReaped == FIX_INTERNAL_CLONE => (Settled => \A m \in MntIds : mt[m].freed)
\* u keeps superblock t alive: u's file lives on t, through the clone
SbKeeps(u, t) == sbs[u].active > 0 /\ sbs[u].pin # NoMnt /\ Sb[sbs[u].pin] = t
SbPinCycle(S) == S # {} /\ \A t \in S : \E u \in S : SbKeeps(u, t)
RECURSIVE SbKeptFrom(_)
SbKeptFrom(S) == LET N == S \cup {t \in SbIds : \E u \in S : SbKeeps(u, t)}
                 IN IF N = S THEN S ELSE SbKeptFrom(N)
\* a superblock that survives everything external is kept by a cycle of
\* superblocks each keeping a file on another's filesystem, or by what
\* such a cycle keeps: the loop device whose image lies on its own
\* filesystem, two images on each other's filesystems
SbLeaksAreCycles == FIX_INTERNAL_CLONE =>
    (Settled => \A t \in SbIds : sbs[t].active > 0 =>
                  \E S \in SUBSET SbIds : SbPinCycle(S) /\ t \in SbKeptFrom(S))
=============================================================================

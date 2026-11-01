---------------------------- MODULE OffsetReaddir ----------------------------
(***************************************************************************)
(* readdir() of a directory with stable offsets, fs/libfs.c as tmpfs uses  *)
(* it: simple_offset_add(), simple_offset_remove(), simple_offset_rename() *)
(* and simple_offset_rename_exchange() as mm/shmem.c calls them, and       *)
(* offset_readdir()/offset_iterate_dir() in four shapes:                   *)
(*                                                                         *)
(*   WALK = "list"      the d_children walk of b44341e39d85: the offset    *)
(*                      tree only maps ctx->pos back to a dentry, the list *)
(*                      walk continues from there                          *)
(*   WALK = "list_eod"  the same, but ending the listing where the walk    *)
(*                      would restart at the head of d_children            *)
(*   WALK = "offset"    the descending walk of the offset tree of          *)
(*                      work.libfs.offset_readdir.v2 9ad16ae61045          *)
(*   WALK = "ascend"    the ascending walk of the offsets of 6faddda69f62  *)
(*                      (v6.6), which generic/736 broke                    *)
(*                                                                         *)
(* REFS, WRITERS_EXCL and RCU_TREE say what the walk of the offset tree    *)
(* relies on: v2 takes no reference on the dentries it emits and carries   *)
(* one ma_state across dir_emit(), because every writer holds the          *)
(* directory's i_rwsem exclusive while readdir holds it shared. PAST_EOD   *)
(* says what a file position past DIR_OFFSET_EOD does.                     *)
(*                                                                         *)
(* Each lister has its own open file. It may telldir() once and seekdir()  *)
(* back to it once, and lseek() past DIR_OFFSET_EOD once.                  *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Names,          \* the names entries can have
    NOff,           \* DIR_OFFSET_MIN..DIR_OFFSET_MAX has NOff offsets
    ND,             \* dentries 1..ND
    SetupOps,       \* directory operations before the first opendir()
    ChurnOps,       \* directory operations after that
    OpKinds,        \* which of create/unlink/rename/over/exchange/whiteout a layout has
    RenameOnRead,   \* generic/736: rename every entry right after readdir() returned it
    Track,          \* remember which dentries a listing returned (NoReReturn, ReReturnNeedsWrap)
    Listers,        \* the listers, each with its own open file
    Seeks,          \* a lister may telldir() once and seekdir() back to that cookie once
    FarSeeks,       \* a lister may lseek() past DIR_OFFSET_EOD once
    WALK,           \* "list", "list_eod", "offset" or "ascend"
    REFS,           \* the offset walk dget()s the entry around dir_emit() (bed62856dba3)
    WRITERS_EXCL,   \* create, unlink and rename hold the parent's i_rwsem exclusive
    RCU_TREE,       \* the offset tree is MT_FLAGS_USE_RCU
    PAST_EOD        \* "relist": offset_readdir() walks for every ctx->pos but DIR_OFFSET_EOD,
                    \* "eod": only for one below it

ASSUME WALK \in {"list", "list_eod", "offset", "ascend"}
ASSUME PAST_EOD \in {"relist", "eod"}
ASSUME OpKinds \subseteq {"create", "unlink", "rename", "over", "exchange", "whiteout"}

FIRST == 2                      \* DIR_OFFSET_FIRST: "." and ".." are done
MIN == FIRST + 1                \* DIR_OFFSET_MIN
MAX == MIN + NOff - 1           \* DIR_OFFSET_MAX
EOD == MAX + 1                  \* DIR_OFFSET_EOD
FAR == EOD + 1                  \* a file position lseek() can set past DIR_OFFSET_EOD
Offs == MIN..MAX
Dents == 1..ND
Nil == 0
NoName == "-"
NoCookie == 0

VARIABLES
    tree,       \* octx->mt: offset -> dentry
    nextoff,    \* octx->next_offset
    dname,      \* d_name
    doff,       \* d_fsdata, the dentry's offset (0: none)
    dstate,     \* "free", "pos" (positive, in the directory), "dead" (gone, still referenced)
    drefs,      \* references the listers hold
    dlist,      \* d_children of the directory, head first
    \* per lister:
    lphase,     \* "closed", "idle" (between getdents64() calls), "find", "emit", "done"
    pos,        \* ctx->pos, the file position the next call resumes at
    first,      \* the next find is the first of this call (a fresh MA_STATE)
    mas,        \* the offset the walk's ma_state is at
    cur,        \* the dentry the walk found and is about to dir_emit()
    emitted,    \* this call returned an entry, so dir_emit() may fail now
    count,      \* how often each name was returned since opendir() or the last seek (saturating)
    startset,   \* the names present at opendir()
    touched,    \* names created, unlinked or renamed since opendir()
    emits,      \* entries returned since opendir() or the last seek (saturating)
    pend,       \* RenameOnRead: dentries returned by this call, to be renamed
    retd,       \* Track: dentries returned since opendir() or the last seek
    dirty,      \* the tree changed while the lister was inside a call
    saved,      \* the telldir() cookie (NoCookie: none)
    before,     \* the names returned before the cookie was taken
    segbefore,  \* after seekdir(): the names returned before its cookie was taken
    seekleft,   \* seekdir()s left
    farleft,    \* lseek()s past DIR_OFFSET_EOD left
    far,        \* the lister seeked past DIR_OFFSET_EOD
    \* global:
    budget,     \* <<setup ops left, churn ops left>>
    err,        \* "none", "uaf" (dir_emit() of a freed dentry), "stale" (walk of a changed tree)
    wrapped,    \* witness: the offset allocator wrapped
    mismatch,   \* witness: d_children and offset order disagreed at an opendir()
    cookiegone, \* witness: a call resumed at an offset whose entry was gone
    rereturn    \* witness: a dentry was returned twice since opendir() or the last seek

dirv == <<tree, nextoff, dname, doff, dstate, drefs, dlist>>
lstv == <<lphase, pos, first, mas, cur, emitted>>
bookv == <<count, startset, touched, emits, pend, retd, dirty>>
seekv == <<saved, before, segbefore, seekleft, farleft, far>>
witv == <<wrapped, mismatch, cookiegone, rereturn>>
vars == <<dirv, lstv, bookv, seekv, budget, err, witv>>

SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x
SetMin(S) == CHOOSE x \in S : \A y \in S : x <= y
Without(s, d) == SelectSeq(s, LAMBDA x : x # d)
Sat(n) == IF n > NOff THEN NOff + 1 ELSE n
SatC(n) == IF n > 2 THEN 2 ELSE n

Live == {d \in Dents : dstate[d] = "pos"}
Present == {dname[d] : d \in Live}
D(n) == CHOOSE d \in Live : dname[d] = n
FreeDents == {d \in Dents : dstate[d] = "free"}
NewDent == IF FreeDents = {} THEN Nil ELSE SetMin(FreeDents)

(***************************************************************************)
(* mtree_alloc_cyclic(): the lowest free offset at or above next_offset,   *)
(* else the lowest free one at all; next_offset becomes the offset + 1.    *)
(***************************************************************************)
FreeOffs(t) == {o \in Offs : t[o] = Nil}
Above(t, nx) == {o \in FreeOffs(t) : o >= nx}
AllocOff(t, nx) == IF Above(t, nx) # {} THEN SetMin(Above(t, nx))
                   ELSE IF FreeOffs(t) # {} THEN SetMin(FreeOffs(t)) ELSE Nil
Wraps(t, nx) == Above(t, nx) = {} /\ FreeOffs(t) # {}

Init ==
    /\ tree = [o \in Offs |-> Nil]
    /\ nextoff = MIN
    /\ dname = [d \in Dents |-> NoName]
    /\ doff = [d \in Dents |-> 0]
    /\ dstate = [d \in Dents |-> "free"]
    /\ drefs = [d \in Dents |-> 0]
    /\ dlist = <<>>
    /\ lphase = [l \in Listers |-> "closed"]
    /\ pos = [l \in Listers |-> FIRST]
    /\ first = [l \in Listers |-> TRUE]
    /\ mas = [l \in Listers |-> 0]
    /\ cur = [l \in Listers |-> Nil]
    /\ emitted = [l \in Listers |-> FALSE]
    /\ count = [l \in Listers |-> [n \in Names |-> 0]]
    /\ startset = [l \in Listers |-> {}]
    /\ touched = [l \in Listers |-> {}]
    /\ emits = [l \in Listers |-> 0]
    /\ pend = [l \in Listers |-> {}]
    /\ retd = [l \in Listers |-> {}]
    /\ dirty = [l \in Listers |-> FALSE]
    /\ saved = [l \in Listers |-> NoCookie]
    /\ before = [l \in Listers |-> {}]
    /\ segbefore = [l \in Listers |-> {}]
    /\ seekleft = [l \in Listers |-> IF Seeks THEN 1 ELSE 0]
    /\ farleft = [l \in Listers |-> IF FarSeeks THEN 1 ELSE 0]
    /\ far = [l \in Listers |-> FALSE]
    /\ budget = <<SetupOps, ChurnOps>>
    /\ err = "none"
    /\ wrapped = FALSE
    /\ mismatch = FALSE
    /\ cookiegone = FALSE
    /\ rereturn = FALSE

(***************************************************************************)
(* Directory operations. Each one is atomic: shmem runs them under the     *)
(* parent's i_rwsem, and with WRITERS_EXCL that excludes listers inside    *)
(* getdents64(). Without it they may run while a lister is inside a call   *)
(* (between its find and its dir_emit()), which no kernel does today.      *)
(***************************************************************************)
Busy(l) == lphase[l] \in {"find", "emit"}
AllClosed == \A l \in Listers : lphase[l] = "closed"
WriterMay ==
    /\ WRITERS_EXCL => \A l \in Listers : ~Busy(l)
    /\ IF AllClosed THEN budget[1] > 0 ELSE budget[2] > 0
Spend == budget' = IF AllClosed THEN <<budget[1] - 1, budget[2]>> ELSE <<budget[1], budget[2] - 1>>
Changed == dirty' = [l \in Listers |-> dirty[l] \/ Busy(l)]
Touch(S) == touched' = [l \in Listers |-> touched[l] \cup S]
LKeep == UNCHANGED <<lstv, count, startset, emits, pend, retd, seekv, err, mismatch, cookiegone, rereturn>>

\* shmem_mknod(): d_alloc() puts the dentry at the head of d_children,
\* simple_offset_add() gives it the next offset.
Create(n) ==
    /\ "create" \in OpKinds /\ WriterMay /\ n \notin Present
    /\ LET d == NewDent
           o == AllocOff(tree, nextoff)
       IN /\ d # Nil /\ o # Nil
          /\ tree' = [tree EXCEPT ![o] = d]
          /\ nextoff' = o + 1
          /\ wrapped' = (wrapped \/ Wraps(tree, nextoff))
          /\ dname' = [dname EXCEPT ![d] = n]
          /\ doff' = [doff EXCEPT ![d] = o]
          /\ dstate' = [dstate EXCEPT ![d] = "pos"]
          /\ dlist' = <<d>> \o dlist
    /\ Touch({n}) /\ Spend /\ Changed /\ LKeep
    /\ UNCHANGED drefs

\* shmem_unlink(): simple_offset_remove(), then the dentry goes away unless
\* a lister holds it.
Unlink(n) ==
    /\ "unlink" \in OpKinds /\ WriterMay /\ n \in Present
    /\ LET d == D(n)
           gone == drefs[d] = 0
       IN /\ tree' = [tree EXCEPT ![doff[d]] = Nil]
          /\ doff' = [doff EXCEPT ![d] = 0]
          /\ dstate' = [dstate EXCEPT ![d] = IF gone THEN "free" ELSE "dead"]
          /\ dname' = IF gone THEN [dname EXCEPT ![d] = NoName] ELSE dname
          /\ dlist' = IF gone THEN Without(dlist, d) ELSE dlist
    /\ Touch({n}) /\ Spend /\ Changed /\ LKeep
    /\ UNCHANGED <<nextoff, drefs, wrapped>>

\* shmem_rename2() to a new name: simple_offset_add() of the negative target
\* while the source still holds its offset, simple_offset_rename() moves the
\* source to that offset, d_move() puts it at the head of d_children.
RenameCore(s, t) ==
    LET d == D(s)
        o == AllocOff(tree, nextoff)
    IN /\ o # Nil
       /\ tree' = [tree EXCEPT ![doff[d]] = Nil, ![o] = d]
       /\ nextoff' = o + 1
       /\ wrapped' = (wrapped \/ Wraps(tree, nextoff))
       /\ doff' = [doff EXCEPT ![d] = o]
       /\ dname' = [dname EXCEPT ![d] = t]
       /\ dlist' = <<d>> \o Without(dlist, d)
       /\ Touch({s, t})
       /\ UNCHANGED <<dstate, drefs>>

Rename(s, t) ==
    /\ "rename" \in OpKinds /\ WriterMay /\ s \in Present /\ t \notin Present
    /\ RenameCore(s, t)
    /\ Spend /\ Changed /\ LKeep

\* shmem_rename2() over an existing name: the source takes the target's
\* offset (simple_offset_rename()), d_move() puts it at the head of
\* d_children, the target goes away unless a lister holds it.
RenameOver(s, t) ==
    /\ "over" \in OpKinds /\ WriterMay /\ s \in Present /\ t \in Present /\ s # t
    /\ LET ds == D(s)
           dt == D(t)
           ot == doff[dt]
           gone == drefs[dt] = 0
       IN /\ tree' = [tree EXCEPT ![doff[ds]] = Nil, ![ot] = ds]
          /\ doff' = [doff EXCEPT ![ds] = ot, ![dt] = 0]
          /\ dstate' = [dstate EXCEPT ![dt] = IF gone THEN "free" ELSE "dead"]
          /\ dname' = [dname EXCEPT ![ds] = t, ![dt] = IF gone THEN NoName ELSE @]
          /\ dlist' = <<ds>> \o SelectSeq(dlist, LAMBDA x : x # ds /\ ~(gone /\ x = dt))
    /\ Touch({s, t}) /\ Spend /\ Changed /\ LKeep
    /\ UNCHANGED <<nextoff, drefs, wrapped>>

\* RENAME_EXCHANGE: simple_offset_rename_exchange() swaps the dentries in the
\* tree so each name keeps its offset, __d_move() puts the target and then
\* the source at the head of d_children.
Exchange(s, t) ==
    /\ "exchange" \in OpKinds /\ WriterMay /\ s \in Present /\ t \in Present /\ s # t
    /\ LET ds == D(s)
           dt == D(t)
       IN /\ tree' = [tree EXCEPT ![doff[dt]] = ds, ![doff[ds]] = dt]
          /\ doff' = [doff EXCEPT ![ds] = doff[dt], ![dt] = doff[ds]]
          /\ dname' = [dname EXCEPT ![ds] = t, ![dt] = s]
          /\ dlist' = <<ds, dt>> \o SelectSeq(dlist, LAMBDA x : x # ds /\ x # dt)
    /\ Touch({s, t}) /\ Spend /\ Changed /\ LKeep
    /\ UNCHANGED <<nextoff, dstate, drefs, wrapped>>

\* RENAME_WHITEOUT: the target's offset (new name: allocated first), then
\* shmem_whiteout() d_alloc()s the whiteout at the head of d_children and
\* gives it the next offset, then the rename as above.
Whiteout(s, t) ==
    /\ "whiteout" \in OpKinds /\ WriterMay /\ s \in Present /\ s # t
    /\ LET ds == D(s)
           over == t \in Present
           dt == IF over THEN D(t) ELSE Nil
           o1 == IF over THEN doff[dt] ELSE AllocOff(tree, nextoff)
           t1 == IF over THEN tree ELSE [tree EXCEPT ![o1] = ds]
           nx1 == IF over THEN nextoff ELSE o1 + 1
           o2 == AllocOff(t1, nx1)
           dw == NewDent
           gone == over /\ drefs[dt] = 0
       IN /\ o1 # Nil /\ o2 # Nil /\ dw # Nil
          /\ tree' = [tree EXCEPT ![doff[ds]] = Nil, ![o1] = ds, ![o2] = dw]
          /\ nextoff' = o2 + 1
          /\ wrapped' = (wrapped \/ (~over /\ Wraps(tree, nextoff)) \/ Wraps(t1, nx1))
          /\ doff' = [d \in Dents |-> IF d = ds THEN o1 ELSE IF d = dw THEN o2
                                      ELSE IF over /\ d = dt THEN 0 ELSE doff[d]]
          /\ dname' = [d \in Dents |-> IF d = ds THEN t ELSE IF d = dw THEN s
                                       ELSE IF gone /\ d = dt THEN NoName ELSE dname[d]]
          /\ dstate' = [d \in Dents |-> IF d = dw THEN "pos"
                                        ELSE IF over /\ d = dt THEN (IF gone THEN "free" ELSE "dead")
                                        ELSE dstate[d]]
          /\ dlist' = <<ds, dw>> \o SelectSeq(dlist, LAMBDA x : x # ds /\ ~(gone /\ x = dt))
    /\ Touch({s, t}) /\ Spend /\ Changed /\ LKeep
    /\ UNCHANGED drefs

\* generic/736: user space renames each entry readdir() handed it to a new
\* name before it calls readdir() again, which refills from getdents64().
RenameRead ==
    /\ RenameOnRead
    /\ \E l \in Listers :
        /\ lphase[l] = "idle" /\ pend[l] # {}
        /\ LET d == SetMin(pend[l]) IN
           /\ pend' = [pend EXCEPT ![l] = @ \ {d}]
           /\ IF dstate[d] = "pos" /\ Names \ Present # {} /\ AllocOff(tree, nextoff) # Nil
              THEN RenameCore(dname[d], CHOOSE t \in Names \ Present : TRUE)
              ELSE UNCHANGED <<tree, nextoff, wrapped, doff, dname, dlist, touched, dstate, drefs>>
    /\ UNCHANGED <<lstv, count, startset, emits, retd, dirty, seekv, budget, err, mismatch,
                   cookiegone, rereturn>>

(***************************************************************************)
(* A lister: opendir(), then getdents64() calls until one finds the end.   *)
(* Each call takes i_rwsem shared (iterate_dir()), runs dir_emit_dots()    *)
(* and offset_iterate_dir(), and returns when dir_emit() fails for a full  *)
(* buffer. A call returns at least one entry ("." and ".." for the first). *)
(* Between calls a lister may telldir(), seekdir() back to that cookie or  *)
(* lseek() past DIR_OFFSET_EOD; the file position is all it keeps.         *)
(***************************************************************************)
DescOrder ==
    LET L == SelectSeq(dlist, LAMBDA d : dstate[d] = "pos")
    IN \A i \in 1..(Len(L) - 1) : doff[L[i]] > doff[L[i + 1]]

HoldsRef == WALK \in {"list", "list_eod"} \/ REFS

\* dput() of one lister's reference; a dead dentry goes away with the last.
DropRef(d) ==
    LET r == [drefs EXCEPT ![d] = @ - 1]
        gone == dstate[d] = "dead" /\ r[d] = 0
    IN /\ drefs' = r
       /\ dstate' = IF gone THEN [dstate EXCEPT ![d] = "free"] ELSE dstate
       /\ dname' = IF gone THEN [dname EXCEPT ![d] = NoName] ELSE dname
       /\ dlist' = IF gone THEN Without(dlist, d) ELSE dlist
KeepRefs == UNCHANGED <<drefs, dstate, dname, dlist>>

Open(l) ==
    /\ lphase[l] = "closed"
    /\ lphase' = [lphase EXCEPT ![l] = "idle"]
    /\ pos' = [pos EXCEPT ![l] = FIRST]
    /\ startset' = [startset EXCEPT ![l] = Present]
    /\ touched' = [touched EXCEPT ![l] = {}]
    /\ count' = [count EXCEPT ![l] = [n \in Names |-> 0]]
    /\ emits' = [emits EXCEPT ![l] = 0]
    /\ mismatch' = (mismatch \/ ~DescOrder)
    /\ budget' = <<0, budget[2]>>
    /\ UNCHANGED <<dirv, first, mas, cur, emitted, pend, retd, dirty, seekv, err, wrapped,
                   cookiegone, rereturn>>

CallStart(l) ==
    /\ lphase[l] = "idle" /\ pend[l] = {}
    /\ IF pos[l] = EOD \/ (PAST_EOD = "eod" /\ pos[l] > EOD)
       THEN /\ lphase' = [lphase EXCEPT ![l] = "done"]
            /\ UNCHANGED <<first, emitted, cookiegone>>
       ELSE /\ lphase' = [lphase EXCEPT ![l] = "find"]
            /\ first' = [first EXCEPT ![l] = TRUE]
            /\ emitted' = [emitted EXCEPT ![l] = (pos[l] = FIRST)]
            /\ cookiegone' = (cookiegone \/ (pos[l] \in Offs /\ tree[pos[l]] = Nil))
    /\ UNCHANGED <<dirv, pos, mas, cur, bookv, seekv, budget, err, wrapped, mismatch, rereturn>>

\* WALK = "offset": mas_find_rev() on the call's ma_state, from DIR_OFFSET_MAX
\* or ctx->pos on the first find, below the last entry after that; then
\* ctx->pos = dentry2offset(). Without RCU_TREE a walk on a ma_state whose
\* tree changed since its last find reads nodes a writer changed in place.
\* WALK = "ascend": the same upwards, from ctx->pos (DIR_OFFSET_MIN for
\* DIR_OFFSET_FIRST), as offset_find_next() of 6faddda69f62 did.
Start(l) == IF pos[l] = FIRST THEN MAX ELSE pos[l]
AStart(l) == IF pos[l] = FIRST THEN MIN ELSE pos[l]
OffCands(l) ==
    IF WALK = "offset"
    THEN {o \in Offs : tree[o] # Nil /\ IF first[l] THEN o <= Start(l) ELSE o < mas[l]}
    ELSE {o \in Offs : tree[o] # Nil /\ IF first[l] THEN o >= AStart(l) ELSE o > mas[l]}

FindOffset(l) ==
    /\ lphase[l] = "find" /\ WALK \in {"offset", "ascend"}
    /\ err' = IF err = "none" /\ ~first[l] /\ dirty[l] /\ ~RCU_TREE THEN "stale" ELSE err
    /\ dirty' = [dirty EXCEPT ![l] = FALSE]
    /\ IF OffCands(l) = {}
       THEN /\ lphase' = [lphase EXCEPT ![l] = "done"]
            /\ pos' = [pos EXCEPT ![l] = EOD]
            /\ cur' = [cur EXCEPT ![l] = Nil]
            /\ mas' = [mas EXCEPT ![l] = 0]
            /\ UNCHANGED drefs
       ELSE LET o == IF WALK = "offset" THEN SetMax(OffCands(l)) ELSE SetMin(OffCands(l))
                d == tree[o]
            IN /\ lphase' = [lphase EXCEPT ![l] = "emit"]
               /\ cur' = [cur EXCEPT ![l] = d]
               /\ mas' = [mas EXCEPT ![l] = o]
               /\ pos' = [pos EXCEPT ![l] = doff[d]]
               /\ drefs' = IF REFS THEN [drefs EXCEPT ![d] = @ + 1] ELSE drefs
    /\ UNCHANGED <<tree, nextoff, dname, doff, dstate, dlist, first, emitted, count, startset,
                   touched, emits, pend, retd, seekv, budget, witv>>

\* WALK = "list"/"list_eod": offset_dir_lookup() and find_positive_dentry().
\* The first find maps ctx->pos to the entry with the highest offset at or
\* below it and continues from its place in d_children; with no such entry
\* "list" restarts at the head and "list_eod" ends the listing. After that
\* the next positive dentry in d_children, dget() before the dput() of the
\* previous one.
PosAt(from) ==
    LET I == {i \in from..Len(dlist) : dstate[dlist[i]] = "pos"}
    IN IF I = {} THEN Nil ELSE dlist[SetMin(I)]
IndexOf(d) == CHOOSE i \in 1..Len(dlist) : dlist[i] = d
ListStart(l) ==
    IF pos[l] = FIRST THEN PosAt(1)
    ELSE LET C == {o \in Offs : tree[o] # Nil /\ o <= pos[l]}
         IN IF C = {} THEN (IF WALK = "list" THEN PosAt(1) ELSE Nil)
            ELSE PosAt(IndexOf(tree[SetMax(C)]))

FindList(l) ==
    /\ lphase[l] = "find" /\ WALK \in {"list", "list_eod"}
    /\ LET d == IF first[l] THEN ListStart(l) ELSE PosAt(IndexOf(cur[l]) + 1)
           prev == IF first[l] THEN Nil ELSE cur[l]
           r1 == IF d # Nil THEN [drefs EXCEPT ![d] = @ + 1] ELSE drefs
           r2 == IF prev # Nil THEN [r1 EXCEPT ![prev] = @ - 1] ELSE r1
           gone == prev # Nil /\ dstate[prev] = "dead" /\ r2[prev] = 0
       IN /\ drefs' = r2
          /\ dstate' = IF gone THEN [dstate EXCEPT ![prev] = "free"] ELSE dstate
          /\ dname' = IF gone THEN [dname EXCEPT ![prev] = NoName] ELSE dname
          /\ dlist' = IF gone THEN Without(dlist, prev) ELSE dlist
          /\ IF d = Nil
             THEN /\ lphase' = [lphase EXCEPT ![l] = "done"]
                  /\ pos' = [pos EXCEPT ![l] = EOD]
                  /\ cur' = [cur EXCEPT ![l] = Nil]
             ELSE /\ lphase' = [lphase EXCEPT ![l] = "emit"]
                  /\ pos' = [pos EXCEPT ![l] = doff[d]]
                  /\ cur' = [cur EXCEPT ![l] = d]
    /\ UNCHANGED <<tree, nextoff, doff, first, mas, emitted, count, startset, touched, emits,
                   pend, retd, dirty, seekv, budget, err, witv>>

\* dir_emit() fails, the buffer is full: the call returns with ctx->pos at
\* the entry it found, which the next call starts with.
Stop(l) ==
    /\ lphase[l] = "emit" /\ emitted[l]
    /\ IF HoldsRef THEN DropRef(cur[l]) ELSE KeepRefs
    /\ lphase' = [lphase EXCEPT ![l] = "idle"]
    /\ cur' = [cur EXCEPT ![l] = Nil]
    /\ mas' = [mas EXCEPT ![l] = 0]
    /\ first' = [first EXCEPT ![l] = TRUE]
    /\ emitted' = [emitted EXCEPT ![l] = FALSE]
    /\ UNCHANGED <<tree, nextoff, doff, pos, bookv, seekv, budget, err, witv>>

\* dir_emit() succeeds: d_name, d_inode->i_ino and ->i_mode of the dentry.
Emit(l) ==
    /\ lphase[l] = "emit"
    /\ LET d == cur[l] IN
       IF dstate[d] = "free"
       THEN /\ err' = IF err = "none" THEN "uaf" ELSE err
            /\ lphase' = [lphase EXCEPT ![l] = "done"]
            /\ UNCHANGED <<dirv, pos, first, mas, cur, emitted, bookv, seekv, budget, witv>>
       ELSE /\ count' = [count EXCEPT ![l][dname[d]] = SatC(@ + 1)]
            /\ emits' = [emits EXCEPT ![l] = Sat(@ + 1)]
            /\ emitted' = [emitted EXCEPT ![l] = TRUE]
            /\ first' = [first EXCEPT ![l] = FALSE]
            /\ pend' = IF RenameOnRead THEN [pend EXCEPT ![l] = @ \cup {d}] ELSE pend
            /\ retd' = IF Track THEN [retd EXCEPT ![l] = @ \cup {d}] ELSE retd
            /\ rereturn' = (rereturn \/ (Track /\ d \in retd[l]))
            /\ IF WALK \in {"offset", "ascend"} /\ REFS THEN DropRef(d) ELSE KeepRefs
            /\ lphase' = [lphase EXCEPT ![l] = "find"]
            /\ UNCHANGED <<tree, nextoff, doff, pos, mas, cur, startset, touched, dirty, seekv,
                           budget, err, wrapped, mismatch, cookiegone>>

\* telldir() between calls: the cookie is the file position, the d_off of
\* the last entry returned. Only before any seek, so before is what this
\* listing returned so far.
Tell(l) ==
    /\ Seeks /\ lphase[l] = "idle" /\ saved[l] = NoCookie /\ seekleft[l] > 0 /\ ~far[l]
    /\ saved' = [saved EXCEPT ![l] = pos[l]]
    /\ before' = [before EXCEPT ![l] = {n \in Names : count[l][n] > 0}]
    /\ UNCHANGED <<dirv, lstv, bookv, segbefore, seekleft, farleft, far, budget, err, witv>>

\* seekdir() back to the cookie, also after the listing reached its end.
SeekBack(l) ==
    /\ lphase[l] \in {"idle", "done"} /\ saved[l] # NoCookie /\ seekleft[l] > 0 /\ pend[l] = {}
    /\ lphase' = [lphase EXCEPT ![l] = "idle"]
    /\ pos' = [pos EXCEPT ![l] = saved[l]]
    /\ count' = [count EXCEPT ![l] = [n \in Names |-> 0]]
    /\ emits' = [emits EXCEPT ![l] = 0]
    /\ retd' = [retd EXCEPT ![l] = {}]
    /\ segbefore' = [segbefore EXCEPT ![l] = before[l]]
    /\ seekleft' = [seekleft EXCEPT ![l] = 0]
    /\ far' = [far EXCEPT ![l] = FALSE]
    /\ UNCHANGED <<dirv, first, mas, cur, emitted, startset, touched, pend, dirty, saved, before,
                   farleft, budget, err, witv>>

\* lseek() past DIR_OFFSET_EOD: offset_dir_llseek() takes any position up to
\* LONG_MAX.
SeekFar(l) ==
    /\ lphase[l] \in {"idle", "done"} /\ farleft[l] > 0 /\ pend[l] = {}
    /\ lphase' = [lphase EXCEPT ![l] = "idle"]
    /\ pos' = [pos EXCEPT ![l] = FAR]
    /\ count' = [count EXCEPT ![l] = [n \in Names |-> 0]]
    /\ emits' = [emits EXCEPT ![l] = 0]
    /\ retd' = [retd EXCEPT ![l] = {}]
    /\ far' = [far EXCEPT ![l] = TRUE]
    /\ farleft' = [farleft EXCEPT ![l] = 0]
    /\ UNCHANGED <<dirv, first, mas, cur, emitted, startset, touched, pend, dirty, saved, before,
                   segbefore, seekleft, budget, err, witv>>

Lister(l) == Open(l) \/ CallStart(l) \/ FindOffset(l) \/ FindList(l) \/ Stop(l) \/ Emit(l)
Seeker(l) == Tell(l) \/ SeekBack(l) \/ SeekFar(l)

Finished == (\A l \in Listers : lphase[l] = "done") /\ UNCHANGED vars

Next ==
    \/ \E n \in Names : Create(n) \/ Unlink(n)
    \/ \E s, t \in Names : Rename(s, t) \/ RenameOver(s, t) \/ Exchange(s, t) \/ Whiteout(s, t)
    \/ RenameRead
    \/ \E l \in Listers : Lister(l) \/ Seeker(l)
    \/ Finished

Spec == Init /\ [][Next]_vars /\ (\A l \in Listers : WF_vars(Lister(l))) /\ WF_vars(RenameRead)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
    /\ tree \in [Offs -> Dents \cup {Nil}]
    /\ nextoff \in MIN..(MAX + 1)
    /\ dname \in [Dents -> Names \cup {NoName}]
    /\ doff \in [Dents -> Offs \cup {0}]
    /\ dstate \in [Dents -> {"free", "pos", "dead"}]
    /\ drefs \in [Dents -> 0..Cardinality(Listers)]
    /\ dlist \in Seq(Dents)
    /\ lphase \in [Listers -> {"closed", "idle", "find", "emit", "done"}]
    /\ pos \in [Listers -> {FIRST, EOD, FAR} \cup Offs]
    /\ first \in [Listers -> BOOLEAN]
    /\ mas \in [Listers -> {0} \cup Offs]
    /\ cur \in [Listers -> {Nil} \cup Dents]
    /\ emitted \in [Listers -> BOOLEAN]
    /\ count \in [Listers -> [Names -> 0..2]]
    /\ startset \in [Listers -> SUBSET Names]
    /\ touched \in [Listers -> SUBSET Names]
    /\ emits \in [Listers -> 0..(NOff + 1)]
    /\ pend \in [Listers -> SUBSET Dents]
    /\ retd \in [Listers -> SUBSET Dents]
    /\ dirty \in [Listers -> BOOLEAN]
    /\ saved \in [Listers -> {NoCookie, FIRST, FAR} \cup Offs]
    /\ before \in [Listers -> SUBSET Names]
    /\ segbefore \in [Listers -> SUBSET Names]
    /\ seekleft \in [Listers -> 0..1]
    /\ farleft \in [Listers -> 0..1]
    /\ far \in [Listers -> BOOLEAN]
    /\ budget \in (0..SetupOps) \X (0..ChurnOps)
    /\ err \in {"none", "uaf", "stale"}
    /\ {wrapped, mismatch, cookiegone, rereturn} \subseteq BOOLEAN

\* The offset tree, d_fsdata, d_children and the dentries agree.
DirOK ==
    /\ \A o \in Offs : tree[o] # Nil => dstate[tree[o]] = "pos" /\ doff[tree[o]] = o
    /\ \A d \in Live : doff[d] \in Offs /\ tree[doff[d]] = d
    /\ \A d1, d2 \in Live : d1 # d2 => dname[d1] # dname[d2]
    /\ \A d \in Dents : (dstate[d] # "free") <=> (\E i \in 1..Len(dlist) : dlist[i] = d)
    /\ Len(dlist) = Cardinality({d \in Dents : dstate[d] # "free"})
    /\ \A d \in Dents : dstate[d] = "dead" => drefs[d] > 0 /\ doff[d] = 0
    /\ \A d \in Dents : dstate[d] = "free" => drefs[d] = 0 /\ dname[d] = NoName /\ doff[d] = 0

\* An entry nobody touched since opendir() is returned exactly once, and
\* after seekdir() back to a telldir() cookie exactly the untouched entries
\* that hadn't been returned when the cookie was taken come back.
Stable(l) == startset[l] \ touched[l]
NoDup == \A l \in Listers : \A n \in Stable(l) : count[l][n] <= 1
Complete == \A l \in Listers :
                (lphase[l] = "done" /\ err = "none" /\ ~far[l]) =>
                    \A n \in Stable(l) \ segbefore[l] : count[l][n] = 1
NoRepeat == \A l \in Listers : \A n \in Stable(l) \cap segbefore[l] : count[l][n] = 0

\* A file position past DIR_OFFSET_EOD returns nothing, as before
\* b9b588f22a0c and as dcache_readdir() does.
PastEODEmpty == \A l \in Listers : far[l] => \A n \in Names : count[l][n] = 0

\* A listing returns at most one entry per offset, so no listing gets
\* longer than the offset range.
Bounded == \A l \in Listers : emits[l] <= NOff

NoUAF == err # "uaf"
NoStale == err # "stale"

\* Without a wrap of the allocator an entry created or renamed after opendir()
\* gets an offset above everything the descending walk can still reach, so the
\* walk returns no dentry twice. The ascending walk of 6faddda69f62 returns a
\* renamed entry again right away; with 2^31 offsets generic/736 then runs for
\* as long as it keeps renaming. Needs Track.
ReReturnNeedsWrap == rereturn => wrapped

\* generic/736 with fairness: every listing reaches its end.
Terminates == \A l \in Listers : <>(lphase[l] = "done")

\* Witnesses, each expected to be violated: the passing configurations reach
\* these cases.
NoWrap == ~wrapped
OrdersAgree == ~mismatch
NoCookieGone == ~cookiegone
NoReReturn == ~rereturn
\* a seekdir() back to a cookie taken mid-listing, and the listing after it
\* reached its end
NoSeekBack == \A l \in Listers : ~(seekleft[l] = 0 /\ saved[l] # NoCookie /\ segbefore[l] # {}
                                    /\ lphase[l] = "done" /\ ~far[l])
\* two listers inside getdents64() at the same time
NoOverlap == ~(\A l \in Listers : Busy(l))
=============================================================================

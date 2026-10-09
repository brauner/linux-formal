----------------------------- MODULE MntVacant -----------------------------
(***************************************************************************)
(* The lifetime of an unmounted mount that stays attached to its unmounted *)
(* parent, as work.mount.knullfs.4 makes it (namespace: prevent            *)
(* UMOUNT_CONNECTED reference count cycles, with the fixup that decides     *)
(* the last put of a vacant mount under mount_lock):                       *)
(*   - every victim of umount_tree() keeps its own reference, attached or  *)
(*     not; namespace_unlock() waits for a grace period and then drops     *)
(*     those references in tree order from task work                       *)
(*     (mntput_unmounted_work()), each final put followed by the           *)
(*     cleanup_mnt() of that mount; a kernel thread puts them in place and *)
(*     queues the cleanups;                                                *)
(*   - the final put of a mount (mntput_slow() -> mntput_final_locked())   *)
(*     dooms it if it is disconnected, unhashes its children, and puts the *)
(*     vacant ones right after the mount_lock section; a mount still       *)
(*     attached is vacated in place instead (vacate_mount()): pointed at   *)
(*     knullfs (mnt_sb, mnt_root, the instance list), one reference for    *)
(*     the parent, and the release of the filesystem it carried left to    *)
(*     cleanup_mnt();                                                      *)
(*   - the last put of a vacant mount (unhashed by its parent's final put  *)
(*     or by __detach_mounts()) dooms it, and it and the release hand the  *)
(*     free to whoever comes second: the release clears mnt_old_root       *)
(*     under mount_lock and frees if MNT_DOOMED is set                     *)
(*     (vacant_mount_released()); the last put frees if mnt_old_root is    *)
(*     already clear, decided while it still holds mount_lock;             *)
(*   - __detach_mounts() unhashes the mount at a removed mountpoint and    *)
(*     collects it on `disowned` if it is vacant; namespace_unlock() puts  *)
(*     the parent's reference right after dropping namespace_sem, with no  *)
(*     grace period, and a vacant mount never rides the unmounted list     *)
(*     whose first mount carries the task work in its mnt_rcu;             *)
(*   - knullfs is a private nullfs instance that never goes away: a vacant *)
(*     mount takes no reference on it, nothing can be mounted on a vacant  *)
(*     mount, and fanotify refuses mount and filesystem marks on it        *)
(*     (SB_NOUSER); a mark placed before the vacate is accounted on the    *)
(*     superblock recorded in its connector (the fsnotify prep patch) and  *)
(*     cleared by the release before that superblock is torn down.         *)
(*                                                                         *)
(* NOREF is work.mount.knullfs.7: a vacant mount has no reference of its   *)
(* own.  __legitimize_mnt() marks a stand-in before it bumps the count     *)
(* (and under mount_lock on its retry path); the parent's final put, and   *)
(* __detach_mounts(), disown a stand-in under mount_lock: off knullfs'     *)
(* instance list, and unless it is marked and its count says a walk still  *)
(* holds it, doomed, to be freed once the release is done, by the parent's *)
(* cleanup_mnt() through mnt_stuck_children or right away in              *)
(* __detach_mounts().  A walk's last put on a hashed stand-in leaves it    *)
(* at zero where it is; on a disowned one it dooms it and hands off to the *)
(* release as before.                                                      *)
(*                                                                         *)
(* Layout: P, the root of a lazily unmounted subtree, disconnected from    *)
(* its mounted parent; M attached to P; G attached to M, all MNT_UMOUNT    *)
(* with mnt_ns NULL (UMOUNT_CONNECTED, or M and G locked).  The initial    *)
(* state is namespace_unlock() right after up_write(&namespace_sem).  A    *)
(* superblock may pin a mount through a file its filesystem keeps open (M's *)
(* loop device's backing file on P, G's on M: Michael Vogt's cycle), a     *)
(* reference dropped when the superblock is deactivated.                   *)
(*                                                                         *)
(* Tasks: U runs namespace_unlock()'s synchronize_rcu_expedited() and the  *)
(* puts of the unmounted list; holders close their files on P or M, and    *)
(* may put a fanotify mount mark on their mount or the one below it; walkers*)
(* do RCU path walks from a holder's file into the mount below it          *)
(* (__lookup_mnt(), __legitimize_mnt(), mntput(), or the REF walk after     *)
(* -ECHILD); D removes a mountpoint directory (vfs_rmdir() ->              *)
(* __detach_mounts(), then namespace_unlock()); K is the fput() of a        *)
(* released filesystem's file; cleanup_mnt() items run as task work, in    *)
(* any order and at any time, a superset of the kernel's per-task order    *)
(* (U_INLINE narrows U to the task-work shape).  A task that made a final  *)
(* put drops the parent's references of the vacant children right after   *)
(* its mount_lock section, before it does anything else.                   *)
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
    SbIds,           \* the superblocks the mounts carry, one mount each
    Sb,              \* [MntIds -> SbIds]
    NullSb,          \* knullfs' superblock, not in SbIds: never active or inactive, never released
    Pin,             \* [SbIds -> MntIds \cup {NoMnt}]: the mount a superblock's file pins
    Holders,         \* holder tasks, one file each
    HolderMnt,       \* [Holders -> MntIds]: the mount the holder's file is on
    Walkers,         \* walker tasks
    WalkBudget,      \* walks per walker
    DetachTargets,   \* mounts whose mountpoint directory may be removed
    HOLDER_ORDER,    \* "any"; "early": the subtree root's holder closes before U puts
                     \* (dissolve_on_fput() dropping the file's reference under namespace_sem,
                     \* ksys_unshare() freeing the old fs_struct first); "late": after U is done
    Marks,           \* holders may place a fanotify mount mark (FAN_MARK_MOUNT) before they close
    U_INLINE,        \* U runs the cleanup of each final put before its next put, as mntput_unmounted_work() does
    FIX_OWN_REF,     \* attached victims keep their own reference, put by namespace_unlock()
                     \* (off: owned by the parent and put by its cleanup_mnt(), as upstream)
    VACATE_MODE,     \* "vacate": the series; "doom": the last put of an attached mount dooms
                     \* it in place, as the upstream slow path would; "unhash": it disconnects it
    FIX_PUT_VACANT_ONLY,      \* the parent's final put puts only its vacant children (off: every unhashed child)
    FIX_TREE_ORDER,           \* namespace_unlock() puts parents first (off: children first, the hlist order)
    FIX_DETACH_PUTS_VACANT,   \* __detach_mounts() puts a vacant mount it unhashes (off: never)
    DETACH_PUTS_ALL,          \* mutation: __detach_mounts() puts every unmounted mount it unhashes
    FIX_DISOWNED,             \* a vacant mount __detach_mounts() cut loose is put from `disowned` right away
                              \* (off: it rides the unmounted list, whose first mount carries the task work)
    FIX_HANDOFF_LOCKED,       \* release and last put read the other's mark under mount_lock (off: after dropping it)
    FIX_LAST_UNDER_LOCK,      \* mntput_slow() decides whether the last put of a vacant mount frees it
                              \* while it holds mount_lock (off: from the flags re-read after unlock_mount_hash())
    FIX_CONN_SB,              \* a mark is accounted on the superblock recorded in its connector
                              \* (off: on the superblock the object points at when the mark goes)
    FIX_MARK_GATE,            \* fanotify refuses mount marks on a knullfs mount (off: it takes them)
    RELEASE_PUTS,             \* the earlier design: vacate takes two references, the release ends in mntput()
    NOREF,                    \* work.mount.knullfs.7: no reference for the parent, the mark decides (see the header)
    NOREF_MARK,               \* __legitimize_mnt() marks the stand-in it takes a reference to (off: mutation)
    NOREF_TRUST_MARK,         \* the parent frees an unmarked stand-in without summing its count (off: it always sums)
    NOREF_SUM,                \* the parent sums the count of a marked stand-in (off: it never frees a marked one)
    NOREF_HASHED_DOOMS,       \* mutation: a walk's last put dooms a stand-in that is still hashed
    NOREF_DETACH_FREES        \* __detach_mounts() frees a dead stand-in it cut loose (off: mutation, it leaks)

NoMnt == 0
ASSUME VACATE_MODE \in {"vacate", "doom", "unhash"}
ASSUME HOLDER_ORDER \in {"any", "early", "late"}
ASSUME \A h \in Holders : HolderMnt[h] \in MntIds
ASSUME NullSb \notin SbIds
ASSUME NOREF => FIX_OWN_REF /\ VACATE_MODE = "vacate" /\ ~RELEASE_PUTS

\* the tasks that put: U, D, K (a pin drop), C (cleanup task work), the holders, the walkers
Tasks == {"U", "D", "K", "C"} \cup Holders \cup Walkers
WatchSbs == SbIds \cup {NullSb}

VARIABLES
    mt,        \* [MntIds -> record]: hashed, parent, count, doomed, vacant, oldroot (release pending),
               \*   inst ("fs", "null", "none": which instance list), stuck (upstream's owned children;
               \*   with NOREF the dead stand-ins the cleanup frees), held (NOREF: a walk marked it),
               \*   freed, rcufree, mpgone, mark, conn (the superblock the mark is accounted on)
    sbact,     \* [SbIds -> BOOLEAN]: the superblock is active
    watched,   \* [WatchSbs -> Int]: fsnotify's watched objects per superblock
    seq,       \* mount_lock's sequence count
    uhead,     \* the mounts namespace_unlock() still has to put, in order
    upc,       \* U: "gp", "wait", "put", "done"
    ugp,       \* the readers U's synchronize_rcu_expedited() waits for
    ext,       \* [MntIds -> Nat]: holders' references
    hdone,     \* [Holders -> BOOLEAN]
    wpc, wsrc, wtgt, wseq, wroot, wres, wn,   \* the walkers
    rcu,       \* the readers
    dpc, dhead, dgp, dtargets,   \* D: "idle", "gp", "put"; its unmounted list; its grace period; targets left
    tw,        \* pending cleanup_mnt() items: [m, kind ("cleanup" | "release"), step, owner]
    vq,        \* [Tasks -> Seq(MntIds)]: the puts a task still owes right after its final put
    lchk,      \* [Tasks -> MntIds \cup {NoMnt}]: the mount a task just vacated and checks after unlock (FIX_LAST_UNDER_LOCK off)
    pchk, rchk,    \* the unlocked handoff checks still to run (FIX_HANDOFF_LOCKED off)
    pins,      \* mounts whose pin reference is being dropped
    freewait,  \* [MntIds -> SUBSET Walkers]: the readers the RCU free of a mount waits for
    hist

vars == <<mt, sbact, watched, seq, uhead, upc, ugp, ext, hdone, wpc, wsrc, wtgt, wseq, wroot, wres, wn,
          rcu, dpc, dhead, dgp, dtargets, tw, vq, lchk, pchk, rchk, pins, freewait, hist>>

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
\* the superblock the vfsmount points at: knullfs once vacated
CurSb(t, m) == IF t[m].vacant THEN NullSb ELSE Sb[m]
Who(t) == IF t \in Holders THEN "H" ELSE IF t \in Walkers THEN "W" ELSE t

\* the whole state as a record, so that a step can be composed of the
\* kernel's pieces (a put may vacate, free, queue task work, ...)
St == [mt |-> mt, sbact |-> sbact, watched |-> watched, seq |-> seq, uhead |-> uhead, upc |-> upc,
       ugp |-> ugp, ext |-> ext, hdone |-> hdone, wpc |-> wpc, wsrc |-> wsrc, wtgt |-> wtgt,
       wseq |-> wseq, wroot |-> wroot, wres |-> wres, wn |-> wn, rcu |-> rcu, dpc |-> dpc,
       dhead |-> dhead, dgp |-> dgp, dtargets |-> dtargets, tw |-> tw, vq |-> vq, lchk |-> lchk,
       pchk |-> pchk, rchk |-> rchk, pins |-> pins, freewait |-> freewait, hist |-> hist]
Apply(s) ==
    /\ mt' = s.mt /\ sbact' = s.sbact /\ watched' = s.watched /\ seq' = s.seq /\ uhead' = s.uhead
    /\ upc' = s.upc /\ ugp' = s.ugp /\ ext' = s.ext /\ hdone' = s.hdone /\ wpc' = s.wpc
    /\ wsrc' = s.wsrc /\ wtgt' = s.wtgt /\ wseq' = s.wseq /\ wroot' = s.wroot /\ wres' = s.wres
    /\ wn' = s.wn /\ rcu' = s.rcu /\ dpc' = s.dpc /\ dhead' = s.dhead /\ dgp' = s.dgp
    /\ dtargets' = s.dtargets /\ tw' = s.tw /\ vq' = s.vq /\ lchk' = s.lchk /\ pchk' = s.pchk
    /\ rchk' = s.rchk /\ pins' = s.pins /\ freewait' = s.freewait /\ hist' = s.hist

\* rcu_read_unlock() of walker w: the grace periods and RCU frees waiting for it stop waiting
RcuOut(s, w) == [s EXCEPT !.rcu = @ \ {w}, !.ugp = @ \ {w}, !.dgp = @ \ {w},
                          !.freewait = [m \in MntIds |-> @[m] \ {w}]]
Warn(s, w) == [s EXCEPT !.hist.warn = @ \cup {w}]

\* a task with a put still owed, or a check still to run, does that first
Quiet(t) == vq[t] = <<>> /\ lchk[t] = NoMnt

(* ---- freeing ------------------------------------------------------------ *)

\* mnt_free_id() + call_rcu(delayed_free_vfsmnt): the memory goes once the
\* readers present now have left.  The VFS_WARN_ON_ONCEs of
\* free_vacant_mount() (children, marks) and the sanity of freeing a
\* hashed or listed mount are recorded as warnings
Free(s, m) ==
    LET t == s.mt[m]
        w == (IF Kids(s.mt, m) # {} THEN {"free_kids"} ELSE {})
             \cup (IF t.stuck # {} THEN {"free_stuck"} ELSE {})
             \cup (IF t.mark THEN {"free_marks"} ELSE {})
             \cup (IF t.inst # "none" THEN {"free_instance"} ELSE {})
             \cup (IF t.hashed THEN {"free_hashed"} ELSE {})
             \cup (IF t.rcufree THEN {"double_free"} ELSE {})
    IN [s EXCEPT !.mt[m].rcufree = TRUE, !.freewait[m] = s.rcu,
                 !.hist.frees[m] = @ + 1, !.hist.warn = @ \cup w]

(* ---- the slow path of mntput() ------------------------------------------ *)

\* NOREF: disown_vacant_mount() under mount_lock, once the parent's final
\* put or __detach_mounts() unhashed the stand-in: off knullfs' instance
\* list; a walk may still hold it only if it marked it, and the count
\* says whether it does; else it is doomed, and whoever comes second, this
\* or the release, frees it
Disown(t) ==
    LET dead == (NOREF_TRUST_MARK /\ ~t.held) \/ (NOREF_SUM /\ t.count = 0)
    IN [t EXCEPT !.inst = "none", !.doomed = dead]
Dead(t) == Disown(t).doomed /\ ~t.oldroot

\* the last put of a vacant mount inside mntput_final_locked(): it must
\* have been unhashed already (VFS_WARN_ON_ONCE(connected)), MNT_DOOMED,
\* off knullfs' instance list; then `mnt_old_root ? NULL : mnt`, and
\* mntput_slow() frees what came back after unlock_mount_hash(); with the
\* handoff unlocked, mnt_old_root is read after the lock is dropped
VacantPut(s, m, who) ==
    LET t == s.mt[m]
        w == (IF t.hashed THEN {"vacant_put_attached"} ELSE {})
             \cup (IF t.inst # "null" THEN {"instance"} ELSE {})
             \cup (IF RELEASE_PUTS /\ t.oldroot THEN {"release_pending_at_free"} ELSE {})
        s1 == [s EXCEPT !.mt[m].doomed = TRUE, !.mt[m].inst = "none",
                        !.hist.warn = @ \cup w, !.hist.doomby = @ \cup {who}]
    IN IF RELEASE_PUTS THEN Free(s1, m)
       ELSE IF ~FIX_HANDOFF_LOCKED THEN [s1 EXCEPT !.pchk = @ \cup {m}]
       ELSE IF t.oldroot THEN [s1 EXCEPT !.hist.putfirst = @ + 1]
       ELSE Free(s1, m)

\* NOREF: the last put of a walk's reference on a stand-in.  Still hashed,
\* it stays at zero until the parent lets go of it (the mutation dooms it
\* in place); disowned by then, it is doomed here, and it and the release
\* hand the free to whoever comes second
VacantPutNoref(s, m, who) ==
    LET t == s.mt[m]
        w == IF t.inst # "none" THEN {"instance"} ELSE {}
        s1 == [s EXCEPT !.mt[m].doomed = TRUE, !.hist.warn = @ \cup w, !.hist.doomby = @ \cup {who}]
    IN IF t.hashed
       THEN IF NOREF_HASHED_DOOMS THEN [s EXCEPT !.mt[m].doomed = TRUE, !.mt[m].inst = "none"]
            ELSE [s EXCEPT !.hist.hashedzero = @ + 1]
       ELSE IF t.oldroot THEN [s1 EXCEPT !.hist.putfirst = @ + 1]
       ELSE Free(s1, m)

\* the rest of mntput_final_locked() once the count reached zero and the
\* mount is neither doomed nor vacant: unhash the children and owe the
\* puts of the vacant ones (with the mutation of every one; upstream
\* owns them all as stuck children of its cleanup); then either
\* vacate_mount() while still attached, with the release queued, or
\* MNT_DOOMED and cleanup_mnt() queued.  With FIX_LAST_UNDER_LOCK off the
\* vacating task re-reads the flags after unlock_mount_hash() and only then
\* queues the release
LastPut(s, m, who, task) ==
    LET t == s.mt[m]
        connected == t.hashed /\ t.parent # NoMnt
        kids == Kids(s.mt, m)
        vac == FIX_OWN_REF /\ connected /\ VACATE_MODE = "vacate"
        unh == FIX_OWN_REF /\ connected /\ VACATE_MODE = "unhash"
        owed == IF ~FIX_OWN_REF \/ NOREF THEN {}
                ELSE IF FIX_PUT_VACANT_ONLY THEN {c \in kids : s.mt[c].vacant} ELSE kids
        \* upstream: every unhashed child, owned; NOREF: the dead stand-ins the cleanup frees
        stuck == IF ~FIX_OWN_REF THEN kids
                 ELSE IF NOREF THEN {c \in kids : s.mt[c].vacant /\ Dead(s.mt[c])} ELSE {}
        self == IF vac
                THEN [t EXCEPT !.vacant = TRUE, !.oldroot = TRUE, !.inst = "null", !.held = FALSE,
                               !.stuck = stuck,
                               !.count = IF NOREF THEN 0 ELSE IF RELEASE_PUTS THEN 2 ELSE 1]
                ELSE [t EXCEPT !.doomed = TRUE, !.inst = "none", !.stuck = stuck,
                               !.hashed = IF unh THEN FALSE ELSE t.hashed,
                               !.parent = IF unh THEN NoMnt ELSE t.parent]
        Kid(x) == LET k == [s.mt[x] EXCEPT !.hashed = FALSE, !.parent = NoMnt]
                  IN IF NOREF /\ k.vacant THEN Disown(k) ELSE k
        mt1 == [x \in MntIds |-> IF x = m THEN self
                                 ELSE IF x \in kids THEN Kid(x)
                                 ELSE s.mt[x]]
        item == [m |-> m, kind |-> IF vac THEN "release" ELSE "cleanup",
                 step |-> IF ~FIX_OWN_REF \/ stuck # {} THEN "stuck" ELSE "sb", owner |-> task]
        later == vac /\ ~FIX_LAST_UNDER_LOCK
        \* a vacate the put order alone caused: the parent lives on the
        \* reference U has not dropped yet and on nothing else
        needless == vac /\ s.mt[t.parent].count = 1 /\ InSeq(t.parent, s.uhead)
        w == IF connected /\ ~vac /\ ~unh THEN {"doomed_attached"} ELSE {}
    IN [s EXCEPT !.mt = mt1,
                 !.tw = IF later THEN @ ELSE @ \cup {item},
                 !.lchk[task] = IF later THEN m ELSE NoMnt,
                 !.vq[task] = @ \o Ordered(owed),
                 !.hist.vacates = @ + (IF vac THEN 1 ELSE 0),
                 !.hist.needless = @ + (IF needless THEN 1 ELSE 0),
                 !.hist.vacby = @ \cup (IF vac THEN {who} ELSE {}),
                 !.hist.doomby = @ \cup (IF vac THEN {} ELSE {who}),
                 !.hist.warn = @ \cup w]

\* mntput() on a mount with mnt_ns NULL: lock_mount_hash(), the decrement,
\* mnt_get_count(); not the last, a second final put on a doomed mount
\* (returns), the last put of a vacant mount, or the last put
Put(s, m, who, task) ==
    LET t == s.mt[m]
        c == t.count - 1
        s0 == [s EXCEPT !.mt[m].count = c, !.seq = @ + 1]
        s0b == IF t.vacant /\ who \notin {"W", "H"} THEN [s0 EXCEPT !.hist.ownerputs = @ + 1] ELSE s0
    IN IF c < 0 THEN [s0b EXCEPT !.hist.negative = TRUE]
       ELSE IF c > 0 THEN s0b
       ELSE IF t.doomed THEN Warn(s0b, "put_doomed")
       ELSE IF t.vacant THEN (IF NOREF THEN VacantPutNoref(s0b, m, who) ELSE VacantPut(s0b, m, who))
       ELSE LastPut(s0b, m, who, task)

\* the puts a task owes right after its final put: mntput_list() of the
\* vacant children, or the disowned mount of __detach_mounts()
VPut(t) ==
    /\ vq[t] # <<>> /\ lchk[t] = NoMnt
    /\ Apply(Put([St EXCEPT !.vq[t] = Tail(@)], Head(vq[t]), "V", t))

\* the flags re-read after unlock_mount_hash() of the pre-fixup
\* mntput_slow(): the mount it just vacated is vacant, and doomed if the
\* parent's final put or __detach_mounts() plus namespace_unlock() cut it
\* and dropped the parent's reference in the meantime; then it is freed
\* with its release never queued
LCheck(t) ==
    /\ lchk[t] # NoMnt
    /\ LET m == lchk[t]
           s1 == [St EXCEPT !.lchk[t] = NoMnt]
           item == [m |-> m, kind |-> "release", step |-> "sb", owner |-> t]
       IN IF mt[m].vacant /\ mt[m].doomed
          THEN Apply(Free([s1 EXCEPT !.hist.warn = @ \cup (IF mt[m].oldroot THEN {"release_pending_at_free"} ELSE {})], m))
          ELSE Apply([s1 EXCEPT !.tw = @ \cup {item}])

(* ---- cleanup_mnt() as task work ------------------------------------------ *)

\* the steps of an item: upstream's cleanup puts the stuck children first;
\* then the filesystem is released; a doomed mount is freed, a vacant one
\* hands off
NextStep(it) ==
    IF it.step = "stuck" THEN "sb"
    ELSE IF it.step = "sb" THEN (IF it.kind = "cleanup" THEN "free" ELSE "handoff")
    ELSE "done"
Advance(s, it) ==
    LET nxt == NextStep(it)
    IN [s EXCEPT !.tw = IF nxt = "done" THEN @ \ {it} ELSE (@ \ {it}) \cup {[it EXCEPT !.step = nxt]}]

\* mntput_unmounted_work() runs the cleanup of its final put before its
\* next put, and the puts it owes come first
Runnable(it) == ~U_INLINE \/ it.owner # "U" \/ Quiet("U")

\* upstream: hlist_del(&m->mnt_umount); mntput(&m->mnt) for one stuck child;
\* NOREF: free_vacant_mount() of one dead stand-in the final put disowned
TwStuck(it) ==
    /\ it.step = "stuck" /\ Runnable(it)
    /\ IF mt[it.m].stuck = {}
       THEN Apply(Advance(St, it))
       ELSE \E c \in mt[it.m].stuck :
                IF NOREF THEN Apply(Free([St EXCEPT !.mt[it.m].stuck = @ \ {c}, !.hist.deadfrees = @ + 1], c))
                ELSE Apply(Put([St EXCEPT !.mt[it.m].stuck = @ \ {c}], c, "C", "C"))

\* fsnotify_vfsmount_delete(), dput(root), deactivate_super(sb): the mark
\* goes and its accounting is taken back from the superblock the connector
\* recorded (with the fix) or from the one the vfsmount points at now;
\* fsnotify_sb_delete() then waits for the superblock's watched objects to
\* reach zero, for good if they never do; the filesystem the mount carried
\* goes, and its file lets go of what it pinned; a walker that crossed into
\* the mount and is still inside in RCU mode sees the teardown
\* (NoRcuTeardown)
TwSb(it) ==
    /\ it.step = "sb" /\ Runnable(it)
    /\ LET m == it.m
           sb == Sb[m]
           acct == IF FIX_CONN_SB THEN mt[m].conn ELSE CurSb(mt, m)
           w1 == IF mt[m].mark THEN [watched EXCEPT ![acct] = @ - 1] ELSE watched
           inside == \E w \in Walkers : wtgt[w] = m /\ wpc[w] \in {"legit1", "legit2", "lock"}
           s0 == [St EXCEPT !.watched = w1, !.mt[m].mark = FALSE, !.mt[m].conn = ""]
       IN IF w1[sb] > 0
          THEN Apply([s0 EXCEPT !.tw = @ \ {it}, !.hist.hung = TRUE])
          ELSE Apply(Advance([s0 EXCEPT !.sbact[sb] = FALSE,
                                        !.pins = @ \cup (IF Pin[sb] # NoMnt THEN {Pin[sb]} ELSE {}),
                                        !.hist.releases[m] = @ + 1,
                                        !.hist.rcuteardown = @ \/ inside,
                                        !.hist.warn = @ \cup (IF sbact[sb] THEN {} ELSE {"double_release"})], it))

\* the final mnt_free_id() + call_rcu() of a doomed mount
TwFree(it) ==
    /\ it.step = "free" /\ Runnable(it)
    /\ Apply(Advance(Free(St, it.m), it))

\* vacant_mount_released(): under mount_locked_reader, mnt_old_root is
\* cleared and the mount is freed if its last put came first; with
\* RELEASE_PUTS the release's own mntput() instead; with the handoff
\* unlocked the read of MNT_DOOMED happens after the lock is dropped
TwHandoff(it) ==
    /\ it.step = "handoff" /\ Runnable(it)
    /\ LET m == it.m
           s1 == [St EXCEPT !.mt[m].oldroot = FALSE]
       IN IF RELEASE_PUTS THEN Apply(Advance(Put(s1, m, "R", "C"), it))
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

(* ---- U: namespace_unlock() and mntput_unmounted() ------------------------ *)

UGp == upc = "gp" /\ Apply([St EXCEPT !.ugp = rcu, !.upc = "wait"])
UWait == upc = "wait" /\ ugp = {} /\ Apply([St EXCEPT !.upc = "put"])
UPut ==
    /\ upc = "put" /\ Quiet("U")
    /\ U_INLINE => \A it \in tw : it.owner # "U"
    /\ HOLDER_ORDER = "early" => \A h \in RootHolders : hdone[h]
    /\ IF uhead = <<>> THEN Apply([St EXCEPT !.upc = "done"])
       ELSE Apply(Put([St EXCEPT !.uhead = Tail(uhead)], Head(uhead), "U", "U"))
Unlocker == UGp \/ UWait \/ UPut

(* ---- holders: a mark, then close the file ------------------------------- *)

\* fanotify_mark(FAN_MARK_MOUNT) through the holder's file, on its mount or
\* on the one below it: refused on a knullfs mount (SB_NOUSER), else the
\* connector records the superblock the vfsmount points at and that
\* superblock's watched objects go up
HMark(h) ==
    /\ Marks /\ ~hdone[h] /\ Quiet(h)
    /\ \E m \in {HolderMnt[h]} \cup Kids(mt, HolderMnt[h]) :
        /\ ~mt[m].mark /\ ~mt[m].freed
        /\ IF FIX_MARK_GATE /\ mt[m].vacant
           THEN ~hist.markrefused /\ Apply([St EXCEPT !.hist.markrefused = TRUE])
           ELSE LET sb == CurSb(mt, m)
                IN Apply([St EXCEPT !.mt[m].mark = TRUE, !.mt[m].conn = sb, !.watched[sb] = @ + 1,
                                    !.hist.nullmarks = @ + (IF sb = NullSb THEN 1 ELSE 0)])

HClose(h) ==
    /\ ~hdone[h] /\ Quiet(h)
    /\ HOLDER_ORDER = "late" /\ h \in RootHolders => upc = "done"
    /\ LET m == HolderMnt[h]
       IN Apply(Put([St EXCEPT !.hdone[h] = TRUE, !.ext[m] = @ - 1], m, "H", h))

(* ---- the pin drop: fput() of a released filesystem's file --------------- *)

PinPut(m) == m \in pins /\ Quiet("K") /\ Apply(Put([St EXCEPT !.pins = @ \ {m}], m, "K", "K"))

(* ---- walkers: an RCU walk from a holder's file into the mount below ----- *)

\* path_init(): rcu_read_lock(), nd->m_seq = read_seqbegin(&mount_lock),
\* the start is a holder's file on s (no reference of its own), the next
\* component is the mountpoint of t
WStart(w) ==
    /\ wpc[w] = "idle" /\ wn[w] < WalkBudget /\ Quiet(w)
    /\ \E s \in MntIds, t \in MntIds :
        /\ ext[s] > 0 /\ Parent[t] = s
        /\ Apply([St EXCEPT !.wpc[w] = "lookup", !.wsrc[w] = s, !.wtgt[w] = t, !.wseq[w] = seq,
                            !.wroot[w] = "", !.wres[w] = "", !.wn[w] = @ + 1, !.rcu = @ \cup {w}])

\* __d_lookup_rcu() of the mountpoint, then __follow_mount_rcu(): a hit
\* reads the mount's root (knullfs' for a vacant mount); a miss validated
\* by read_seqretry(m_seq) means the walk continues in the directory the
\* mount used to cover (the reveal); an unvalidated miss falls back to the
\* REF walk
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

\* __legitimize_mnt(): read_seqretry(m_seq) then mnt_inc_count()
WLegit1(w) ==
    /\ wpc[w] = "legit1"
    /\ IF seq # wseq[w]
       THEN Apply(RcuOut([St EXCEPT !.wpc[w] = "ref"], w))
       ELSE Apply([St EXCEPT !.mt[wtgt[w]].count = @ + 1, !.wpc[w] = "legit2",
                             !.mt[wtgt[w]].held = @ \/ (NOREF_MARK /\ mt[wtgt[w]].vacant)])

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
          ELSE Apply(RcuOut([St EXCEPT !.seq = @ + 1, !.wpc[w] = "put",
                                       !.mt[t].held = @ \/ (NOREF_MARK /\ mt[t].vacant)], w))

\* the mntput() after __legitimize_mnt() returned -1; the walk then restarts in REF mode
WPut(w) ==
    /\ wpc[w] = "put"
    /\ Apply(Put([St EXCEPT !.wpc[w] = "ref"], wtgt[w], "W", w))

\* the legitimized walk used the mount (on knullfs if it was vacated) and puts it
WUse(w) ==
    /\ wpc[w] = "use"
    /\ Apply(Put([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "into",
                            !.hist.nullseen = @ \/ mt[wtgt[w]].vacant], wtgt[w], "W", w))

\* the REF walk after -ECHILD: the file must still be open; the mountpoint
\* may be gone; lookup_mnt() finds the mount if it is hashed there and
\* spins for good if that mount is doomed (legitimize_mnt() never succeeds);
\* otherwise the walk lands in the covered directory
WRef(w) ==
    /\ wpc[w] = "ref" /\ Quiet(w)
    /\ LET s == wsrc[w]
           t == wtgt[w]
           found == mt[t].hashed /\ mt[t].parent = s
       IN IF ext[s] = 0 THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "ebadf"])
          ELSE IF mt[t].mpgone THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "enoent"])
          ELSE IF ~found THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "beneath"])
          ELSE IF mt[t].doomed THEN Apply([St EXCEPT !.wpc[w] = "idle", !.wres[w] = "hang"])
          ELSE Apply([St EXCEPT !.mt[t].count = @ + 1, !.seq = @ + 1, !.wpc[w] = "use",
                                !.mt[t].held = @ \/ (NOREF_MARK /\ mt[t].vacant),
                                !.wroot[w] = IF mt[t].vacant THEN "null" ELSE "fs"])

Walk(w) == WStart(w) \/ WLookup(w) \/ WLegit1(w) \/ WLegit2(w) \/ WLock(w) \/ WPut(w) \/ WUse(w) \/ WRef(w)

(* ---- D: rmdir of a mountpoint -> __detach_mounts() ---------------------- *)

\* under namespace_sem and mount_lock: the mount at the removed directory
\* (MNT_UMOUNT) is unhashed with umount_mnt(); a vacant one is cut loose on
\* `disowned` and namespace_unlock() puts the parent's reference right after
\* dropping namespace_sem, with no grace period.  Without FIX_DISOWNED it
\* rides the unmounted list instead: a grace period, then the put from
\* task work carried in the first mount's mnt_rcu, which clobbers the
\* release that mount still has pending in the same union.  The mutation
\* lists every unmounted mount, upstream lists every one since it owns none
DDetach ==
    /\ dpc = "idle" /\ Quiet("D")
    /\ \E t \in dtargets :
        /\ ~mt[t].mpgone /\ sbact[Sb[Parent[t]]]
        /\ LET attached == mt[t].hashed /\ mt[t].parent = Parent[t]
               listed == attached /\ (IF ~FIX_OWN_REF THEN TRUE
                                      ELSE IF NOREF THEN FALSE
                                      ELSE IF mt[t].vacant THEN FIX_DETACH_PUTS_VACANT
                                      ELSE DETACH_PUTS_ALL)
               direct == FIX_OWN_REF /\ FIX_DISOWNED
               lost == listed /\ ~direct /\ mt[t].vacant /\ \E it \in tw : it.m = t /\ it.kind = "release"
               s1 == [St EXCEPT !.mt[t].mpgone = TRUE, !.seq = @ + 1, !.dtargets = @ \ {t},
                                !.hist.detachputs = @ + (IF listed THEN 1 ELSE 0),
                                !.hist.lost = @ \/ lost,
                                !.tw = IF lost THEN {it \in @ : it.m # t} ELSE @]
               s2 == IF ~listed THEN s1
                     ELSE IF direct THEN [s1 EXCEPT !.vq["D"] = <<t>>]
                     ELSE [s1 EXCEPT !.dpc = "gp", !.dgp = rcu, !.dhead = <<t>>]
               \* NOREF: the stand-in is disowned under mount_lock and, dead
               \* with its release done, freed before namespace_sem is dropped
               cut == [s1.mt[t] EXCEPT !.hashed = FALSE, !.parent = NoMnt]
               s3 == [s1 EXCEPT !.mt[t] = IF mt[t].vacant THEN Disown(cut) ELSE cut]
               s4 == IF mt[t].vacant /\ Dead(mt[t]) /\ NOREF_DETACH_FREES
                     THEN Free([s3 EXCEPT !.hist.deadfrees = @ + 1], t) ELSE s3
           IN IF NOREF /\ attached THEN Apply(s4)
              ELSE Apply(IF attached THEN [s2 EXCEPT !.mt[t].hashed = FALSE, !.mt[t].parent = NoMnt] ELSE s2)
DGp == dpc = "gp" /\ dgp = {} /\ Apply([St EXCEPT !.dpc = "put"])
DPut ==
    /\ dpc = "put"
    /\ IF dhead = <<>> THEN Apply([St EXCEPT !.dpc = "idle"])
       ELSE Apply(Put([St EXCEPT !.dhead = Tail(dhead)], Head(dhead), "D", "D"))
Detach == DDetach \/ DGp \/ DPut

(* ---- the specification --------------------------------------------------- *)

Settled ==
    /\ upc = "done" /\ \A h \in Holders : hdone[h]
    /\ \A w \in Walkers : wpc[w] = "idle"
    /\ dpc = "idle" /\ tw = {} /\ pins = {} /\ pchk = {} /\ rchk = {}
    /\ \A t \in Tasks : Quiet(t)
    /\ \A m \in MntIds : mt[m].rcufree => mt[m].freed

Victims == IF FIX_OWN_REF THEN MntIds ELSE {m \in MntIds : Parent[m] = NoMnt}
Init ==
    /\ mt = [m \in MntIds |->
              [hashed |-> Parent[m] # NoMnt, parent |-> Parent[m],
               count |-> 1 + Ext0(m) + Pinned0(m),
               doomed |-> FALSE, vacant |-> FALSE, oldroot |-> FALSE, inst |-> "fs",
               stuck |-> {}, held |-> FALSE, freed |-> FALSE, rcufree |-> FALSE, mpgone |-> FALSE,
               mark |-> FALSE, conn |-> ""]]
    /\ sbact = [s \in SbIds |-> TRUE]
    /\ watched = [s \in WatchSbs |-> 0]
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
    /\ vq = [t \in Tasks |-> <<>>] /\ lchk = [t \in Tasks |-> NoMnt]
    /\ freewait = [m \in MntIds |-> {}]
    /\ hist = [vacates |-> 0, needless |-> 0, negative |-> FALSE, warn |-> {},
               frees |-> [m \in MntIds |-> 0], releases |-> [m \in MntIds |-> 0],
               vacby |-> {}, doomby |-> {}, putfirst |-> 0, relfirst |-> 0, detachputs |-> 0,
               rcuteardown |-> FALSE, hung |-> FALSE, lost |-> FALSE, markrefused |-> FALSE,
               nullmarks |-> 0, nullseen |-> FALSE, ownerputs |-> 0, hashedzero |-> 0, deadfrees |-> 0]

Next ==
    \/ Unlocker
    \/ \E h \in Holders : HMark(h) \/ HClose(h)
    \/ \E w \in Walkers : Walk(w)
    \/ Detach
    \/ TaskWork
    \/ \E t \in Tasks : VPut(t) \/ LCheck(t)
    \/ \E m \in MntIds : PinPut(m) \/ PutCheck(m) \/ ReleaseCheck(m) \/ RcuFree(m)
    \/ (Settled /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* ---- what is checked ----------------------------------------------------- *)

TypeOK ==
    /\ \A m \in MntIds : mt[m].count \in Int /\ mt[m].inst \in {"fs", "null", "none"}
                         /\ mt[m].stuck \subseteq MntIds /\ mt[m].parent \in MntIds \cup {NoMnt}
                         /\ mt[m].mark \in BOOLEAN /\ mt[m].conn \in WatchSbs \cup {""}
                         /\ mt[m].held \in BOOLEAN
    /\ \A s \in WatchSbs : watched[s] \in Int
    /\ upc \in {"gp", "wait", "put", "done"} /\ dpc \in {"idle", "gp", "put"}
    /\ \A w \in Walkers : wpc[w] \in {"idle", "lookup", "legit1", "legit2", "lock", "put", "use", "ref"}
                          /\ wres[w] \in {"", "into", "ebadf", "enoent", "beneath", "hang"}
    /\ \A it \in tw : it.m \in MntIds /\ it.kind \in {"cleanup", "release"}
                      /\ it.step \in {"stuck", "sb", "free", "handoff"} /\ it.owner \in Tasks
    /\ \A t \in Tasks : lchk[t] \in MntIds \cup {NoMnt} /\ \A i \in 1..Len(vq[t]) : vq[t][i] \in MntIds

\* the WARN_ON(count < 0) of mntput_slow()
NoNegative == ~hist.negative

\* none of the kernel's warnings and none of the model's sanity marks: a
\* vacant mount put while attached, freed with children, stuck children or
\* marks, on an instance list or hashed, freed twice, used after
\* call_rcu(), doomed while attached, a filesystem released twice, a put
\* at zero on a doomed mount, a free with the release still pending
NoWarn == hist.warn = {}

\* every mount is freed at most once and releases its filesystem at most once
ExactlyOnce == \A m \in MntIds : hist.frees[m] <= 1 /\ hist.releases[m] <= 1

\* nothing refers to a freed mount: not the hash, no instance list, no
\* parent pointer, no stuck list, no put list, no pin, no task work, no
\* owed put, no check, no mark, no holder, no walker that found it or
\* started from it and is still in RCU (a walker that only names its
\* mountpoint misses in the hash)
NoDangling ==
    \A m \in MntIds : mt[m].freed =>
        /\ ~mt[m].hashed /\ mt[m].inst = "none" /\ mt[m].stuck = {} /\ ext[m] = 0 /\ ~mt[m].mark
        /\ \A x \in MntIds : mt[x].parent # m /\ m \notin mt[x].stuck
        /\ ~InSeq(m, uhead) /\ ~InSeq(m, dhead) /\ m \notin pins /\ m \notin pchk /\ m \notin rchk
        /\ \A t \in Tasks : ~InSeq(m, vq[t]) /\ lchk[t] # m
        /\ \A it \in tw : it.m # m
        /\ \A w \in Walkers : /\ wpc[w] \in {"legit1", "legit2", "lock", "put", "use"} => wtgt[w] # m
                              /\ wpc[w] \in {"lookup", "legit1", "legit2", "lock"} => wsrc[w] # m

\* a hashed mount is referenced (its own reference, or the parent's once it
\* is vacant) and never doomed: what keeps the covered directory covered
HashedHasRef == \A m \in MntIds : (~mt[m].freed /\ mt[m].hashed) =>
    (~mt[m].doomed /\ (mt[m].count >= 1 \/ (NOREF /\ mt[m].vacant)))

\* the walkers' references: __legitimize_mnt()'s increment until the
\* walker's own decrement or mntput(), and the REF walk's lookup_mnt()
WRefs(m) == Cardinality({w \in Walkers : wtgt[w] = m /\ wpc[w] \in {"legit2", "lock", "put", "use"}})

\* MNT_DOOMED means the last reference is gone, but for a walker's
\* increment that its lock_mount_hash() path is about to take back
DoomedIsLast == \A m \in MntIds : mt[m].doomed =>
    mt[m].count = Cardinality({w \in Walkers : wtgt[w] = m /\ wpc[w] \in {"legit2", "lock"}})

\* the reference count rules of the series, mount by mount:
\*  - a mount whose own reference namespace_unlock() has not dropped yet
\*    holds it: it is neither vacant nor doomed, its count is at least one
\*  - a vacant mount is held by exactly one owner, its parent (the
\*    reference is in flight once the parent unhashed it, until the owed
\*    put), plus the walkers that legitimized it; the release holds none
\*    (the earlier design's release held one)
\*  - once it is doomed only walkers' transient increments remain (DoomedIsLast)
OwnRefOnRing == \A m \in MntIds : InSeq(m, uhead) =>
    ~mt[m].freed /\ ~mt[m].vacant /\ ~mt[m].doomed /\ mt[m].count >= 1
InFlight(m) == mt[m].hashed \/ (\E t \in Tasks : InSeq(m, vq[t])) \/ InSeq(m, dhead)
VacantCount == \A m \in MntIds : (mt[m].vacant /\ ~mt[m].doomed /\ ~mt[m].freed) =>
    mt[m].count = (IF NOREF THEN 0 ELSE IF InFlight(m) THEN 1 ELSE 0) + WRefs(m)
                  + (IF RELEASE_PUTS /\ mt[m].oldroot THEN 1 ELSE 0)

\* NOREF: a walk that holds a stand-in has marked it, so a parent that finds
\* no mark can free it without a sum
HeldCoversRefs == \A m \in MntIds : (NOREF /\ mt[m].vacant /\ ~mt[m].freed /\ WRefs(m) > 0) => mt[m].held

\* a vacant mount stands on knullfs' instance list until its last put, and
\* the release of what it carried is pending until its release visit ran
VacantOK == \A m \in MntIds : mt[m].vacant /\ ~mt[m].doomed =>
    mt[m].inst = (IF NOREF /\ ~mt[m].hashed THEN "none" ELSE "null")

\* knullfs: only vacant mounts stand on its instance list, a vacant mount
\* has no children (nothing can be mounted on it, its own were unhashed
\* before it was vacated), and it is never released (structural: it is no
\* element of SbIds, so no cleanup item can target it)
KnullfsOK == \A m \in MntIds : ~mt[m].freed =>
    /\ mt[m].inst = "null" => mt[m].vacant
    /\ mt[m].vacant => Kids(mt, m) = {}

\* a vacant mount never rides the unmounted list: its mnt_rcu may carry
\* its pending release, the list's first mount carries the task work there
NoVacantOnRing == \A m \in MntIds : mt[m].vacant => ~InSeq(m, uhead) /\ ~InSeq(m, dhead)

\* no walk ever lands in a directory a mount covered: the mount stays
\* hashed until nobody can reach its parent any more
NoReveal == \A w \in Walkers : wres[w] # "beneath"

\* lookup_mnt() never spins on a hashed doomed mount
NoHang == \A w \in Walkers : wres[w] # "hang"

\* fsnotify: no superblock's watched-objects count goes below zero, no
\* release waits in fsnotify_sb_delete() for a count that never drops,
\* and once everything settled every count is back at zero
NoNegativeWatch == \A s \in WatchSbs : watched[s] >= 0
NoTeardownHang == ~hist.hung
WatchedBalanced == Settled => \A s \in WatchSbs : watched[s] = 0

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
NoLostRelease == ~hist.lost
NoMarkRefused == ~hist.markrefused
NoNullMark == hist.nullmarks = 0
NoNullSeen == ~hist.nullseen
\* NOREF: nobody but a walk ever puts a stand-in (the parent frees it), a
\* walk's last put may leave a hashed stand-in at zero, and the parent or
\* __detach_mounts() do free dead stand-ins
NoOwnerPut == hist.ownerputs = 0
NoHashedZero == hist.hashedzero = 0
NoDeadFree == hist.deadfrees = 0
\* an RCU walker that crossed into a mount is still inside it (on its
\* dentries, before legitimizing) when the filesystem it carried is torn
\* down: the series through the release of a vacated mount, upstream
\* through the stuck children a parent's final put unhashes and puts with
\* no grace period in between; the RCU-pathwalk contract covers both
NoRcuTeardown == ~hist.rcuteardown
=============================================================================

------------------------------ MODULE MntPut ------------------------------
(***************************************************************************)
(* The reference counts of a batch of two mounts under concurrent lockless *)
(* use: __legitimize_mnt() and mntput_no_expire() against the unmount of   *)
(* both mounts in one write section and mntput_unmounted()'s peek          *)
(* (work.mount.gp_on_demand.proposal at 4379d47fd314, fs/namespace.c).     *)
(*                                                                         *)
(* Two mounts A and B, unmounted together.  Tasks:                         *)
(*   U        the umounter.  MODE "umount": do_umount() of A (sync, or     *)
(*            MNT_DETACH when LAZY) whose umount_tree() takes B along, the *)
(*            caller's reference dropped in the write section, then        *)
(*            namespace_unlock() -> mntput_unmounted().  MODE "nsdeath":   *)
(*            put_mnt_ns(): the same write section without a caller's      *)
(*            reference and without MNT_SYNC_UMOUNT.  MODE "kern":         *)
(*            kern_unmount_array(): mnt_make_shortterm() stores mnt_ns =   *)
(*            NULL with no lock and no seqcount bump, then                  *)
(*            mntput_unmounted().                                          *)
(*   Walkers  RCU path walkers, one per mount: read_seqbegin(mount_lock),  *)
(*            __lookup_mnt(), __legitimize_mnt(), use the mount, mntput()  *)
(*   Holders  tasks holding a reference on one mount from the start (an    *)
(*            open file): mntget()/mntput() pairs, migration, the final    *)
(*            mntput() -- on the fast path or past the batch               *)
(*                                                                         *)
(* mntput_unmounted() (L1534): one lock_mount_hash(), one smp_mb(), then   *)
(* for every mount of the batch in list order mntput_unheld() (L1518):     *)
(* mnt_get_count() == 1 means the mount's own reference is the only one    *)
(* left, so it is dropped and the mount finished right there (MNT_DOOMED,  *)
(* mntput_final_locked()), wherever it sits in the batch; any other count  *)
(* moves the mount to the held list.  unlock_mount_hash(), the cleanups of *)
(* the finished mounts are queued (cleanup_mnt() -> call_rcu()), and if    *)
(* the held list is not empty ONE synchronize_rcu_expedited() and a plain  *)
(* mntput() for each held mount (the slow path: lock, smp_mb(), decrement, *)
(* sum, MNT_DOOMED test).                                                  *)
(*                                                                         *)
(* Why one is the mount's own reference: a holder's get is visible before  *)
(* its put (split per-CPU counters summed puts first, the smp_wmb() of     *)
(* mntput_no_expire() pairing with the smp_mb() of mnt_get_count()); a     *)
(* walker's increment is either visible to the sum or the walker sees the  *)
(* seqcount change (the Dekker pairing of the smp_mb() in __legitimize_mnt *)
(* with the one in mntput_unmounted()) and drops it under mount_lock where *)
(* it finds MNT_DOOMED; and the mount left its namespace, so no new walker *)
(* finds it.                                                               *)
(*                                                                         *)
(* Memory model as in kernel/mount/MntPut.tla: TSO store buffers, store    *)
(* forwarding, smp_mb() and the RMW of spin_lock() drain, a grace period   *)
(* drains every buffer; WEAK_STORES lets a CPU's stores to different words *)
(* retire out of order unless an smp_wmb() sits between them.  Per-CPU    *)
(* gets and puts of each mount; FIX_SPLIT_COUNT off is the single counter. *)
(*                                                                         *)
(* Mutations: PREV_SHAPE is the shape before 4379d47fd314's last patch    *)
(* (d5546255be07 in the branch's reflog): mntput_unheld() takes mount_lock *)
(* per mount, and from the first held mount on the rest gets one grace     *)
(* period and plain mntput()s.  PEEK_LOOSE finishes a mount at a count of  *)
(* two as well.  QUEUE_LATE queues the cleanups after the grace period and *)
(* the held puts (the task-work timing of a user task).  FIX_MB_PEEK off   *)
(* drops the smp_mb() of mntput_unmounted().  FIX_RCU_DELAY off drops the  *)
(* grace period for the held mounts.  FIX_PUT_RECHECK (exploratory, not in *)
(* the series) makes the fast path of mntput_no_expire() re-read mnt_ns    *)
(* after its decrement behind a full barrier and take a look under         *)
(* mount_lock when it reads NULL; it is meant to be run without the grace  *)
(* period.                                                                 *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets

CONSTANTS
    TaskList,        \* the tasks, as a sequence: the umounter "U" first
    Walkers,         \* the walker tasks
    Holders,         \* the holder tasks
    TaskMount,       \* [Walkers \cup Holders -> Mounts]: the mount a task walks or holds
    BatchOrder,      \* the batch as mntput_unmounted() walks it: <<"A", "B">> or <<"B", "A">>
    NCPU,            \* CPUs 1..NCPU; mnt_get_count() reads them in order
    GetBudget,       \* mntget()/mntput() pairs a holder may do
    MIGRATE,         \* holders may migrate between CPUs
    MigBudget,       \* how often a holder may migrate
    MODE,            \* "umount", "nsdeath" or "kern", see above
    LAZY,            \* umount2(MNT_DETACH) instead of a synchronous umount (MODE "umount")
    FIX_MB_LEGIT,    \* smp_mb() in __legitimize_mnt()
    FIX_MB_UMOUNT,   \* smp_mb() in do_umount() before the refcount checks
    FIX_MB_PUT,      \* smp_mb() in mntput_no_expire_slowpath()
    FIX_MB_PEEK,     \* smp_mb() in mntput_unmounted() after lock_mount_hash()
    FIX_RCU_DELAY,   \* synchronize_rcu_expedited() before the puts of the held mounts
    FIX_PUT_RCU,     \* rcu_read_lock() around the mnt_ns test in mntput_no_expire()
    FIX_SYNC_FLAG,   \* __legitimize_mnt() fails on MNT_SYNC_UMOUNT
    FIX_DOOMED_FLAG, \* __legitimize_mnt() fails on MNT_DOOMED
    FIX_SPLIT_COUNT, \* gets and puts in separate counters, puts summed first
    SPLIT_GETS_FIRST, \* mutation: the split sum reads the gets first
    WEAK_STORES,     \* stores of one CPU may become visible out of order
    FIX_PUT_WMB,     \* smp_wmb() before the increment of the puts in mntput_no_expire()
    PEEK_LOOSE,      \* mutation: mntput_unheld() finishes a mount off at two as well
    PREV_SHAPE,      \* mutation: the shape of d5546255be07, one lock hold per mount
    QUEUE_LATE,      \* mutation: the cleanups are queued after the grace period and the held puts
    FIX_PUT_RECHECK  \* exploratory: the fast path re-reads mnt_ns after its decrement

U == "U"
Mounts == {"A", "B"}
Root == "A"                 \* the mount umount(2) is called on: it carries the caller's reference
NoMnt == "none"
Tasks == {TaskList[i] : i \in 1..Len(TaskList)}
Others == Tasks \ {U}
NoTask == "none"
CPUs == 1..NCPU
NB == Len(BatchOrder)
Rev == [i \in 1..NB |-> BatchOrder[NB + 1 - i]]   \* umount_tree()'s order: hlist_add_head() reverses it
Pos(x) == CHOOSE i \in 1..NB : BatchOrder[i] = x
Sync == MODE = "umount" /\ ~LAZY
Umount2 == MODE = "umount"
MountOf(t) == IF t = U THEN Root ELSE TaskMount[t]
TasksOf(x) == {t \in Others : TaskMount[t] = x}
HoldersOf(x) == {h \in Holders : TaskMount[h] = x}
Allow(x) == IF x = Root THEN 2 ELSE 1     \* propagate_mount_busy(mnt, 2): the root may have the caller's reference

ASSUME /\ U \in Tasks /\ Walkers \subseteq Others /\ Holders \subseteq Others
       /\ Walkers \cap Holders = {} /\ Walkers \cup Holders = Others
       /\ MODE \in {"umount", "nsdeath", "kern"}
       /\ MODE = "kern" => Walkers = {}   \* a kern_mount() is never in a namespace: no RCU walker finds it
       /\ NB = Cardinality(Mounts) /\ {BatchOrder[i] : i \in 1..NB} = Mounts

VARIABLES
    seqv,     \* mount_lock's seqcount as the other CPUs see it
    cntv,     \* [Mounts -> [CPUs -> Int]]: mnt_gets - mnt_puts per CPU as the other CPUs see it
    putv,     \* [Mounts -> [CPUs -> Nat]]: mnt_puts per CPU as the other CPUs see it
    lockv,    \* mount_lock's spinlock as the other CPUs see it: holder or NoTask
    m,        \* [Mounts -> record]: hashed, ns (mnt_ns != NULL), umount, sync, doomed, freed
    buf,      \* [Tasks -> Seq(store)]: the store buffer of the task's CPU
    cpu,      \* [Tasks -> CPUs]
    rcu,      \* [Tasks -> BOOLEAN]: inside rcu_read_lock()
    gp,       \* U's synchronize_rcu_expedited(): [on, wait] -- the readers it waits for
    gpfree,   \* [Mounts -> [on, wait]]: call_rcu(delayed_free_vfsmnt) of each mount
    pc,       \* [Tasks -> label]
    ret,      \* [Tasks -> label]: where mntput() returns to
    sq,       \* [Tasks -> Nat]: a walker's read_seqbegin() sample
    acc,      \* [Tasks -> Int]: mnt_get_count()'s running sum
    ci,       \* [Tasks -> Nat]: mnt_get_count()'s next read
    refs,     \* [Tasks -> Nat]: references the task holds on its mount (U: on Root), the ledger
    own,      \* [Mounts -> BOOLEAN]: the mount's own reference has not been dropped yet
    um,       \* the mount U is summing or putting, or NoMnt
    ownput,   \* U is dropping the own reference of um (else the caller's)
    gets,     \* [Tasks -> Nat]: mntget() calls a holder has made
    migs,     \* [Tasks -> Nat]: migrations a holder has made
    cleaner,  \* [Mounts -> Tasks \cup {NoTask}]: the task that ran cleanup_mnt()
    uresult,  \* "", "ok" or "busy"
    bi,       \* U's index into BatchOrder
    head,     \* the mounts still on U's list `head` (unmounted, not yet queued or moved)
    held,     \* the mounts on U's list `held`
    fin,      \* the mounts the peek finished whose cleanup is not queued yet
    synced    \* PREV_SHAPE: the grace period has been waited for

vars == <<seqv, cntv, putv, lockv, m, buf, cpu, rcu, gp, gpfree, pc, ret, sq, acc, ci,
          refs, own, um, ownput, gets, migs, cleaner, uresult, bi, head, held, fin, synced>>
uvars == <<um, ownput, bi, head, held, fin, synced, uresult>>

(* ---- the store buffers ------------------------------------------------- *)

\* a store: seq := v, cnt[x][c] += d, hashed[x] := v, ns[x] := v, lock := v;
\* a wmb entry is smp_wmb(): the stores behind it wait for the ones before
StWmb          == [f |-> "wmb"]
Wmb(on)        == IF on THEN <<StWmb>> ELSE <<>>
StSeq(v)       == [f |-> "seq", v |-> v]
StCnt(x, c, d) == [f |-> "cnt", x |-> x, c |-> c, d |-> d]
StHash(x, v)   == [f |-> "hashed", x |-> x, v |-> v]
StNs(x, v)     == [f |-> "ns", x |-> x, v |-> v]
StLock(v)      == [f |-> "lock", v |-> v]

\* the visible state as a record, so that stores can be applied in order
Vis == [seqv |-> seqv, cntv |-> cntv, putv |-> putv, lockv |-> lockv, m |-> m]
Apply(s, e) ==
    CASE e.f = "seq"    -> [s EXCEPT !.seqv = e.v]
      [] e.f = "cnt"    -> [s EXCEPT !.cntv[e.x][e.c] = @ + e.d,
                                     !.putv[e.x][e.c] = @ + (IF e.d < 0 THEN 1 ELSE 0)]
      [] e.f = "hashed" -> [s EXCEPT !.m[e.x].hashed = e.v]
      [] e.f = "ns"     -> [s EXCEPT !.m[e.x].ns = e.v]
      [] e.f = "lock"   -> [s EXCEPT !.lockv = e.v]
      [] e.f = "wmb"    -> s
RECURSIVE ApplyAll(_, _)
ApplyAll(s, es) == IF es = <<>> THEN s ELSE ApplyAll(Apply(s, Head(es)), Tail(es))

RECURSIVE SumD(_)
SumD(s) == IF s = <<>> THEN 0 ELSE Head(s) + SumD(Tail(s))
IsCnt(e, x, c) == e.f = "cnt" /\ e.x = x /\ e.c = c
\* the task's own buffered increments of one counter (store forwarding)
Buffered(t, x, c) == SumD([i \in 1..Len(buf[t]) |-> IF IsCnt(buf[t][i], x, c) THEN buf[t][i].d ELSE 0])
\* what a load of cnt[x][c] by t returns
SeenCnt(t, x, c) == cntv[x][c] + Buffered(t, x, c)
\* the split counters: what a load of puts[c] or gets[c] of x by t returns
BufferedPuts(t, x, c) == SumD([i \in 1..Len(buf[t]) |->
                               IF IsCnt(buf[t][i], x, c) /\ buf[t][i].d < 0 THEN 1 ELSE 0])
BufferedGets(t, x, c) == SumD([i \in 1..Len(buf[t]) |->
                               IF IsCnt(buf[t][i], x, c) /\ buf[t][i].d > 0 THEN 1 ELSE 0])
SeenPuts(t, x, c) == putv[x][c] + BufferedPuts(t, x, c)
SeenGets(t, x, c) == cntv[x][c] + putv[x][c] + BufferedGets(t, x, c)
\* the count of x as it will be once every buffer has drained
Total(x) == SumD([c \in 1..NCPU |-> cntv[x][c]])
            + SumD([i \in 1..Len(TaskList) |->
                    SumD([c \in 1..NCPU |-> Buffered(TaskList[i], x, c)])])

Push(t, e) == buf' = [buf EXCEPT ![t] = Append(@, e)]
PushAll(t, es) == buf' = [buf EXCEPT ![t] = @ \o es]
Empty(t) == buf[t] = <<>>

\* everything t has stored becomes visible: after a full barrier, an
\* atomic RMW, a migration, or the end of a grace period that waited for t
Drained(t, extra) ==
    LET r == ApplyAll(Vis, buf[t] \o extra)
    IN /\ seqv' = r.seqv /\ cntv' = r.cntv /\ putv' = r.putv /\ lockv' = r.lockv /\ m' = r.m
       /\ buf' = [buf EXCEPT ![t] = <<>>]
Unchanged_vis == UNCHANGED <<seqv, cntv, putv, lockv, m>>

\* a grace period is a full memory barrier on every CPU: everything any
\* task has stored before it starts is visible when it ends
RECURSIVE ApplyTasks(_, _)
ApplyTasks(s, i) == IF i > Len(TaskList) THEN s ELSE ApplyTasks(ApplyAll(s, buf[TaskList[i]]), i + 1)
DrainedAll ==
    LET r == ApplyTasks(Vis, 1)
    IN /\ seqv' = r.seqv /\ cntv' = r.cntv /\ putv' = r.putv /\ lockv' = r.lockv /\ m' = r.m
       /\ buf' = [t \in Tasks |-> <<>>]

(* ---- RCU --------------------------------------------------------------- *)

\* rcu_read_unlock(): the grace periods waiting for t stop waiting; the
\* RCU guarantee makes t's stores visible to whoever waited
RcuOut(t) ==
    /\ rcu' = [rcu EXCEPT ![t] = FALSE]
    /\ gp' = [gp EXCEPT !.wait = @ \ {t}]
    /\ gpfree' = [x \in Mounts |-> [gpfree[x] EXCEPT !.wait = @ \ {t}]]
Waited(t) == t \in gp.wait \/ \E x \in Mounts : t \in gpfree[x].wait
Readers == {t \in Tasks : rcu[t]}

(* ---- mount_lock -------------------------------------------------------- *)

\* lock_mount_hash() = write_seqlock(): the atomic RMW of spin_lock()
\* drains the buffer; the seqcount increment is a plain store
Lock(t) ==
    /\ lockv = NoTask /\ Empty(t)
    /\ lockv' = t
    /\ PushAll(t, <<StSeq(seqv + 1), StWmb>>)
    /\ UNCHANGED <<seqv, cntv, putv, m>>
\* the seqcount as t sees it: its own increment may still sit in its buffer
SeenSeq(t) == LET ss == SelectSeq(buf[t], LAMBDA e : e.f = "seq")
              IN IF ss = <<>> THEN seqv ELSE ss[Len(ss)].v
\* unlock_mount_hash() = write_sequnlock(): two plain stores
UnlockStores(t) == <<StWmb, StSeq(SeenSeq(t) + 1), StWmb, StLock(NoTask)>>

(* ---- the labels -------------------------------------------------------- *)

PutLabels == {"p_enter", "p_fast", "p_recheck", "p_look_lock", "p_look_mb", "p_look_sum", "p_look_check",
              "p_lock", "p_mb", "p_dec", "p_sum", "p_check", "p_cleanup"}
WalkLabels == {"w_start", "w_lookup", "w_l1", "w_l2", "w_mb", "w_l4", "w_lock", "w_flags", "w_use"}
ULabels == {"u_lock", "u_mb", "u_sum", "u_busy", "u_tree", "u_caller_drop", "u_unlock", "u_nsunlock",
            "k_shortterm", "u_peek", "u_peek_mb", "u_peek_sum", "u_peek_check", "u_peek_unlock",
            "u_queue", "u_gp", "u_gpwait", "u_held_next",
            "v_next", "v_lock", "v_mb", "v_sum", "v_check", "v_queue", "v_gp", "v_gpwait", "v_adv"}
Done == {"done", "lost", "w_none"}
Labels == PutLabels \cup WalkLabels \cup ULabels \cup Done \cup {"h_idle"}
\* the labels at which a walker or holder reads or writes its mount
\* (__lookup_mnt() only walks the hash, which the mount left before it could be freed)
Touching == PutLabels \cup {"w_l1", "w_l2", "w_mb", "w_l4", "w_lock", "w_flags", "w_use"}
\* the labels at which U reads or writes the mount `um` in particular
UMountLabels == PutLabels \cup {"u_sum", "u_busy", "u_peek_sum", "u_peek_check",
                                "v_lock", "v_mb", "v_sum", "v_check", "v_queue", "v_gp", "v_gpwait"}

\* the mount t is putting: U puts `um`, everybody else its own mount
Mnt(t) == IF t = U THEN um ELSE TaskMount[t]

(* ---- init -------------------------------------------------------------- *)

HolderCpu == IF NCPU >= 2 THEN 2 ELSE 1
Init ==
    /\ seqv = 0
    \* each mount's own reference and the caller's on CPU 1, the holders' on CPU 2
    /\ cntv = [x \in Mounts |-> [c \in CPUs |->
                 (IF c = 1 THEN 1 + (IF x = Root /\ Umount2 THEN 1 ELSE 0) ELSE 0)
                 + (IF c = HolderCpu THEN Cardinality(HoldersOf(x)) ELSE 0)]]
    /\ putv = [x \in Mounts |-> [c \in CPUs |-> 0]]
    /\ lockv = NoTask
    /\ m = [x \in Mounts |-> [hashed |-> MODE # "kern", ns |-> TRUE, umount |-> FALSE, sync |-> FALSE,
                              doomed |-> FALSE, freed |-> FALSE]]
    /\ buf = [t \in Tasks |-> <<>>]
    /\ cpu = [t \in Tasks |-> IF t \in Holders THEN HolderCpu ELSE 1]
    /\ rcu = [t \in Tasks |-> FALSE]
    /\ gp = [on |-> FALSE, wait |-> {}]
    /\ gpfree = [x \in Mounts |-> [on |-> FALSE, wait |-> {}]]
    /\ pc = [t \in Tasks |-> IF t = U THEN (IF MODE = "kern" THEN "k_shortterm" ELSE "u_lock")
                             ELSE IF t \in Walkers THEN "w_start" ELSE "h_idle"]
    /\ ret = [t \in Tasks |-> "done"]
    /\ sq = [t \in Tasks |-> 0]
    /\ acc = [t \in Tasks |-> 0]
    /\ ci = [t \in Tasks |-> 1]
    /\ refs = [t \in Tasks |-> IF (t = U /\ Umount2) \/ t \in Holders THEN 1 ELSE 0]
    /\ own = [x \in Mounts |-> TRUE]
    /\ um = NoMnt
    /\ ownput = FALSE
    /\ gets = [t \in Tasks |-> 0]
    /\ migs = [t \in Tasks |-> 0]
    /\ cleaner = [x \in Mounts |-> NoTask]
    /\ uresult = ""
    /\ bi = 1
    /\ head = Mounts
    /\ held = {}
    /\ fin = {}
    /\ synced = FALSE

(* ---- the memory system ------------------------------------------------- *)

\* one store leaves a buffer: the oldest one, or with WEAK_STORES any one
\* that no wmb entry and no older store to the same word precede (stores
\* to one location stay in program order on every architecture); a wmb
\* entry itself retires once it is the oldest.  With the split counters
\* the gets and the puts of a CPU are two words, with the single counter one.
Remove(s, i) == [j \in 1..(Len(s) - 1) |-> IF j < i THEN s[j] ELSE s[j + 1]]
Loc(e) == IF e.f = "cnt"
          THEN (IF FIX_SPLIT_COUNT THEN <<"cnt", e.x, e.c, e.d > 0>> ELSE <<"cnt", e.x, e.c>>)
          ELSE IF e.f \in {"hashed", "ns"} THEN <<e.f, e.x>> ELSE <<e.f>>
Flushable(t) == IF WEAK_STORES
                THEN {i \in 1..Len(buf[t]) :
                        /\ \A j \in 1..(i - 1) : buf[t][j].f # "wmb" /\ Loc(buf[t][j]) # Loc(buf[t][i])
                        /\ (buf[t][i].f = "wmb" => i = 1)}
                ELSE {1}
Flush(t) ==
    /\ ~Empty(t)
    /\ \E i \in Flushable(t) :
        /\ LET r == Apply(Vis, buf[t][i])
           IN seqv' = r.seqv /\ cntv' = r.cntv /\ putv' = r.putv /\ lockv' = r.lockv /\ m' = r.m
        /\ buf' = [buf EXCEPT ![t] = Remove(@, i)]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, pc, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* delayed_free_vfsmnt(): the RCU callback of x runs after its grace period
RcuFree(x) ==
    /\ gpfree[x].on /\ gpfree[x].wait = {}
    /\ gpfree' = [gpfree EXCEPT ![x] = [on |-> FALSE, wait |-> {}]]
    /\ m' = [m EXCEPT ![x].freed = TRUE]
    /\ UNCHANGED <<seqv, cntv, putv, lockv, buf, cpu, rcu, gp, pc, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

(* ---- mntput() ---------------------------------------------------------- *)
(* entered at "p_enter" with ret[t] set; the ledger entry it drops is the   *)
(* own reference of um when U runs with ownput, else one of t's own         *)

DropRef(t) ==
    IF t = U /\ ownput THEN own' = [own EXCEPT ![um] = FALSE] /\ UNCHANGED refs
    ELSE refs' = [refs EXCEPT ![t] = @ - 1] /\ UNCHANGED own

\* mntput_no_expire() L1484: rcu_read_lock(), READ_ONCE(mnt->mnt_ns)
PutEnter(t) ==
    /\ pc[t] = "p_enter"
    /\ rcu' = [rcu EXCEPT ![t] = FIX_PUT_RCU]
    /\ pc' = [pc EXCEPT ![t] = IF m[Mnt(t)].ns THEN "p_fast" ELSE "p_lock"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* the fast path L1499: smp_wmb(), mnt_dec_count() with nothing held but RCU;
\* with FIX_PUT_RECHECK the task stays in RCU and re-reads mnt_ns
PutFast(t) ==
    /\ pc[t] = "p_fast"
    /\ IF FIX_PUT_RECHECK
       THEN /\ PushAll(t, Wmb(FIX_PUT_WMB) \o <<StCnt(Mnt(t), cpu[t], -1)>>) /\ Unchanged_vis
            /\ UNCHANGED <<rcu, gp, gpfree>>
            /\ pc' = [pc EXCEPT ![t] = "p_recheck"]
       ELSE /\ IF Waited(t) THEN Drained(t, Wmb(FIX_PUT_WMB) \o <<StCnt(Mnt(t), cpu[t], -1)>>)
               ELSE PushAll(t, Wmb(FIX_PUT_WMB) \o <<StCnt(Mnt(t), cpu[t], -1)>>) /\ Unchanged_vis
            /\ RcuOut(t)
            /\ pc' = [pc EXCEPT ![t] = ret[t]]
    /\ DropRef(t)
    /\ UNCHANGED <<cpu, ret, sq, acc, ci, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* exploratory: smp_mb(), then READ_ONCE(mnt->mnt_ns) again; NULL means the
\* unmount may have summed without our decrement: look under mount_lock
PutRecheck(t) ==
    /\ pc[t] = "p_recheck"
    /\ Empty(t)
    /\ IF m[Mnt(t)].ns
       THEN RcuOut(t) /\ pc' = [pc EXCEPT ![t] = ret[t]]
       ELSE UNCHANGED <<rcu, gp, gpfree>> /\ pc' = [pc EXCEPT ![t] = "p_look_lock"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

PutLookLock(t) ==
    /\ pc[t] = "p_look_lock"
    /\ Lock(t)
    /\ pc' = [pc EXCEPT ![t] = "p_look_mb"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

PutLookMb(t) ==
    /\ pc[t] = "p_look_mb"
    /\ FIX_MB_PUT => Empty(t)
    /\ acc' = [acc EXCEPT ![t] = 0]
    /\ ci' = [ci EXCEPT ![t] = 1]
    /\ pc' = [pc EXCEPT ![t] = "p_look_sum"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* mntput_no_expire_slowpath() L1458: lock_mount_hash()
PutLock(t) ==
    /\ pc[t] = "p_lock"
    /\ Lock(t)
    /\ pc' = [pc EXCEPT ![t] = "p_mb"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L1463 smp_mb(): "if __legitimize_mnt() has not seen us grab mount_lock,
\* we'll see their refcount increment here"
PutMb(t) ==
    /\ pc[t] = "p_mb"
    /\ FIX_MB_PUT => Empty(t)
    /\ pc' = [pc EXCEPT ![t] = "p_dec"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L1464 mnt_dec_count(), then mnt_get_count() starts
PutDec(t) ==
    /\ pc[t] = "p_dec"
    /\ PushAll(t, <<StCnt(Mnt(t), cpu[t], -1)>>)
    /\ DropRef(t)
    /\ acc' = [acc EXCEPT ![t] = 0]
    /\ ci' = [ci EXCEPT ![t] = 1]
    /\ pc' = [pc EXCEPT ![t] = "p_sum"]
    /\ Unchanged_vis
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* mnt_get_count() L291: one read per step; with FIX_SPLIT_COUNT two passes,
\* the puts of every CPU first and the gets second (SPLIT_GETS_FIRST: the
\* other way round)
Reads == IF FIX_SPLIT_COUNT THEN 2 * NCPU ELSE NCPU
ReadCnt(t, x, i) ==
    IF ~FIX_SPLIT_COUNT THEN SeenCnt(t, x, i)
    ELSE LET c == IF i <= NCPU THEN i ELSE i - NCPU
             putsPass == (i <= NCPU) # SPLIT_GETS_FIRST
         IN IF putsPass THEN -SeenPuts(t, x, c) ELSE SeenGets(t, x, c)
SumStep(t, next) ==
    /\ IF ci[t] <= Reads
       THEN /\ acc' = [acc EXCEPT ![t] = @ + ReadCnt(t, Mnt(t), ci[t])]
            /\ ci' = [ci EXCEPT ![t] = @ + 1]
            /\ UNCHANGED pc
       ELSE /\ pc' = [pc EXCEPT ![t] = next]
            /\ UNCHANGED <<acc, ci>>
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

PutSum(t) == pc[t] = "p_sum" /\ SumStep(t, "p_check")
PutLookSum(t) == pc[t] = "p_look_sum" /\ SumStep(t, "p_look_check")

\* L1466: count != 0 means not the last reference; MNT_DOOMED already (L1472)
\* means somebody else's job; else mntput_final_locked() (MNT_DOOMED), unlock,
\* mntput_queue_cleanup()
FinalOrLeave(t, next) ==
    IF acc[t] # 0 \/ m[Mnt(t)].doomed
    THEN /\ Drained(t, UnlockStores(t))
         /\ pc' = [pc EXCEPT ![t] = ret[t]]
    ELSE LET r == ApplyAll(Vis, buf[t] \o UnlockStores(t))
         IN /\ seqv' = r.seqv /\ cntv' = r.cntv /\ putv' = r.putv /\ lockv' = r.lockv
            /\ m' = [r.m EXCEPT ![Mnt(t)].doomed = TRUE]
            /\ buf' = [buf EXCEPT ![t] = <<>>]
            /\ pc' = [pc EXCEPT ![t] = next]
PutCheck(t) ==
    /\ pc[t] = "p_check"
    /\ FinalOrLeave(t, "p_cleanup")
    /\ RcuOut(t)
    /\ UNCHANGED <<cpu, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars
\* the exploratory look: the same without a decrement of its own
PutLookCheck(t) ==
    /\ pc[t] = "p_look_check"
    /\ FinalOrLeave(t, "p_cleanup")
    /\ RcuOut(t)
    /\ UNCHANGED <<cpu, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* cleanup_mnt() L1378: call_rcu(&mnt->mnt_rcu, delayed_free_vfsmnt) (L1394)
PutCleanup(t) ==
    /\ pc[t] = "p_cleanup"
    /\ gpfree' = [gpfree EXCEPT ![Mnt(t)] = [on |-> TRUE, wait |-> Readers]]
    /\ cleaner' = [cleaner EXCEPT ![Mnt(t)] = t]
    /\ pc' = [pc EXCEPT ![t] = ret[t]]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, ret, sq, acc, ci, refs, own, gets, migs>>
    /\ UNCHANGED uvars

Put(t) == PutEnter(t) \/ PutFast(t) \/ PutRecheck(t) \/ PutLookLock(t) \/ PutLookMb(t) \/ PutLookSum(t)
          \/ PutLookCheck(t) \/ PutLock(t) \/ PutMb(t) \/ PutDec(t) \/ PutSum(t) \/ PutCheck(t) \/ PutCleanup(t)

(* ---- the walker: __follow_mount_rcu() + __legitimize_mnt() L776 --------- *)

\* path_init(): rcu_read_lock(), nd->m_seq = read_seqbegin(&mount_lock)
\* (read_seqbegin() spins while the count is odd)
WStart(t) ==
    /\ pc[t] = "w_start"
    /\ seqv % 2 = 0
    /\ rcu' = [rcu EXCEPT ![t] = TRUE]
    /\ sq' = [sq EXCEPT ![t] = seqv]
    /\ pc' = [pc EXCEPT ![t] = "w_lookup"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, gp, gpfree, ret, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* the walker reaches its mount by __lookup_mnt() (the hash is read
\* locklessly) or as the fs->pwd of a task sharing its fs_struct, read under
\* fs->seq with no reference of its own; that task may chdir() away and
\* drop the reference at any time (its chdir() is HPut)
ViaPwd(x) == \E h \in HoldersOf(x) : refs[h] > 0 /\ pc[h] = "h_idle"
WLookup(t) ==
    /\ pc[t] = "w_lookup"
    /\ IF m[TaskMount[t]].hashed \/ ViaPwd(TaskMount[t])
       THEN pc' = [pc EXCEPT ![t] = "w_l1"] /\ UNCHANGED <<rcu, gp, gpfree>>
       ELSE pc' = [pc EXCEPT ![t] = "w_none"] /\ RcuOut(t)
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L779: if (read_seqretry(&mount_lock, seq)) return 1
WL1(t) ==
    /\ pc[t] = "w_l1"
    /\ IF seqv # sq[t]
       THEN pc' = [pc EXCEPT ![t] = "lost"] /\ RcuOut(t)
       ELSE pc' = [pc EXCEPT ![t] = "w_l2"] /\ UNCHANGED <<rcu, gp, gpfree>>
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L784: mnt_inc_count(mnt)
WL2(t) ==
    /\ pc[t] = "w_l2"
    /\ Push(t, StCnt(TaskMount[t], cpu[t], 1))
    /\ refs' = [refs EXCEPT ![t] = @ + 1]
    /\ pc' = [pc EXCEPT ![t] = "w_mb"]
    /\ Unchanged_vis
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L785: smp_mb(); /* see mntput_no_expire_slowpath(), mntput_unheld() and do_umount() */
WMb(t) ==
    /\ pc[t] = "w_mb"
    /\ FIX_MB_LEGIT => Empty(t)
    /\ pc' = [pc EXCEPT ![t] = "w_l4"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L786: if (likely(!read_seqretry(&mount_lock, seq))) return 0
WL4(t) ==
    /\ pc[t] = "w_l4"
    /\ pc' = [pc EXCEPT ![t] = IF seqv = sq[t] THEN "w_use" ELSE "w_lock"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L788: lock_mount_hash()
WLock(t) ==
    /\ pc[t] = "w_lock"
    /\ Lock(t)
    /\ pc' = [pc EXCEPT ![t] = "w_flags"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L789: MNT_SYNC_UMOUNT | MNT_DOOMED: drop the count under the lock, return 1;
\* else unlock and return -1: the caller will mntput() (L795)
WFlags(t) ==
    /\ pc[t] = "w_flags"
    /\ IF (FIX_SYNC_FLAG /\ m[TaskMount[t]].sync) \/ (FIX_DOOMED_FLAG /\ m[TaskMount[t]].doomed)
       THEN /\ Drained(t, <<StCnt(TaskMount[t], cpu[t], -1)>> \o UnlockStores(t))
            /\ refs' = [refs EXCEPT ![t] = @ - 1]
            /\ pc' = [pc EXCEPT ![t] = "lost"]
            /\ UNCHANGED ret
       ELSE /\ Drained(t, UnlockStores(t))
            /\ ret' = [ret EXCEPT ![t] = "lost"]
            /\ pc' = [pc EXCEPT ![t] = "p_enter"]
            /\ UNCHANGED refs
    /\ RcuOut(t)
    /\ UNCHANGED <<cpu, sq, acc, ci, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* legitimized: leave RCU, use the mount, then mntput()
WUse(t) ==
    /\ pc[t] = "w_use"
    /\ RcuOut(t)
    /\ ret' = [ret EXCEPT ![t] = "done"]
    /\ pc' = [pc EXCEPT ![t] = "p_enter"]
    /\ IF Waited(t) THEN Drained(t, <<>>) ELSE Unchanged_vis /\ UNCHANGED buf
    /\ UNCHANGED <<cpu, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

Walk(t) == WStart(t) \/ WLookup(t) \/ WL1(t) \/ WL2(t) \/ WMb(t) \/ WL4(t)
           \/ WLock(t) \/ WFlags(t) \/ WUse(t)

(* ---- the holder: mntget(), migration, mntput() ------------------------- *)

\* path_get() on a path the task holds: mnt_inc_count() with nothing held
\* but that reference
HGet(t) ==
    /\ pc[t] = "h_idle" /\ refs[t] > 0 /\ gets[t] < GetBudget
    /\ Push(t, StCnt(TaskMount[t], cpu[t], 1))
    /\ refs' = [refs EXCEPT ![t] = @ + 1]
    /\ gets' = [gets EXCEPT ![t] = @ + 1]
    /\ Unchanged_vis
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, pc, ret, sq, acc, ci, own, migs, cleaner>>
    /\ UNCHANGED uvars

\* the scheduler moves the task: its stores are visible before it runs again
HMigrate(t) ==
    /\ MIGRATE /\ pc[t] = "h_idle" /\ migs[t] < MigBudget
    /\ \E c \in CPUs \ {cpu[t]} : cpu' = [cpu EXCEPT ![t] = c]
    /\ migs' = [migs EXCEPT ![t] = @ + 1]
    /\ Drained(t, <<>>)
    /\ UNCHANGED <<rcu, gp, gpfree, pc, ret, sq, acc, ci, refs, own, gets, cleaner>>
    /\ UNCHANGED uvars

HPut(t) ==
    /\ pc[t] = "h_idle" /\ refs[t] > 0
    /\ ret' = [ret EXCEPT ![t] = "h_idle"]
    /\ pc' = [pc EXCEPT ![t] = "p_enter"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

HDone(t) ==
    /\ pc[t] = "h_idle" /\ refs[t] = 0
    /\ pc' = [pc EXCEPT ![t] = "done"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

Hold(t) == HGet(t) \/ HMigrate(t) \/ HPut(t) \/ HDone(t)

(* ---- the umounter, part 1: the write section ---------------------------- *)

\* do_umount() L2065: namespace_lock(); lock_mount_hash()
ULock ==
    /\ pc[U] = "u_lock"
    /\ Lock(U)
    /\ pc' = [pc EXCEPT ![U] = IF Sync THEN "u_mb" ELSE "u_tree"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L2084: smp_mb(); // paired with __legitimize_mnt()
UMb ==
    /\ pc[U] = "u_mb"
    /\ FIX_MB_UMOUNT => Empty(U)
    /\ acc' = [acc EXCEPT ![U] = 0]
    /\ ci' = [ci EXCEPT ![U] = 1]
    /\ bi' = 1 /\ um' = BatchOrder[1]
    /\ pc' = [pc EXCEPT ![U] = "u_sum"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<ownput, head, held, fin, synced, uresult>>

\* propagate_mount_busy(mnt, 2) L2087 / do_refcount_check(): the root is busy
\* above two (its own reference and the caller's), the other mounts of the
\* batch above one
USum == pc[U] = "u_sum" /\ SumStep(U, "u_busy")

\* busy: unlock_mount_hash(), namespace_unlock() with nothing unmounted, and
\* the __free(mntput_no_expire) of the caller's reference, the fast path
\* since the root is still in its namespace; else the next mount, or umount_tree()
UBusy ==
    /\ pc[U] = "u_busy"
    /\ IF acc[U] > Allow(um)
       THEN /\ Drained(U, UnlockStores(U))
            /\ uresult' = "busy"
            /\ ret' = [ret EXCEPT ![U] = "done"]
            /\ um' = Root /\ ownput' = FALSE
            /\ pc' = [pc EXCEPT ![U] = "p_enter"]
            /\ UNCHANGED <<acc, ci, bi>>
       ELSE IF bi < NB
       THEN /\ Unchanged_vis /\ UNCHANGED buf
            /\ bi' = bi + 1 /\ um' = BatchOrder[bi + 1]
            /\ acc' = [acc EXCEPT ![U] = 0]
            /\ ci' = [ci EXCEPT ![U] = 1]
            /\ pc' = [pc EXCEPT ![U] = "u_sum"]
            /\ UNCHANGED <<uresult, ret, ownput>>
       ELSE /\ Unchanged_vis /\ UNCHANGED buf
            /\ pc' = [pc EXCEPT ![U] = "u_tree"]
            /\ UNCHANGED <<uresult, ret, acc, ci, bi, um, ownput>>
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, sq, refs, own, gets, migs, cleaner, head, held, fin, synced>>

\* umount_tree() L1905 over the batch in its order: MNT_UMOUNT (L1917),
\* WRITE_ONCE(p->mnt_ns, NULL) (L1944), MNT_SYNC_UMOUNT for a synchronous
\* umount (L1946), umount_mnt() unhashes (L1951), hlist_add_head() onto
\* `unmounted` (L1953), which namespace_unlock() moves to `head` (L1850)
RECURSIVE TreeStores(_)
TreeStores(i) == IF i > NB THEN <<>>
                 ELSE <<StHash(Rev[i], FALSE), StNs(Rev[i], FALSE)>> \o TreeStores(i + 1)
UTree ==
    /\ pc[U] = "u_tree"
    /\ m' = [x \in Mounts |-> [m[x] EXCEPT !.umount = TRUE, !.sync = Sync]]
    /\ buf' = [buf EXCEPT ![U] = @ \o TreeStores(1)]
    /\ uresult' = "ok"
    /\ pc' = [pc EXCEPT ![U] = IF Umount2 THEN "u_caller_drop" ELSE "u_unlock"]
    /\ UNCHANGED <<seqv, cntv, putv, lockv, cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<um, ownput, bi, head, held, fin, synced>>

\* do_umount() L2097: mnt_dec_count(mnt) of the caller's reference inside the
\* write section, a plain store (no smp_wmb() here); not the last one, the
\* mount's own is still there
UCallerDrop ==
    /\ pc[U] = "u_caller_drop"
    /\ PushAll(U, <<StCnt(Root, cpu[U], -1)>>)
    /\ refs' = [refs EXCEPT ![U] = @ - 1]
    /\ pc' = [pc EXCEPT ![U] = "u_unlock"]
    /\ Unchanged_vis
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L2101: unlock_mount_hash()
UUnlock ==
    /\ pc[U] = "u_unlock"
    /\ Drained(U, UnlockStores(U))
    /\ pc' = [pc EXCEPT ![U] = "u_nsunlock"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* namespace_unlock() L1844: up_write(&namespace_sem), a full barrier; then
\* mntput_unmounted(&head) (L1877)
UNsUnlock ==
    /\ pc[U] = "u_nsunlock"
    /\ Empty(U)
    /\ bi' = 1
    /\ pc' = [pc EXCEPT ![U] = IF PREV_SHAPE THEN "v_next" ELSE "u_peek"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<um, ownput, head, held, fin, synced, uresult>>

\* kern_unmount_array() L6606: mnt_make_shortterm() (L1594) for each mount,
\* WRITE_ONCE(mnt_ns, NULL) with no lock and no seqcount bump, hlist_add_head()
\* onto `head`; then mntput_unmounted(&head) (L6617)
RECURSIVE ShortStores(_)
ShortStores(i) == IF i > NB THEN <<>> ELSE <<StNs(Rev[i], FALSE)>> \o ShortStores(i + 1)
KShortterm ==
    /\ pc[U] = "k_shortterm"
    /\ PushAll(U, ShortStores(1))
    /\ uresult' = "ok"
    /\ bi' = 1
    /\ pc' = [pc EXCEPT ![U] = IF PREV_SHAPE THEN "v_next" ELSE "u_peek"]
    /\ Unchanged_vis
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<um, ownput, head, held, fin, synced>>

(* ---- the umounter, part 2: mntput_unmounted() L1534 --------------------- *)

\* L1541: lock_mount_hash()
UPeek ==
    /\ pc[U] = "u_peek"
    /\ Lock(U)
    /\ pc' = [pc EXCEPT ![U] = "u_peek_mb"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L1542: smp_mb(); /* see __legitimize_mnt() and mntput_no_expire() */ --
\* the one barrier for the whole batch; then the first mount's mnt_get_count()
UPeekMb ==
    /\ pc[U] = "u_peek_mb"
    /\ FIX_MB_PEEK => Empty(U)
    /\ acc' = [acc EXCEPT ![U] = 0]
    /\ ci' = [ci EXCEPT ![U] = 1]
    /\ bi' = 1 /\ um' = BatchOrder[1]
    /\ pc' = [pc EXCEPT ![U] = "u_peek_sum"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<ownput, head, held, fin, synced, uresult>>

\* mntput_unheld() L1521: mnt_get_count(mnt)
UPeekSum == pc[U] = "u_peek_sum" /\ SumStep(U, "u_peek_check")

Finish == acc[U] = 1 \/ (PEEK_LOOSE /\ acc[U] = 2)

\* one: the own reference is the only one -- mnt_dec_count() (L1523),
\* mntput_final_locked() sets MNT_DOOMED (L1423), the mount stays on `head`
\* for its cleanup; else hlist_del(), hlist_add_head() onto `held` (L1546);
\* then the next mount under the same lock hold, or unlock
UPeekCheck ==
    /\ pc[U] = "u_peek_check"
    /\ IF Finish
       THEN /\ PushAll(U, <<StCnt(um, cpu[U], -1)>>)
            /\ m' = [m EXCEPT ![um].doomed = TRUE]
            /\ own' = [own EXCEPT ![um] = FALSE]
            /\ fin' = fin \cup {um}
            /\ UNCHANGED <<head, held, seqv, cntv, putv, lockv>>
       ELSE /\ held' = held \cup {um}
            /\ head' = head \ {um}
            /\ UNCHANGED <<buf, fin, own>> /\ Unchanged_vis
    /\ IF bi < NB
       THEN /\ bi' = bi + 1 /\ um' = BatchOrder[bi + 1]
            /\ acc' = [acc EXCEPT ![U] = 0]
            /\ ci' = [ci EXCEPT ![U] = 1]
            /\ pc' = [pc EXCEPT ![U] = "u_peek_sum"]
       ELSE /\ pc' = [pc EXCEPT ![U] = "u_peek_unlock"]
            /\ UNCHANGED <<bi, um, acc, ci>>
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, refs, gets, migs, cleaner, ownput, synced, uresult>>

\* L1549: unlock_mount_hash()
UPeekUnlock ==
    /\ pc[U] = "u_peek_unlock"
    /\ Drained(U, UnlockStores(U))
    /\ pc' = [pc EXCEPT ![U] = IF QUEUE_LATE /\ held # {} THEN "u_gp" ELSE "u_queue"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L1552: hlist_del() and mntput_queue_cleanup() for every mount left on
\* `head`, i.e. the finished ones: cleanup_mnt() -> call_rcu(delayed_free_vfsmnt),
\* at once (MNT_INTERNAL) or from task work; the model starts the RCU delay here
UQueue ==
    /\ pc[U] = "u_queue"
    /\ gpfree' = [x \in Mounts |-> IF x \in fin THEN [on |-> TRUE, wait |-> Readers] ELSE gpfree[x]]
    /\ cleaner' = [x \in Mounts |-> IF x \in fin THEN U ELSE cleaner[x]]
    /\ head' = head \ fin
    /\ fin' = {}
    /\ pc' = [pc EXCEPT ![U] = IF held = {} \/ QUEUE_LATE THEN "done" ELSE "u_gp"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, ret, sq, acc, ci, refs, own, gets, migs>>
    /\ UNCHANGED <<um, ownput, bi, held, synced, uresult>>

\* L1560: synchronize_rcu_expedited(), once, a full barrier on every CPU
UGp ==
    /\ pc[U] = "u_gp"
    /\ Empty(U)
    /\ IF FIX_RCU_DELAY
       THEN /\ gp' = [on |-> TRUE, wait |-> Readers] /\ pc' = [pc EXCEPT ![U] = "u_gpwait"]
            /\ DrainedAll
       ELSE /\ UNCHANGED gp /\ pc' = [pc EXCEPT ![U] = "u_held_next"]
            /\ Unchanged_vis /\ UNCHANGED buf
    /\ UNCHANGED <<cpu, rcu, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

UGpWait ==
    /\ pc[U] = "u_gpwait"
    /\ gp.wait = {}
    /\ gp' = [on |-> FALSE, wait |-> {}]
    /\ pc' = [pc EXCEPT ![U] = "u_held_next"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

\* L1561: hlist_del() and mntput(&m->mnt) for each held mount; `held` was
\* built with hlist_add_head(), so the mount found last goes first
HeldNext == CHOOSE x \in held : \A y \in held : Pos(y) <= Pos(x)
UHeldNext ==
    /\ pc[U] = "u_held_next"
    /\ IF held = {}
       THEN /\ pc' = [pc EXCEPT ![U] = IF QUEUE_LATE THEN "u_queue" ELSE "done"]
            /\ UNCHANGED <<um, ownput, held, ret>>
       ELSE /\ um' = HeldNext /\ held' = held \ {HeldNext} /\ ownput' = TRUE
            /\ ret' = [ret EXCEPT ![U] = "u_held_next"]
            /\ pc' = [pc EXCEPT ![U] = "p_enter"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<bi, head, fin, synced, uresult>>

(* ---- the umounter, part 2': the previous shape (d5546255be07) ----------- *)
(* for each mount in list order: hlist_del(); until the first held mount    *)
(* mntput_unheld() takes mount_lock itself, smp_mb(), sums, and finishes    *)
(* the mount (unlock, cleanup queued) or unlocks and the one grace period   *)
(* runs; from then on every mount gets a plain mntput()                     *)

VNext ==
    /\ pc[U] = "v_next"
    /\ IF bi > NB
       THEN /\ pc' = [pc EXCEPT ![U] = "done"]
            /\ UNCHANGED <<um, head, ownput, ret>>
       ELSE /\ um' = BatchOrder[bi] /\ head' = head \ {BatchOrder[bi]}
            /\ IF ~synced
               THEN pc' = [pc EXCEPT ![U] = "v_lock"] /\ UNCHANGED <<ownput, ret>>
               ELSE /\ ownput' = TRUE /\ ret' = [ret EXCEPT ![U] = "v_adv"]
                    /\ pc' = [pc EXCEPT ![U] = "p_enter"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<bi, held, fin, synced, uresult>>

VLock ==
    /\ pc[U] = "v_lock"
    /\ Lock(U)
    /\ pc' = [pc EXCEPT ![U] = "v_mb"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

VMb ==
    /\ pc[U] = "v_mb"
    /\ FIX_MB_PEEK => Empty(U)
    /\ acc' = [acc EXCEPT ![U] = 0]
    /\ ci' = [ci EXCEPT ![U] = 1]
    /\ pc' = [pc EXCEPT ![U] = "v_sum"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED uvars

VSum == pc[U] = "v_sum" /\ SumStep(U, "v_check")

VCheck ==
    /\ pc[U] = "v_check"
    /\ IF Finish
       THEN LET r == ApplyAll(Vis, buf[U] \o <<StCnt(um, cpu[U], -1)>> \o UnlockStores(U))
            IN /\ seqv' = r.seqv /\ cntv' = r.cntv /\ putv' = r.putv /\ lockv' = r.lockv
               /\ m' = [r.m EXCEPT ![um].doomed = TRUE]
               /\ buf' = [buf EXCEPT ![U] = <<>>]
               /\ own' = [own EXCEPT ![um] = FALSE]
               /\ pc' = [pc EXCEPT ![U] = "v_queue"]
       ELSE /\ Drained(U, UnlockStores(U))
            /\ UNCHANGED own
            /\ pc' = [pc EXCEPT ![U] = "v_gp"]
    /\ UNCHANGED <<cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, gets, migs, cleaner>>
    /\ UNCHANGED uvars

VQueue ==
    /\ pc[U] = "v_queue"
    /\ gpfree' = [gpfree EXCEPT ![um] = [on |-> TRUE, wait |-> Readers]]
    /\ cleaner' = [cleaner EXCEPT ![um] = U]
    /\ pc' = [pc EXCEPT ![U] = "v_adv"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, ret, sq, acc, ci, refs, own, gets, migs>>
    /\ UNCHANGED uvars

VGp ==
    /\ pc[U] = "v_gp"
    /\ Empty(U)
    /\ IF FIX_RCU_DELAY
       THEN /\ gp' = [on |-> TRUE, wait |-> Readers] /\ pc' = [pc EXCEPT ![U] = "v_gpwait"]
            /\ DrainedAll
            /\ UNCHANGED <<synced, ownput, ret>>
       ELSE /\ UNCHANGED gp /\ Unchanged_vis /\ UNCHANGED buf
            /\ synced' = TRUE /\ ownput' = TRUE /\ ret' = [ret EXCEPT ![U] = "v_adv"]
            /\ pc' = [pc EXCEPT ![U] = "p_enter"]
    /\ UNCHANGED <<cpu, rcu, gpfree, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<um, bi, head, held, fin, uresult>>

VGpWait ==
    /\ pc[U] = "v_gpwait"
    /\ gp.wait = {}
    /\ gp' = [on |-> FALSE, wait |-> {}]
    /\ synced' = TRUE /\ ownput' = TRUE /\ ret' = [ret EXCEPT ![U] = "v_adv"]
    /\ pc' = [pc EXCEPT ![U] = "p_enter"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gpfree, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<um, bi, head, held, fin, uresult>>

VAdv ==
    /\ pc[U] = "v_adv"
    /\ bi' = bi + 1
    /\ pc' = [pc EXCEPT ![U] = "v_next"]
    /\ Unchanged_vis
    /\ UNCHANGED <<buf, cpu, rcu, gp, gpfree, ret, sq, acc, ci, refs, own, gets, migs, cleaner>>
    /\ UNCHANGED <<um, ownput, head, held, fin, synced, uresult>>

Umount == ULock \/ UMb \/ USum \/ UBusy \/ UTree \/ UCallerDrop \/ UUnlock \/ UNsUnlock \/ KShortterm
          \/ UPeek \/ UPeekMb \/ UPeekSum \/ UPeekCheck \/ UPeekUnlock \/ UQueue \/ UGp \/ UGpWait \/ UHeldNext
          \/ VNext \/ VLock \/ VMb \/ VSum \/ VCheck \/ VQueue \/ VGp \/ VGpWait \/ VAdv

(* ---- the specification ------------------------------------------------- *)

TaskStep(t) ==
    \/ Put(t)
    \/ (t \in Walkers /\ Walk(t))
    \/ (t \in Holders /\ Hold(t))
    \/ (t = U /\ Umount)

Next ==
    \/ \E t \in Tasks : TaskStep(t) \/ Flush(t)
    \/ \E x \in Mounts : RcuFree(x)

Spec == Init /\ [][Next]_vars
        /\ \A t \in Tasks : WF_vars(TaskStep(t)) /\ WF_vars(Flush(t))
        /\ \A x \in Mounts : WF_vars(RcuFree(x))

(* ---- what is checked --------------------------------------------------- *)

IsStore(e) == \/ (e.f = "seq" /\ e.v \in Nat)
              \/ (e.f = "cnt" /\ e.x \in Mounts /\ e.c \in CPUs /\ e.d \in {-1, 1})
              \/ (e.f \in {"hashed", "ns"} /\ e.x \in Mounts /\ e.v \in BOOLEAN)
              \/ (e.f = "lock" /\ e.v = NoTask)
              \/ (e.f = "wmb")
MountRec == [hashed: BOOLEAN, ns: BOOLEAN, umount: BOOLEAN, sync: BOOLEAN, doomed: BOOLEAN, freed: BOOLEAN]
TypeOK ==
    /\ seqv \in Nat /\ cntv \in [Mounts -> [CPUs -> Int]] /\ putv \in [Mounts -> [CPUs -> Nat]]
    /\ lockv \in Tasks \cup {NoTask}
    /\ m \in [Mounts -> MountRec]
    /\ \A t \in Tasks : \A i \in 1..Len(buf[t]) : IsStore(buf[t][i])
    /\ cpu \in [Tasks -> CPUs] /\ rcu \in [Tasks -> BOOLEAN]
    /\ pc \in [Tasks -> Labels] /\ ret \in [Tasks -> Labels]
    /\ refs \in [Tasks -> Nat] /\ own \in [Mounts -> BOOLEAN] /\ um \in Mounts \cup {NoMnt}
    /\ uresult \in {"", "ok", "busy"} /\ bi \in 1..(NB + 1)
    /\ head \subseteq Mounts /\ held \subseteq Mounts /\ fin \subseteq head /\ head \cap held = {}

\* a walker's count between mnt_inc_count() and the decision is transient,
\* and so is the one it drops itself after __legitimize_mnt() returned -1
Transient(t) == t \in Walkers /\ (pc[t] \in {"w_mb", "w_l4", "w_lock", "w_flags"} \/ ret[t] = "lost")
RefsOn(x) == SumD([i \in 1..Len(TaskList) |->
                   IF MountOf(TaskList[i]) = x THEN refs[TaskList[i]] ELSE 0])
RealRefs(x) == SumD([i \in 1..Len(TaskList) |->
                     IF MountOf(TaskList[i]) = x /\ ~Transient(TaskList[i]) THEN refs[TaskList[i]] ELSE 0])

\* the ledger: each mount's counters add up to the references on it
Ledger == \A x \in Mounts : Total(x) = (IF own[x] THEN 1 ELSE 0) + RefsOn(x)

\* W1: nobody touches a freed mount; U touches a mount while it is on one of
\* its lists or while it is the one U sums or puts
UTouches(x) == x \in head \cup held \/ (um = x /\ pc[U] \in UMountLabels)
NoUAF == \A x \in Mounts : m[x].freed =>
             /\ \A t \in TasksOf(x) : pc[t] \notin Touching
             /\ ~UTouches(x)

\* W2: MNT_DOOMED means the last reference is gone; the summed count is
\* never negative (the WARN_ON in mntput_no_expire_slowpath())
DoomedIsLast == \A x \in Mounts : m[x].doomed => ~own[x] /\ RealRefs(x) = 0
NoNegative == \A t \in Tasks : pc[t] \in {"p_check", "p_look_check"} => acc[t] >= 0

\* W3: a synchronous umount that succeeded left no reference behind, and the
\* cleanups ran from the caller -- the filesystems are shut down before
\* umount(2) returns
SyncClean == (uresult = "ok" /\ Sync) =>
                 /\ \A t \in Others : ~Transient(t) => refs[t] = 0
                 /\ \A x \in Mounts : cleaner[x] # NoTask => cleaner[x] = U

\* W7: both mounts are freed unless the umount was refused
Freed == <>((\A x \in Mounts : m[x].freed) \/ uresult = "busy")
AllDone == <>(\A t \in Tasks : pc[t] \in Done)

\* the witnesses: the peek never finishes a mount off without the grace
\* period (its violation shows the fast finish being taken); the peek never
\* finishes a mount off once an earlier mount of the batch went on `held`
\* (its violation is the point of the one-lock-hold restructure: the previous
\* shape put every mount after the first held one the plain way)
NoFastFinal == [][pc[U] \in {"u_peek_check", "v_check"} => own' = own]_vars
NoFinishAfterHeld == [][(pc[U] \in {"u_peek_check", "v_check"} /\ (held # {} \/ synced)) => own' = own]_vars

=============================================================================

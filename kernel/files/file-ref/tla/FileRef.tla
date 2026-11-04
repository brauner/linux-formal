------------------------------ MODULE FileRef ------------------------------
(***************************************************************************)
(* file_ref_t, the reference count of struct file: include/linux/file_ref.h *)
(* and the slow path __file_ref_put() in fs/file.c, under concurrent        *)
(* lockless use with files that are SLAB_TYPESAFE_BY_RCU.                   *)
(*                                                                         *)
(* The counter holds "references - 1".  Zones, scaled down from 64 bits to *)
(* BITS bits so that TLC can reach every one of them:                      *)
(*                                                                         *)
(*   ONEREF = 0 .. MAXREF         valid                                    *)
(*   MIN .. RELEASED-1            saturation zone, SATURATED in the middle *)
(*   RELEASED .. NOREF-1          dead zone, DEAD in the middle            *)
(*   NOREF = -1                   the last reference is gone               *)
(*                                                                         *)
(* file_ref_get() adds 1 and succeeds if the result is not negative, so a  *)
(* get on NOREF resurrects the file (the put that made it NOREF then loses *)
(* its cmpxchg).  file_ref_put() subtracts 1; a negative result goes to    *)
(* __file_ref_put(), which turns NOREF into DEAD with a cmpxchg, parks a   *)
(* count in the dead zone back on DEAD with a warning, and a count in the  *)
(* saturation zone on SATURATED.  file_ref_put_close() tries ONEREF->DEAD  *)
(* with one cmpxchg first.                                                 *)
(*                                                                         *)
(* Memory: a file is a slab object.  kmem_cache_free() puts it on the free *)
(* list where it keeps its contents and can be allocated again at once;    *)
(* the slab page itself goes back to the page allocator only after an RCU  *)
(* grace period.  So an object is "live", "free" (its memory is still a    *)
(* file, DEAD, and may be recycled into a new incarnation at any time) or  *)
(* "gone" (the page is released: any access is a use after free).  Tasks   *)
(* in a read-side section -- rcu_read_lock() in the fget-rcu lookup, the   *)
(* guard(preempt)() of file_ref_put() -- hold the page of every object     *)
(* freed while they are inside.                                            *)
(*                                                                         *)
(* Atomic read-modify-writes on one word are totally ordered, so every     *)
(* atomic is one step and the model is sequentially consistent.  What the  *)
(* ordering of the counter against the other words buys (the fd table      *)
(* slot, the fields of the file) is the business of the litmus tests in    *)
(* ../litmus/.                                                             *)
(*                                                                         *)
(* Tasks:                                                                  *)
(*   Owner      owns the descriptor table: close(2) (file_close_fd(),      *)
(*              filp_flush(), fput_close_sync() or __fput_sync()), open(2) *)
(*              (kmem_cache_alloc() recycling a free object, init_file(),  *)
(*              fd_install()), dup2(2) (get_file(), install)               *)
(*   Getters    __fget_files_rcu(): rcu_read_lock(), load the slot,        *)
(*              file_ref_get(), reload and compare the slot, use, fput()   *)
(*   Holders    tasks holding a reference from the start (a VMA, another   *)
(*              table): get_file()/fput() pairs and the final fput()       *)
(*   EpollTasks epi_fget(): file_ref_get() under ep->mtx on the file an    *)
(*              epitem points to, which eventpoll_release_file() clears    *)
(*              under the same mutex before the file can be freed          *)
(*                                                                         *)
(* Every protection the code has is a switch (the FIX_* constants).  With  *)
(* one off TLC finds the trace it prevents, among them the two races of    *)
(* the file_ref series (08ef26ea9ab3): the slow path that re-read the      *)
(* counter and warned about a balanced put, and the get slow path that     *)
(* marked a recycled file dead behind its new owner's back.               *)
(***************************************************************************)
EXTENDS Naturals, Integers, FiniteSets

CONSTANTS
    Owner,              \* the task that owns the descriptor table
    Getters,            \* the fget-rcu tasks
    Holders,            \* tasks holding a reference from the start
    EpollTasks,         \* the epi_fget() tasks (may be empty)
    Objs,               \* the slab objects
    Slots,              \* the descriptor table slots
    Live0,              \* the object that is open at the start
    Slot0,              \* the slot it is installed in
    BITS,               \* width of the counter: the zones are scaled from 64 bits
    GetBudget,          \* lookups a getter may do (retries included)
    HoldBudget,         \* get_file() calls a holder may do
    EpollBudget,        \* epi_fget() attempts an epoll task may do
    OpenBudget,         \* open(2) calls the owner may do
    DupBudget,          \* dup2(2) calls the owner may do
    CLOSE_PUT,          \* "put_close": close(2) uses fput_close_sync(); "put": __fput_sync()
    FIX_PREEMPT_GUARD,  \* guard(preempt)() around file_ref_put()
    FIX_PASS_CNT,       \* __file_ref_put() gets the decrement's result instead of re-reading
    FIX_NO_GET_SLOWPATH, \* file_ref_get() has no slow path (v2 had __file_ref_get())
    FIX_CMPXCHG_DEAD,   \* NOREF -> DEAD by cmpxchg, not by a plain store
    FIX_DEAD_MARK,      \* the last put marks the count DEAD at all before the free
    FIX_RECHECK,        \* __fget_files_rcu() reloads and compares the slot after the get
    FIX_GET_RCU,        \* __fget_files_rcu() runs under rcu_read_lock()
    TRACK_HIST          \* record the witnesses (off: hist never changes, fewer states)

Tasks == {Owner} \cup Getters \cup Holders \cup EpollTasks
ASSUME /\ Owner \notin Getters /\ Owner \notin Holders /\ Owner \notin EpollTasks
       /\ Getters \cap Holders = {} /\ Getters \cap EpollTasks = {} /\ Holders \cap EpollTasks = {}
       /\ Live0 \in Objs /\ Slot0 \in Slots /\ BITS >= 4
       /\ CLOSE_PUT \in {"put", "put_close"}

NULL == "null"
NoTask == "none"
NoSlot == "noslot"

(* ---- the counter ------------------------------------------------------ *)

M == 2^BITS
Half == 2^(BITS - 1)
MAXREF == Half - 1                               \* FILE_REF_MAXREF    0x7FFF...
MIN == -Half                                     \*                    0x8000...
SATURATED == MIN + 2^(BITS - 3)                  \* FILE_REF_SATURATED 0xA000...
RELEASED == MIN + 2^(BITS - 2)                   \* FILE_REF_RELEASED  0xC000...
DEAD == MIN + 2^(BITS - 2) + 2^(BITS - 3)        \* FILE_REF_DEAD      0xE000...
NOREF == -1                                      \* FILE_REF_NOREF     0xFFFF...

\* two's complement wraparound of the atomic_long_t
Add(c, d) == ((c + d + Half + M) % M) - Half
\* (unsigned long)cnt >= FILE_REF_RELEASED
InDeadZone(c) == c >= RELEASED /\ c <= NOREF
\* FILE_REF_MAXREF < (unsigned long)cnt < FILE_REF_RELEASED
InSatZone(c) == c >= MIN /\ c < RELEASED
\* file_ref_read() == 0
ReadZero(c) == InDeadZone(c)

Guard == IF FIX_PREEMPT_GUARD THEN 1 ELSE 0
Rcu == IF FIX_GET_RCU THEN 1 ELSE 0

VARIABLES
    obj,      \* [Objs -> [cnt, inc, st, gpw, epi]]: the counter, the incarnation,
              \* "live" | "free" | "gone", the readers the page release waits for,
              \* whether an epitem points to the object
    slot,     \* [Slots -> Objs \cup {NULL}]: the descriptor table
    pc,       \* [Tasks -> label]
    rd,       \* [Tasks -> Nat]: read-side nesting: rcu_read_lock() and guard(preempt)()
    refs,     \* [Tasks -> [Objs -> Nat]]: the references a task holds (the ledger)
    rel,      \* [Tasks -> SUBSET Objs]: the __fput()s a task owes (task work)
    lock,     \* ep->mtx: its holder or NoTask
    reg,      \* [Tasks -> record]: the registers of a task
    budget,   \* [Tasks -> [open, dup, get]]
    warn,     \* the WARN_ONCE()s and CHECK_DATA_CORRUPTION() that fired
    hist,     \* witnesses: what happened at least once
    uaf,      \* an object was accessed after its page was released
    stale     \* a reference was used on an object that was freed or recycled under it

vars == <<obj, slot, pc, rd, refs, rel, lock, reg, budget, warn, hist, uaf, stale>>

RECURSIVE SumSet(_, _)
SumSet(f, S) == IF S = {} THEN 0
                ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + SumSet(f, S \ {x})
TotalRefs(o) == SumSet([t \in Tasks |-> refs[t][o]], Tasks)

\* t leaves its last read-side section: the grace periods stop waiting for it
Drop(t, f) == [o \in Objs |-> [f[o] EXCEPT !.gpw = @ \ {t}]]
Leaving(t, n) == rd[t] - n = 0

\* the registers of an idle task; a put that returns to an idle label clears
\* them, one that returns into a lookup's retry keeps the slot it is after
CleanReg == [p |-> NULL, po |-> NULL, s |-> NoSlot, pv |-> 0, c |-> 0,
             ret |-> "done", ginc |-> 0, gotinc |-> 0, gok |-> TRUE]
Idle == {"g_idle", "h_idle", "o_idle"}
AfterPut(r) == IF r.ret \in Idle THEN CleanReg ELSE [r EXCEPT !.pv = 0, !.po = NULL]
Hist(h) == IF TRACK_HIST THEN h ELSE hist

(* ---- init -------------------------------------------------------------- *)

Init ==
    /\ obj = [o \in Objs |->
                IF o = Live0
                THEN [cnt |-> Cardinality(Holders), inc |-> 1, st |-> "live", gpw |-> {},
                      epi |-> EpollTasks # {}]
                ELSE [cnt |-> DEAD, inc |-> 0, st |-> "free", gpw |-> {}, epi |-> FALSE]]
    /\ slot = [s \in Slots |-> IF s = Slot0 THEN Live0 ELSE NULL]
    /\ pc = [t \in Tasks |-> IF t = Owner THEN "o_idle"
                             ELSE IF t \in Getters THEN "g_idle"
                             ELSE IF t \in Holders THEN "h_idle" ELSE "e_idle"]
    /\ rd = [t \in Tasks |-> 0]
    /\ refs = [t \in Tasks |-> [o \in Objs |->
                IF o = Live0 /\ (t = Owner \/ t \in Holders) THEN 1 ELSE 0]]
    /\ rel = [t \in Tasks |-> {}]
    /\ lock = NoTask
    /\ reg = [t \in Tasks |-> CleanReg]
    /\ budget = [t \in Tasks |->
                 [open |-> IF t = Owner THEN OpenBudget ELSE 0,
                  dup |-> IF t = Owner THEN DupBudget ELSE 0,
                  get |-> IF t \in Getters THEN GetBudget
                          ELSE IF t \in Holders THEN HoldBudget
                          ELSE IF t \in EpollTasks THEN EpollBudget ELSE 0]]
    /\ warn = [imbalanced |-> FALSE, inc |-> FALSE, count0 |-> FALSE]
    /\ hist = [resurrect |-> FALSE, recycled_get |-> FALSE, cas_lost |-> FALSE,
               pc_fallback |-> FALSE, epi_fail |-> FALSE, same_slot |-> FALSE,
               get_fail |-> FALSE]
    /\ uaf = FALSE
    /\ stale = FALSE

(* ---- file_ref_put() ----------------------------------------------------- *)
(* entered at "put_dec" (or "pc_read" for file_ref_put_close()) with         *)
(* reg[t].po the object and reg[t].ret the label to continue at              *)

\* guard(preempt)(); cnt = atomic_long_dec_return(&ref->refcnt); if (cnt >= 0)
\* return false; the task's reference is gone with the decrement
PutDec(t) ==
    LET o == reg[t].po
        new == Add(obj[o].cnt, -1)
        f1 == [obj EXCEPT ![o].cnt = new]
    IN
    /\ pc[t] = "put_dec"
    /\ uaf' = (uaf \/ obj[o].st = "gone")
    /\ refs' = [refs EXCEPT ![t][o] = @ - 1]
    /\ obj' = f1
    /\ IF new >= 0
       THEN /\ pc' = [pc EXCEPT ![t] = reg[t].ret]
            /\ reg' = [reg EXCEPT ![t] = AfterPut(reg[t])]
            /\ UNCHANGED rd
       ELSE /\ rd' = [rd EXCEPT ![t] = @ + Guard]
            /\ reg' = [reg EXCEPT ![t].pv = new]
            /\ pc' = [pc EXCEPT ![t] = "put_slow"]
    /\ UNCHANGED <<slot, lock, rel, budget, warn, hist, stale>>

\* __file_ref_put(): the value is the decrement's result (FIX_PASS_CNT) or a
\* fresh atomic_long_read().  NOREF: try_cmpxchg(NOREF, DEAD), true on success.
\* Dead zone: WARN_ONCE("imbalanced put"), set DEAD, false.  Saturation zone:
\* set SATURATED, false.  Then the guard ends.
PutSlow(t) ==
    LET o == reg[t].po
        c == IF FIX_PASS_CNT THEN reg[t].pv ELSE obj[o].cnt
        last == c = NOREF
        won == ~FIX_DEAD_MARK \/ ~FIX_CMPXCHG_DEAD \/ obj[o].cnt = NOREF
        newcnt == IF last
                  THEN (IF FIX_DEAD_MARK /\ won THEN DEAD ELSE obj[o].cnt)
                  ELSE IF InDeadZone(c) THEN DEAD
                  ELSE IF InSatZone(c) THEN SATURATED
                  ELSE obj[o].cnt
        f1 == [obj EXCEPT ![o].cnt = newcnt]
    IN
    /\ pc[t] = "put_slow"
    /\ uaf' = (uaf \/ obj[o].st = "gone")
    /\ warn' = [warn EXCEPT !.imbalanced = @ \/ (~last /\ InDeadZone(c))]
    /\ hist' = Hist([hist EXCEPT !.cas_lost = @ \/ (last /\ ~won)])
    /\ rd' = [rd EXCEPT ![t] = @ - Guard]
    /\ obj' = IF Leaving(t, Guard) THEN Drop(t, f1) ELSE f1
    /\ rel' = [rel EXCEPT ![t] = IF last /\ won THEN @ \cup {o} ELSE @]
    /\ pc' = [pc EXCEPT ![t] = reg[t].ret]
    /\ reg' = [reg EXCEPT ![t] = AfterPut(reg[t])]
    /\ UNCHANGED <<slot, lock, refs, budget, stale>>

\* file_ref_put_close(): old = atomic_long_read(); ONEREF: try the cmpxchg
PutCloseRead(t) ==
    LET o == reg[t].po IN
    /\ pc[t] = "pc_read"
    /\ uaf' = (uaf \/ obj[o].st = "gone")
    /\ pc' = [pc EXCEPT ![t] = IF obj[o].cnt = 0 THEN "pc_cas" ELSE "put_dec"]
    /\ hist' = Hist([hist EXCEPT !.pc_fallback = @ \/ obj[o].cnt # 0])
    /\ UNCHANGED <<obj, slot, lock, rd, refs, rel, reg, budget, warn, stale>>

\* try_cmpxchg(ONEREF, DEAD): true, else fall back to file_ref_put()
PutCloseCas(t) ==
    LET o == reg[t].po IN
    /\ pc[t] = "pc_cas"
    /\ uaf' = (uaf \/ obj[o].st = "gone")
    /\ IF obj[o].cnt = 0
       THEN /\ obj' = [obj EXCEPT ![o].cnt = DEAD]
            /\ refs' = [refs EXCEPT ![t][o] = @ - 1]
            /\ rel' = [rel EXCEPT ![t] = @ \cup {o}]
            /\ pc' = [pc EXCEPT ![t] = reg[t].ret]
            /\ reg' = [reg EXCEPT ![t] = AfterPut(reg[t])]
            /\ UNCHANGED hist
       ELSE /\ pc' = [pc EXCEPT ![t] = "put_dec"]
            /\ hist' = Hist([hist EXCEPT !.pc_fallback = TRUE])
            /\ UNCHANGED <<obj, refs, rel, reg>>
    /\ UNCHANGED <<slot, lock, rd, budget, warn, stale>>

\* __fput() from task work (or synchronously): outside every read-side
\* section; eventpoll_release_file() takes ep->mtx and drops the epitem;
\* file_free() -> kmem_cache_free(): the object goes on the free list, its
\* page is held for every task inside a read-side section right now
Release(t) ==
    /\ rd[t] = 0 /\ lock = NoTask
    /\ \E o \in rel[t] :
        /\ obj' = [obj EXCEPT ![o].st = "free", ![o].gpw = {u \in Tasks : rd[u] > 0},
                              ![o].epi = FALSE]
        /\ rel' = [rel EXCEPT ![t] = @ \ {o}]
    /\ UNCHANGED <<slot, pc, rd, refs, lock, reg, budget, warn, hist, uaf, stale>>

\* the grace period ended with the object still on the free list: the slab
\* page goes back to the page allocator
Gone(o) ==
    /\ obj[o].st = "free" /\ obj[o].gpw = {}
    /\ obj' = [obj EXCEPT ![o].st = "gone"]
    /\ UNCHANGED <<slot, pc, rd, refs, rel, lock, reg, budget, warn, hist, uaf, stale>>

(* ---- the owner: close(2), open(2), dup2(2) ------------------------------ *)

\* file_close_fd(): the slot is cleared under file_lock; the table's
\* reference is now the caller's to drop
Close(t) ==
    /\ pc[t] = "o_idle"
    /\ \E s \in Slots :
        /\ slot[s] # NULL
        /\ slot' = [slot EXCEPT ![s] = NULL]
        /\ reg' = [reg EXCEPT ![t].po = slot[s]]
    /\ pc' = [pc EXCEPT ![t] = "o_flush"]
    /\ UNCHANGED <<obj, rd, refs, rel, lock, budget, warn, hist, uaf, stale>>

\* filp_flush(): CHECK_DATA_CORRUPTION(file_count(filp) == 0), then
\* fput_close_sync() or __fput_sync()
Flush(t) ==
    LET o == reg[t].po IN
    /\ pc[t] = "o_flush"
    /\ uaf' = (uaf \/ obj[o].st = "gone")
    /\ warn' = [warn EXCEPT !.count0 = @ \/ ReadZero(obj[o].cnt)]
    /\ reg' = [reg EXCEPT ![t].ret = "o_idle"]
    /\ pc' = [pc EXCEPT ![t] = IF CLOSE_PUT = "put_close" THEN "pc_read" ELSE "put_dec"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, budget, hist, stale>>

\* alloc_empty_file(): kmem_cache_alloc() hands out a free object at once,
\* init_file() sets the fields and file_ref_init(1) last: a new incarnation
Open(t) ==
    /\ pc[t] = "o_idle" /\ budget[t].open > 0
    /\ \E s \in Slots, o \in Objs :
        /\ slot[s] = NULL /\ obj[o].st = "free"
        /\ obj' = [obj EXCEPT ![o].st = "live", ![o].inc = @ + 1, ![o].cnt = 0, ![o].gpw = {}]
        /\ refs' = [refs EXCEPT ![t][o] = @ + 1]
        /\ reg' = [reg EXCEPT ![t].po = o, ![t].s = s]
    /\ budget' = [budget EXCEPT ![t].open = @ - 1]
    /\ pc' = [pc EXCEPT ![t] = "o_install"]
    /\ UNCHANGED <<slot, rd, rel, lock, warn, hist, uaf, stale>>

\* fd_install(): rcu_assign_pointer(fdt->fd[fd], file)
Install(t) ==
    /\ pc[t] = "o_install"
    /\ slot' = [slot EXCEPT ![reg[t].s] = reg[t].po]
    /\ reg' = [reg EXCEPT ![t] = CleanReg]
    /\ pc' = [pc EXCEPT ![t] = "o_idle"]
    /\ UNCHANGED <<obj, rd, refs, rel, lock, budget, warn, hist, uaf, stale>>

\* dup2(2): get_file() = file_ref_inc(), WARN_ONCE() if the old value was
\* negative, and the new slot under file_lock
Dup(t) ==
    /\ pc[t] = "o_idle" /\ budget[t].dup > 0
    /\ \E s, s2 \in Slots :
        /\ slot[s] # NULL /\ slot[s2] = NULL
        /\ LET o == slot[s] IN
            /\ uaf' = (uaf \/ obj[o].st = "gone")
            /\ warn' = [warn EXCEPT !.inc = @ \/ obj[o].cnt < 0]
            /\ obj' = [obj EXCEPT ![o].cnt = Add(@, 1)]
            /\ refs' = [refs EXCEPT ![t][o] = @ + 1]
            /\ slot' = [slot EXCEPT ![s2] = o]
    /\ budget' = [budget EXCEPT ![t].dup = @ - 1]
    /\ UNCHANGED <<pc, rd, rel, lock, reg, hist, stale>>

ODone(t) ==
    /\ pc[t] = "o_idle" /\ rel[t] = {}
    /\ \A s \in Slots : slot[s] = NULL
    /\ pc' = [pc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, reg, budget, warn, hist, uaf, stale>>

(* ---- the getter: __fget_files_rcu() ------------------------------------- *)

\* rcu_read_lock(), pick the descriptor
GStart(t) ==
    /\ pc[t] = "g_idle" /\ budget[t].get > 0
    /\ \E s \in Slots : reg' = [reg EXCEPT ![t].s = s]
    /\ rd' = [rd EXCEPT ![t] = @ + Rcu]
    /\ budget' = [budget EXCEPT ![t].get = @ - 1]
    /\ pc' = [pc EXCEPT ![t] = "g_load"]
    /\ UNCHANGED <<obj, slot, refs, rel, lock, warn, hist, uaf, stale>>

\* file = rcu_dereference_raw(*fdentry); NULL: return NULL
GLoad(t) ==
    LET s == reg[t].s
        p == slot[s]
    IN
    /\ pc[t] = "g_load"
    /\ IF p = NULL
       THEN /\ pc' = [pc EXCEPT ![t] = "g_idle"]
            /\ rd' = [rd EXCEPT ![t] = @ - Rcu]
            /\ obj' = IF Leaving(t, Rcu) THEN Drop(t, obj) ELSE obj
            /\ reg' = [reg EXCEPT ![t] = CleanReg]
       ELSE /\ reg' = [reg EXCEPT ![t].p = p, ![t].ginc = obj[p].inc]
            /\ pc' = [pc EXCEPT ![t] = "g_get"]
            /\ UNCHANGED <<rd, obj>>
    /\ UNCHANGED <<slot, refs, rel, lock, budget, warn, hist, uaf, stale>>

\* file_ref_get(): !atomic_long_add_negative(1, &f_ref); on failure
\* `continue` (or the v2 slow path with FIX_NO_GET_SLOWPATH off)
GGet(t) ==
    LET p == reg[t].p
        old == obj[p].cnt
        new == Add(old, 1)
    IN
    /\ pc[t] = "g_get"
    /\ uaf' = (uaf \/ obj[p].st = "gone")
    /\ obj' = [obj EXCEPT ![p].cnt = new]
    /\ IF new >= 0
       THEN /\ refs' = [refs EXCEPT ![t][p] = @ + 1]
            /\ reg' = [reg EXCEPT ![t].gotinc = obj[p].inc]
            /\ hist' = Hist([hist EXCEPT !.resurrect = @ \/ old = NOREF,
                                         !.recycled_get = @ \/ obj[p].inc # reg[t].ginc])
            /\ pc' = [pc EXCEPT ![t] = IF FIX_RECHECK THEN "g_recheck" ELSE "g_return"]
       ELSE /\ hist' = Hist([hist EXCEPT !.get_fail = TRUE])
            /\ pc' = [pc EXCEPT ![t] = IF FIX_NO_GET_SLOWPATH THEN "g_retry" ELSE "g_slow1"]
            /\ UNCHANGED <<refs, reg>>
    /\ UNCHANGED <<slot, rd, rel, lock, budget, warn, stale>>

\* the v2 __file_ref_get(): cnt = atomic_long_read(&ref->refcnt) ...
GSlow1(t) ==
    LET p == reg[t].p IN
    /\ pc[t] = "g_slow1"
    /\ uaf' = (uaf \/ obj[p].st = "gone")
    /\ reg' = [reg EXCEPT ![t].c = obj[p].cnt]
    /\ pc' = [pc EXCEPT ![t] = "g_slow2"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, budget, warn, hist, stale>>

\* ... dead zone: atomic_long_set(DEAD), return false; otherwise return true,
\* parking a saturated count on SATURATED
GSlow2(t) ==
    LET p == reg[t].p
        c == reg[t].c
    IN
    /\ pc[t] = "g_slow2"
    /\ uaf' = (uaf \/ obj[p].st = "gone")
    /\ IF InDeadZone(c)
       THEN /\ obj' = [obj EXCEPT ![p].cnt = DEAD]
            /\ reg' = [reg EXCEPT ![t].c = 0]
            /\ pc' = [pc EXCEPT ![t] = "g_retry"]
            /\ UNCHANGED <<refs, hist>>
       ELSE /\ obj' = IF InSatZone(c) THEN [obj EXCEPT ![p].cnt = SATURATED] ELSE obj
            /\ refs' = [refs EXCEPT ![t][p] = @ + 1]
            /\ reg' = [reg EXCEPT ![t].gotinc = obj[p].inc, ![t].c = 0]
            /\ hist' = Hist([hist EXCEPT !.recycled_get = @ \/ obj[p].inc # reg[t].ginc])
            /\ pc' = [pc EXCEPT ![t] = IF FIX_RECHECK THEN "g_recheck" ELSE "g_return"]
    /\ UNCHANGED <<slot, rd, rel, lock, budget, warn, stale>>

\* file != rcu_dereference_raw(*fdentry): fput() and continue; else the
\* lookup is done: this load is where it takes effect
GRecheck(t) ==
    LET p == reg[t].p
        s == reg[t].s
    IN
    /\ pc[t] = "g_recheck"
    /\ IF slot[s] = p
       THEN /\ reg' = [reg EXCEPT ![t].gok = TRUE]
            /\ hist' = Hist([hist EXCEPT !.same_slot = @ \/ obj[p].inc # reg[t].ginc])
            /\ rd' = [rd EXCEPT ![t] = @ - Rcu]
            /\ obj' = IF Leaving(t, Rcu) THEN Drop(t, obj) ELSE obj
            /\ pc' = [pc EXCEPT ![t] = "g_use"]
       ELSE /\ reg' = [reg EXCEPT ![t].po = p, ![t].ret = "g_retry"]
            /\ pc' = [pc EXCEPT ![t] = "put_dec"]
            /\ UNCHANGED <<hist, rd, obj>>
    /\ UNCHANGED <<slot, refs, rel, lock, budget, warn, uaf, stale>>

\* without the recheck the file is returned right after the increment: it
\* is the right file if its incarnation is the one the slot held when it
\* was loaded, or if the slot holds it now
GReturn(t) ==
    LET p == reg[t].p
        s == reg[t].s
    IN
    /\ pc[t] = "g_return"
    /\ reg' = [reg EXCEPT ![t].gok = (obj[p].inc = reg[t].ginc \/ slot[s] = p)]
    /\ rd' = [rd EXCEPT ![t] = @ - Rcu]
    /\ obj' = IF Leaving(t, Rcu) THEN Drop(t, obj) ELSE obj
    /\ pc' = [pc EXCEPT ![t] = "g_use"]
    /\ UNCHANGED <<slot, refs, rel, lock, budget, warn, hist, uaf, stale>>

\* the caller uses the file it holds a reference on, then fput()s it
GUse(t) ==
    LET p == reg[t].p IN
    /\ pc[t] = "g_use"
    /\ uaf' = (uaf \/ obj[p].st = "gone")
    /\ stale' = (stale \/ obj[p].st # "live" \/ obj[p].inc # reg[t].gotinc)
    /\ reg' = [reg EXCEPT ![t].po = p, ![t].ret = "g_idle"]
    /\ pc' = [pc EXCEPT ![t] = "put_dec"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, budget, warn, hist>>

\* `continue` in __fget_files_rcu(): the budget bounds the loop
GRetry(t) ==
    /\ pc[t] = "g_retry"
    /\ IF budget[t].get > 0
       THEN /\ budget' = [budget EXCEPT ![t].get = @ - 1]
            /\ pc' = [pc EXCEPT ![t] = "g_load"]
            /\ UNCHANGED <<rd, obj>>
       ELSE /\ rd' = [rd EXCEPT ![t] = @ - Rcu]
            /\ obj' = IF Leaving(t, Rcu) THEN Drop(t, obj) ELSE obj
            /\ pc' = [pc EXCEPT ![t] = "g_idle"]
            /\ UNCHANGED budget
    /\ reg' = IF budget[t].get > 0 THEN reg ELSE [reg EXCEPT ![t] = CleanReg]
    /\ UNCHANGED <<slot, refs, rel, lock, warn, hist, uaf, stale>>

GDone(t) ==
    /\ pc[t] = "g_idle" /\ budget[t].get = 0 /\ rel[t] = {}
    /\ pc' = [pc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, reg, budget, warn, hist, uaf, stale>>

(* ---- the holder: get_file(), fput() ------------------------------------- *)

\* get_file(): file_ref_inc() on a file the task holds a reference on
HGet(t) ==
    /\ pc[t] = "h_idle" /\ budget[t].get > 0
    /\ \E o \in Objs :
        /\ refs[t][o] > 0
        /\ uaf' = (uaf \/ obj[o].st = "gone")
        /\ warn' = [warn EXCEPT !.inc = @ \/ obj[o].cnt < 0]
        /\ obj' = [obj EXCEPT ![o].cnt = Add(@, 1)]
        /\ refs' = [refs EXCEPT ![t][o] = @ + 1]
    /\ budget' = [budget EXCEPT ![t].get = @ - 1]
    /\ UNCHANGED <<slot, pc, rd, rel, lock, reg, hist, stale>>

HPut(t) ==
    /\ pc[t] = "h_idle"
    /\ \E o \in Objs :
        /\ refs[t][o] > 0
        /\ reg' = [reg EXCEPT ![t].po = o, ![t].ret = "h_idle"]
    /\ pc' = [pc EXCEPT ![t] = "put_dec"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, budget, warn, hist, uaf, stale>>

HDone(t) ==
    /\ pc[t] = "h_idle" /\ rel[t] = {}
    /\ \A o \in Objs : refs[t][o] = 0
    /\ pc' = [pc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, reg, budget, warn, hist, uaf, stale>>

(* ---- the epoll task: epi_fget() under ep->mtx --------------------------- *)

ELock(t) ==
    /\ pc[t] = "e_idle" /\ budget[t].get > 0 /\ lock = NoTask
    /\ lock' = t
    /\ budget' = [budget EXCEPT ![t].get = @ - 1]
    /\ pc' = [pc EXCEPT ![t] = "e_get"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, reg, warn, hist, uaf, stale>>

\* the epitem is gone (eventpoll_release_file() ran): nothing to get;
\* else file_ref_get() on epi->ffd.file, whose memory the mutex pins
EGet(t) ==
    LET o == Live0
        new == Add(obj[o].cnt, 1)
    IN
    /\ pc[t] = "e_get"
    /\ IF ~obj[o].epi
       THEN /\ pc' = [pc EXCEPT ![t] = "e_unlock"]
            /\ UNCHANGED <<obj, refs, reg, hist, uaf>>
       ELSE /\ uaf' = (uaf \/ obj[o].st = "gone")
            /\ obj' = [obj EXCEPT ![o].cnt = new]
            /\ IF new >= 0
               THEN /\ refs' = [refs EXCEPT ![t][o] = @ + 1]
                    /\ reg' = [reg EXCEPT ![t].gotinc = obj[o].inc]
                    /\ pc' = [pc EXCEPT ![t] = "e_use"]
                    /\ UNCHANGED hist
               ELSE /\ hist' = Hist([hist EXCEPT !.epi_fail = TRUE])
                    /\ pc' = [pc EXCEPT ![t] = "e_unlock"]
                    /\ UNCHANGED <<refs, reg>>
    /\ UNCHANGED <<slot, rd, rel, lock, budget, warn, stale>>

\* ep_remove_file() touches file->f_lock and f_ep, then the __free(fput)
EUse(t) ==
    LET o == Live0 IN
    /\ pc[t] = "e_use"
    /\ uaf' = (uaf \/ obj[o].st = "gone")
    /\ stale' = (stale \/ obj[o].st # "live" \/ obj[o].inc # reg[t].gotinc)
    /\ reg' = [reg EXCEPT ![t].po = o, ![t].ret = "e_unlock"]
    /\ pc' = [pc EXCEPT ![t] = "put_dec"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, budget, warn, hist>>

EUnlock(t) ==
    /\ pc[t] = "e_unlock"
    /\ lock' = NoTask
    /\ reg' = [reg EXCEPT ![t] = CleanReg]
    /\ pc' = [pc EXCEPT ![t] = "e_idle"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, budget, warn, hist, uaf, stale>>

EDone(t) ==
    /\ pc[t] = "e_idle" /\ budget[t].get = 0 /\ rel[t] = {}
    /\ pc' = [pc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<obj, slot, rd, refs, rel, lock, reg, budget, warn, hist, uaf, stale>>

(* ---- the specification -------------------------------------------------- *)

Put(t) == PutDec(t) \/ PutSlow(t) \/ PutCloseRead(t) \/ PutCloseCas(t) \/ Release(t)
OwnerStep(t) == Close(t) \/ Flush(t) \/ Open(t) \/ Install(t) \/ Dup(t) \/ ODone(t)
GetterStep(t) == GStart(t) \/ GLoad(t) \/ GGet(t) \/ GSlow1(t) \/ GSlow2(t) \/ GRecheck(t)
                 \/ GReturn(t) \/ GUse(t) \/ GRetry(t) \/ GDone(t)
HolderStep(t) == HGet(t) \/ HPut(t) \/ HDone(t)
EpollStep(t) == ELock(t) \/ EGet(t) \/ EUse(t) \/ EUnlock(t) \/ EDone(t)

TaskStep(t) ==
    \/ Put(t)
    \/ (t = Owner /\ OwnerStep(t))
    \/ (t \in Getters /\ GetterStep(t))
    \/ (t \in Holders /\ HolderStep(t))
    \/ (t \in EpollTasks /\ EpollStep(t))

Next == \/ \E t \in Tasks : TaskStep(t)
        \/ \E o \in Objs : Gone(o)

Spec == Init /\ [][Next]_vars /\ \A t \in Tasks : WF_vars(TaskStep(t))

(* ---- what is checked ---------------------------------------------------- *)

Labels == {"done", "put_dec", "put_slow", "pc_read", "pc_cas",
           "o_idle", "o_flush", "o_install",
           "g_idle", "g_load", "g_get", "g_slow1", "g_slow2", "g_recheck", "g_return",
           "g_use", "g_retry", "h_idle", "e_idle", "e_get", "e_use", "e_unlock"}
TypeOK ==
    /\ obj \in [Objs -> [cnt: MIN..MAXREF, inc: Nat, st: {"live", "free", "gone"},
                         gpw: SUBSET Tasks, epi: BOOLEAN]]
    /\ slot \in [Slots -> Objs \cup {NULL}]
    /\ pc \in [Tasks -> Labels]
    /\ rd \in [Tasks -> Nat]
    /\ refs \in [Tasks -> [Objs -> Nat]]
    /\ rel \in [Tasks -> SUBSET Objs]
    /\ lock \in Tasks \cup {NoTask}

\* no access to an object whose slab page was released
NoUAF == ~uaf

\* no reference is used on an object that was freed or recycled under it
NoStale == ~stale

\* the counter of a live file that is not saturated is its references minus
\* one, NOREF included (a put that is about to lose its cmpxchg); a file in
\* the dead zone, on the free list or gone has no reference at all
Ledger == \A o \in Objs :
    obj[o].st = "live" /\ obj[o].cnt >= NOREF => obj[o].cnt = TotalRefs(o) - 1
DeadMeansNoRefs == \A o \in Objs :
    (obj[o].st # "live" \/ (InDeadZone(obj[o].cnt) /\ obj[o].cnt # NOREF)) => TotalRefs(o) = 0

\* a put that returned true owes exactly one __fput() of a live file nobody
\* references anymore; no two tasks owe the same one
OwedRelease == \A t \in Tasks : \A o \in rel[t] :
    /\ obj[o].st = "live" /\ TotalRefs(o) = 0
    /\ \A u \in Tasks \ {t} : o \notin rel[u]

\* a lookup that returned a file holds a reference on the incarnation the
\* slot held when it was loaded, or on the one the slot holds now
RightFile == \A t \in Getters : pc[t] = "g_use" => reg[t].gok

\* none of the warnings fire: "imbalanced put on file reference count",
\* "file_ref_inc() on a released file reference", "VFS: Close: file count is 0"
NoWarn == ~warn.imbalanced /\ ~warn.inc /\ ~warn.count0

\* when every task is done every file has been freed: nothing leaked
AllDone == \A t \in Tasks : pc[t] = "done"
FinalClean == AllDone => \A o \in Objs : obj[o].st # "live"

\* every task finishes
Terminates == <>AllDone

\* witnesses: these are expected to fail
NoResurrect == ~hist.resurrect          \* a get brought NOREF back to ONEREF
NoRecycledGet == ~hist.recycled_get     \* a get succeeded on a recycled file
NoCasLost == ~hist.cas_lost             \* the NOREF -> DEAD cmpxchg lost to a get/put pair
NoPutCloseFallback == ~hist.pc_fallback \* file_ref_put_close() fell back to file_ref_put()
NoEpiFail == ~hist.epi_fail             \* epi_fget() found the file dead
NoSameSlot == ~hist.same_slot           \* the recheck passed on a recycled file in the same slot
NoGetFail == ~hist.get_fail             \* file_ref_get() failed

=============================================================================

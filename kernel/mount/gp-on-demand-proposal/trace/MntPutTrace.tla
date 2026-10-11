--------------------------- MODULE MntPutTrace ---------------------------
(***************************************************************************)
(* Trace validation of MntPut (kernel/work.mount.gp_on_demand.proposal)    *)
(* against the events of include/trace/events/mount.h, one mount per trace *)
(* (trace2ndjson.py).  The traced mount is "A"; "B" is a phantom nobody    *)
(* touches, so every step of U on it is unlogged.                           *)
(*                                                                         *)
(* Line 1 of the NDJSON file is the configuration (tasks, mode, budgets),  *)
(* the rest are the events, each naming the model task that performs it.   *)
(* Each task consumes its events in program order; the events emitted      *)
(* under mount_lock carry lk, their rank in mount_lock sequence order, and  *)
(* are consumed in that order across tasks; lockless events of different   *)
(* tasks interleave freely.  Model actions that no event logs are free     *)
(* steps.  The trace is accepted when every event has been consumed.       *)
(***************************************************************************)
EXTENDS MntPut, TLC, Json, IOUtils

ToSet(s) == {s[i] : i \in 1..Len(s)}

Trace == ndJsonDeserialize(IOEnv.TRACE_PATH)
Cfg == Trace[1]
NEv == Len(Trace) - 1
Ev == [i \in 1..NEv |-> Trace[i + 1]]

\* the constants, from the configuration line
TraceTaskList == Cfg.tasklist
TraceWalkers == ToSet(Cfg.walkers)
TraceHolders == ToSet(Cfg.holders)
TraceOthers == TraceWalkers \cup TraceHolders
TraceTaskMount == [t \in TraceOthers |-> "A"]
TraceMode == Cfg.shape
TraceLazy == ~Cfg.sync
TraceGetBudget == Cfg.getbudget
OrderAB == <<"A", "B">>

Rcu == "rcu"
TTasks == ToSet(Cfg.tasklist) \cup {Rcu}
Evs(t) == SelectSeq(Ev, LAMBDA e : e.task = t)
NLocked == Cfg.nlocked

VARIABLES cur, lkc    \* per-task cursor into Evs(t); the next locked rank
tvars == <<vars, cur, lkc>>

ASSUME TLCSet(0, 0)

Consumed == SumD([i \in 1..Len(Cfg.tasklist) |-> cur[Cfg.tasklist[i]] - 1]) + cur[Rcu] - 1
Accepted == \A t \in TTasks : cur[t] = Len(Evs(t)) + 1

SeenSum(t, x) == SumD([c \in 1..NCPU |-> SeenCnt(t, x, c)])
Flags == m["A"].sync \/ m["A"].doomed

TraceInit == Init /\ cur = [t \in TTasks |-> 1] /\ lkc = 1

\* the event -> action mapping
Match(t, e) ==
    CASE e.ev = "mnt_umount_tree" -> t = U /\ UTree /\ SeenSum(U, "A") = e.count
      [] e.ev = "mnt_caller_drop" -> t = U /\ UCallerDrop
      [] e.ev = "mnt_peek"        -> t = U /\ um = "A" /\ UPeekCheck /\ acc[U] = e.count /\ Finish = e.unheld
      [] e.ev = "mnt_final"       -> m["A"].doomed /\ UNCHANGED vars
      [] e.ev = "mnt_slowpath"    -> t # Rcu /\ Mnt(t) = "A" /\ PutCheck(t) /\ acc[t] = e.count
                                     /\ m["A"].doomed = e.doomed
      [] e.ev = "mnt_gp"          -> t = U /\ IF e.end THEN UGpWait ELSE UGp
      [] e.ev = "mnt_cleanup"     -> IF t = U /\ pc[U] = "u_queue" THEN UQueue /\ "A" \in fin
                                     ELSE t # Rcu /\ Mnt(t) = "A" /\ PutCleanup(t)
      [] e.ev = "mnt_free"        -> RcuFree("A")
      [] e.ev = "mnt_legitimize"  -> t \in Walkers /\
                                     (CASE e.early        -> WL1(t) /\ seqv # sq[t]
                                        [] e.result = 0   -> WL4(t) /\ seqv = sq[t]
                                        [] e.result = 1   -> WFlags(t) /\ Flags
                                        [] e.result = -1  -> WFlags(t) /\ ~Flags)
      [] e.ev = "mnt_get"         -> t \in Holders /\ HGet(t)
      [] e.ev = "mnt_put_fast"    -> t # Rcu /\ Mnt(t) = "A" /\ PutFast(t)

Logged ==
    \E t \in TTasks :
        /\ cur[t] <= Len(Evs(t))
        /\ LET e == Evs(t)[cur[t]]
           IN /\ e.lk > 0 => e.lk = lkc
              /\ lkc' = IF e.lk > 0 THEN lkc + 1 ELSE lkc
              /\ cur' = [cur EXCEPT ![t] = @ + 1]
              /\ Match(t, e)
              /\ TLCSet(0, IF Consumed + 1 > TLCGet(0) THEN Consumed + 1 ELSE TLCGet(0))

\* the model actions no event logs
Free ==
    /\ UNCHANGED <<cur, lkc>>
    /\ \/ \E t \in Tasks : Flush(t)
       \/ RcuFree("B")
       \/ \E t \in Tasks : PutEnter(t) \/ PutLock(t) \/ PutMb(t) \/ PutDec(t) \/ PutSum(t)
       \/ \E t \in Walkers : WStart(t) \/ WLookup(t) \/ (WL1(t) /\ seqv = sq[t]) \/ WL2(t) \/ WMb(t)
                             \/ (WL4(t) /\ seqv # sq[t]) \/ WLock(t) \/ WUse(t)
       \/ \E t \in Holders : HPut(t) \/ HDone(t) \/ HMigrate(t)
       \/ ULock \/ UMb \/ USum \/ (UBusy /\ acc[U] <= Allow(um)) \/ UUnlock \/ UNsUnlock
       \/ UPeek \/ UPeekMb \/ UPeekSum \/ (UPeekCheck /\ um = "B") \/ UPeekUnlock
       \/ (UQueue /\ "A" \notin fin) \/ UHeldNext

TraceNext == Logged \/ Free

TraceSpec == TraceInit /\ [][TraceNext]_tvars

\* a terminal state that is not acceptance is only a report, not an error
TraceAccepted ==
    IF TLCGet(0) = NEv
    THEN PrintT(<<"ACCEPTED", Cfg.id, "events", NEv>>)
    ELSE PrintT(<<"REJECTED", Cfg.id, "consumed", TLCGet(0), "of", NEv,
                  "next events per task", [t \in TTasks |-> IF Len(Evs(t)) = 0 THEN "-" ELSE Evs(t)[1].ev]>>) /\ FALSE

=============================================================================

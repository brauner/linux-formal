--------------------------- MODULE RangeCloseRace ---------------------------
(***************************************************************************)
(* __range_close() in place while the other threads of the process open,  *)
(* install, close and re-flag descriptors in the shared table.  The walk   *)
(* starts one past the last descriptor it may close and asks               *)
(* last_fd_to_close() for the highest selected open descriptor below its   *)
(* bound, which then comes down to that descriptor.  It drops file_lock    *)
(* around filp_close_sync() and re-reads the table afterwards; the bound   *)
(* it computed at the start only ever comes down.  The model lets the      *)
(* others run between any two iterations, which is more than the kernel    *)
(* allows.                                                                 *)
(*                                                                         *)
(* MUTATION = "no_range_mask" takes dup_fd_dropped_word() out of           *)
(* last_fd_to_close(): the walk then closes what the range and the flags   *)
(* keep.                                                                   *)
(***************************************************************************)
EXTENDS FdTable

CONSTANTS NWords

VARIABLES table, range, flags, pc, n, ok
vars == <<table, range, flags, pc, n, ok>>

LoopFlags == {f \in ValidFlags : ~f.unshare /\ ~f.cloexec}  \* the combinations that walk
Ranges == RangesUpTo(W * NWords)

Init ==
    /\ table \in Table(W)      \* one word to start with, it can grow to NWords
    /\ range \in Ranges
    /\ flags \in LoopFlags
    /\ pc = "start" /\ n = 0 /\ ok = TRUE

(* the bound, computed once under the lock *)
Start ==
    /\ pc = "start"
    /\ n' = WalkStart(table, range, flags)
    /\ pc' = "scan"
    /\ UNCHANGED <<table, range, flags, ok>>

(* one iteration under the lock: find the highest descriptor to close below the
   bound, bring the bound down to it, take it out of the table *)
Scan ==
    /\ pc = "scan"
    /\ LET fd == LastFdToClose(table, n, range, flags) IN
       IF fd >= n
       THEN pc' = "done" /\ UNCHANGED <<table, n, ok>>
       ELSE /\ n' = fd
            /\ IF table[fd].file
               THEN /\ table' = CloseSlot(table, fd)
                    /\ ok' = (ok /\ Selected(table, range, flags, fd))
                    /\ pc' = "closing"
               ELSE /\ pc' = "scan"
                    /\ UNCHANGED <<table, ok>>
    /\ UNCHANGED <<range, flags>>

(* filp_close_sync() outside the lock *)
FilpClose == pc = "closing" /\ pc' = "scan" /\ UNCHANGED <<table, range, flags, n, ok>>

(* the rest of the process *)
Grow ==      \* expand_fdtable()
    /\ MaxFds(table) < W * NWords
    /\ table' = [d \in 0..(MaxFds(table) + W - 1) |-> IF d \in DOMAIN table THEN table[d] ELSE Free]
    /\ UNCHANGED <<range, flags, pc, n, ok>>
Open ==      \* alloc_fd(): the lowest free slot, close-on-exec or not
    \E b \in BOOLEAN :
        LET free == {d \in DOMAIN table : ~table[d].open} IN
        /\ free # {}
        /\ table' = [table EXCEPT ![SetMin(free)] = [open |-> TRUE, file |-> FALSE, cloexec |-> b]]
        /\ UNCHANGED <<range, flags, pc, n, ok>>
Install ==   \* fd_install()
    \E d \in DOMAIN table :
        /\ table[d].open /\ ~table[d].file
        /\ table' = [table EXCEPT ![d].file = TRUE]
        /\ UNCHANGED <<range, flags, pc, n, ok>>
Close ==     \* close()
    \E d \in DOMAIN table :
        /\ table[d].file
        /\ table' = CloseSlot(table, d)
        /\ UNCHANGED <<range, flags, pc, n, ok>>
SetFd ==     \* fcntl(F_SETFD)
    \E d \in DOMAIN table :
        /\ table[d].file
        /\ table' = [table EXCEPT ![d].cloexec = ~table[d].cloexec]
        /\ UNCHANGED <<range, flags, pc, n, ok>>

Next == Start \/ Scan \/ FilpClose \/ Grow \/ Open \/ Install \/ Close \/ SetFd
Spec == Init /\ [][Next]_vars /\ WF_vars(Start) /\ WF_vars(Scan) /\ WF_vars(FilpClose)

TypeOK ==
    /\ table \in UNION {Table(W * k) : k \in 1..NWords}
    /\ pc \in {"start", "scan", "closing", "done"}
    /\ n \in 0..(W * NWords)
(* every descriptor the walk closes is one the range and the flags select at that moment *)
ClosedOnlySelected == ok
(* the bound computed at the start stays inside the table, which never shrinks *)
Bounded == pc \in {"scan", "closing"} => n <= MaxFds(table)
(* the walk ends whatever the other threads do *)
Terminates == <>(pc = "done")

=============================================================================

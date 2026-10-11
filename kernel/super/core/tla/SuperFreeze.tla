---------------------------- MODULE SuperFreeze ----------------------------
(***************************************************************************)
(* The freeze protocol of one superblock, fs/super.c at fc1c25014ff8.     *)
(*                                                                         *)
(* freeze_super() with its sb_rdonly() shortcut, the drop of s_umount     *)
(* around sb_wait_write(SB_FREEZE_WRITE), wait_for_partially_frozen()      *)
(* (killable, re-checks s_writers.frozen), the sync_filesystem() and       *)
(* ->freeze_fs() failures; thaw_super_locked() with the shortcut on        *)
(* sb_rdonly(), the ->unfreeze_fs() failure and the freeze_inc() that      *)
(* undoes its freeze_dec(); may_freeze()/may_unfreeze() for                *)
(* FREEZE_HOLDER_USERSPACE, FREEZE_HOLDER_KERNEL, FREEZE_MAY_NEST and      *)
(* FREEZE_EXCL with its owner; the single active reference all freezers    *)
(* share; the three percpu rwsems of s_writers with writers holding them   *)
(* for read; reconfigure_super()'s refusal while frozen; umount            *)
(* (deactivate_super() of the mount's reference); the emergency thaw's     *)
(* thaw_super_locked(FREEZE_HOLDER_USERSPACE) under get_active_super();    *)
(* filesystems that set SB_RDONLY on an error without s_umount.            *)
(*                                                                         *)
(* Freezer kinds and the callers they stand for:                           *)
(*   "user"   FIFREEZE/FITHAW (fs/ioctl.c): FREEZE_HOLDER_USERSPACE       *)
(*   "bdev"   fs_bdev_freeze()/fs_bdev_thaw() through fs_super_freeze()/  *)
(*            fs_super_thaw(): FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE,  *)
(*            the superblock pinned by get_active_super()                  *)
(*   "kernel" xchk_fsfreeze(), btrfs_ioctl_shutdown(), f2fs_resize_fs():  *)
(*            FREEZE_HOLDER_KERNEL                                         *)
(*   "excl"   filesystems_freeze()/filesystems_thaw():                    *)
(*            FREEZE_EXCL | FREEZE_HOLDER_KERNEL with an owner, pinned by  *)
(*            get_active_super()                                           *)
(* Rogues thaw without having frozen (FITHAW from another process, or a   *)
(* buggy kernel caller).                                                   *)
(*                                                                         *)
(* Memory model: sequentially consistent, except with WEAK_WAKE, where     *)
(* the s_umount holder's stores to s_writers.frozen sit in a store buffer  *)
(* until a full barrier, the release of s_umount, or an arbitrary drain.  *)
(* Only the condition of wait_var_event_killable() in                     *)
(* wait_for_partially_frozen() (and, with HAS_QWAIT, in quotactl_block()  *)
(* as changed after fc1c25014ff8) reads frozen without s_umount, so that  *)
(* is where a stale value can be seen; wake_up_var() looks at the wait    *)
(* queue without a lock (waitqueue_active()).                             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Freezers,       \* freezer tasks
    FKind,          \* [Freezers -> {"user", "bdev", "kernel", "excl"}]
    Rogues,         \* tasks that thaw without a freeze of their own
    RKind,          \* [Rogues -> {"user", "kernel"}]
    Writers,        \* tasks holding a freeze level for read
    WLevel,         \* [Writers -> 1..3]: sb_start_write/_pagefault/_intwrite
    WUmount,        \* [Writers -> BOOLEAN]: takes s_umount with its level held
    HAS_UMOUNT,     \* the mount's active reference is dropped
    HAS_REMOUNT,    \* one reconfigure_super() flipping SB_RDONLY
    HAS_ETHAW,      \* the emergency thaw's thaw_super_locked(USERSPACE)
    HAS_QWAIT,      \* quotactl_block() as changed by "quota: really wait for the thaw in quotactl_block()" after
                    \* fc1c25014ff8: wait_var_event_killable(frozen == SB_UNFROZEN)
    ASYNC_RO,       \* an error sets SB_RDONLY without s_umount (fat, exfat, ...)
    RO_INIT,        \* the superblock starts read-only
    SYNC_FAIL,      \* sync_filesystem() in freeze_super() may fail
    FREEZEFS_FAIL,  \* ->freeze_fs() may fail
    UNFREEZE_FAIL,  \* ->unfreeze_fs() may fail
    KILLABLE,       \* a fatal signal can end wait_for_partially_frozen()
    WEAK_WAKE,      \* stores to frozen are buffered (see above)
    SBW_BARRIER,    \* percpu_down_write()'s atomic_xchg() is a full barrier
    FIX_DROP_UMOUNT,     \* freeze_super() drops s_umount around sb_wait_write(SB_FREEZE_WRITE)
    FIX_NESTED_THAW_RET, \* fe967191e585: a nested thaw that dropped its hold returns 0
    FIX_EXCL_OWNER,      \* may_unfreeze() refuses a KERNEL thaw of the owner's last kernel hold
    FIX_RO_RECORD,       \* proposed: thaw by how the freeze was taken, not by sb_rdonly()
    FIX_WAKE_MB          \* proposed: smp_mb() between the store to frozen and wake_up_var()

UNF == 0  WR == 1  PF == 2  FSL == 3  COMP == 4
Levels == 1..3
Extra == (IF HAS_UMOUNT THEN {"U"} ELSE {}) \cup (IF HAS_REMOUNT THEN {"M"} ELSE {})
         \cup (IF HAS_ETHAW THEN {"E"} ELSE {}) \cup (IF ASYNC_RO THEN {"A"} ELSE {})
         \cup (IF HAS_QWAIT THEN {"Q"} ELSE {})
Procs == Freezers \cup Rogues \cup Writers \cup Extra
NoOne == "none"

KindWho(k) ==
    CASE k = "user"   -> [k |-> FALSE, u |-> TRUE,  nest |-> FALSE, excl |-> FALSE]
      [] k = "bdev"   -> [k |-> FALSE, u |-> TRUE,  nest |-> TRUE,  excl |-> FALSE]
      [] k = "kernel" -> [k |-> TRUE,  u |-> FALSE, nest |-> FALSE, excl |-> FALSE]
      [] k = "excl"   -> [k |-> TRUE,  u |-> FALSE, nest |-> FALSE, excl |-> TRUE]
Who(p) == CASE p \in Freezers -> KindWho(FKind[p])
            [] p \in Rogues   -> KindWho(RKind[p])
            [] OTHER          -> KindWho("user")          \* the emergency thaw
Own(p) == IF p \in Freezers /\ FKind[p] = "excl" THEN p ELSE NoOne
Pinned(p) == p \in Freezers /\ FKind[p] \in {"bdev", "excl"}   \* get_active_super() first

VARIABLES
    sb,     \* the superblock, its locks and the wait queue of s_writers.frozen
    pc,     \* [Procs -> label]
    pv,     \* [Procs -> per-task record]
    err     \* "" or what went wrong in a way the kernel WARNs about

vars == <<sb, pc, pv, err>>

PvInit == [ret |-> "ok", cont |-> "unlock", nxt |-> "done", killed |-> FALSE,
           granted |-> FALSE, belief |-> FALSE, tmp |-> 0, old |-> UNF]

Init ==
    /\ sb = [frozen |-> UNF, fvis |-> UNF, kcount |-> 0, ucount |-> 0, owner |-> NoOne,
             frozenRO |-> FALSE, active |-> 1, mounted |-> TRUE, dying |-> FALSE,
             sharedRef |-> 0, rdonly |-> RO_INIT, um |-> NoOne,
             wpend |-> [l \in Levels |-> FALSE], wheld |-> [l \in Levels |-> FALSE],
             readers |-> [l \in Levels |-> {}],
             waitq |-> {}, pend |-> {}, wk |-> {}]
    /\ pc = [p \in Procs |->
               CASE p \in Freezers -> (IF Pinned(p) THEN "f_gas" ELSE "f_lock")
                 [] p \in Rogues   -> "r_lock"
                 [] p \in Writers  -> "w_start"
                 [] p = "U" -> "u_go"
                 [] p = "M" -> "m_go"
                 [] p = "E" -> "e_gas"
                 [] p = "A" -> "a_go"
                 [] p = "Q" -> "q_lock"]
    /\ pv = [p \in Procs |-> PvInit]
    /\ err = ""

(* ---- helpers ------------------------------------------------------------ *)

Inc(s, w) == [s EXCEPT !.kcount = IF w.k THEN @ + 1 ELSE @, !.ucount = IF w.u THEN @ + 1 ELSE @]
Dec(s, w) == [s EXCEPT !.kcount = IF w.k /\ @ > 0 THEN @ - 1 ELSE @,
                       !.ucount = IF w.u /\ @ > 0 THEN @ - 1 ELSE @]

\* may_freeze(), called by freeze_super() only when SB_FREEZE_COMPLETE
MayFreeze(s, w, own) ==
    IF w.excl
    THEN IF s.owner # NoOne THEN [ok |-> FALSE, owner |-> s.owner]
         ELSE [ok |-> TRUE, owner |-> IF s.kcount + s.ucount > 0 THEN own ELSE s.owner]
    ELSE IF w.k THEN [ok |-> w.nest \/ s.kcount = 0, owner |-> s.owner]
    ELSE [ok |-> w.nest \/ s.ucount = 0, owner |-> s.owner]

\* may_unfreeze()
MayUnfreeze(s, w, own) ==
    IF w.excl
    THEN IF s.kcount = 0 \/ s.owner = NoOne \/ s.owner # own
         THEN [ok |-> FALSE, owner |-> s.owner]
         ELSE [ok |-> TRUE, owner |-> IF s.kcount + s.ucount > 1 THEN NoOne ELSE s.owner]
    ELSE IF w.k
    THEN IF FIX_EXCL_OWNER /\ s.kcount = 1 /\ s.owner # NoOne
         THEN [ok |-> FALSE, owner |-> s.owner]
         ELSE [ok |-> s.kcount > 0, owner |-> s.owner]
    ELSE [ok |-> s.ucount > 0, owner |-> s.owner]

\* a store to s_writers.frozen by the s_umount holder p
StoreF(s, p, v, wake) ==
    IF WEAK_WAKE
    THEN [s EXCEPT !.frozen = v, !.pend = @ \cup {p}, !.wk = IF wake THEN @ \cup {p} ELSE @]
    ELSE [s EXCEPT !.frozen = v, !.fvis = v]
Flushed(s, p) == IF p \in s.pend THEN [s EXCEPT !.fvis = s.frozen, !.pend = @ \ {p}] ELSE s

\* wake_up_var(&sb->s_writers.frozen): every queued waiter re-runs its check
Woken(pc1, s) == [q \in Procs |-> IF q \in s.waitq THEN (IF q = "Q" THEN "q_wait" ELSE "fw_enq")
                                   ELSE pc1[q]]

\* the release at the end of a section: up_write(&sb->s_umount), possibly
\* through deactivate_locked_super() (never the last reference here)
RelSb(s, p, c) ==
    LET s1 == [Flushed(s, p) EXCEPT !.um = NoOne] IN
    CASE c = "unlock"      -> s1
      [] c = "drop_tmp"    -> [s1 EXCEPT !.active = @ - 1]
      [] c = "to_shared"   -> [s1 EXCEPT !.sharedRef = 1]
      [] c = "drop_shared" -> [s1 EXCEPT !.active = @ - 1, !.sharedRef = 0]
RelTmp(c) == IF c \in {"drop_tmp", "to_shared"} THEN 1 ELSE 0
RelErr(s, c) == IF c \in {"drop_tmp", "drop_shared"} /\ s.active <= 1
                THEN "deactivate_locked_super() in freeze/thaw dropped the last reference" ELSE ""

\* A waking store followed by its release.  Without WEAK_WAKE the store,
\* wake_up_var() and the release are one step; with it the task goes
\* through "wake" and "rel".  s is the state after the store; nxt the
\* label after the release; pr the per-task record after the store.
WakeRel(p, s, c, nxt, pr) ==
    IF WEAK_WAKE
    THEN /\ sb' = s
         /\ pc' = [pc EXCEPT ![p] = "wake"]
         /\ pv' = [pv EXCEPT ![p] = [pr EXCEPT !.cont = c, !.nxt = nxt]]
         /\ UNCHANGED err
    ELSE /\ sb' = [RelSb(s, p, c) EXCEPT !.waitq = {}]
         /\ pc' = [Woken(pc, s) EXCEPT ![p] = nxt]
         /\ pv' = [pv EXCEPT ![p] = [pr EXCEPT !.tmp = @ - RelTmp(c)]]
         /\ err' = RelErr(s, c)

\* a release without a wake (no store to frozen in the section)
PlainRel(p, s, c, nxt, pr) ==
    /\ sb' = RelSb(s, p, c)
    /\ pc' = [pc EXCEPT ![p] = nxt]
    /\ pv' = [pv EXCEPT ![p] = [pr EXCEPT !.tmp = @ - RelTmp(c)]]
    /\ err' = RelErr(s, c)

\* kill_sb() for the last active reference: generic_shutdown_super()
\* (SB_DYING), kill_super_notify() (SB_DEAD)
Killed(s) == [s EXCEPT !.active = 0, !.dying = TRUE]
KillErr(s) == IF s.frozen # UNF \/ s.kcount + s.ucount > 0 THEN "killed a frozen superblock" ELSE ""

(* ---- the store buffer ---------------------------------------------------- *)

Flush(p) ==
    /\ p \in sb.pend
    /\ sb' = Flushed(sb, p)
    /\ UNCHANGED <<pc, pv, err>>

\* wake_up_var() of a task with a buffered store: waitqueue_active() reads
\* the queue; with FIX_WAKE_MB an smp_mb() drains the store first
WakeStep(p) ==
    /\ pc[p] = "wake"
    /\ LET s1 == IF FIX_WAKE_MB THEN Flushed(sb, p) ELSE sb IN
       /\ sb' = [s1 EXCEPT !.waitq = {}, !.wk = @ \ {p}]
       /\ pc' = [Woken(pc, s1) EXCEPT ![p] = "rel"]
    /\ UNCHANGED <<pv, err>>

RelStep(p) ==
    /\ pc[p] = "rel"
    /\ sb' = RelSb(sb, p, pv[p].cont)
    /\ pc' = [pc EXCEPT ![p] = pv[p].nxt]
    /\ pv' = [pv EXCEPT ![p].tmp = @ - RelTmp(pv[p].cont)]
    /\ err' = RelErr(sb, pv[p].cont)

(* ---- deactivate_super() of a task's own reference ------------------------- *)

Deact(p, nxt) ==
    /\ IF sb.active > 1
       THEN sb' = [sb EXCEPT !.active = @ - 1] /\ UNCHANGED err
       ELSE /\ sb.um = NoOne
            /\ sb' = Killed(sb)
            /\ err' = KillErr(sb)
    /\ pc' = [pc EXCEPT ![p] = nxt]
    /\ pv' = [pv EXCEPT ![p].tmp = @ - 1]

(* ---- freeze_super() --------------------------------------------------------- *)

AfterFreeze(p, r) == IF Pinned(p) THEN "f_put" ELSE IF r = "ok" THEN "f_hold" ELSE "done"

\* get_active_super(): super_lock_excl() (fails on SB_DYING), atomic_inc_not_zero()
FGas(f) ==
    /\ pc[f] = "f_gas"
    /\ IF sb.dying
       THEN /\ pc' = [pc EXCEPT ![f] = "done"]
            /\ pv' = [pv EXCEPT ![f].ret = "skip"]
            /\ UNCHANGED <<sb, err>>
       ELSE /\ sb.um = NoOne
            /\ sb' = [sb EXCEPT !.active = @ + 1]
            /\ pv' = [pv EXCEPT ![f].tmp = @ + 1]
            /\ pc' = [pc EXCEPT ![f] = "f_lock"]
            /\ UNCHANGED err

\* super_lock_excl(); atomic_inc(&sb->s_active)
FLock(f) ==
    /\ pc[f] = "f_lock"
    /\ IF sb.dying
       THEN /\ err' = "freeze_super() on a dying superblock"
            /\ pc' = [pc EXCEPT ![f] = "done"]
            /\ UNCHANGED <<sb, pv>>
       ELSE /\ sb.um = NoOne
            /\ sb' = [sb EXCEPT !.um = f, !.active = @ + 1]
            /\ pv' = [pv EXCEPT ![f].tmp = @ + 1]
            /\ pc' = [pc EXCEPT ![f] = "f_check"]
            /\ UNCHANGED err

\* retry: in freeze_super(), s_umount held
FCheck(f) ==
    /\ pc[f] = "f_check"
    /\ sb.um = f
    /\ LET w == Who(f) IN
       CASE sb.frozen = COMP ->
              LET mf == MayFreeze(sb, w, Own(f))
                  s1 == IF mf.ok THEN [Inc(sb, w) EXCEPT !.owner = mf.owner] ELSE sb
                  r  == IF mf.ok THEN "ok" ELSE "EBUSY"
              IN PlainRel(f, s1, "drop_tmp", AfterFreeze(f, r),
                          [pv[f] EXCEPT !.ret = r, !.granted = mf.ok])
         [] sb.frozen \in {WR, PF, FSL} ->
              \* wait_for_partially_frozen(): sample, drop s_umount
              /\ sb' = [Flushed(sb, f) EXCEPT !.um = NoOne]
              /\ pv' = [pv EXCEPT ![f].old = sb.frozen]
              /\ pc' = [pc EXCEPT ![f] = "fw_enq"]
              /\ UNCHANGED err
         [] sb.frozen = UNF /\ sb.rdonly ->
              \* the sb_rdonly() shortcut
              WakeRel(f, StoreF([Inc(sb, w) EXCEPT !.owner = Own(f), !.frozenRO = TRUE], f, COMP, TRUE),
                      "to_shared", AfterFreeze(f, "ok"), [pv[f] EXCEPT !.ret = "ok", !.granted = TRUE])
         [] sb.frozen = UNF /\ ~sb.rdonly ->
              \* SB_FREEZE_WRITE, then drop s_umount (FIX_DROP_UMOUNT)
              /\ sb' = IF FIX_DROP_UMOUNT
                       THEN [Flushed(StoreF(sb, f, WR, FALSE), f) EXCEPT !.um = NoOne]
                       ELSE StoreF(sb, f, WR, FALSE)
              /\ pc' = [pc EXCEPT ![f] = "f_sw1"]
              /\ UNCHANGED <<pv, err>>

\* sb_wait_write(level): percpu_down_write() sets ->block (atomic_xchg(),
\* a full barrier), new readers block; then it waits for the readers
FSw(f, l, from, to) ==
    /\ pc[f] = from
    /\ ~sb.wpend[l] /\ ~sb.wheld[l]
    /\ sb' = [(IF SBW_BARRIER THEN Flushed(sb, f) ELSE sb) EXCEPT !.wpend[l] = TRUE]
    /\ pc' = [pc EXCEPT ![f] = to]
    /\ UNCHANGED <<pv, err>>
FSwWait(f, l, from, to) ==
    /\ pc[f] = from
    /\ sb.readers[l] = {}
    /\ sb' = [sb EXCEPT !.wpend[l] = FALSE, !.wheld[l] = TRUE]
    /\ pc' = [pc EXCEPT ![f] = to]
    /\ UNCHANGED <<pv, err>>

FSw1(f)  == FSw(f, 1, "f_sw1", "f_sw1w")
FSw1w(f) == /\ pc[f] = "f_sw1w"
            /\ sb.readers[1] = {}
            /\ IF FIX_DROP_UMOUNT
               THEN /\ sb' = [sb EXCEPT !.wpend[1] = FALSE, !.wheld[1] = TRUE]
                    /\ pc' = [pc EXCEPT ![f] = "f_relock"]
               ELSE /\ sb' = StoreF([sb EXCEPT !.wpend[1] = FALSE, !.wheld[1] = TRUE], f, PF, FALSE)
                    /\ pc' = [pc EXCEPT ![f] = "f_sw2"]
            /\ UNCHANGED <<pv, err>>
\* __super_lock_excl(); SB_FREEZE_PAGEFAULT
FRelock(f) ==
    /\ pc[f] = "f_relock"
    /\ sb.um = NoOne
    /\ sb' = StoreF([sb EXCEPT !.um = f], f, PF, FALSE)
    /\ pc' = [pc EXCEPT ![f] = "f_sw2"]
    /\ UNCHANGED <<pv, err>>
FSw2(f)  == FSw(f, 2, "f_sw2", "f_sw2w")
FSw2w(f) == FSwWait(f, 2, "f_sw2w", "f_sync")

\* sync_filesystem(): on failure SB_UNFROZEN, sb_freeze_unlock(SB_FREEZE_PAGEFAULT),
\* wake_up_var(), deactivate_locked_super()
FSync(f) ==
    /\ pc[f] = "f_sync"
    /\ \/ /\ sb' = StoreF(sb, f, FSL, FALSE)
          /\ pc' = [pc EXCEPT ![f] = "f_sw3"]
          /\ UNCHANGED <<pv, err>>
       \/ /\ SYNC_FAIL
          /\ WakeRel(f, StoreF([sb EXCEPT !.wheld = [l \in Levels |-> IF l <= 2 THEN FALSE ELSE @[l]]],
                               f, UNF, TRUE),
                     "drop_tmp", AfterFreeze(f, "EIO"), [pv[f] EXCEPT !.ret = "EIO"])
FSw3(f)  == FSw(f, 3, "f_sw3", "f_sw3w")
FSw3w(f) == FSwWait(f, 3, "f_sw3w", "f_ffs")

\* ->freeze_fs(); success: freeze_inc(), freeze_owner, SB_FREEZE_COMPLETE,
\* wake_up_var(), super_unlock_excl() (the reference becomes the shared one)
FFreezeFs(f) ==
    /\ pc[f] = "f_ffs"
    /\ \/ WakeRel(f, StoreF([Inc(sb, Who(f)) EXCEPT !.owner = Own(f), !.frozenRO = FALSE], f, COMP, TRUE),
                  "to_shared", AfterFreeze(f, "ok"), [pv[f] EXCEPT !.ret = "ok", !.granted = TRUE])
       \/ /\ FREEZEFS_FAIL
          /\ WakeRel(f, StoreF([sb EXCEPT !.wheld = [l \in Levels |-> FALSE]], f, UNF, TRUE),
                     "drop_tmp", AfterFreeze(f, "EFS"), [pv[f] EXCEPT !.ret = "EFS"])

(* ---- wait_for_partially_frozen() ----------------------------------------- *)

\* wait_var_event_killable(&frozen, frozen != old): prepare_to_wait_event()
\* queues the task (smp_mb() in set_current_state()), then the condition
FWaitEnq(f) ==
    /\ pc[f] = "fw_enq"
    /\ \/ /\ sb.fvis # pv[f].old
          /\ pc' = [pc EXCEPT ![f] = "fw_relock"]
          /\ UNCHANGED <<sb, pv, err>>
       \/ /\ sb.fvis = pv[f].old
          /\ sb' = [sb EXCEPT !.waitq = @ \cup {f}]
          /\ pc' = [pc EXCEPT ![f] = "fw_sleep"]
          /\ UNCHANGED <<pv, err>>
       \/ /\ KILLABLE /\ sb.fvis = pv[f].old
          /\ pc' = [pc EXCEPT ![f] = "fw_relock"]
          /\ pv' = [pv EXCEPT ![f].killed = TRUE]
          /\ UNCHANGED <<sb, err>>
\* a fatal signal wakes the sleeper; it re-runs the check above, which
\* ends the wait with -ERESTARTSYS only while the condition is false
FWaitKill(f) ==
    /\ pc[f] = "fw_sleep" /\ KILLABLE
    /\ sb' = [sb EXCEPT !.waitq = @ \ {f}]
    /\ pc' = [pc EXCEPT ![f] = "fw_enq"]
    /\ UNCHANGED <<pv, err>>
\* down_write(&sb->s_umount); loop while partially frozen and not killed
FWaitRelock(f) ==
    /\ pc[f] = "fw_relock"
    /\ sb.um = NoOne
    /\ CASE pv[f].killed ->
              PlainRel(f, [sb EXCEPT !.um = f], "drop_tmp", AfterFreeze(f, "EINTR"),
                       [pv[f] EXCEPT !.ret = "EINTR", !.killed = FALSE])
         [] ~pv[f].killed /\ sb.frozen \in {WR, PF, FSL} ->
              /\ pv' = [pv EXCEPT ![f].old = sb.frozen]
              /\ pc' = [pc EXCEPT ![f] = "fw_enq"]
              /\ UNCHANGED <<sb, err>>
         [] ~pv[f].killed /\ sb.frozen \in {UNF, COMP} ->
              /\ sb' = [sb EXCEPT !.um = f]
              /\ pc' = [pc EXCEPT ![f] = "f_check"]
              /\ UNCHANGED <<pv, err>>


\* deactivate_super() of get_active_super()'s reference
FPut(f) == /\ pc[f] = "f_put"
           /\ Deact(f, IF pv[f].ret = "ok" THEN "f_hold" ELSE "done")

\* the freeze is held; the caller now believes it holds it
FHold(f) ==
    /\ pc[f] = "f_hold"
    /\ pc' = [pc EXCEPT ![f] = IF Pinned(f) THEN "t_gas" ELSE "t_lock"]
    /\ pv' = [pv EXCEPT ![f].belief = TRUE]
    /\ UNCHANGED <<sb, err>>

(* ---- thaw_super() / thaw_super_locked() ------------------------------------ *)

AfterThaw(p) == CASE p \in Freezers -> (IF Pinned(p) THEN "t_put" ELSE "t_done")
                  [] p \in Rogues   -> "done"
                  [] p = "E"        -> "e_put"

\* thaw_super_locked() with s_umount just taken by p
ThawLocked(p) ==
    LET s0 == [sb EXCEPT !.um = p]
        w  == Who(p)
        mu == MayUnfreeze(s0, w, Own(p))
        s1 == [Dec(s0, w) EXCEPT !.owner = mu.owner]
        left == s1.kcount + s1.ucount
        roThaw == IF FIX_RO_RECORD THEN s0.frozenRO ELSE s0.rdonly
        nested == IF FIX_NESTED_THAW_RET THEN "ok" ELSE "EINVAL"
        own == p \in Freezers      \* only freezers carry a hold of their own
    IN
    CASE s0.frozen # COMP \/ ~mu.ok ->
           PlainRel(p, s0, "unlock", AfterThaw(p), [pv[p] EXCEPT !.ret = "EINVAL"])
      [] s0.frozen = COMP /\ mu.ok /\ left > 0 ->
           \* other freezers remain: drop our hold (fe967191e585 returns 0)
           PlainRel(p, s1, "unlock", AfterThaw(p),
                    [pv[p] EXCEPT !.ret = nested, !.granted = IF own THEN FALSE ELSE @])
      [] s0.frozen = COMP /\ mu.ok /\ left = 0 /\ roThaw ->
           \* sb_rdonly(): SB_UNFROZEN without sb_freeze_unlock()
           WakeRel(p, StoreF([s1 EXCEPT !.owner = NoOne], p, UNF, TRUE), "drop_shared", AfterThaw(p),
                   [pv[p] EXCEPT !.ret = "ok", !.granted = IF own THEN FALSE ELSE @])
      [] s0.frozen = COMP /\ mu.ok /\ left = 0 /\ ~roThaw ->
           \/ \* ->unfreeze_fs() succeeds: SB_UNFROZEN, wake_up_var(),
              \* sb_freeze_unlock(SB_FREEZE_FS), deactivate_locked_super()
              WakeRel(p, StoreF([s1 EXCEPT !.owner = NoOne, !.wheld = [l \in Levels |-> FALSE]],
                                p, UNF, TRUE),
                      "drop_shared", AfterThaw(p),
                      [pv[p] EXCEPT !.ret = "ok", !.granted = IF own THEN FALSE ELSE @])
           \/ \* ->unfreeze_fs() fails: freeze_inc() undoes the freeze_dec()
              /\ UNFREEZE_FAIL
              /\ PlainRel(p, Inc(s1, w), "unlock", AfterThaw(p), [pv[p] EXCEPT !.ret = "ETHAW"])

\* get_active_super() before the thaw (fs_bdev_thaw(), filesystems_thaw_callback())
TGas(f) ==
    /\ pc[f] = "t_gas"
    /\ IF sb.dying
       THEN /\ pc' = [pc EXCEPT ![f] = "t_done"]
            /\ pv' = [pv EXCEPT ![f].ret = "ok"]          \* skipped: nothing to thaw
            /\ UNCHANGED <<sb, err>>
       ELSE /\ sb.um = NoOne
            /\ sb' = [sb EXCEPT !.active = @ + 1]
            /\ pv' = [pv EXCEPT ![f].tmp = @ + 1]
            /\ pc' = [pc EXCEPT ![f] = "t_lock"]
            /\ UNCHANGED err

\* thaw_super(): super_lock_excl() (WARNs and fails on SB_DYING)
TLock(f) ==
    /\ pc[f] = "t_lock"
    /\ IF sb.dying
       THEN /\ err' = "thaw_super() on a dying superblock"
            /\ pc' = [pc EXCEPT ![f] = "done"]
            /\ UNCHANGED <<sb, pv>>
       ELSE /\ sb.um = NoOne
            /\ ThawLocked(f)

TPut(f) == /\ pc[f] = "t_put"
           /\ Deact(f, "t_done")

\* the caller's view: a failed thaw means the freeze is still its own; a
\* failed ->unfreeze_fs() is retried (the filesystem is still frozen)
TDone(f) ==
    /\ pc[f] = "t_done"
    /\ pc' = [pc EXCEPT ![f] = IF pv[f].ret = "ETHAW"
                                THEN (IF Pinned(f) THEN "t_gas" ELSE "t_lock")
                                ELSE "done"]
    /\ pv' = [pv EXCEPT ![f].belief = (pv[f].ret # "ok")]
    /\ UNCHANGED <<sb, err>>

Freezer(f) ==
    \/ FGas(f) \/ FLock(f) \/ FCheck(f) \/ FSw1(f) \/ FSw1w(f) \/ FRelock(f)
    \/ FSw2(f) \/ FSw2w(f) \/ FSync(f) \/ FSw3(f) \/ FSw3w(f) \/ FFreezeFs(f)
    \/ FWaitEnq(f) \/ FWaitKill(f) \/ FWaitRelock(f) \/ FPut(f) \/ FHold(f)
    \/ TGas(f) \/ TLock(f) \/ TPut(f) \/ TDone(f)

(* ---- rogue thaws, the emergency thaw --------------------------------------- *)

\* FITHAW (or a kernel thaw) from a task that holds no freeze; it has the
\* filesystem open, so the superblock is mounted and alive
Rogue(r) ==
    /\ pc[r] = "r_lock"
    /\ sb.mounted /\ ~sb.dying /\ sb.um = NoOne
    /\ ThawLocked(r)

\* do_thaw_all_callback(): get_active_super(), [the bdev_thaw() loop is in
\* SuperHolder], super_lock_excl() + thaw_super_locked(USERSPACE),
\* deactivate_super()
EGas == /\ HAS_ETHAW /\ pc["E"] = "e_gas"
        /\ IF sb.dying
           THEN pc' = [pc EXCEPT !["E"] = "done"] /\ UNCHANGED <<sb, pv, err>>
           ELSE /\ sb.um = NoOne
                /\ sb' = [sb EXCEPT !.active = @ + 1]
                /\ pv' = [pv EXCEPT !["E"].tmp = @ + 1]
                /\ pc' = [pc EXCEPT !["E"] = "e_lock"]
                /\ UNCHANGED err
ELock == /\ HAS_ETHAW /\ pc["E"] = "e_lock"
         /\ sb.um = NoOne
         /\ ThawLocked("E")
EPut == /\ HAS_ETHAW /\ pc["E"] = "e_put"
        /\ Deact("E", "done")
Emergency == EGas \/ ELock \/ EPut

(* ---- writers ----------------------------------------------------------------- *)

\* __sb_start_write(): percpu_down_read() blocks while a freezer has set
\* ->block or holds the level
WStart(w) ==
    LET l == WLevel[w] IN
    /\ pc[w] = "w_start"
    /\ sb.mounted /\ ~sb.dying
    /\ ~sb.wpend[l] /\ ~sb.wheld[l]
    /\ sb' = [sb EXCEPT !.readers[l] = @ \cup {w}]
    /\ pc' = [pc EXCEPT ![w] = IF WUmount[w] THEN "w_um" ELSE "w_end"]
    /\ UNCHANGED <<pv, err>>
\* with the level held, down_write(&sb->s_umount) and up_write() (e.g.
\* f2fs_ioc_shutdown(): mnt_want_write_file(), then f2fs_do_shutdown())
WUm(w) ==
    /\ pc[w] = "w_um"
    /\ sb.um = NoOne
    /\ pc' = [pc EXCEPT ![w] = "w_end"]
    /\ UNCHANGED <<sb, pv, err>>
WEnd(w) ==
    /\ pc[w] = "w_end"
    /\ sb' = [sb EXCEPT !.readers[WLevel[w]] = @ \ {w}]
    /\ pc' = [pc EXCEPT ![w] = "done"]
    /\ UNCHANGED <<pv, err>>
Writer(w) == WStart(w) \/ WUm(w) \/ WEnd(w)

(* ---- remount, errors, umount -------------------------------------------------- *)

\* reconfigure_super() under s_umount: -EBUSY unless SB_UNFROZEN; a
\* remount read-only fails while writers are active
\* (sb_prepare_remount_readonly())
Remount ==
    /\ HAS_REMOUNT /\ pc["M"] = "m_go"
    /\ sb.mounted /\ ~sb.dying /\ sb.um = NoOne
    /\ sb' = IF sb.frozen # UNF THEN sb
             ELSE IF sb.rdonly THEN [sb EXCEPT !.rdonly = FALSE]
             ELSE IF sb.readers[1] # {} THEN sb
             ELSE [sb EXCEPT !.rdonly = TRUE]
    /\ pc' = [pc EXCEPT !["M"] = "done"]
    /\ pv' = [pv EXCEPT !["M"].ret = IF sb.frozen # UNF THEN "EBUSY" ELSE "ok"]
    /\ UNCHANGED err

\* fat_fs_error(), exfat_fs_error(), ext2_error(), __nilfs_error(),
\* jfs_handle_error(), hfs/hfsplus/affs: sb->s_flags |= SB_RDONLY without
\* s_umount (ext4 stopped doing this in d3476f3dad4a)
AsyncRo ==
    /\ ASYNC_RO /\ pc["A"] = "a_go"
    /\ sb.mounted /\ ~sb.dying
    /\ sb' = [sb EXCEPT !.rdonly = TRUE]
    /\ pc' = [pc EXCEPT !["A"] = "done"]
    /\ UNCHANGED <<pv, err>>

\* umount: the mount's reference goes once nobody uses the mount
\* (cleanup_mnt() -> deactivate_super())
MountUsers == Writers \cup Rogues \cup {f \in Freezers : FKind[f] \in {"user", "kernel"}}
              \cup ({"M", "A"} \cap Procs)
Umount ==
    /\ HAS_UMOUNT /\ pc["U"] = "u_go"
    /\ sb.mounted
    /\ \A p \in MountUsers : pc[p] = "done"
    /\ IF sb.active > 1
       THEN sb' = [sb EXCEPT !.active = @ - 1, !.mounted = FALSE] /\ UNCHANGED err
       ELSE /\ sb.um = NoOne
            /\ sb' = [Killed(sb) EXCEPT !.mounted = FALSE]
            /\ err' = KillErr(sb)
    /\ pc' = [pc EXCEPT !["U"] = "done"]
    /\ UNCHANGED pv

\* quotactl_block() for a write command, as changed by "quota: really wait for the thaw in quotactl_block()" after
\* fc1c25014ff8: user_get_super() (s_umount, a passive reference), and while
\* not SB_UNFROZEN drop s_umount and wait_var_event_killable(&frozen,
\* frozen == SB_UNFROZEN), then retry.  (At fc1c25014ff8 it waited with
\* sb_start_write()/sb_end_write() and spun on a superblock frozen by the
\* sb_rdonly() shortcut.)
QLock ==
    /\ HAS_QWAIT /\ pc["Q"] = "q_lock"
    /\ IF sb.dying
       THEN pc' = [pc EXCEPT !["Q"] = "done"] /\ UNCHANGED <<sb, pv, err>>
       ELSE /\ sb.um = NoOne
            /\ pc' = [pc EXCEPT !["Q"] = IF sb.frozen = UNF THEN "done" ELSE "q_wait"]
            /\ UNCHANGED <<sb, pv, err>>
QWait ==
    /\ HAS_QWAIT /\ pc["Q"] = "q_wait"
    /\ \/ /\ sb.fvis = UNF
          /\ pc' = [pc EXCEPT !["Q"] = "q_lock"]
          /\ UNCHANGED <<sb, pv, err>>
       \/ /\ sb.fvis # UNF
          /\ sb' = [sb EXCEPT !.waitq = @ \cup {"Q"}]
          /\ pc' = [pc EXCEPT !["Q"] = "q_sleep"]
          /\ UNCHANGED <<pv, err>>
       \/ /\ KILLABLE /\ sb.fvis # UNF
          /\ pc' = [pc EXCEPT !["Q"] = "done"]
          /\ pv' = [pv EXCEPT !["Q"].ret = "EINTR"]
          /\ UNCHANGED <<sb, err>>
QKill ==
    /\ HAS_QWAIT /\ KILLABLE /\ pc["Q"] = "q_sleep"
    /\ sb' = [sb EXCEPT !.waitq = @ \ {"Q"}]
    /\ pc' = [pc EXCEPT !["Q"] = "q_wait"]
    /\ UNCHANGED <<pv, err>>

(* ---- the specification ------------------------------------------------------- *)

Done == \A p \in Procs : pc[p] = "done"

Next ==
    \/ \E f \in Freezers : Freezer(f)
    \/ \E r \in Rogues : Rogue(r)
    \/ \E w \in Writers : Writer(w)
    \/ \E p \in Procs : Flush(p) \/ WakeStep(p) \/ RelStep(p)
    \/ EGas \/ ELock \/ EPut
    \/ Remount
    \/ AsyncRo
    \/ Umount
    \/ QLock \/ QWait \/ QKill
    \/ (Done /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

(* ---- invariants ----------------------------------------------------------------- *)

RECURSIVE SumOver(_, _)
SumOver(F, S) == IF S = {} THEN 0 ELSE LET x == CHOOSE y \in S : TRUE IN F[x] + SumOver(F, S \ {x})
SumTmp == SumOver([p \in Procs |-> pv[p].tmp], Procs)

NoErr == err = ""

\* frozen = SB_FREEZE_COMPLETE exactly while a freeze is held
CountsOK == (sb.frozen = COMP) <=> (sb.kcount + sb.ucount > 0)

\* the counters are the holds the kernel granted and did not take back
HoldsOK ==
    /\ sb.kcount = Cardinality({f \in Freezers : pv[f].granted /\ Who(f).k})
    /\ sb.ucount = Cardinality({f \in Freezers : pv[f].granted /\ Who(f).u})

\* what a caller was told matches what it holds
BeliefOK == \A f \in Freezers : pc[f] = "done" => pv[f].belief = pv[f].granted

\* s_active is the mount, the tasks' own references and the one reference
\* all freezers share, which exists exactly while SB_FREEZE_COMPLETE
ActiveOK ==
    /\ sb.active = (IF sb.mounted THEN 1 ELSE 0) + SumTmp + sb.sharedRef
    /\ sb.um = NoOne => ((sb.sharedRef = 1) <=> (sb.frozen = COMP))

\* an exclusive freeze stays its owner's
ExclOK == \A x \in Freezers :
             (FKind[x] = "excl" /\ pv[x].granted) => (sb.owner = x /\ sb.kcount >= 1)

\* nothing frozen dies
DeadOK == sb.dying => /\ sb.frozen = UNF /\ sb.kcount + sb.ucount = 0
                      /\ sb.sharedRef = 0 /\ \A l \in Levels : ~sb.wheld[l]

\* the levels are held exactly by a full freeze
RwsemOK ==
    /\ sb.frozen = UNF => \A l \in Levels : ~sb.wheld[l] /\ ~sb.wpend[l]
    /\ sb.frozen = COMP => \A l \in Levels : sb.wheld[l] = ~sb.frozenRO

\* a task asleep in wait_for_partially_frozen() whose condition holds will
\* be woken: a store with its wake_up_var() is still to come
MidFreeze == {"f_sw1", "f_sw1w", "f_relock", "f_sw2", "f_sw2w", "f_sync", "f_sw3", "f_sw3w", "f_ffs"}
NoLostWakeup ==
    /\ \A f \in Freezers :
          pc[f] = "fw_sleep" =>
              \/ sb.fvis = pv[f].old
              \/ sb.wk # {}
              \/ \E q \in Freezers : pc[q] \in MidFreeze
    /\ HAS_QWAIT =>
          (pc["Q"] = "q_sleep" =>
              \/ sb.fvis # UNF
              \/ sb.wk # {}
              \/ \E q \in Freezers : pc[q] \in MidFreeze)

=============================================================================

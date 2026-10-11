------------------------------ MODULE SuperLife ------------------------------
(***************************************************************************)
(* The superblock lifecycle of fs/super.c (work.super.fixes at            *)
(* fc1c25014ff8): allocation, publication on super_blocks and fs_supers,  *)
(* SB_BORN, SB_DYING, SB_DEAD, s_active, s_passive (refcount_t), s_umount *)
(* (an rwsem), sb_lock (a spinlock), the RCU-delayed free, and the tasks  *)
(* that find superblocks without owning them.                             *)
(*                                                                         *)
(* Tasks:                                                                  *)
(*   mounters  sget_fc() L839: under sb_lock walk fs_supers, skip SB_DEAD, *)
(*             test() (which may dereference s_fs_info); no match: drop   *)
(*             sb_lock, alloc_super() (s_umount held, s_passive 1,        *)
(*             s_active 1), retry; still no match: set() (s_fs_info, the  *)
(*             device-table entry registered with its passive reference), *)
(*             publish on both lists, shrinker_register(); a match:       *)
(*             grab_super() L632 (passive reference under sb_lock,        *)
(*             super_lock_excl() waits for SB_BORN|SB_DYING, then         *)
(*             atomic_inc_not_zero(s_active), else wait for SB_DEAD and   *)
(*             retry) and destroy_unused_super() of the own allocation.   *)
(*             Then fill_super() (success: vfs_get_tree() SB_BORN,        *)
(*             fc_mount() up_write(); failure: deactivate_locked_super()) *)
(*             and the unmount: deactivate_super() L610 ->                *)
(*             deactivate_locked_super() L581: shrinker_free(), ->kill_sb *)
(*             = generic_shutdown_super() (SB_DYING, s_umount dropped)    *)
(*             with kill_super_notify() early (KILL "anon":               *)
(*             kill_anon_super() L1360) or not (KILL "block"), the        *)
(*             filesystem freeing s_fs_info, kill_super_notify() (the     *)
(*             entry's claim, SB_DEAD under sb_lock), put_super() L419    *)
(*             (at zero: unlink from both lists under sb_lock, call_rcu)  *)
(*   iterator  __iterate_supers() L958 over super_blocks (ITER "all") or  *)
(*             iterate_supers_type() L1008 over fs_supers (ITER "type"):  *)
(*             under sb_lock skip SB_DYING, refcount_inc_not_zero(),      *)
(*             drop sb_lock, super_lock() shared, the callback, unlock,   *)
(*             put_super() of the previous one, retake sb_lock, advance   *)
(*             from the current node                                      *)
(*   ugs       user_get_super() L1043 through the target superblock's     *)
(*             device-table entry: pin it (inc_not_zero under RCU),       *)
(*             super_lock(), refcount_inc(s_passive), drop the pin, use,  *)
(*             drop_super()                                               *)
(*   shrinker  super_cache_scan() L181 (super_trylock_shared() without a  *)
(*             reference) or super_cache_count() L238 (SB_BORN read       *)
(*             without locks) on a registered shrinker; shrinker_free()   *)
(*             waits for callbacks in flight                              *)
(*                                                                         *)
(* Waits (wait_var_event()) are modelled as enabling conditions on        *)
(* monotonic flags: a waiter can be stuck only if the flag is never set,  *)
(* which TLC reports as a deadlock (the models end in a stuttering        *)
(* Finished state).                                                       *)
(*                                                                         *)
(* Mutations (each FIX_* off is a known-bad or earlier shape):             *)
(*   FIX_DEAD_SKIP    off: sget_fc() does not skip SB_DEAD superblocks     *)
(*   FIX_DEAD_LOCK    off: kill_super_notify() sets SB_DEAD without sb_lock *)
(*   FIX_UNLINK_LATE  off: fs_supers is unlinked in kill_super_notify()    *)
(*                    (the shape before 2d2a2d7aa987)                      *)
(*   FIX_ITER_PIN     off: the iterator drops the current superblock       *)
(*                    before it advances from it                           *)
(*   FIX_SHRINK_FIRST off: shrinker_free() after ->kill_sb()               *)
(*   FIX_RCU_SB       off: put_super() frees right away (no call_rcu())    *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Mnt,             \* mounter tasks
    MntSb,           \* [Mnt -> Sbs]: the superblock slot alloc_super() gives each mounter
    Umount,          \* [Mnt -> BOOLEAN]: the mounter unmounts again
    FillFail,        \* [Mnt -> BOOLEAN]: fill_super() may fail
    TEST,            \* "single" (get_tree_single(): test() always matches), "none" (get_tree_nodev()),
                     \* "keyed" (get_tree_keyed()-like: matches the superblocks of mounters with the same Key)
    Key,             \* [Mnt -> Nat]: the key of each mounter (TEST "keyed")
    TEST_DEREF,      \* test() dereferences s_fs_info
    KILL,            \* "anon": kill_anon_super() notifies before the fs frees s_fs_info;
                     \* "block": the fs frees s_fs_info, deactivate_locked_super() notifies
    ITER,            \* "none", "all" (__iterate_supers()), "type" (iterate_supers_type())
    UGS,             \* "none" or the superblock user_get_super() looks for
    SHRINK,          \* the number of shrinker callbacks to run (0: no shrinker task)
    FIX_DEAD_SKIP,
    FIX_DEAD_LOCK,
    FIX_UNLINK_LATE,
    FIX_ITER_PIN,
    FIX_SHRINK_FIRST,
    FIX_RCU_SB

NIL == "nil"
Sbs == {MntSb[m] : m \in Mnt}
IterP == IF ITER = "none" THEN {} ELSE {"it"}
UgsP == IF UGS = "none" THEN {} ELSE {"ug"}
ShrP == IF SHRINK = 0 THEN {} ELSE {"sh"}
Procs == Mnt \cup IterP \cup UgsP \cup ShrP
NoOne == "noone"
Owner(s) == CHOOSE m \in Mnt : MntSb[m] = s
Matches(m, o) == TEST = "single" \/ (TEST = "keyed" /\ Key[m] = Key[Owner(o)])

ASSUME /\ \A m \in Mnt : Umount[m] \in BOOLEAN /\ FillFail[m] \in BOOLEAN
       /\ \A m, n \in Mnt : m # n => MntSb[m] # MntSb[n]
       /\ TEST \in {"single", "none", "keyed"} /\ TEST_DEREF \in BOOLEAN
       /\ \A m \in Mnt : Key[m] \in Nat
       /\ KILL \in {"anon", "block"}
       /\ ITER \in {"none", "all", "type"}
       /\ UGS = "none" \/ UGS \in Sbs
       /\ SHRINK \in Nat
       /\ Mnt \cap {"it", "ug", "sh"} = {}

VARIABLES
    L,        \* [Procs -> locals]: pc, ret (return of put_super()), ps (the sb put_super() puts),
              \* s (the mounter's own allocation / the sb a task works on), old (sget_fc()'s
              \* match), idx (fs_supers index of the scan), cur, prv (the iterator's current and
              \* previous superblock), n (shrinker callbacks run)
    st,       \* [Sbs -> "none", "alloc", "pub", "unlinked", "rcu", "freed"]: the memory
    born, dying, dead,  \* [Sbs -> BOOLEAN]: SB_BORN, SB_DYING, SB_DEAD
    act,      \* [Sbs -> Nat]: s_active
    pass,     \* [Sbs -> Int]: s_passive
    umx,      \* [Sbs -> Procs \cup {NoOne}]: s_umount held exclusive by
    ums,      \* [Sbs -> SUBSET Procs]: s_umount held shared by
    sblock,   \* sb_lock holder or NoOne
    fsl,      \* fs_supers: Seq(Sbs), hlist_add_head()
    sbl,      \* super_blocks: Seq(Sbs), list_add_tail()
    fsi,      \* [Sbs -> "none", "live", "freed"]: s_fs_info
    shr,      \* [Sbs -> "none", "reg", "freed"]: the shrinker
    shrun,    \* [Sbs -> SUBSET Procs]: shrinker callbacks in flight
    ent,      \* [Sbs -> [st: "none", "linked", "gone"; ref: Nat]]: s_super_dev, the device-table
              \* entry sget_fc()'s set() registers (its claim and the cursor pins)
    own,      \* [Sbs -> 0..1]: alloc_super()'s passive reference not yet put
    tmp,      \* [Procs -> [Sbs -> Nat]]: ghost, passive references a task holds
    hasact,   \* [Mnt -> SUBSET Sbs]: ghost, the superblocks the mounter holds s_active on
    rcu,      \* tasks inside an RCU read section (rcu_read_lock() or holding sb_lock)
    gp,       \* [Sbs -> SUBSET Procs]: the readers call_rcu() waits for
    err

vars == <<L, st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
          ent, own, tmp, hasact, rcu, gp, err>>

-----------------------------------------------------------------------------
Flag(msg) == err' = err \cup {msg}
Goto(p, l) == L' = [L EXCEPT ![p].pc = l]

Idx(seq, x) == CHOOSE i \in 1..Len(seq) : seq[i] = x
InSeq(seq, x) == \E i \in 1..Len(seq) : seq[i] = x
Remove(seq, x) == IF InSeq(seq, x)
                  THEN LET i == Idx(seq, x) IN SubSeq(seq, 1, i - 1) \o SubSeq(seq, i + 1, Len(seq))
                  ELSE seq
IterList == IF ITER = "type" THEN fsl ELSE sbl
\* the list node after x (x must be linked)
NextOf(seq, x) == LET i == Idx(seq, x) IN IF i < Len(seq) THEN seq[i + 1] ELSE NIL
UmFree(s) == umx[s] = NoOne /\ ums[s] = {}

FreshL(lbl) == [pc |-> lbl, ret |-> "none", ps |-> NIL, s |-> NIL, old |-> NIL, idx |-> 1,
                cur |-> NIL, prv |-> NIL, n |-> 0]

Init ==
    /\ L = [p \in Procs |-> FreshL(CASE p \in Mnt -> "m_lock"
                                     [] p = "it" -> "i_lock"
                                     [] p = "ug" -> "u_pin"
                                     [] OTHER -> "h_pick")]
    /\ st = [s \in Sbs |-> "none"]
    /\ born = [s \in Sbs |-> FALSE]
    /\ dying = [s \in Sbs |-> FALSE]
    /\ dead = [s \in Sbs |-> FALSE]
    /\ act = [s \in Sbs |-> 0]
    /\ pass = [s \in Sbs |-> 0]
    /\ umx = [s \in Sbs |-> NoOne]
    /\ ums = [s \in Sbs |-> {}]
    /\ sblock = NoOne
    /\ fsl = <<>>
    /\ sbl = <<>>
    /\ fsi = [s \in Sbs |-> "none"]
    /\ shr = [s \in Sbs |-> "none"]
    /\ shrun = [s \in Sbs |-> {}]
    /\ ent = [s \in Sbs |-> [st |-> "none", ref |-> 0]]
    /\ own = [s \in Sbs |-> 0]
    /\ tmp = [p \in Procs |-> [s \in Sbs |-> 0]]
    /\ hasact = [m \in Mnt |-> {}]
    /\ rcu = {}
    /\ gp = [s \in Sbs |-> {}]
    /\ err = {}

\* leaving an RCU read section: no longer holds up a pending call_rcu()
ExitRcu(p) == /\ rcu' = rcu \ {p}
              /\ gp' = [s \in Sbs |-> gp[s] \ {p}]

\* touching a superblock's memory
Touch(s) == IF st[s] = "freed" THEN {"use-after-free of a superblock"} ELSE {}

-----------------------------------------------------------------------------
(***************************************************************************)
(* put_super() L419: PS1 refcount_dec_and_test() L421; PS2 at zero:        *)
(* spin_lock(sb_lock) L424, list_del_init(s_list) L425,                    *)
(* hlist_del_init(s_instances) L426 (FIX_UNLINK_LATE), unlock, call_rcu()  *)
(* L432.  The caller sets ps and ret, and has already dropped its tmp      *)
(* ghost or own reference.                                                 *)
(***************************************************************************)
PS1(p) ==
    /\ L[p].pc = "PS1"
    /\ LET s == L[p].ps IN
       /\ pass' = [pass EXCEPT ![s] = @ - 1]
       /\ err' = err \cup Touch(s) \cup (IF pass[s] < 1 THEN {"s_passive underflow"} ELSE {})
       /\ Goto(p, IF pass[s] = 1 THEN "PS2" ELSE L[p].ret)
    /\ UNCHANGED <<st, born, dying, dead, act, umx, ums, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp>>

PS2(p) ==
    /\ L[p].pc = "PS2"
    /\ sblock = NoOne
    /\ LET s == L[p].ps IN
       /\ sbl' = Remove(sbl, s)
       /\ fsl' = Remove(fsl, s)
       /\ st' = [st EXCEPT ![s] = IF FIX_RCU_SB THEN "rcu" ELSE "freed"]
       /\ gp' = [gp EXCEPT ![s] = IF FIX_RCU_SB THEN rcu ELSE {}]
       /\ err' = err \cup (IF ent[s].st = "linked" THEN {"superblock freed with its device-table entry linked"} ELSE {})
                     \cup (IF shr[s] = "reg" THEN {"superblock freed with its shrinker registered"} ELSE {})
                     \cup (IF ~dead[s] /\ st[s] = "pub" THEN {"superblock freed before SB_DEAD"} ELSE {})
    /\ Goto(p, L[p].ret)
    /\ UNCHANGED <<born, dying, dead, act, pass, umx, ums, sblock, fsi, shr, shrun, ent, own, tmp,
                   hasact, rcu>>

\* destroy_super_rcu() -> destroy_super_work(): every reader present at call_rcu() has left
RcuFree(s) ==
    /\ st[s] = "rcu"
    /\ gp[s] = {}
    /\ st' = [st EXCEPT ![s] = "freed"]
    /\ UNCHANGED <<L, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp, err>>

\* put_super() of a temporary reference the task holds
PutTmp(p, s, r) ==
    /\ L' = [L EXCEPT ![p].ps = s, ![p].ret = r, ![p].pc = "PS1"]
    /\ tmp' = [tmp EXCEPT ![p][s] = @ - 1]

\* super_dev_put() of s_super_dev (L466): at zero the entry's passive reference goes
EntPut(p, s, r) ==
    IF ent[s].ref = 1
    THEN /\ ent' = [ent EXCEPT ![s] = [st |-> "gone", ref |-> 0]]
         /\ L' = [L EXCEPT ![p].ps = s, ![p].ret = r, ![p].pc = "PS1"]
    ELSE /\ ent' = [ent EXCEPT ![s].ref = @ - 1]
         /\ Goto(p, r)

-----------------------------------------------------------------------------
(***************************************************************************)
(* sget_fc() L839                                                          *)
(***************************************************************************)
\* L861 spin_lock(&sb_lock)
m_lock(m) ==
    /\ L[m].pc = "m_lock"
    /\ sblock = NoOne
    /\ sblock' = m
    /\ rcu' = rcu \cup {m}
    /\ L' = [L EXCEPT ![m].idx = 1, ![m].pc = IF TEST = "none" THEN "m_nomatch" ELSE "m_scan"]
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, fsl, sbl, fsi, shr, shrun, ent, own,
                   tmp, hasact, gp, err>>

\* L863-865: hlist_for_each_entry(old, fs_supers): SB_DEAD -> continue
m_scan(m) ==
    /\ L[m].pc = "m_scan"
    /\ IF L[m].idx > Len(fsl)
       THEN /\ Goto(m, "m_nomatch")
            /\ UNCHANGED err
       ELSE LET o == fsl[L[m].idx] IN
            /\ err' = err \cup Touch(o)
            /\ IF FIX_DEAD_SKIP /\ dead[o]
               THEN L' = [L EXCEPT ![m].idx = @ + 1]
               ELSE L' = [L EXCEPT ![m].old = o, ![m].pc = "m_test"]
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp>>

\* L867 test(old, fc): may dereference s_fs_info; get_tree_single() matches everything, a
\* keyed test the superblocks created for the same key; no match: the next one L863
m_test(m) ==
    /\ L[m].pc = "m_test"
    /\ LET o == L[m].old IN
       /\ err' = err \cup Touch(o)
                     \cup (IF TEST_DEREF /\ fsi[o] = "freed" THEN {"test() dereferences a freed s_fs_info"} ELSE {})
       /\ IF Matches(m, o)
          THEN Goto(m, "m_grab0")
          ELSE L' = [L EXCEPT ![m].idx = @ + 1, ![m].old = NIL, ![m].pc = "m_scan"]
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp>>

\* L871-877: no match and nothing allocated yet: drop sb_lock, alloc_super(), retry
m_nomatch(m) ==
    /\ L[m].pc = "m_nomatch"
    /\ IF L[m].s = NIL
       THEN /\ sblock' = NoOne
            /\ ExitRcu(m)
            /\ Goto(m, "m_alloc")
       ELSE /\ Goto(m, "m_set")
            /\ UNCHANGED <<sblock, rcu, gp>>
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, fsl, sbl, fsi, shr, shrun, ent, own,
                   tmp, hasact, err>>

\* alloc_super() L323: down_write_nested(s_umount) L351, s_passive 1 L376, s_active 1 L377,
\* the entry preallocated unregistered L401
m_alloc(m) ==
    /\ L[m].pc = "m_alloc"
    /\ LET s == MntSb[m] IN
       /\ st' = [st EXCEPT ![s] = "alloc"]
       /\ pass' = [pass EXCEPT ![s] = 1]
       /\ own' = [own EXCEPT ![s] = 1]
       /\ act' = [act EXCEPT ![s] = 1]
       /\ hasact' = [hasact EXCEPT ![m] = @ \cup {s}]
       /\ umx' = [umx EXCEPT ![s] = m]
       /\ L' = [L EXCEPT ![m].s = s, ![m].pc = "m_lock"]
    /\ UNCHANGED <<born, dying, dead, ums, sblock, fsl, sbl, fsi, shr, shrun, ent, tmp, rcu, gp, err>>

\* L879-902: s_fs_info = fc->s_fs_info, set() registers s_super_dev (super_dev_register() L493:
\* the entry and its passive reference), list_add_tail(super_blocks) L899,
\* hlist_add_head(fs_supers) L900, spin_unlock() L901
m_set(m) ==
    /\ L[m].pc = "m_set"
    /\ LET s == L[m].s IN
       /\ fsi' = [fsi EXCEPT ![s] = "live"]
       /\ ent' = [ent EXCEPT ![s] = [st |-> "linked", ref |-> 1]]
       /\ pass' = [pass EXCEPT ![s] = @ + 1]
       /\ sbl' = Append(sbl, s)
       /\ fsl' = <<s>> \o fsl
       /\ st' = [st EXCEPT ![s] = "pub"]
       /\ sblock' = NoOne
       /\ ExitRcu(m)
       /\ Goto(m, "m_shreg")
    /\ UNCHANGED <<born, dying, dead, act, umx, ums, shr, shrun, own, tmp, hasact, err>>

\* L903 shrinker_register()
m_shreg(m) ==
    /\ L[m].pc = "m_shreg"
    /\ shr' = [shr EXCEPT ![L[m].s] = "reg"]
    /\ Goto(m, "m_fill")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shrun, ent,
                   own, tmp, hasact, rcu, gp, err>>

\* fill_super(): success -> vfs_get_tree() super_wake(SB_BORN) L1963; failure ->
\* deactivate_locked_super() with s_umount held (vfs_get_super() L1385, get_tree_bdev_flags() L1848)
m_fill(m) ==
    /\ L[m].pc = "m_fill"
    /\ \/ /\ born' = [born EXCEPT ![L[m].s] = TRUE]
          /\ Goto(m, "m_unlock")
       \/ /\ FillFail[m]
          /\ Goto(m, "m_dls")
          /\ UNCHANGED born
    /\ UNCHANGED <<st, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp, err>>

\* fc_mount() up_write(s_umount) (fs/namespace.c L1280)
m_unlock(m) ==
    /\ L[m].pc = "m_unlock"
    /\ LET s == L[m].s IN
       /\ err' = err \cup (IF umx[s] # m THEN {"s_umount released by a task that does not hold it"} ELSE {})
       /\ umx' = [umx EXCEPT ![s] = NoOne]
    /\ Goto(m, "m_mounted")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp>>

m_mounted(m) ==
    /\ L[m].pc = "m_mounted"
    /\ Goto(m, IF Umount[m] THEN "m_deact" ELSE "Done")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp, err>>

(* grab_super() L632 *)
\* L636-637 refcount_inc(&sb->s_passive) under sb_lock, spin_unlock()
m_grab0(m) ==
    /\ L[m].pc = "m_grab0"
    /\ LET o == L[m].old IN
       /\ pass' = [pass EXCEPT ![o] = @ + 1]
       /\ tmp' = [tmp EXCEPT ![m][o] = @ + 1]
       /\ err' = err \cup Touch(o)
                     \cup (IF pass[o] < 1 THEN {"refcount_inc(s_passive) from zero in grab_super()"} ELSE {})
       /\ sblock' = NoOne
       /\ ExitRcu(m)
       /\ Goto(m, "m_grab1")
    /\ UNCHANGED <<st, born, dying, dead, act, umx, ums, fsl, sbl, fsi, shr, shrun, ent, own,
                   hasact>>

\* L638 super_lock_excl(): wait_var_event(SB_BORN|SB_DYING) L118, SB_DYING -> false L121
m_grab1(m) ==
    /\ L[m].pc = "m_grab1"
    /\ LET o == L[m].old IN
       /\ born[o] \/ dying[o]
       /\ Goto(m, IF dying[o] THEN "m_grabwait" ELSE "m_grab2")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp, err>>

\* L124 down_write(), L131 SB_DYING -> up_write() and false
m_grab2(m) ==
    /\ L[m].pc = "m_grab2"
    /\ LET o == L[m].old IN
       /\ UmFree(o)
       /\ IF dying[o]
          THEN /\ Goto(m, "m_grabwait")
               /\ UNCHANGED umx
          ELSE /\ umx' = [umx EXCEPT ![o] = m]
               /\ Goto(m, "m_grab3")
       /\ err' = err \cup Touch(o)
    /\ UNCHANGED <<st, born, dying, dead, act, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp>>

\* L640-643 atomic_inc_not_zero(s_active) -> put_super() (keeps s_umount); else
\* super_unlock_excl() L644 and wait for SB_DEAD
m_grab3(m) ==
    /\ L[m].pc = "m_grab3"
    /\ LET o == L[m].old IN
       IF act[o] > 0
       THEN /\ act' = [act EXCEPT ![o] = @ + 1]
            /\ hasact' = [hasact EXCEPT ![m] = @ \cup {o}]
            /\ PutTmp(m, o, "m_gotold")
            /\ UNCHANGED umx
       ELSE /\ umx' = [umx EXCEPT ![o] = NoOne]
            /\ Goto(m, "m_grabwait")
            /\ UNCHANGED <<act, hasact, tmp>>
    /\ UNCHANGED <<st, born, dying, dead, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, ent, own,
                   rcu, gp, err>>

\* L646-648 wait_var_event(SB_DEAD), put_super(), return false: sget_fc() retries L916
m_grabwait(m) ==
    /\ L[m].pc = "m_grabwait"
    /\ dead[L[m].old]
    /\ PutTmp(m, L[m].old, "m_lock")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, hasact, rcu, gp, err>>

\* L918 destroy_unused_super(s) L302: up_write(), the never-published superblock freed at once
\* (its unregistered entry with it); then the caller uses the existing superblock, already
\* SB_BORN with s_root: vfs_get_tree() super_wake(SB_BORN) again, fc_mount() up_write()
m_gotold(m) ==
    /\ L[m].pc = "m_gotold"
    /\ LET s == L[m].s
           o == L[m].old IN
       /\ IF s # NIL
          THEN /\ st' = [st EXCEPT ![s] = "freed"]
               /\ pass' = [pass EXCEPT ![s] = 0]
               /\ own' = [own EXCEPT ![s] = 0]
               /\ act' = [act EXCEPT ![s] = 0]
               /\ umx' = [umx EXCEPT ![s] = NoOne]
               /\ hasact' = [hasact EXCEPT ![m] = @ \ {s}]
               /\ err' = err \cup (IF InSeq(sbl, s) \/ InSeq(fsl, s) \/ ent[s].st = "linked"
                                   THEN {"destroy_unused_super() of a superblock others can see"} ELSE {})
          ELSE /\ UNCHANGED <<st, pass, own, act, umx, hasact, err>>
       /\ L' = [L EXCEPT ![m].s = o, ![m].pc = "m_unlock"]
    /\ UNCHANGED <<born, dying, dead, ums, sblock, fsl, sbl, fsi, shr, shrun, ent, tmp, rcu, gp>>

(***************************************************************************)
(* The unmount: deactivate_super() L610, deactivate_locked_super() L581    *)
(***************************************************************************)
\* L612 atomic_add_unless(&s_active, -1, 1); else L613 __super_lock_excl()
m_deact(m) ==
    /\ L[m].pc = "m_deact"
    /\ LET s == L[m].s IN
       IF act[s] > 1
       THEN /\ act' = [act EXCEPT ![s] = @ - 1]
            /\ hasact' = [hasact EXCEPT ![m] = @ \ {s}]
            /\ Goto(m, "Done")
            /\ UNCHANGED umx
       ELSE /\ UmFree(s)
            /\ umx' = [umx EXCEPT ![s] = m]
            /\ Goto(m, "m_dls")
            /\ UNCHANGED <<act, hasact>>
    /\ UNCHANGED <<st, born, dying, dead, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, ent, own,
                   tmp, rcu, gp, err>>

\* L584 atomic_dec_and_test(&s_active); else L596 super_unlock_excl()
m_dls(m) ==
    /\ L[m].pc = "m_dls"
    /\ LET s == L[m].s IN
       /\ act' = [act EXCEPT ![s] = @ - 1]
       /\ hasact' = [hasact EXCEPT ![m] = @ \ {s}]
       /\ IF act[s] = 1
          THEN /\ Goto(m, IF FIX_SHRINK_FIRST THEN "m_shfree" ELSE "m_gss")
               /\ UNCHANGED umx
          ELSE /\ umx' = [umx EXCEPT ![s] = NoOne]
               /\ Goto(m, "Done")
       /\ err' = err \cup (IF umx[s] # m THEN {"deactivate_locked_super() without s_umount"} ELSE {})
    /\ UNCHANGED <<st, born, dying, dead, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, ent, own,
                   tmp, rcu, gp>>

\* L585 shrinker_free(): waits for callbacks in flight, none starts afterwards
m_shfree(m) ==
    /\ L[m].pc = "m_shfree"
    /\ LET s == L[m].s IN
       /\ shrun[s] = {}
       /\ shr' = [shr EXCEPT ![s] = "freed"]
    /\ Goto(m, IF FIX_SHRINK_FIRST THEN "m_gss" ELSE "m_put")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shrun, ent,
                   own, tmp, hasact, rcu, gp, err>>

\* L586 ->kill_sb() -> generic_shutdown_super() L723: the teardown with s_umount held, then
\* L787 super_wake(SB_DYING), L788 super_unlock_excl()
m_gss(m) ==
    /\ L[m].pc = "m_gss"
    /\ LET s == L[m].s IN
       /\ dying' = [dying EXCEPT ![s] = TRUE]
       /\ umx' = [umx EXCEPT ![s] = NoOne]
       /\ err' = err \cup (IF umx[s] # m THEN {"s_umount released by a task that does not hold it"} ELSE {})
       /\ Goto(m, IF KILL = "anon" THEN "m_notify" ELSE "m_freefsi")
    /\ UNCHANGED <<st, born, dead, act, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, ent, own,
                   tmp, hasact, rcu, gp>>

\* kill_super_notify() L543: L552-553 super_dev_put(s_super_dev) (sget_fc()'s claim)
m_notify(m) ==
    /\ L[m].pc = "m_notify"
    /\ LET s == L[m].s IN
       IF dead[s]
       THEN /\ Goto(m, "m_put")                          \* L548: already notified
            /\ UNCHANGED ent
       ELSE EntPut(m, s, "m_dead")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   own, tmp, hasact, rcu, gp, err>>

\* L565-567 spin_lock(sb_lock), super_wake(SB_DEAD), spin_unlock() (FIX_DEAD_LOCK); with
\* FIX_UNLINK_LATE off the shape before 2d2a2d7aa987: hlist_del_init(s_instances) here
m_dead(m) ==
    /\ L[m].pc = "m_dead"
    /\ LET s == L[m].s IN
       /\ FIX_DEAD_LOCK => sblock = NoOne
       /\ dead' = [dead EXCEPT ![s] = TRUE]
       /\ fsl' = IF FIX_UNLINK_LATE THEN fsl ELSE Remove(fsl, s)
       /\ Goto(m, IF KILL = "anon" THEN "m_freefsi" ELSE "m_put0")
    /\ UNCHANGED <<st, born, dying, act, pass, umx, ums, sblock, sbl, fsi, shr, shrun, ent, own,
                   tmp, hasact, rcu, gp, err>>

\* the filesystem frees what s_fs_info points to: after kill_anon_super() returned (KILL
\* "anon": nfs, ceph, cifs, afs, fuse, kernfs, ...) or inside ->kill_sb() before
\* deactivate_locked_super()'s kill_super_notify() (KILL "block")
m_freefsi(m) ==
    /\ L[m].pc = "m_freefsi"
    /\ fsi' = [fsi EXCEPT ![L[m].s] = "freed"]
    /\ Goto(m, IF KILL = "anon" THEN "m_put0" ELSE "m_notify")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp, err>>

\* deactivate_locked_super(): kill_super_notify() L588 (a no-op after kill_anon_super()),
\* list_lru_destroy(), then (FIX_SHRINK_FIRST off) the late shrinker_free()
m_put0(m) ==
    /\ L[m].pc = "m_put0"
    /\ Goto(m, IF FIX_SHRINK_FIRST THEN "m_put" ELSE "m_shfree")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp, err>>

\* L594 put_super(): alloc_super()'s reference
m_put(m) ==
    /\ L[m].pc = "m_put"
    /\ LET s == L[m].s IN
       /\ own' = [own EXCEPT ![s] = 0]
       /\ L' = [L EXCEPT ![m].ps = s, ![m].ret = "Done", ![m].pc = "PS1"]
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, tmp, hasact, rcu, gp, err>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* __iterate_supers() L958 / iterate_supers_type() L1008                   *)
(***************************************************************************)
\* L964/L1013 spin_lock(&sb_lock); the first node
i_lock(p) ==
    /\ L[p].pc = "i_lock"
    /\ sblock = NoOne
    /\ sblock' = p
    /\ rcu' = rcu \cup {p}
    /\ L' = [L EXCEPT ![p].cur = IF Len(IterList) = 0 THEN NIL ELSE IterList[1], ![p].pc = "i_loop"]
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, fsl, sbl, fsi, shr, shrun, ent, own,
                   tmp, hasact, gp, err>>

\* L969-974 / L1017-1022: SB_DYING -> continue, refcount_inc_not_zero() fails -> continue,
\* spin_unlock(); the end of the list: L989-991 / L1036-1038 spin_unlock(), put_super(prev)
i_loop(p) ==
    /\ L[p].pc = "i_loop"
    /\ LET s == L[p].cur IN
       IF s = NIL
       THEN /\ sblock' = NoOne
            /\ ExitRcu(p)
            /\ IF L[p].prv # NIL
               THEN PutTmp(p, L[p].prv, "Done")
               ELSE /\ Goto(p, "Done")
                    /\ UNCHANGED tmp
            /\ UNCHANGED <<pass, err>>
       ELSE /\ err' = err \cup Touch(s)
            /\ IF dying[s] \/ pass[s] = 0
               THEN /\ L' = [L EXCEPT ![p].cur = NextOf(IterList, s)]
                    /\ UNCHANGED <<pass, tmp, sblock, rcu, gp>>
               ELSE /\ pass' = [pass EXCEPT ![s] = @ + 1]
                    /\ tmp' = [tmp EXCEPT ![p][s] = @ + 1]
                    /\ sblock' = NoOne
                    /\ ExitRcu(p)
                    /\ Goto(p, "i_slock")
    /\ UNCHANGED <<st, born, dying, dead, act, umx, ums, fsl, sbl, fsi, shr, shrun, ent, own, hasact>>

\* super_lock(sb, false) L113: wait for SB_BORN|SB_DYING, SB_DYING -> false, down_read(),
\* recheck SB_DYING
i_slock(p) ==
    /\ L[p].pc = "i_slock"
    /\ LET s == L[p].cur IN
       /\ born[s] \/ dying[s]
       /\ IF dying[s]
          THEN /\ Goto(p, "i_putprev")
               /\ UNCHANGED ums
          ELSE /\ umx[s] = NoOne
               /\ ums' = [ums EXCEPT ![s] = @ \cup {p}]
               /\ Goto(p, "i_cb")
       /\ err' = err \cup Touch(s)
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp>>

\* the callback f(sb, arg) with s_umount shared (it may use the filesystem), super_unlock()
i_cb(p) ==
    /\ L[p].pc = "i_cb"
    /\ LET s == L[p].cur IN
       /\ err' = err \cup Touch(s)
                     \cup (IF fsi[s] # "live" \/ dying[s] THEN {"iterator callback on a superblock being torn down"} ELSE {})
       /\ ums' = [ums EXCEPT ![s] = @ \ {p}]
    /\ Goto(p, "i_putprev")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp>>

\* L984-986 / L1031-1033: put_super(prev), prev = sb (FIX_ITER_PIN off: put sb itself)
i_putprev(p) ==
    /\ L[p].pc = "i_putprev"
    /\ IF FIX_ITER_PIN
       THEN IF L[p].prv # NIL
            THEN PutTmp(p, L[p].prv, "i_relock")
            ELSE /\ Goto(p, "i_relock")
                 /\ UNCHANGED tmp
       ELSE PutTmp(p, L[p].cur, "i_relock")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, hasact, rcu, gp, err>>

\* L987 / L1034 spin_lock(&sb_lock), then the for-loop advance from sb: next_super() L950 or
\* hlist_for_each_entry()'s ->next -- the node must still be linked
i_relock(p) ==
    /\ L[p].pc = "i_relock"
    /\ sblock = NoOne
    /\ sblock' = p
    /\ rcu' = rcu \cup {p}
    /\ LET s == L[p].cur IN
       /\ L' = [L EXCEPT ![p].prv = IF FIX_ITER_PIN THEN s ELSE NIL,
                         ![p].cur = IF InSeq(IterList, s) THEN NextOf(IterList, s) ELSE NIL,
                         ![p].pc = "i_loop"]
       /\ err' = err \cup Touch(s)
                     \cup (IF ~InSeq(IterList, s) THEN {"iterator advances from an unlinked node"} ELSE {})
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, fsl, sbl, fsi, shr, shrun, ent, own,
                   tmp, hasact, gp>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* user_get_super() L1043 through the target superblock's s_super_dev     *)
(***************************************************************************)
\* super_dev_first(): rcu_read_lock(), the lookup, refcount_inc_not_zero() L515
u_pin(p) ==
    /\ L[p].pc = "u_pin"
    /\ IF ent[UGS].st = "linked" /\ ent[UGS].ref > 0
       THEN /\ ent' = [ent EXCEPT ![UGS].ref = @ + 1]
            /\ L' = [L EXCEPT ![p].s = UGS, ![p].pc = "u_lock"]
       ELSE /\ Goto(p, "Done")
            /\ UNCHANGED ent
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   own, tmp, hasact, rcu, gp, err>>

\* L1050 super_lock(sb, excl): wait for SB_BORN|SB_DYING; SB_DYING -> continue (the next entry:
\* none, the pin is dropped by super_dev_next()); else down_write(), recheck
u_lock(p) ==
    /\ L[p].pc = "u_lock"
    /\ LET s == L[p].s IN
       /\ born[s] \/ dying[s]
       /\ err' = err \cup Touch(s)
       /\ IF dying[s]
          THEN /\ EntPut(p, s, "Done")
               /\ UNCHANGED umx
          ELSE /\ UmFree(s)
               /\ umx' = [umx EXCEPT ![s] = p]
               /\ Goto(p, "u_inc")
               /\ UNCHANGED ent
    /\ UNCHANGED <<st, born, dying, dead, act, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, own,
                   tmp, hasact, rcu, gp>>

\* L1054 refcount_inc(&sb->s_passive), L1055 super_dev_put()
u_inc(p) ==
    /\ L[p].pc = "u_inc"
    /\ LET s == L[p].s IN
       /\ pass' = [pass EXCEPT ![s] = @ + 1]
       /\ tmp' = [tmp EXCEPT ![p][s] = @ + 1]
       /\ err' = err \cup Touch(s)
                     \cup (IF pass[s] < 1 THEN {"refcount_inc(s_passive) from zero in user_get_super()"} ELSE {})
       /\ EntPut(p, s, "u_use")
    /\ UNCHANGED <<st, born, dying, dead, act, umx, ums, sblock, fsl, sbl, fsi, shr, shrun, own,
                   hasact, rcu, gp>>

\* the caller (quotactl_block(), vfs_ustat()) uses the superblock under s_umount
u_use(p) ==
    /\ L[p].pc = "u_use"
    /\ LET s == L[p].s IN
       err' = err \cup Touch(s)
                  \cup (IF dying[s] \/ fsi[s] # "live" THEN {"user_get_super() returned a superblock being torn down"} ELSE {})
    /\ Goto(p, "u_drop")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp>>

\* drop_super_exclusive() L931: up_write(), put_super()
u_drop(p) ==
    /\ L[p].pc = "u_drop"
    /\ LET s == L[p].s IN
       /\ umx' = [umx EXCEPT ![s] = NoOne]
       /\ PutTmp(p, s, "Done")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, ums, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, hasact, rcu, gp, err>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* The shrinker: shrink_slab() finds a registered shrinker and takes its   *)
(* shrinker reference (shrinker_free() waits for it), then                 *)
(* super_cache_scan() L181 or super_cache_count() L238 with no superblock  *)
(* reference.                                                              *)
(***************************************************************************)
h_pick(p) ==
    /\ L[p].pc = "h_pick"
    /\ IF L[p].n < SHRINK /\ \E s \in Sbs : shr[s] = "reg"
       THEN \E s \in Sbs :
              /\ shr[s] = "reg"
              /\ shrun' = [shrun EXCEPT ![s] = @ \cup {p}]
              /\ \/ L' = [L EXCEPT ![p].s = s, ![p].n = @ + 1, ![p].pc = "h_scan"]
                 \/ L' = [L EXCEPT ![p].s = s, ![p].n = @ + 1, ![p].pc = "h_count"]
       ELSE /\ Goto(p, "Done")
            /\ UNCHANGED shrun
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, ent,
                   own, tmp, hasact, rcu, gp, err>>

\* L200 super_trylock_shared() L668: down_read_trylock(), !SB_DYING && s_root && SB_BORN; then
\* the dcache, icache and ->free_cached_objects() of the filesystem
h_scan(p) ==
    /\ L[p].pc = "h_scan"
    /\ LET s == L[p].s IN
       /\ err' = err \cup Touch(s)
       /\ IF umx[s] = NoOne /\ ~dying[s] /\ born[s]
          THEN /\ ums' = [ums EXCEPT ![s] = @ \cup {p}]
               /\ Goto(p, "h_scanuse")
          ELSE /\ Goto(p, "h_end")
               /\ UNCHANGED ums
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp>>

h_scanuse(p) ==
    /\ L[p].pc = "h_scanuse"
    /\ LET s == L[p].s IN
       /\ err' = err \cup Touch(s)
                     \cup (IF fsi[s] # "live" THEN {"super_cache_scan() uses a freed filesystem"} ELSE {})
       /\ ums' = [ums EXCEPT ![s] = @ \ {p}]
    /\ Goto(p, "h_end")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, sblock, fsl, sbl, fsi, shr, shrun, ent,
                   own, tmp, hasact, rcu, gp>>

\* L260-265: SB_BORN without locks, then ->nr_cached_objects() and the list_lru counts
h_count(p) ==
    /\ L[p].pc = "h_count"
    /\ LET s == L[p].s IN
       err' = err \cup Touch(s)
                  \cup (IF born[s] /\ fsi[s] # "live" THEN {"super_cache_count() uses a freed filesystem"} ELSE {})
    /\ Goto(p, "h_end")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, shrun,
                   ent, own, tmp, hasact, rcu, gp>>

h_end(p) ==
    /\ L[p].pc = "h_end"
    /\ shrun' = [shrun EXCEPT ![L[p].s] = @ \ {p}]
    /\ Goto(p, "h_pick")
    /\ UNCHANGED <<st, born, dying, dead, act, pass, umx, ums, sblock, fsl, sbl, fsi, shr, ent,
                   own, tmp, hasact, rcu, gp, err>>

-----------------------------------------------------------------------------
AllDone == \A p \in Procs : L[p].pc = "Done"
Quiet == AllDone /\ \A s \in Sbs : st[s] # "rcu"

Finished ==
    /\ Quiet
    /\ UNCHANGED vars

Step(p) ==
    \/ PS1(p) \/ PS2(p)
    \/ m_lock(p) \/ m_scan(p) \/ m_test(p) \/ m_nomatch(p) \/ m_alloc(p) \/ m_set(p)
    \/ m_shreg(p) \/ m_fill(p) \/ m_unlock(p) \/ m_mounted(p)
    \/ m_grab0(p) \/ m_grab1(p) \/ m_grab2(p) \/ m_grab3(p) \/ m_grabwait(p) \/ m_gotold(p)
    \/ m_deact(p) \/ m_dls(p) \/ m_shfree(p) \/ m_gss(p) \/ m_notify(p) \/ m_dead(p)
    \/ m_freefsi(p) \/ m_put0(p) \/ m_put(p)
    \/ i_lock(p) \/ i_loop(p) \/ i_slock(p) \/ i_cb(p) \/ i_putprev(p) \/ i_relock(p)
    \/ u_pin(p) \/ u_lock(p) \/ u_inc(p) \/ u_use(p) \/ u_drop(p)
    \/ h_pick(p) \/ h_scan(p) \/ h_scanuse(p) \/ h_count(p) \/ h_end(p)

Next ==
    \/ \E p \in Procs : Step(p)
    \/ \E s \in Sbs : RcuFree(s)
    \/ Finished

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)
TypeOK ==
    /\ \A s \in Sbs : st[s] \in {"none", "alloc", "pub", "rcu", "freed"} /\ act[s] \in Nat
    /\ sblock \in Procs \cup {NoOne}

NoErr == err = {}

RECURSIVE SumP(_, _)
SumP(f, ps) == IF ps = {} THEN 0 ELSE LET p == CHOOSE p \in ps : TRUE IN f[p] + SumP(f, ps \ {p})

\* s_passive adds up: alloc_super()'s own, the registered entry's, the tasks' temporary ones,
\* and the one a put_super() in flight is dropping
PassLedger == \A s \in Sbs : st[s] \in {"alloc", "pub"} =>
    pass[s] = own[s] + (IF ent[s].st = "linked" THEN 1 ELSE 0)
              + SumP([p \in Procs |-> tmp[p][s]], Procs)
              + Cardinality({p \in Procs : L[p].pc = "PS1" /\ L[p].ps = s})

\* s_active adds up: one per mounter holding the superblock
ActLedger == \A s \in Sbs : st[s] \in {"alloc", "pub"} =>
    act[s] = Cardinality({m \in Mnt : s \in hasact[m]})

\* a published superblock is on both lists until its last passive reference is gone
Lists == \A s \in Sbs :
    /\ st[s] = "pub" => (InSeq(sbl, s) /\ (FIX_UNLINK_LATE => InSeq(fsl, s)))
    /\ st[s] \in {"none", "alloc", "rcu", "freed"} => ~InSeq(sbl, s) /\ ~InSeq(fsl, s)

\* SB_DEAD implies SB_DYING; a superblock dies only after it was published or failed
Flags == \A s \in Sbs : (dead[s] => dying[s]) /\ (dying[s] => act[s] = 0)

\* nobody holds s_umount of a superblock that is gone
UmountSane == \A s \in Sbs : st[s] \in {"none", "rcu", "freed"} => (umx[s] = NoOne /\ ums[s] = {})

\* the end: every superblock whose mounters all unmounted is freed
NoLeak == Quiet => \A s \in Sbs :
    (\A m \in Mnt : s \notin hasact[m]) /\ st[s] # "none" => st[s] = "freed"
=============================================================================

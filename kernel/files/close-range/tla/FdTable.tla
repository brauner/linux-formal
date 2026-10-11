------------------------------ MODULE FdTable ------------------------------
(***************************************************************************)
(* Descriptor tables and the close_range()/dup_fd() logic of the series   *)
(* "files,close_range: add CLOSE_RANGE_{CLOEXEC_ONLY,EXCEPT}".             *)
(*                                                                         *)
(* Tree: vfs-7.4.sync_close at 02de8d0c3512, which is vfs-7.4.close_range  *)
(* (c73c0e243836) with the synchronous closing of files on top; "fs: close *)
(* files from the highest descriptor down" turned the walk of              *)
(* __range_close() around.                                                 *)
(*                                                                         *)
(* A table is a function from descriptor numbers to slots.  A slot is the  *)
(* open_fds bit, whether a struct file is installed and the close_on_exec  *)
(* bit.  alloc_fd() sets the open bit before fd_install() stores the       *)
(* pointer, so a slot can be open without a file (claimed), and close()    *)
(* leaves close_on_exec behind, so the bit can be set on a closed slot.    *)
(*                                                                         *)
(* The operators follow fs/file.c: fd_range_word(), dup_fd_dropped_word(), *)
(* sane_fdtable_size(), the copy loop of dup_fd(), __range_cloexec(),      *)
(* last_fd_to_close(), __range_close() and sys_close_range().              *)
(* DROP_IN_DUP_FD = FALSE is the code before the series: the punch_hole    *)
(* sizing, every descriptor the size covers copied and referenced, the     *)
(* range closed from the clone afterwards.  MUTATION names one change to   *)
(* the code that a configuration expects the properties to catch, "none"   *)
(* is the code as it is.                                                   *)
(*                                                                         *)
(* Meaning() says what the flags mean.  The models check that the code    *)
(* refines it, that the clone's bitmaps are consistent, that dup_fd() is   *)
(* sized to the last descriptor it carries over and nothing more, and that *)
(* it never takes a reference on a descriptor it leaves behind.            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    W,               \* BITS_PER_LONG, which is also NR_OPEN_DEFAULT
    INF,             \* stands for ~0U: above every table
    DROP_IN_DUP_FD,  \* TRUE: the series; FALSE: the code before it
    MUTATION         \* "none" or one of Mutations

Mutations == {"none",
              "no_last_word_mask",    \* last_fd_to_close() without BITMAP_LAST_WORD_MASK(n)
              "skip_off_by_one",      \* the empty-stretch skip resumes one word too low
              "hop_off_by_one",       \* the hop resumes one word too low
              "hop_partial",          \* the hop also takes words that stick out above the window
              "no_range_mask",        \* last_fd_to_close() without dup_fd_dropped_word()
              "size_no_except_clamp"} \* sane_fdtable_size() keeps the last descriptor above an EXCEPT range

ASSUME W \in Nat /\ W >= 1
ASSUME MUTATION \in Mutations

NR_OPEN_DEFAULT == W
WordBits == 0..(W - 1)

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b
SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x
SetMin(S) == CHOOSE x \in S : \A y \in S : y >= x
Align(x) == ((x + W - 1) \div W) * W        \* ALIGN(x, BITS_PER_LONG)

Slot == [open : BOOLEAN, file : BOOLEAN, cloexec : BOOLEAN]
Slots == {s \in Slot : s.file => s.open}
Free == [open |-> FALSE, file |-> FALSE, cloexec |-> FALSE]
Closed(s) == [s EXCEPT !.open = FALSE, !.file = FALSE]  \* __put_unused_fd(): close_on_exec stays

Table(n) == [0..(n - 1) -> Slots]
MaxFds(t) == Cardinality(DOMAIN t)
LastFd(t) == MaxFds(t) - 1
Words(t) == 0..(MaxFds(t) \div W - 1)
OpenBits(t, i) == {b \in WordBits : t[i * W + b].open}

Flags == [unshare : BOOLEAN, cloexec : BOOLEAN, except : BOOLEAN, cloexec_only : BOOLEAN]
ValidFlags == {f \in Flags : ~(f.cloexec /\ f.cloexec_only)}   \* the hweight32() check
OldFlags == {f \in Flags : ~f.except /\ ~f.cloexec_only}        \* before the series
ValidFlagsDef == ValidFlags
OldFlagsDef == OldFlags

NoRange == [from |-> 0, to |-> 0, null |-> TRUE]                  \* the NULL fd_range pointer
RangesUpTo(m) == {r \in [from : (0..m) \cup {INF}, to : (0..m) \cup {INF}, null : {FALSE}] :
                      r.from <= r.to}
InRange(r, d) == r.from <= d /\ d <= r.to

(* fd_range_word(): the bits of [from, to] that fall into word i *)
FdRangeWord(r, i) ==
    LET first == i * W
        last == first + W - 1
    IN IF r.to < first \/ r.from > last THEN {}
       ELSE (Max(r.from, first) - first)..(Min(r.to, last) - first)

(* dup_fd_dropped_word(): the bits of word i that dup_fd() leaves behind *)
DupFdDroppedWord(t, i, r, f) ==
    IF r.null THEN {}
    ELSE LET base == FdRangeWord(r, i)
             d1 == IF f.except THEN WordBits \ base ELSE base
         IN IF f.cloexec_only THEN {b \in d1 : t[i * W + b].cloexec} ELSE d1

(* the bit of descriptor d in dup_fd_dropped_word() *)
DupFdDrops(t, d, r, f) == (d % W) \in DupFdDroppedWord(t, d \div W, r, f)

(* find_last_bit(open_fds, size): the last open descriptor below size, or size *)
FindLastBit(t, size) ==
    LET open == {d \in 0..(size - 1) : t[d].open}
    IN IF open = {} THEN size ELSE SetMax(open)

(* sane_fdtable_size() of the series: reach the last open descriptor that is carried over *)
SaneFdtableSizeNew(t, r, f) ==
    LET last == FindLastBit(t, MaxFds(t))
    IN IF last = MaxFds(t) THEN NR_OPEN_DEFAULT
       ELSE IF r.null THEN Align(last + 1)
       ELSE IF f.cloexec_only
       THEN \* the close-on-exec bits decide what is dropped, walk the words
            LET kept == {i \in 0..(last \div W) : OpenBits(t, i) \ DupFdDroppedWord(t, i, r, f) # {}}
            IN IF kept = {} THEN NR_OPEN_DEFAULT ELSE (SetMax(kept) + 1) * W
       ELSE IF f.except
       THEN \* only the range is carried over
            IF last > r.to /\ MUTATION # "size_no_except_clamp"
            THEN LET l1 == FindLastBit(t, r.to + 1)
                 IN IF l1 > r.to THEN NR_OPEN_DEFAULT
                    ELSE IF l1 < r.from THEN NR_OPEN_DEFAULT
                    ELSE Align(l1 + 1)
            ELSE IF last < r.from THEN NR_OPEN_DEFAULT
            ELSE Align(last + 1)
       ELSE IF last >= r.from /\ last <= r.to
       THEN \* the last open descriptor goes, the kept ones sit below the range
            LET l2 == FindLastBit(t, r.from)
            IN IF l2 = r.from THEN NR_OPEN_DEFAULT ELSE Align(l2 + 1)
       ELSE Align(last + 1)

(* sane_fdtable_size() before the series: the punch_hole special case *)
SaneFdtableSizeOld(t, r) ==
    LET last == FindLastBit(t, MaxFds(t))
    IN IF last = MaxFds(t) THEN NR_OPEN_DEFAULT
       ELSE IF ~r.null /\ r.to >= last /\ r.from <= last
            THEN LET l2 == FindLastBit(t, r.from)
                 IN IF l2 = r.from THEN NR_OPEN_DEFAULT ELSE Align(l2 + 1)
            ELSE Align(last + 1)

SaneFdtableSize(t, r, f) ==
    IF DROP_IN_DUP_FD THEN SaneFdtableSizeNew(t, r, f) ELSE SaneFdtableSizeOld(t, r)

(* the copy loop of dup_fd(): a file is carried over unless it is dropped; the loop
   reads dup_fd_dropped_word() once per word, which under file_lock is the same *)
Keeps(t, d, r, f) == t[d].file /\ (DROP_IN_DUP_FD => ~DupFdDrops(t, d, r, f))

(* what sane_fdtable_size() has to reach: open and not dropped *)
Carried(t, d, r, f) == t[d].open /\ ~DupFdDrops(t, d, r, f)

(* dup_fd(): the clone.  max is the size the copy needs (alloc_fdtable() may hand
   out more, those slots are free), slots the descriptors, full the full_fds_bits
   words, refs the descriptors get_file() was called on. *)
DupFd(t, r, f) ==
    LET open_files == SaneFdtableSize(t, r, f)
        copied == open_files \div W       \* the words copy_fd_bitmaps() copies
        slots == [d \in 0..(open_files - 1) |->
                     IF Keeps(t, d, r, f)
                     THEN [open |-> TRUE, file |-> TRUE, cloexec |-> t[d].cloexec]
                     ELSE [open |-> FALSE, file |-> FALSE, cloexec |-> t[d].cloexec]]
        full == [i \in 0..(copied - 1) |->
                     /\ OpenBits(t, i) = WordBits                        \* copied
                     /\ \A b \in WordBits : Keeps(t, i * W + b, r, f)]   \* __clear_open_fd()
    IN [max |-> open_files, slots |-> slots, full |-> full,
        refs |-> {d \in 0..(open_files - 1) : Keeps(t, d, r, f)}]

(* __range_cloexec() *)
RangeCloexec(t, r, f) ==
    LET last == LastFd(t)
        marked == IF ~f.except
                  THEN IF r.from <= last THEN r.from..Min(r.to, last) ELSE {}
                  ELSE (IF r.from > 0 THEN 0..Min(r.from - 1, last) ELSE {})
                       \cup (IF r.to < last THEN (r.to + 1)..last ELSE {})
    IN [d \in DOMAIN t |-> IF d \in marked THEN [t[d] EXCEPT !.cloexec = TRUE] ELSE t[d]]

(* last_fd_to_close(): the highest open descriptor below n that the range selects,
   or n.  The loop is "for (i = n ? (n - 1) / BITS_PER_LONG + 1 : 0; i-- > lo; )",
   LtcLoop gets i before the decrement and j is the word an iteration looks at. *)
RECURSIVE LtcLoop(_, _, _, _, _, _)
LtcLoop(t, n, r, f, i, lo) ==
    IF ~(i > lo) THEN n
    ELSE LET j == i - 1
             set == OpenBits(t, j)
         IN IF set = {}
            THEN \* skip the empty stretch at find_last_bit() speed
                 LET last == FindLastBit(t, j * W)
                 IN IF last >= j * W THEN n
                    ELSE LtcLoop(t, n, r, f,
                                 IF MUTATION = "skip_off_by_one" THEN last \div W
                                 ELSE last \div W + 1, lo)
            ELSE IF /\ f.except
                    /\ j * W >= r.from
                    /\ (MUTATION = "hop_partial" \/ j * W + W - 1 <= r.to)
                 THEN \* hop below the kept window in one step
                      IF r.from = 0 THEN n
                      ELSE LtcLoop(t, n, r, f,
                                   IF MUTATION = "hop_off_by_one" THEN (r.from - 1) \div W
                                   ELSE (r.from - 1) \div W + 1, lo)
                 ELSE LET s1 == IF MUTATION = "no_range_mask" THEN set
                                ELSE set \cap DupFdDroppedWord(t, j, r, f)
                          s2 == IF j = (n - 1) \div W /\ MUTATION # "no_last_word_mask"
                                THEN {b \in s1 : j * W + b < n}    \* BITMAP_LAST_WORD_MASK(n)
                                ELSE s1
                      IN IF s2 # {} THEN j * W + SetMax(s2)        \* __fls()
                         ELSE LtcLoop(t, n, r, f, j, lo)

LastFdToClose(t, n, r, f) ==
    LtcLoop(t, n, r, f, IF n = 0 THEN 0 ELSE (n - 1) \div W + 1,
            IF f.except THEN 0 ELSE r.from \div W)

(* where __range_close() starts: one past the last descriptor it may close *)
WalkStart(t, r, f) == IF f.except THEN MaxFds(t) ELSE Min(r.to, LastFd(t)) + 1

CloseSlot(t, d) == [t EXCEPT ![d] = Closed(t[d])]   \* file_close_fd_locked()

(* __range_close() with nothing running next to it: highest descriptor first, the
   bound comes down to each descriptor the walk finds, a claimed slot stays open *)
RECURSIVE RangeCloseLoop(_, _, _, _)
RangeCloseLoop(t, n, r, f) ==
    LET fd == LastFdToClose(t, n, r, f)
    IN IF fd >= n THEN t
       ELSE RangeCloseLoop(IF t[fd].file THEN CloseSlot(t, fd) ELSE t, fd, r, f)

RangeClose(t, r, f) == RangeCloseLoop(t, WalkStart(t, r, f), r, f)

NoClone == [max |-> 0, slots |-> <<>>, full |-> <<>>, refs |-> {}]

(* sys_close_range() on table t; shared says whether files->count > 1 *)
CloseRange(t, r, f, shared) ==
    IF f.unshare /\ shared
    THEN LET drop == IF f.cloexec THEN NoRange ELSE r   \* "we always copy all of the file descriptors"
             clone == DupFd(t, drop, f)
             cur == IF f.cloexec THEN RangeCloexec(clone.slots, r, f)
                    ELSE IF DROP_IN_DUP_FD THEN clone.slots   \* dup_fd() already left behind what we'd close
                    ELSE RangeClose(clone.slots, r, f)        \* before the series: close from the clone
         IN [cur |-> cur, unshared |-> TRUE, drop |-> drop, clone |-> clone]
    ELSE [cur |-> IF f.cloexec THEN RangeCloexec(t, r, f) ELSE RangeClose(t, r, f),
          unshared |-> FALSE, drop |-> NoRange, clone |-> NoClone]

(* what the flags mean: the descriptors the call acts on *)
Selected(t, r, f, d) ==
    /\ t[d].open
    /\ IF f.except THEN ~InRange(r, d) ELSE InRange(r, d)
    /\ f.cloexec_only => t[d].cloexec

(* and the table the caller ends up with *)
Meaning(t, r, f, shared) ==
    LET base == IF f.unshare /\ shared     \* a private copy holds the installed descriptors
                THEN [d \in DOMAIN t |-> IF t[d].file THEN t[d] ELSE Closed(t[d])]
                ELSE t
    IN IF f.cloexec
       THEN [d \in DOMAIN base |-> IF Selected(base, r, f, d)
                                   THEN [base[d] EXCEPT !.cloexec = TRUE] ELSE base[d]]
       ELSE [d \in DOMAIN base |-> IF Selected(base, r, f, d) /\ base[d].file
                                   THEN Closed(base[d]) ELSE base[d]]

(* observable state: the close_on_exec bit of a closed slot is not, a slot beyond a
   table is free *)
Obs(t, d) == IF d \in DOMAIN t /\ t[d].open THEN t[d] ELSE Free
SameTable(a, b) == \A d \in (DOMAIN a) \cup (DOMAIN b) : Obs(a, d) = Obs(b, d)

SlotsOK(c) == \A d \in DOMAIN c.slots : c.slots[d].file => c.slots[d].open
FullBitsOK(c) == \A i \in DOMAIN c.full :
                     c.full[i] = (\A b \in WordBits : c.slots[i * W + b].open)
SizedExactly(t, r, f, c) ==
    LET carried == {d \in DOMAIN t : Carried(t, d, r, f)}
    IN c.max = IF carried = {} THEN NR_OPEN_DEFAULT ELSE Align(SetMax(carried) + 1)

=============================================================================

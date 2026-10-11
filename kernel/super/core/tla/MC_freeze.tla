---------------------------- MODULE MC_freeze ----------------------------
(* Layouts for SuperFreeze.  The process names are strings; "U", "M", "E" *)
(* and "A" are taken by umount, remount, the emergency thaw and the error  *)
(* that sets SB_RDONLY.                                                    *)
EXTENDS SuperFreeze

KNone == [r \in {} |-> "user"]
LNone == [w \in {} |-> 1]
BNone == [w \in {} |-> FALSE]

\* mix: FIFREEZE, a block device freeze, filesystems_freeze()
KMix == ("u" :> "user") @@ ("b" :> "bdev") @@ ("x" :> "excl")
\* two block devices of one filesystem (fs_bdev_freeze() per device)
KTwoDev == ("b1" :> "bdev") @@ ("b2" :> "bdev")
\* kernel freezers: xfs scrub and filesystems_freeze()
KKern == ("k" :> "kernel") @@ ("x" :> "excl")
\* FIFREEZE and a block device freeze
KUserBdev == ("u" :> "user") @@ ("b" :> "bdev")
\* one block device freeze
KBdev == ("b" :> "bdev")
\* a block device freeze and filesystems_freeze()
KBdevExcl == ("b" :> "bdev") @@ ("x" :> "excl")

\* everything: FIFREEZE, two devices, xfs scrub, filesystems_freeze()
KAll == ("u" :> "user") @@ ("b1" :> "bdev") @@ ("b2" :> "bdev") @@ ("k" :> "kernel") @@ ("x" :> "excl")

RUser == ("r" :> "user")
RKern == ("r" :> "kernel")

\* one writer at SB_FREEZE_WRITE that takes s_umount with it held
WL1 == ("w" :> 1)
WUyes == ("w" :> TRUE)
WUno == ("w" :> FALSE)
\* a page fault and an internal writer
WL23 == ("p" :> 2) @@ ("i" :> 3)
WU23 == ("p" :> FALSE) @@ ("i" :> FALSE)
\* a writer taking s_umount and a page fault
WL12 == ("w" :> 1) @@ ("p" :> 2)
WU12 == ("w" :> TRUE) @@ ("p" :> FALSE)
=============================================================================

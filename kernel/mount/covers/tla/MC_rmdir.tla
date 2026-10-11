------------------------------- MODULE MC_rmdir -------------------------------
(* rmdir of P's mountpoint dP: __detach_mounts() takes the whole tree     *)
(* down with UMOUNT_COVER.  R the root, P on R at dP, C on P at dC, G on  *)
(* C at dG, none of them locked.  One holder keeps a file on P, another   *)
(* one on C; the walkers look dC up on P and dG on C.  The second         *)
(* operation is rmdir of dG.                                              *)
EXTENDS MntCover
ParentDef == ("R" :> NoMnt) @@ ("P" :> "R") @@ ("C" :> "P") @@ ("G" :> "C")
MpDef     == ("R" :> NoDentry) @@ ("P" :> "dP") @@ ("C" :> "dC") @@ ("G" :> "dG")
HolderDef == ("H" :> "P") @@ ("H2" :> "C")
FromDef   == ("W1" :> "H") @@ ("W2" :> "H2")
AtDef     == ("W1" :> "dC") @@ ("W2" :> "dG")
OpsDef    == {[kind |-> "detach", mnt |-> NoMnt, d |-> "dP"],
              [kind |-> "detach", mnt |-> NoMnt, d |-> "dG"]}
=============================================================================

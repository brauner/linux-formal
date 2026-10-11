------------------------------- MODULE MC_lazy --------------------------------
(* umount2(MNT_DETACH) of P while a holder keeps a file open on it: R the  *)
(* root, P on R at dP, C on P at the directory dC, F on P at the file dF.  *)
(* Walkers look dC and dF up from the holder's file.  The second           *)
(* operation is rmdir of dC, from wherever the dentry is reachable.        *)
EXTENDS MntCover
ParentDef == ("R" :> NoMnt) @@ ("P" :> "R") @@ ("C" :> "P") @@ ("F" :> "P")
MpDef     == ("R" :> NoDentry) @@ ("P" :> "dP") @@ ("C" :> "dC") @@ ("F" :> "dF")
HolderDef == ("H" :> "P")
FromDef   == ("W1" :> "H") @@ ("W2" :> "H")
AtDef     == ("W1" :> "dC") @@ ("W2" :> "dF")
OpsDef    == {[kind |-> "lazy", mnt |-> "P", d |-> NoDentry],
              [kind |-> "detach", mnt |-> NoMnt, d |-> "dC"]}
=============================================================================

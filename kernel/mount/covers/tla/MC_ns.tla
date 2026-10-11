------------------------------- MODULE MC_ns ----------------------------------
(* The namespace dies: put_mnt_ns() runs umount_tree() on the root with   *)
(* no flags.  R the root, P on R at dP and locked, C on P at dC and not.  *)
(* One holder keeps a file on R, another one on P; the walkers look dP up *)
(* on R and dC on P.  The second operation is rmdir of dP.                *)
EXTENDS MntCover
ParentDef == ("R" :> NoMnt) @@ ("P" :> "R") @@ ("C" :> "P")
MpDef     == ("R" :> NoDentry) @@ ("P" :> "dP") @@ ("C" :> "dC")
HolderDef == ("H" :> "R") @@ ("H2" :> "P")
FromDef   == ("W1" :> "H") @@ ("W2" :> "H2")
AtDef     == ("W1" :> "dP") @@ ("W2" :> "dC")
OpsDef    == {[kind |-> "nsdeath", mnt |-> NoMnt, d |-> NoDentry],
              [kind |-> "detach", mnt |-> NoMnt, d |-> "dP"]}
=============================================================================

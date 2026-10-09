---------------------------- MODULE MC_mntvacant ----------------------------
(* P 1, the root of the unmounted subtree; M 2 attached to P; G 3 attached *)
(* to M.  With PinDef, M's superblock pins P (the loop device's backing    *)
(* file lives on P) and G's pins M (an image inside the image).  H1 has a  *)
(* file on P, H2 on M.                                                     *)
EXTENDS MntVacant, TLC
ParentDef    == (1 :> 0) @@ (2 :> 1) @@ (3 :> 2)
SbDef        == (1 :> "p") @@ (2 :> "m") @@ (3 :> "g")
PinDef       == ("p" :> 0) @@ ("m" :> 1) @@ ("g" :> 2)
NoPinDef     == ("p" :> 0) @@ ("m" :> 0) @@ ("g" :> 0)
HolderMntDef == ("H1" :> 1) @@ ("H2" :> 2)
=============================================================================

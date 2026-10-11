------------------------------ MODULE MC_mntown ------------------------------
(* Root 1; A 2 under 1 with the loop mount L 3 under it whose superblock   *)
(* pins A (the backing file was opened inside the namespace); D 4 under 1 *)
(* with M 5 under it whose superblock pins D; N 6 under L: an image       *)
(* inside the image, its superblock pins L.                               *)
EXTENDS MntOwn, TLC
ParentDef == (1 :> 0) @@ (2 :> 1) @@ (3 :> 2) @@ (4 :> 1) @@ (5 :> 4) @@ (6 :> 3)
SbDef     == (1 :> "root") @@ (2 :> "a") @@ (3 :> "l") @@ (4 :> "d") @@ (5 :> "m") @@ (6 :> "n")
PinDef    == ("root" :> 0) @@ ("a" :> 0) @@ ("l" :> 2) @@ ("d" :> 0) @@ ("m" :> 4) @@ ("n" :> 3) @@ ("null" :> 0)
PinnerSbsDef == {"l", "m", "n"}
ExtDef    == (1 :> 0) @@ (2 :> 1) @@ (3 :> 0) @@ (4 :> 0) @@ (5 :> 0) @@ (6 :> 0)
=============================================================================

---------------------------- MODULE MC_mountwalk3 ----------------------------
(* The vacate layout.  Root filesystem S: R > a=A, x=X.  Filesystem F:      *)
(* F > pub=Fp > s=Fs, and a negative "x" below F.  The mounter binds Fp,   *)
(* a subdirectory of F, so the mount's root has a parent that lies outside *)
(* the mount.  N is knullfs, a single empty root.  W1 walks a, .., x from  *)
(* the root: through the bind, back up, then x, which exists in S but is   *)
(* negative in F.  W2 walks a, s, .., .., x: two ".." inside the bind.     *)
EXTENDS MountWalk, TLC

DentriesDef == {"R", "A", "X", "F", "Fp", "Fs", "Fx", "N"}
DParentDef  == ("R" :> "R") @@ ("A" :> "R") @@ ("X" :> "R")
               @@ ("F" :> "F") @@ ("Fp" :> "F") @@ ("Fs" :> "Fp") @@ ("Fx" :> "F") @@ ("N" :> "N")
DNameDef    == ("R" :> "/") @@ ("A" :> "a") @@ ("X" :> "x")
               @@ ("F" :> "/") @@ ("Fp" :> "pub") @@ ("Fs" :> "s") @@ ("Fx" :> "x") @@ ("N" :> "/")
DSbDef      == ("R" :> "S") @@ ("A" :> "S") @@ ("X" :> "S")
               @@ ("F" :> "F") @@ ("Fp" :> "F") @@ ("Fs" :> "F") @@ ("Fx" :> "F") @@ ("N" :> "N")
SbRootDef   == ("S" :> "R") @@ ("F" :> "F") @@ ("N" :> "N")
NegativeDef == {"Fx"}
WProgDef    == ("W1" :> <<"a", "..", "x">>) @@ ("W2" :> <<"a", "s", "..", "..", "x">>)
WRootDef    == ("W1" :> [mnt |-> 1, d |-> "R"]) @@ ("W2" :> [mnt |-> 1, d |-> "R"])
WScopedDef  == ("W1" :> FALSE) @@ ("W2" :> FALSE)
=============================================================================

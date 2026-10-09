----------------------------- MODULE MC_propns -----------------------------
(* A propagated copy with a child: pi makes the rootfs shared and clones   *)
(* the namespace within its user namespace (3, 4: peers), mounts F on /a  *)
(* of the copy (5; the copy 6 lands on /a of the initial namespace) and G *)
(* on 5's c (7; the copy 8 under 6).  A lazy umount of 5 commits 8 and    *)
(* then 6: mainline hands them back in that order, the series 6 then 8.   *)
(* MaxOps 1 leaves the umount of 5 as one of the next steps.              *)
EXTENDS MountOps
SbsDef      == {"N", "R", "F", "G"}
DentriesDef == {"N", "R", "Ra", "Rb", "F", "Fc", "G"}
DSbDef      == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R") @@ ("Rb" :> "R") @@ ("F" :> "F") @@ ("Fc" :> "F") @@ ("G" :> "G")
DParentDef  == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R") @@ ("Rb" :> "R") @@ ("F" :> "F") @@ ("Fc" :> "F") @@ ("G" :> "G")
SbRootDef   == ("N" :> "N") @@ ("R" :> "R") @@ ("F" :> "F") @@ ("G" :> "G")
ProcsDef    == {"pi"}
ProcUserDef == ("pi" :> 1)
MountSbsDef == {"F", "G"}
PreludeDef  == << [kind |-> "chtype", p |-> "pi", m |-> 2, type |-> "shared", rec |-> TRUE],
                  [kind |-> "clonens", p |-> "pi", empty |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 4, dentry |-> "Ra"], sb |-> "F", auto |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 5, dentry |-> "Fc"], sb |-> "G", auto |-> FALSE] >>
=============================================================================

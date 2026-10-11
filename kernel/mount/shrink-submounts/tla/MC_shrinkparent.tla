-------------------------- MODULE MC_shrinkparent --------------------------
(* The parent of the shrunk mount goes along with it, the selftest          *)
(* shrink_submounts_test's parent_goes_with_child: V (3), a mount of G at    *)
(* R@Ra; T (4), a shrinkable mount of F at V@Gt, shared; M (5), another      *)
(* shrinkable mount of F on T@Fo, made before anything receives from T;     *)
(* Q (6), a bind of T at V@Gq, made a slave of T; then T is moved to Q@Fo:  *)
(* T sits at the dentry M sits on, under a receiver of T.  MaxOps 0: the synchronous umount of V is the last step. *)
(* the synchronous umount of V as one of the next steps: its shrink        *)
(* unmounts M, which makes T the propagated victim at Q@Fo and takes it     *)
(* along, while the walk is in T's children.                                *)
EXTENDS MountOps
SbsDef      == {"N", "R", "F", "G"}
DentriesDef == {"N", "R", "Ra", "F", "Fo", "G", "Gt", "Gq"}
DSbDef      == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R")
               @@ ("F" :> "F") @@ ("Fo" :> "F") @@ ("G" :> "G") @@ ("Gt" :> "G") @@ ("Gq" :> "G")
DParentDef  == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R")
               @@ ("F" :> "F") @@ ("Fo" :> "F") @@ ("G" :> "G") @@ ("Gt" :> "G") @@ ("Gq" :> "G")
SbRootDef   == ("N" :> "N") @@ ("R" :> "R") @@ ("F" :> "F") @@ ("G" :> "G")
ProcsDef    == {"pi"}
ProcUserDef == ("pi" :> 1)
MountSbsDef == {"F", "G"}
PreludeDef  == << [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 2, dentry |-> "Ra"], sb |-> "G", auto |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 3, dentry |-> "Gt"], sb |-> "F", auto |-> TRUE],
                  [kind |-> "chtype", p |-> "pi", m |-> 4, type |-> "shared", rec |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 4, dentry |-> "Fo"], sb |-> "F", auto |-> TRUE],
                  [kind |-> "bind", p |-> "pi", src |-> [mnt |-> 4, dentry |-> "F"], dst |-> [mnt |-> 3, dentry |-> "Gq"], rec |-> FALSE],
                  [kind |-> "chtype", p |-> "pi", m |-> 6, type |-> "slave", rec |-> FALSE],
                  [kind |-> "move", p |-> "pi", src |-> [mnt |-> 4, dentry |-> "F"], dst |-> [mnt |-> 6, dentry |-> "Fo"], beneath |-> FALSE],
                  [kind |-> "umount", p |-> "pi", m |-> 3, mode |-> "sync"] >>
=============================================================================

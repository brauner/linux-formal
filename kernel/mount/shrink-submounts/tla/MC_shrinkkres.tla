--------------------------- MODULE MC_shrinkkres ---------------------------
(* The layout of the shrink_submounts() finding, the selftest              *)
(* shrink_submounts_test's busy_mount_moved_into_reach: P (3), a shrinkable *)
(* mount of F at R@Ra, shared; P1 (4), a bind of P at R@Rb, a slave of P   *)
(* made shared in turn; P2 (5), a bind of P1 at R@Rc, its peer.  B (6),    *)
(* another shrinkable mount of F on P@Fo, propagates to P1@Fo (7) and       *)
(* P2@Fo (8).  The copy on P2 is made private and R (9), a mount of G, sits *)
(* on its root and is the process's working directory.  P, with B on it,   *)
(* is moved to P1@Fi.  MaxOps 0: the synchronous umount of P1 is the last step. *)
(* of the next steps: its shrink unmounts P1's copy of B first, which      *)
(* takes P2's copy along and slides R to P2@Fo, where the copy of B is     *)
(* looked up when B's turn comes.                                          *)
EXTENDS MountOps
SbsDef      == {"N", "R", "F", "G"}
DentriesDef == {"N", "R", "Ra", "Rb", "Rc", "F", "Fo", "Fi", "G"}
DSbDef      == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R") @@ ("Rb" :> "R") @@ ("Rc" :> "R")
               @@ ("F" :> "F") @@ ("Fo" :> "F") @@ ("Fi" :> "F") @@ ("G" :> "G")
DParentDef  == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R") @@ ("Rb" :> "R") @@ ("Rc" :> "R")
               @@ ("F" :> "F") @@ ("Fo" :> "F") @@ ("Fi" :> "F") @@ ("G" :> "G")
SbRootDef   == ("N" :> "N") @@ ("R" :> "R") @@ ("F" :> "F") @@ ("G" :> "G")
ProcsDef    == {"pi"}
ProcUserDef == ("pi" :> 1)
MountSbsDef == {"F", "G"}
PreludeDef  == << [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 2, dentry |-> "Ra"], sb |-> "F", auto |-> TRUE],
                  [kind |-> "chtype", p |-> "pi", m |-> 3, type |-> "shared", rec |-> FALSE],
                  [kind |-> "bind", p |-> "pi", src |-> [mnt |-> 3, dentry |-> "F"], dst |-> [mnt |-> 2, dentry |-> "Rb"], rec |-> FALSE],
                  [kind |-> "chtype", p |-> "pi", m |-> 4, type |-> "slave", rec |-> FALSE],
                  [kind |-> "chtype", p |-> "pi", m |-> 4, type |-> "shared", rec |-> FALSE],
                  [kind |-> "bind", p |-> "pi", src |-> [mnt |-> 4, dentry |-> "F"], dst |-> [mnt |-> 2, dentry |-> "Rc"], rec |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 3, dentry |-> "Fo"], sb |-> "F", auto |-> TRUE],
                  [kind |-> "chtype", p |-> "pi", m |-> 8, type |-> "private", rec |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 8, dentry |-> "F"], sb |-> "G", auto |-> FALSE],
                  [kind |-> "chdir", p |-> "pi", pos |-> [mnt |-> 9, dentry |-> "G"]],
                  [kind |-> "move", p |-> "pi", src |-> [mnt |-> 3, dentry |-> "F"], dst |-> [mnt |-> 4, dentry |-> "Fi"], beneath |-> FALSE],
                  [kind |-> "umount", p |-> "pi", m |-> 4, mode |-> "sync"] >>
=============================================================================

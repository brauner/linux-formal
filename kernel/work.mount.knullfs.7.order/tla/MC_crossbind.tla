---------------------------- MODULE MC_crossbind ----------------------------
(* A candidate above a candidate that is discovered after it: the copies  *)
(* do not mirror the tree they are cognates of.  pi makes the rootfs      *)
(* shared, mounts F on /a (3, made shared) and G on 3's c (4), binds 3 at *)
(* /b (5, then a slave of 3), binds the rootfs at 5's c (6, then a slave  *)
(* of the rootfs), binds 3 at 6's a (7, then private) and mounts G on 7's *)
(* c (8).  A lazy umount of 3 finds 7 (at /b/c/a under 6, a receiver of   *)
(* the rootfs) from 3 first and 6 (at /b/c under 5, a receiver of 3) from *)
(* 4 second, so trim_one() looks at 6 while its child 7 is undecided, and  *)
(* 7 keeps 8 and stays.  MaxOps 1 leaves the umount of 3 as one of the    *)
(* next steps.                                                            *)
EXTENDS MountOps
SbsDef      == {"N", "R", "F", "G"}
DentriesDef == {"N", "R", "Ra", "Rb", "F", "Fc", "G"}
DSbDef      == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R") @@ ("Rb" :> "R") @@ ("F" :> "F") @@ ("Fc" :> "F") @@ ("G" :> "G")
DParentDef  == ("N" :> "N") @@ ("R" :> "R") @@ ("Ra" :> "R") @@ ("Rb" :> "R") @@ ("F" :> "F") @@ ("Fc" :> "F") @@ ("G" :> "G")
SbRootDef   == ("N" :> "N") @@ ("R" :> "R") @@ ("F" :> "F") @@ ("G" :> "G")
ProcsDef    == {"pi"}
ProcUserDef == ("pi" :> 1)
MountSbsDef == {"G"}
PreludeDef  == << [kind |-> "chtype", p |-> "pi", m |-> 2, type |-> "shared", rec |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 2, dentry |-> "Ra"], sb |-> "F", auto |-> FALSE],
                  [kind |-> "chtype", p |-> "pi", m |-> 3, type |-> "shared", rec |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 3, dentry |-> "Fc"], sb |-> "G", auto |-> FALSE],
                  [kind |-> "bind", p |-> "pi", src |-> [mnt |-> 3, dentry |-> "F"], dst |-> [mnt |-> 2, dentry |-> "Rb"], rec |-> FALSE],
                  [kind |-> "chtype", p |-> "pi", m |-> 5, type |-> "slave", rec |-> FALSE],
                  [kind |-> "bind", p |-> "pi", src |-> [mnt |-> 2, dentry |-> "R"], dst |-> [mnt |-> 5, dentry |-> "Fc"], rec |-> FALSE],
                  [kind |-> "chtype", p |-> "pi", m |-> 6, type |-> "slave", rec |-> FALSE],
                  [kind |-> "bind", p |-> "pi", src |-> [mnt |-> 3, dentry |-> "F"], dst |-> [mnt |-> 6, dentry |-> "Ra"], rec |-> FALSE],
                  [kind |-> "chtype", p |-> "pi", m |-> 7, type |-> "private", rec |-> FALSE],
                  [kind |-> "mount", p |-> "pi", pos |-> [mnt |-> 7, dentry |-> "Fc"], sb |-> "G", auto |-> FALSE] >>
=============================================================================

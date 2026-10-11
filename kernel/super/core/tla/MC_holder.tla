---------------------------- MODULE MC_holder ----------------------------
(* Layouts for SuperHolder.  Task names: m<sb> mounts, u<sb> unmounts,     *)
(* dm<dev> suspends and resumes a device-mapper device, sh<sb> runs a     *)
(* shutdown ioctl, f<sb> FIFREEZE/FITHAW, r<sb> FITHAW without a freeze,  *)
(* e the emergency thaw, a<sb> adds a device, x<sb> removes one.          *)
EXTENDS SuperHolder

\* one: a filesystem on d1
OneMain == ("s1" :> "d1")
OneX == ("s1" :> "none")
OneAfter == ("s1" :> "none")
OneRO == ("s1" :> FALSE)
OneDeg == ("s1" :> FALSE)
OneDegYes == ("s1" :> TRUE)
OneRole == ("m1" :> "mount") @@ ("u1" :> "umount") @@ ("dm1" :> "dm") @@ ("f1" :> "user")
           @@ ("sh1" :> "shut") @@ ("r1" :> "rogue") @@ ("e" :> "ethaw")
OneTgt == ("m1" :> "s1") @@ ("u1" :> "s1") @@ ("dm1" :> "d1") @@ ("f1" :> "s1")
          @@ ("sh1" :> "s1") @@ ("r1" :> "s1") @@ ("e" :> "none")
OneXTgt == [p \in DOMAIN OneRole |-> "none"]

\* remount: s1b mounts d1 once s1 is dead
ReMain == ("s1" :> "d1") @@ ("s1b" :> "d1")
ReX == ("s1" :> "none") @@ ("s1b" :> "none")
ReAfter == ("s1" :> "none") @@ ("s1b" :> "s1")
ReRO == ("s1" :> FALSE) @@ ("s1b" :> FALSE)
ReDeg == ("s1" :> FALSE) @@ ("s1b" :> FALSE)
ReRole == ("m1" :> "mount") @@ ("u1" :> "umount") @@ ("m1b" :> "mount") @@ ("u1b" :> "umount")
          @@ ("dm1" :> "dm") @@ ("f1" :> "user")
ReTgt == ("m1" :> "s1") @@ ("u1" :> "s1") @@ ("m1b" :> "s1b") @@ ("u1b" :> "s1b")
         @@ ("dm1" :> "d1") @@ ("f1" :> "s1")
ReXTgt == [p \in DOMAIN ReRole |-> "none"]

\* multi: s1 on d1 with an extra device d2 (xfs log, ext4 journal, btrfs member)
MultiMain == ("s1" :> "d1")
MultiX == ("s1" :> "d2")
MultiRole == ("m1" :> "mount") @@ ("u1" :> "umount") @@ ("dm1" :> "dm") @@ ("dm2" :> "dm")
             @@ ("f1" :> "user") @@ ("sh1" :> "shut") @@ ("e" :> "ethaw") @@ ("r1" :> "rogue")
MultiTgt == ("m1" :> "s1") @@ ("u1" :> "s1") @@ ("dm1" :> "d1") @@ ("dm2" :> "d2")
            @@ ("f1" :> "s1") @@ ("sh1" :> "s1") @@ ("e" :> "none") @@ ("r1" :> "s1")
MultiXTgt == [p \in DOMAIN MultiRole |-> "none"]

\* shared: s1 on d1 and s2 on d2 share the extra device d3 (erofs, holder
\* the file_system_type)
ShMain == ("s1" :> "d1") @@ ("s2" :> "d2")
ShX == ("s1" :> "d3") @@ ("s2" :> "d3")
ShAfter == ("s1" :> "none") @@ ("s2" :> "none")
ShRO == ("s1" :> TRUE) @@ ("s2" :> TRUE)
ShRW == ("s1" :> FALSE) @@ ("s2" :> FALSE)
ShDeg == ("s1" :> FALSE) @@ ("s2" :> FALSE)
ShRole == ("m1" :> "mount") @@ ("m2" :> "mount") @@ ("u1" :> "umount") @@ ("u2" :> "umount")
          @@ ("dm3" :> "dm") @@ ("f2" :> "user") @@ ("e" :> "ethaw")
ShTgt == ("m1" :> "s1") @@ ("m2" :> "s2") @@ ("u1" :> "s1") @@ ("u2" :> "s2")
         @@ ("dm3" :> "d3") @@ ("f2" :> "s2") @@ ("e" :> "none")
ShXTgt == [p \in DOMAIN ShRole |-> "none"]

\* btrfs: s1 on d1 with the member d2; x1 removes d2, a1 adds d3
BtMain == ("s1" :> "d1")
BtX == ("s1" :> "d2")
BtRole == ("m1" :> "mount") @@ ("u1" :> "umount") @@ ("dm2" :> "dm") @@ ("dm3" :> "dm")
          @@ ("x1" :> "rm") @@ ("a1" :> "add")
BtTgt == ("m1" :> "s1") @@ ("u1" :> "s1") @@ ("dm2" :> "d2") @@ ("dm3" :> "d3")
         @@ ("x1" :> "s1") @@ ("a1" :> "s1")
BtXTgt == ("m1" :> "none") @@ ("u1" :> "none") @@ ("dm2" :> "none") @@ ("dm3" :> "none")
          @@ ("x1" :> "d2") @@ ("a1" :> "d3")
\* big: s1 on d1, s2 on d2, both with the shared extra device d3 (read-write)
BigRole == ("m1" :> "mount") @@ ("m2" :> "mount") @@ ("u1" :> "umount") @@ ("u2" :> "umount")
           @@ ("dm1" :> "dm") @@ ("dm2" :> "dm") @@ ("dm3" :> "dm") @@ ("f1" :> "user")
           @@ ("f2" :> "user") @@ ("sh1" :> "shut") @@ ("e" :> "ethaw") @@ ("r2" :> "rogue")
BigTgt == ("m1" :> "s1") @@ ("m2" :> "s2") @@ ("u1" :> "s1") @@ ("u2" :> "s2")
          @@ ("dm1" :> "d1") @@ ("dm2" :> "d2") @@ ("dm3" :> "d3") @@ ("f1" :> "s1")
          @@ ("f2" :> "s2") @@ ("sh1" :> "s1") @@ ("e" :> "none") @@ ("r2" :> "s2")
BigXTgt == [p \in DOMAIN BigRole |-> "none"]
=============================================================================

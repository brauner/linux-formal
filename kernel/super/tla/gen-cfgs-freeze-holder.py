#!/usr/bin/env python3
# Generate the TLC configurations of SuperFreeze (freeze_*.cfg, module
# MC_freeze) and SuperHolder (holder_*.cfg, module MC_holder).
# Every file starts with a comment line naming what to expect; check-all.sh
# reads it.  Run from this directory: ./gen-cfgs-freeze-holder.py
import os

FREEZE_BASE = dict(
    Rogues="{}", RKind="<- KNone",
    Writers="{}", WLevel="<- LNone", WUmount="<- BNone",
    HAS_UMOUNT="TRUE", HAS_REMOUNT="FALSE", HAS_ETHAW="FALSE", HAS_QWAIT="FALSE",
    ASYNC_RO="FALSE", RO_INIT="FALSE",
    SYNC_FAIL="FALSE", FREEZEFS_FAIL="FALSE", UNFREEZE_FAIL="FALSE",
    KILLABLE="FALSE", WEAK_WAKE="FALSE", SBW_BARRIER="TRUE",
    FIX_DROP_UMOUNT="TRUE", FIX_NESTED_THAW_RET="TRUE", FIX_EXCL_OWNER="TRUE",
    FIX_RO_RECORD="FALSE", FIX_WAKE_MB="FALSE",
)
FREEZE_ORDER = ["Freezers", "FKind", "Rogues", "RKind", "Writers", "WLevel", "WUmount",
                "HAS_UMOUNT", "HAS_REMOUNT", "HAS_ETHAW", "HAS_QWAIT", "ASYNC_RO", "RO_INIT",
                "SYNC_FAIL", "FREEZEFS_FAIL", "UNFREEZE_FAIL", "KILLABLE",
                "WEAK_WAKE", "SBW_BARRIER",
                "FIX_DROP_UMOUNT", "FIX_NESTED_THAW_RET", "FIX_EXCL_OWNER",
                "FIX_RO_RECORD", "FIX_WAKE_MB"]
F_ALL = ["NoErr", "CountsOK", "HoldsOK", "BeliefOK", "ActiveOK", "ExclOK", "DeadOK", "RwsemOK"]
F_NOHOLD = ["NoErr", "CountsOK", "BeliefOK", "ActiveOK", "ExclOK", "DeadOK", "RwsemOK"]
# the emergency thaw takes holds by design, so neither the holds nor what the
# freezers were told are checked with it
F_STATE = ["NoErr", "CountsOK", "ActiveOK", "ExclOK", "DeadOK", "RwsemOK"]

MIX = dict(Freezers='{"u", "b", "x"}', FKind="<- KMix")
FAILS = dict(SYNC_FAIL="TRUE", FREEZEFS_FAIL="TRUE", UNFREEZE_FAIL="TRUE", KILLABLE="TRUE")
W1U = dict(Writers='{"w"}', WLevel="<- WL1", WUmount="<- WUyes")
W1 = dict(Writers='{"w"}', WLevel="<- WL1", WUmount="<- WUno")
W23 = dict(Writers='{"p", "i"}', WLevel="<- WL23", WUmount="<- WU23")

FREEZE = [
    ("freeze_mix_fixed", "pass",
     "FIFREEZE, a block device freeze and filesystems_freeze() against a writer that takes s_umount with SB_FREEZE_WRITE held, a remount and the umount",
     dict(MIX, **W1U, HAS_REMOUNT="TRUE"), F_ALL),
    ("freeze_mix_fail", "pass",
     "the mix with sync_filesystem(), ->freeze_fs() and ->unfreeze_fs() failing and fatal signals in wait_for_partially_frozen()",
     dict(MIX, **W1U, **FAILS), F_ALL),
    ("freeze_twodev_fail", "pass",
     "two block devices of one filesystem freezing it with FREEZE_MAY_NEST, a page fault and an internal writer, every failure",
     dict(Freezers='{"b1", "b2"}', FKind="<- KTwoDev", **W23, **FAILS), F_ALL),
    ("freeze_ro_init", "pass",
     "the mix on a read-only superblock (the sb_rdonly() shortcuts) with a remount read-write",
     dict(MIX, **W1, RO_INIT="TRUE", HAS_REMOUNT="TRUE"), F_ALL),
    ("freeze_kern_fixed", "pass",
     "xfs scrub's kernel freeze, filesystems_freeze() and a kernel thaw without a freeze: the owner check keeps the exclusive freeze",
     dict(Freezers='{"k", "x"}', FKind="<- KKern", Rogues='{"r"}', RKind="<- RKern"), F_NOHOLD),
    ("freeze_kern_no_owner", "violation: ExclOK",
     "without may_unfreeze()'s owner check a kernel thaw takes the last kernel hold of filesystems_freeze()",
     dict(Freezers='{"k", "x"}', FKind="<- KKern", Rogues='{"r"}', RKind="<- RKern",
          FIX_EXCL_OWNER="FALSE"), F_NOHOLD),
    ("freeze_steal", "violation: HoldsOK",
     "FITHAW from a task that holds no freeze takes the block device's FREEZE_MAY_NEST hold (they share freeze_ucount)",
     dict(Freezers='{"b"}', FKind="<- KBdev", Rogues='{"r"}', RKind="<- RUser"), F_ALL),
    ("freeze_nested_ret", "violation: BeliefOK",
     "before fe967191e585 a nested thaw that dropped its hold returned -EINVAL",
     dict(Freezers='{"u", "b"}', FKind="<- KUserBdev", FIX_NESTED_THAW_RET="FALSE"), F_ALL),
    ("freeze_ro_async", "violation: RwsemOK",
     "a filesystem that sets SB_RDONLY on an error while frozen: thaw_super_locked() takes the sb_rdonly() branch and never releases the freeze levels",
     dict(Freezers='{"b"}', FKind="<- KBdev", **W1, ASYNC_RO="TRUE"), F_ALL),
    ("freeze_ro_async_fixed", "pass",
     "the same with the thaw deciding by how the freeze was taken (proposed fix)",
     dict(Freezers='{"b"}', FKind="<- KBdev", **W1, ASYNC_RO="TRUE", FIX_RO_RECORD="TRUE"), F_ALL),
    ("freeze_ro_async_mix", "pass",
     "the mix with the error setting SB_RDONLY and the proposed fix",
     dict(MIX, **W1, ASYNC_RO="TRUE", HAS_REMOUNT="TRUE", FIX_RO_RECORD="TRUE", **FAILS), F_ALL),
    ("freeze_drop_umount", "deadlock",
     "freeze_super() holding s_umount across sb_wait_write(SB_FREEZE_WRITE) deadlocks against a writer that takes s_umount",
     dict(Freezers='{"b"}', FKind="<- KBdev", **W1U, FIX_DROP_UMOUNT="FALSE"), F_ALL),
    ("freeze_wake_weak", "pass",
     "stores to s_writers.frozen buffered: no smp_mb() before wake_up_var(), still no lost wakeup in wait_for_partially_frozen()",
     dict(Freezers='{"u", "b"}', FKind="<- KUserBdev", **W1, WEAK_WAKE="TRUE", KILLABLE="TRUE",
          SYNC_FAIL="TRUE", FREEZEFS_FAIL="TRUE"), F_ALL + ["NoLostWakeup"]),
    ("freeze_wake_nobarrier", "violation: NoLostWakeup",
     "the same without the full barrier of percpu_down_write() after the SB_FREEZE_PAGEFAULT store: the wakeup is lost",
     dict(Freezers='{"u", "b"}', FKind="<- KUserBdev", **W1, WEAK_WAKE="TRUE", SBW_BARRIER="FALSE"),
     F_ALL + ["NoLostWakeup"]),
    ("freeze_wake_mb", "pass",
     "no barrier in percpu_down_write() but smp_mb() before wake_up_var()",
     dict(Freezers='{"u", "b"}', FKind="<- KUserBdev", **W1, WEAK_WAKE="TRUE", SBW_BARRIER="FALSE",
          FIX_WAKE_MB="TRUE"), F_ALL + ["NoLostWakeup"]),
    ("freeze_all_fail", "pass",
     "FIFREEZE, two block devices, xfs scrub and filesystems_freeze() against a writer taking s_umount and a page fault, a remount, every failure (large: run on a big machine)",
     dict(Freezers='{"u", "b1", "b2", "k", "x"}', FKind="<- KAll", Writers='{"w", "p"}',
          WLevel="<- WL12", WUmount="<- WU12", HAS_REMOUNT="TRUE", **FAILS), F_ALL),
    ("freeze_all_weak", "pass",
     "the same set of freezers with buffered stores to s_writers.frozen and NoLostWakeup (large)",
     dict(Freezers='{"u", "b1", "b2", "k", "x"}', FKind="<- KAll", **W1, WEAK_WAKE="TRUE",
          KILLABLE="TRUE", SYNC_FAIL="TRUE", FREEZEFS_FAIL="TRUE"), F_ALL + ["NoLostWakeup"]),
    ("freeze_qwait_nomb", "violation: NoLostWakeup",
     "quotactl_block() waiting for SB_UNFROZEN on s_writers.frozen (\"quota: really wait for the thaw in quotactl_block()\" without its smp_mb() before wake_up_var()): the thaw's wakeup is lost",
     dict(Freezers='{"u", "b"}', FKind="<- KUserBdev", HAS_QWAIT="TRUE", WEAK_WAKE="TRUE"),
     F_ALL + ["NoLostWakeup"]),
    ("freeze_qwait_mb", "pass",
     "the same with sb_freeze_wake()'s smp_mb() (\"quota: really wait for the thaw in quotactl_block()\")",
     dict(Freezers='{"u", "b"}', FKind="<- KUserBdev", HAS_QWAIT="TRUE", WEAK_WAKE="TRUE",
          FIX_WAKE_MB="TRUE", KILLABLE="TRUE", RO_INIT="FALSE"), F_ALL + ["NoLostWakeup"]),
    ("freeze_qwait_ro_mb", "pass",
     "the same on a read-only superblock (frozen by the shortcut, the case the change is for)",
     dict(Freezers='{"u", "b"}', FKind="<- KUserBdev", HAS_QWAIT="TRUE", WEAK_WAKE="TRUE",
          FIX_WAKE_MB="TRUE", KILLABLE="TRUE", RO_INIT="TRUE"), F_ALL + ["NoLostWakeup"]),
    ("freeze_ethaw", "pass",
     "the emergency thaw against a block device freeze, filesystems_freeze() and umount",
     dict(Freezers='{"b", "x"}', FKind="<- KBdevExcl", HAS_ETHAW="TRUE", **W1), F_STATE),
    ("freeze_ethaw_hold", "violation: HoldsOK",
     "the emergency thaw takes the block device's hold (documented: it thaws every userspace freeze)",
     dict(Freezers='{"b", "x"}', FKind="<- KBdevExcl", HAS_ETHAW="TRUE"), F_ALL),
]


def write(name, module, expect, desc, consts, order, invs):
    with open(name + ".cfg", "w") as f:
        f.write(f"\\* generated by gen-cfgs-freeze-holder.py: {module}, expected: {expect}\n")
        f.write(f"\\* {desc}\n")
        f.write("SPECIFICATION Spec\nCONSTANTS\n")
        for k in order:
            v = consts[k]
            if v.startswith("<-"):
                f.write(f"  {k} {v}\n")
            else:
                f.write(f"  {k} = {v}\n")
        f.write("INVARIANTS\n")
        for i in invs:
            f.write(f"  {i}\n")


def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    for name, expect, desc, over, invs in FREEZE:
        c = dict(FREEZE_BASE)
        c.update(over)
        write(name, "SuperFreeze", expect, desc, c, FREEZE_ORDER, invs)
    for name, expect, desc, consts, order, invs in HOLDER:
        write(name, "SuperHolder", expect, desc, consts, order, invs)


HOLDER_BASE = dict(
    FREEZE_FAIL="FALSE", SYNC_FAIL="FALSE", ADD_ABORT="FALSE",
    FIX_SETUP_CHECK="TRUE", FIX_REGISTER_CHECK="TRUE", FIX_NESTED_THAW_RET="TRUE",
    FIX_THAW_ALL_UNLOCKED="TRUE", FIX_SWALLOW="TRUE", FIX_DENY="TRUE",
    FIX_UNREGISTER_FIRST="TRUE", FIX_SYNC_ROLLBACK="FALSE", FIX_THAW_EINVAL_OK="FALSE",
)
HOLDER_ORDER = ["Devs", "Sbs", "Main", "XDev", "After", "RO", "XDegraded", "Procs", "Role", "Tgt", "XTgt",
                "FREEZE_FAIL", "SYNC_FAIL", "ADD_ABORT",
                "FIX_SETUP_CHECK", "FIX_REGISTER_CHECK", "FIX_NESTED_THAW_RET",
                "FIX_THAW_ALL_UNLOCKED", "FIX_SWALLOW", "FIX_DENY", "FIX_UNREGISTER_FIRST",
                "FIX_SYNC_ROLLBACK", "FIX_THAW_EINVAL_OK"]
H_ALL = ["NoErr", "SbOK", "FrozenWhileHeld", "UserOK", "CountOK", "FinalOK"]
# with the emergency thaw the freezes of others are taken by design, so only
# what is left at the end is checked
H_ETHAW = ["NoErr", "SbOK", "FinalOK"]

ONE = dict(Devs='{"d1"}', Sbs='{"s1"}', Main="<- OneMain", XDev="<- OneX", After="<- OneAfter",
           RO="<- OneRO", XDegraded="<- OneDeg", Role="<- OneRole", Tgt="<- OneTgt", XTgt="<- OneXTgt")
RE = dict(Devs='{"d1"}', Sbs='{"s1", "s1b"}', Main="<- ReMain", XDev="<- ReX", After="<- ReAfter",
          RO="<- ReRO", XDegraded="<- ReDeg", Role="<- ReRole", Tgt="<- ReTgt", XTgt="<- ReXTgt")
MULTI = dict(Devs='{"d1", "d2"}', Sbs='{"s1"}', Main="<- MultiMain", XDev="<- MultiX",
             After="<- OneAfter", RO="<- OneRO", XDegraded="<- OneDeg", Role="<- MultiRole", Tgt="<- MultiTgt",
             XTgt="<- MultiXTgt")
SHARED = dict(Devs='{"d1", "d2", "d3"}', Sbs='{"s1", "s2"}', Main="<- ShMain", XDev="<- ShX",
              After="<- ShAfter", RO="<- ShRO", XDegraded="<- ShDeg", Role="<- ShRole", Tgt="<- ShTgt", XTgt="<- ShXTgt")
BTRFS = dict(Devs='{"d1", "d2", "d3"}', Sbs='{"s1"}', Main="<- BtMain", XDev="<- BtX",
             After="<- OneAfter", RO="<- OneRO", XDegraded="<- OneDeg", Role="<- BtRole", Tgt="<- BtTgt", XTgt="<- BtXTgt")

BIG = dict(Devs='{"d1", "d2", "d3"}', Sbs='{"s1", "s2"}', Main="<- ShMain", XDev="<- ShX",
           After="<- ShAfter", RO="<- ShRW", XDegraded="<- ShDeg", Role="<- BigRole", Tgt="<- BigTgt",
           XTgt="<- BigXTgt")


def procs(*names):
    return "{" + ", ".join(f'"{n}"' for n in names) + "}"


HOLDER_SPECS = [
    ("holder_one_fixed", "pass",
     "one filesystem: mount, dm suspend/resume, FIFREEZE/FITHAW, a shutdown ioctl, umount",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "f1", "sh1")), H_ALL),
    ("holder_one_fail", "pass",
     "the same with freezes that fail",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "f1", "sh1"), FREEZE_FAIL="TRUE"), H_ALL),
    ("holder_one_nested_ret", "violation: CountOK",
     "before fe967191e585: FIFREEZE, dm suspend, dm resume leaves bd_fsfreeze_count at 1",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "f1"), FIX_NESTED_THAW_RET="FALSE"), H_ALL),
    ("holder_one_steal", "violation: FrozenWhileHeld",
     "FITHAW without a freeze thaws the filesystem under a suspended dm device",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "r1")), H_ALL),
    ("holder_one_steal_count", "violation: CountOK",
     "and dm resume then fails, bd_fsfreeze_count stays 1: the device can never be mounted again",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "r1")), ["NoErr", "SbOK", "CountOK", "FinalOK"]),
    ("holder_one_steal_fixed", "pass",
     "FITHAW without a freeze with the proposed fs_bdev_thaw() fix: the filesystem is still thawed under dm, but the count goes",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "r1", "f1", "sh1"), FIX_THAW_EINVAL_OK="TRUE"),
     ["NoErr", "SbOK", "CountOK", "FinalOK"]),
    ("holder_one_sync", "violation: FinalOK",
     "sync_blockdev() fails after fs_bdev_freeze() froze the superblock: bdev_freeze() fails, drops the count, the filesystem stays frozen",
     dict(ONE, Procs=procs("m1", "u1", "dm1"), SYNC_FAIL="TRUE"), H_ALL),
    ("holder_one_sync_rollback", "pass",
     "the same with the frozen superblocks thawed again on that failure (proposed fix)",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "f1", "sh1"), SYNC_FAIL="TRUE", FIX_SYNC_ROLLBACK="TRUE"),
     H_ALL),
    ("holder_one_ethaw", "violation: FinalOK",
     "the emergency thaw's bdev_thaw() loop finds the device unfrozen, dm suspends, thaw_super_locked() takes dm's hold, dm resume fails: bd_fsfreeze_count stays 1",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "f1", "e")), H_ETHAW),
    ("holder_one_ethaw_fixed", "pass",
     "the same with fs_bdev_thaw() counting a superblock without a userspace hold as thawed (proposed fix)",
     dict(ONE, Procs=procs("m1", "u1", "dm1", "f1", "e"), FIX_THAW_EINVAL_OK="TRUE"), H_ETHAW),
    ("holder_one_ethaw_locked", "deadlock",
     "before 749d7aa0377a the emergency thaw held s_umount across bdev_thaw(), which takes it again",
     dict(ONE, Procs=procs("m1", "dm1", "e"), FIX_THAW_ALL_UNLOCKED="FALSE"), H_ETHAW),
    ("holder_one_mountrace", "pass",
     "a mount racing with dm suspend: refused while the device is frozen, else frozen by the walk",
     dict(ONE, Procs=procs("m1", "dm1", "u1")), H_ALL),
    ("holder_one_mountrace_nocheck", "violation: FrozenWhileHeld",
     "without setup_bdev_super()'s check the superblock is mounted unfrozen on a frozen device",
     dict(ONE, Procs=procs("m1", "dm1", "u1"), FIX_SETUP_CHECK="FALSE"), H_ALL),
    ("holder_remount", "pass",
     "umount while dm-frozen, the thaw kills the superblock, a new superblock mounts the device",
     dict(RE, Procs=procs("m1", "u1", "m1b", "u1b", "dm1", "f1")), H_ALL),
    ("holder_multi_fixed", "pass",
     "a filesystem on two devices: dm on either, FIFREEZE, a shutdown ioctl, umount",
     dict(MULTI, Procs=procs("m1", "u1", "dm1", "dm2", "f1", "sh1")), H_ALL),
    ("holder_multi_fail", "pass",
     "the two-device filesystem with failing freezes, two dm devices, FIFREEZE, the shutdown ioctl and umount",
     dict(MULTI, Procs=procs("m1", "u1", "dm1", "dm2", "f1", "sh1"), FREEZE_FAIL="TRUE"), H_ALL),
    ("holder_multi_all_fixed", "pass",
     "everything on the two-device filesystem including the emergency thaw and a FITHAW without a freeze, with both proposed fixes and sync_blockdev() failing",
     dict(MULTI, Procs=procs("m1", "u1", "dm1", "dm2", "f1", "sh1", "e", "r1"), FREEZE_FAIL="TRUE",
          SYNC_FAIL="TRUE", FIX_SYNC_ROLLBACK="TRUE", FIX_THAW_EINVAL_OK="TRUE"), H_ETHAW),
    ("holder_degraded", "violation: CountOK",
     "btrfs -o degraded: the member's registration is refused while frozen but its entry was briefly visible; a bdev_thaw() walk pinned it, waits for SB_BORN and thaws a superblock that was never frozen through the device: bd_fsfreeze_count stays 1 (the device-table model's dtdeg_tree)",
     dict(MULTI, XDegraded="<- OneDegYes", Procs=procs("m1", "u1", "dm2")), H_ALL),
    ("holder_degraded_leak", "violation: FinalOK",
     "the freeze direction: a bdev_freeze() walk pins the refused entry, freezes the superblock once born, and the thaw finds no holder on the device: the superblock stays frozen",
     dict(MULTI, XDegraded="<- OneDegYes", Procs=procs("m1", "u1", "dm2"), FIX_THAW_EINVAL_OK="TRUE"),
     ["NoErr", "SbOK", "CountOK", "FinalOK"]),
    ("holder_degraded_steal", "violation: FrozenWhileHeld",
     "and with a freeze of the main device the stray thaw takes that device's freeze (dtmultideg_tree); the proposed fix does not cover this",
     dict(MULTI, XDegraded="<- OneDegYes", Procs=procs("m1", "u1", "dm1", "dm2"),
          FIX_THAW_EINVAL_OK="TRUE"), H_ALL),
    ("holder_multi_xrace_nocheck", "violation: FrozenWhileHeld",
     "without fs_bdev_register()'s check the extra device is opened while frozen",
     dict(MULTI, Procs=procs("m1", "u1", "dm2"), FIX_REGISTER_CHECK="FALSE"), H_ALL),
    ("holder_multi_ethaw", "violation: FinalOK",
     "the emergency thaw thaws the filesystem frozen through the extra device; dm resume of that device then fails and its count stays",
     dict(MULTI, Procs=procs("m1", "u1", "dm2", "e")), H_ETHAW),
    ("holder_multi_ethaw_fixed", "pass",
     "the same with the proposed fs_bdev_thaw() fix",
     dict(MULTI, Procs=procs("m1", "u1", "dm1", "dm2", "f1", "e"), FIX_THAW_EINVAL_OK="TRUE"), H_ETHAW),
    ("holder_shared_ro", "violation: FinalOK",
     "two read-only superblocks (erofs) sharing a device under dm suspend/resume and the emergency thaw: the shared device is never s_bdev, its count is left at 1 and the next mount using it fails",
     dict(SHARED, Procs=procs("m1", "m2", "u1", "u2", "dm3", "e"), FREEZE_FAIL="TRUE"), H_ETHAW),
    ("holder_shared_ro_fixed", "pass",
     "the same with the proposed fs_bdev_thaw() fix",
     dict(SHARED, Procs=procs("m1", "m2", "u1", "u2", "dm3", "e"), FREEZE_FAIL="TRUE",
          FIX_THAW_EINVAL_OK="TRUE"), H_ETHAW),
    ("holder_shared_ro_held", "pass",
     "the same without the emergency thaw, every invariant",
     dict(SHARED, Procs=procs("m1", "m2", "u1", "u2", "dm3"), FREEZE_FAIL="TRUE"), H_ALL),
    ("holder_shared_fail", "violation: FrozenWhileHeld",
     "read-write superblocks sharing a device: a swallowed per-superblock freeze failure leaves one unfrozen under the frozen device (intended by 7a7ef107b449)",
     dict(SHARED, RO="<- ShRW", Procs=procs("m1", "m2", "u1", "u2", "dm3"), FREEZE_FAIL="TRUE"), H_ALL),
    ("holder_shared_steal", "violation: UserOK",
     "and fs_bdev_thaw() then thaws that superblock anyway, taking the FIFREEZE hold of its owner",
     dict(SHARED, RO="<- ShRW", Procs=procs("m1", "m2", "u1", "u2", "dm3", "f2"), FREEZE_FAIL="TRUE"),
     ["NoErr", "SbOK", "UserOK", "CountOK", "FinalOK"]),
    ("holder_shared_noswallow", "violation: FinalOK",
     "before 7a7ef107b449 the per-superblock error failed bdev_freeze() and left the others frozen",
     dict(SHARED, RO="<- ShRW", Procs=procs("m1", "m2", "u1", "u2", "dm3"), FREEZE_FAIL="TRUE",
          FIX_SWALLOW="FALSE"), H_ALL),
    ("holder_big", "pass",
     "two read-write superblocks sharing a device: mounts, umounts, dm on all three devices, FIFREEZE on both, a shutdown ioctl (large: run on a big machine)",
     dict(BIG, Procs=procs("m1", "m2", "u1", "u2", "dm1", "dm2", "dm3", "f1", "f2", "sh1")), H_ALL),
    ("holder_big_fixed", "pass",
     "the same plus the emergency thaw, a FITHAW without a freeze, failing freezes and sync_blockdev(), with both proposed fixes (large)",
     dict(BIG, Procs=procs("m1", "m2", "u1", "u2", "dm1", "dm3", "f1", "f2", "sh1", "e", "r2"),
          FREEZE_FAIL="TRUE", SYNC_FAIL="TRUE", FIX_SYNC_ROLLBACK="TRUE", FIX_THAW_EINVAL_OK="TRUE"),
     H_ETHAW),
    ("holder_btrfs_fixed", "pass",
     "a device removed and a device added (with an abort) under dm suspend/resume of both",
     dict(BTRFS, Procs=procs("m1", "u1", "dm2", "dm3", "x1", "a1"), ADD_ABORT="TRUE"), H_ALL),
    ("holder_btrfs_nodeny", "violation: FinalOK",
     "without bdev_deny_freeze() a removal or an aborted add strands a freeze",
     dict(BTRFS, Procs=procs("m1", "u1", "dm2", "dm3", "x1", "a1"), ADD_ABORT="TRUE", FIX_DENY="FALSE"),
     ["NoErr", "SbOK", "FinalOK"]),
    ("holder_btrfs_allow_first", "violation: FinalOK",
     "re-allowing the freeze before unregistering the removed device strands a freeze",
     dict(BTRFS, Procs=procs("m1", "u1", "dm2", "x1"), FIX_UNREGISTER_FIRST="FALSE"),
     ["NoErr", "SbOK", "FinalOK"]),
]

HOLDER = []
for name, expect, desc, over, invs in HOLDER_SPECS:
    c = dict(HOLDER_BASE)
    c.update(over)
    HOLDER.append((name, expect, desc, c, HOLDER_ORDER, invs))

if __name__ == "__main__":
    main()

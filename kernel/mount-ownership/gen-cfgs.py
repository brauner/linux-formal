#!/usr/bin/env python3
"""Generate the TLC configurations of MntOwn: who owns an unmounted mount,
for the three unmerged answers (tombstones, disconnecting pinners, internal
clones) against upstream."""
import pathlib

# MntOwn: who owns an unmounted mount.  name: (fixes off, locked mounts,
# LAZY, SYNC, DETACH, invariants, expectation)
OWN_FIXES = ["FIX_PUT_MNT_NS_DISCONNECT", "FIX_DISOWN", "FIX_DISCONNECT_PINNERS", "PINNERS_ANCESTOR_ONLY", "PINNERS_REEXAMINE",
             "FIX_INTERNAL_CLONE", "PIN_BUSY"]
OWN_SAFETY = ["TypeOK", "NoUAF", "Reaped", "OwnRef", "TombOK"]
OWN_PROOF = ["TypeOK", "NoUAF", "OwnRef", "TombOK", "TombLeaf", "LeaksAreCycles"]
OWN_CLONE_PROOF = ["TypeOK", "NoUAF", "OwnRef", "TombOK", "MountsReaped", "SbLeaksAreCycles", "LeaksAreCycles"]
OWN_CONFIGS = {
    # every way the three pinning superblocks can hold a file on a mount,
    # including mutual pins: with the tombstones the only mounts left at the
    # end are the ones a cycle of pins keeps alive by itself; without them
    # the ownership of attached unmounted mounts leaks more
    "mntown_disown_anypin":           ([], set(), True, True, True, OWN_PROOF, "pass"),
    "mntown_disown_anypin_locked":    ([], {3, 5}, True, True, True, OWN_PROOF, "pass"),
    "mntown_disown_anypin_connected": (["FIX_PUT_MNT_NS_DISCONNECT"], {3, 5}, True, True, True, OWN_PROOF, "pass"),
    "mntown_revert_anypin":           (["FIX_DISOWN"], set(), True, True, True, OWN_PROOF, "violation"),
    "mntown_disown_anypin_reaped":    ([], set(), True, True, True, OWN_SAFETY, "violation"),
    # the targeted alternative: no disowning, umount_tree() disconnects a
    # victim whose superblock pins a victim.  "all pinners" is expected to
    # leave only pin cycles; "ancestor only" is expected to miss the cycles
    # that run through two pins
    "mntown_pinners_anypin":          (["FIX_DISOWN", "PINNERS_ANCESTOR_ONLY"], set(), True, True, True, OWN_PROOF, "violation"),
    "mntown_pinners_anypin_locked":   (["FIX_DISOWN", "PINNERS_ANCESTOR_ONLY"], {3, 5}, True, True, True, OWN_PROOF, "violation"),
    "mntown_pinners_anypin_connected": (["FIX_DISOWN", "PINNERS_ANCESTOR_ONLY", "FIX_PUT_MNT_NS_DISCONNECT"], {3, 5}, True, True, True, OWN_PROOF, "violation"),
    "mntown_pinners_ancestor_anypin": (["FIX_DISOWN"], set(), True, True, True, OWN_PROOF, "violation"),
    # the disconnect rule applied to the mounts earlier teardowns left
    # connected as well: the only complete form of the targeted fix
    "mntown_reexamine_anypin":        (["FIX_DISOWN", "PINNERS_ANCESTOR_ONLY"], set(), True, True, True, OWN_PROOF, "pass"),
    "mntown_reexamine_anypin_locked": (["FIX_DISOWN", "PINNERS_ANCESTOR_ONLY"], {3, 5}, True, True, True, OWN_PROOF, "pass"),
    "mntown_reexamine_anypin_connected": (["FIX_DISOWN", "PINNERS_ANCESTOR_ONLY", "FIX_PUT_MNT_NS_DISCONNECT"], {3, 5}, True, True, True, OWN_PROOF, "pass"),
    # 0342482a4d15: put_mnt_ns() leaves the tree connected, the loop mount's
    # superblock pins its ancestor, nothing is ever freed (Michael Vogt's report)
    "mntown_connected_ns":     (["FIX_DISOWN", "FIX_PUT_MNT_NS_DISCONNECT"], set(), False, False, False, OWN_SAFETY, "violation"),
    # the revert: put_mnt_ns() disconnects, the cycle cannot form
    "mntown_revert":           (["FIX_DISOWN"], set(), False, True, False, OWN_SAFETY, "pass"),
    # the same class through a locked child that stays connected under a
    # lazy umount or the namespace's death
    "mntown_revert_locked":    (["FIX_DISOWN"], {3}, True, False, False, OWN_SAFETY, "violation"),
    # and through rmdir of a mountpoint: __detach_mounts() keeps the subtree connected
    "mntown_revert_detach":    (["FIX_DISOWN"], set(), False, False, True, OWN_SAFETY, "violation"),
    # the tombstone mechanism closes every entry point, with or without the revert
    "mntown_disown":           ([], set(), True, True, True, OWN_SAFETY, "pass"),
    "mntown_disown_locked":    ([], {3}, True, True, True, OWN_SAFETY, "pass"),
    "mntown_disown_connected": (["FIX_PUT_MNT_NS_DISCONNECT"], {3, 5}, True, True, True, OWN_SAFETY, "pass"),
    # the rule of work.mount.private_clone: holders keep their files on
    # internal clones, so a pin is a reference on a superblock and never on
    # a mount; no tombstones, no pinner rule, with or without the revert,
    # locked children or not, every entry point available
    "mntown_clone":            (["FIX_DISOWN"], set(), True, True, True, OWN_SAFETY, "pass"),
    "mntown_clone_locked":     (["FIX_DISOWN"], {3}, True, True, True, OWN_SAFETY, "pass"),
    "mntown_clone_connected":  (["FIX_DISOWN", "FIX_PUT_MNT_NS_DISCONNECT"], {3, 5}, True, True, True, OWN_SAFETY, "pass"),
    "mntown_clone_busy":       (["FIX_DISOWN"], set(), True, True, True, OWN_SAFETY, "pass"),
    # every pin configuration: every mount is freed, only cycles of
    # superblocks survive; `_reaped` shows those cycles exist in the layout
    "mntown_clone_anypin":           (["FIX_DISOWN"], set(), True, True, True, OWN_CLONE_PROOF, "pass"),
    "mntown_clone_anypin_locked":    (["FIX_DISOWN"], {3, 5}, True, True, True, OWN_CLONE_PROOF, "pass"),
    "mntown_clone_anypin_connected": (["FIX_DISOWN", "FIX_PUT_MNT_NS_DISCONNECT"], {3, 5}, True, True, True, OWN_CLONE_PROOF, "pass"),
    "mntown_clone_anypin_busy":      (["FIX_DISOWN"], set(), True, True, True, OWN_CLONE_PROOF, "pass"),
    "mntown_clone_anypin_reaped":    (["FIX_DISOWN"], set(), True, True, True, OWN_SAFETY, "violation"),
}
for name, (off, locked, lazy, sync, detach, invs, expect) in OWN_CONFIGS.items():
    lines = [f"\\* generated by gen-cfgs.py: MntOwn, expected: {expect}", "SPECIFICATION Spec", "CONSTANTS",
             "  MntIds = {1, 2, 3, 4, 5, 6}", "  Root = 1", "  Parent <- ParentDef",
             '  SbIds = {"root", "a", "l", "d", "m", "n", "null"}', "  Sb <- SbDef", "  Pin <- PinDef",
             "  Locked = {" + ", ".join(str(x) for x in sorted(locked)) + "}", "  ExtRefs <- ExtDef", "  NsUsers = 1",
             f"  LAZY = {'TRUE' if lazy else 'FALSE'}", f"  SYNC = {'TRUE' if sync else 'FALSE'}", f"  DETACH = {'TRUE' if detach else 'FALSE'}",
             f"  ANY_PIN = {'TRUE' if 'anypin' in name else 'FALSE'}",
             # the residual witnesses show a cycle of two filesystems, not a
             # file on the pinning filesystem itself
             f"  SELF_PIN = {'FALSE' if 'reaped' in name else 'TRUE'}", "  PinnerSbs <- PinnerSbsDef"]
    for f in OWN_FIXES:
        on = f not in off
        if f in ("FIX_DISCONNECT_PINNERS", "PINNERS_ANCESTOR_ONLY", "PINNERS_REEXAMINE") and "pinners" not in name and "reexamine" not in name:
            on = False
        if f == "PINNERS_REEXAMINE" and "reexamine" not in name:
            on = False
        if f == "FIX_INTERNAL_CLONE":
            on = "clone" in name
        if f == "PIN_BUSY":
            on = "busy" in name
        lines.append(f"  {f} = {'TRUE' if on else 'FALSE'}")
    lines += ["INVARIANTS"] + [f"  {i}" for i in invs]
    pathlib.Path(__file__).resolve().parent.joinpath(name + ".cfg").write_text("\n".join(lines) + "\n")
print(f"{len(OWN_CONFIGS)} configurations written")

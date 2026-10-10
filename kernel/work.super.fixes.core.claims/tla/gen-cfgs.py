#!/usr/bin/env python3
"""Generate the TLC configurations and the MC_* layout modules of the
SuperDevTable model as of work.super.fixes.core.claims (587d78169911 on
fc1c25014ff8): the device table of fs/super.c with super_dev_get() waiting
for an unborn superblock without pinning its entry (FIX_UNBORN_WAIT).

A configuration is named <layout>_<what>; check.sh picks MC_<layout>.tla.
This script writes MC_dt*.tla and dt*.cfg.
"""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent

# --------------------------------------------------------------------------
# SuperDevTable layouts
# fs: sb -> dict(main, xmode, xdev, onfail, dropx, umount, mayfail)
# --------------------------------------------------------------------------

def fs(main, xmode="none", xdev=None, onfail="fail", dropx="no", umount=False, mayfail=False):
    return dict(main=main, xmode=xmode, xdev=xdev or ("d2" if main == "d1" else "d1"),
                onfail=onfail, dropx=dropx, umount=umount, mayfail=mayfail)


DT_LAYOUTS = {
    # one superblock on d1; a freezer and a cursor on d1; the sb is unmounted
    "dtbase": dict(
        desc="s1 on d1 (sget entry + setup_bdev_super claim), mount may fail, unmounted; "
             "a freezer and a user_get_super() cursor on d1",
        devs=["d1"], sbs=["s1"], slots=2,
        fs={"s1": fs("d1", umount=True, mayfail=True)},
        freezers={"F1": "d1"}, cursors={"C1": "d1"}, dups={}),
    # two superblocks share d2: s1 has d2 as an extra member device (xfs log, ext4
    # journal: refused -> mount fails), s2 lives on d2
    "dtshare": dict(
        desc="s1 on d1 with extra member d2 registered during the mount (refused -> the mount "
             "fails), s2 on d2; both unmounted; a freezer and a cursor on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", umount=True),
            "s2": fs("d2", umount=True)},
        freezers={"F2": "d2"}, cursors={"C2": "d2"}, dups={}),
    # the shared list without unmounts: the freeze/thaw balance on a shared device
    "dtsharefz": dict(
        desc="s1 on d1 with extra member d2 (refused -> the mount fails), s2 on d2, nobody "
             "unmounts; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2"),
            "s2": fs("d2")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    # btrfs -o degraded: the extra device is refused, the mount goes on without it
    "dtdeg": dict(
        desc="s1 on d1 with extra member d2 registered during the mount, refused -> the mount "
             "goes on without it (btrfs -o degraded); a freezer on d2",
        devs=["d1", "d2"], sbs=["s1"], slots=3,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    # btrfs extra devids: the extra device is accepted, then released before SB_BORN
    "dtdrop": dict(
        desc="s1 on d1 with extra member d2 accepted during the mount and released again "
             "before SB_BORN while the mount goes on (btrfs __btrfs_free_extra_devids()); "
             "a freezer on d2",
        devs=["d1", "d2"], sbs=["s1"], slots=3,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    # btrfs device add / remove on the live superblock, under bdev_deny_freeze()
    "dtlive": dict(
        desc="s1 on d1, d2 added to the live superblock and removed again (btrfs device "
             "add/remove under bdev_deny_freeze()), unmounted; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1"], slots=3,
        fs={"s1": fs("d1", xmode="live", xdev="d2", dropx="live", umount=True)},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    # the btrfs-style drops under cursors only: the table stays sound
    "dtdegc": dict(
        desc="s1 on d1 with extra member d2 refused and the mount going on (btrfs -o degraded), "
             "s2 on d2, both unmounted; a user_get_super() cursor on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded", umount=True),
            "s2": fs("d2", umount=True)},
        freezers={}, cursors={"C2": "d2"}, dups={}),
    "dtdropc": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, s2 on d2, both "
             "unmounted; a user_get_super() cursor on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early", umount=True),
            "s2": fs("d2", umount=True)},
        freezers={}, cursors={"C2": "d2"}, dups={}),
    # a multi-device superblock frozen through both of its devices
    "dtmulti": dict(
        desc="s1 on d1 with extra member d2 (refused -> the mount fails); a freezer on d1 and "
             "one on d2",
        devs=["d1", "d2"], sbs=["s1"], slots=3,
        fs={"s1": fs("d1", xmode="mount", xdev="d2")},
        freezers={"F1": "d1", "F2": "d2"}, cursors={}, dups={}),
    # degraded multi-device: the thaw of d2 may take d1's freeze
    "dtmultideg": dict(
        desc="s1 on d1 with extra member d2, refused -> the mount goes on (btrfs -o degraded); "
             "a freezer on d1 and one on d2",
        devs=["d1", "d2"], sbs=["s1"], slots=3,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded")},
        freezers={"F1": "d1", "F2": "d2"}, cursors={}, dups={}),
    # the list with removals under a cursor: several entries per device
    "dtwalk": dict(
        desc="s1 on d1 with extra member d2 (refused -> the mount fails) and s2 on d2, both "
             "unmounted, mount of s2 may fail; two user_get_super() cursors on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", umount=True),
            "s2": fs("d2", umount=True, mayfail=True)},
        freezers={}, cursors={"C1": "d2", "C2": "d2"}, dups={}),
    # the btrfs-style drops on a device shared with a live superblock, under a freezer:
    # the walk can pin s2's entry and then come across unborn s1 (looks again from prev)
    "dtdropfz": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, s2 on d2, "
             "nobody unmounts; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early"),
            "s2": fs("d2")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    "dtdegfz": dict(
        desc="s1 on d1 with extra member d2 refused and the mount going on (btrfs -o degraded), "
             "s2 on d2, nobody unmounts; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded"),
            "s2": fs("d2")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    # caller contract: a second concurrent registration of the same (dev, sb)
    "dtdup": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, plus a "
             "second concurrent fs_bdev_register()/fs_bdev_unregister() of (d2, s1)",
        devs=["d1", "d2"], sbs=["s1"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early")},
        freezers={}, cursors={}, dups={"D1": ("s1", False)}),
    # a re-add: the same (dev, sb) registered again once the first claim is being dropped
    "dtreadd": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, then "
             "registered and released again by another task (a re-add)",
        devs=["d1", "d2"], sbs=["s1"], slots=4,
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early")},
        freezers={}, cursors={}, dups={"D1": ("s1", True)}),
}

DT_FIXES = ["FIX_RCU_FREE", "FIX_NEXT_PIN", "FIX_PUBLISH_FIRST", "FIX_DENY", "FIX_FIRST_MATCH",
            "FIX_UNBORN_WAIT"]
DT_SAFETY = ["TypeOK", "NoErr", "ListOK", "RefLinked", "NoFreedReach", "PassLedger",
             "EntryKeepsSb", "FrozenCovers", "NoLeak"]

CONFIGS = {}


def add(name, layout, off=(), invs=None, expect="pass", deadlock=True, extra=None):
    assert name.startswith(layout + "_"), name
    CONFIGS[name] = dict(layout=layout, off=list(off), invs=invs, expect=expect,
                         deadlock=deadlock, extra=extra or {})


# ---- SuperDevTable: the tree ----------------------------------------------
add("dtbase_tree", "dtbase")
add("dtshare_tree", "dtshare")
add("dtsharefz_tree", "dtsharefz")
add("dtwalk_tree", "dtwalk")
add("dtlive_tree", "dtlive")
add("dtmulti_tree", "dtmulti")
add("dtdegc_tree", "dtdegc")
add("dtdropc_tree", "dtdropc")
add("dtdeg_tree", "dtdeg",
    expect="pass: the walk does not pin the refused registration's entry while s1 is unborn; "
           "it waits unpinned, the rollback unlinks the entry and the walk does not find it again")
add("dtdrop_tree", "dtdrop",
    expect="pass: the walk does not pin s1's d2 entry while s1 is unborn; s1 releases d2 before "
           "SB_BORN, the entry is unlinked and the walk does not find it again")
add("dtmultideg_tree", "dtmultideg")
add("dtdup_tree", "dtdup",
    expect="violation: NoErr, two live entries for (d2, s1); an unregister finds the one whose "
           "count already hit zero first: refcount underflow, use-after-free after the grace "
           "period, the other entry and s1's passive reference leak")

# ---- SuperDevTable: mutations ----------------------------------------------
add("dtwalk_no_rcu_free", "dtwalk", off=["FIX_RCU_FREE"],
    expect="violation: NoFreedReach, a cursor that read the head or a ->next before the removal "
           "reaches the entry after kfree()")
add("dtwalk_no_next_pin", "dtwalk", off=["FIX_NEXT_PIN"],
    expect="violation: NoFreedReach, super_dev_next() drops prev, prev is removed and freed, "
           "then prev->sd_node.next is read")
add("dtsharefz_no_publish_first", "dtsharefz", off=["FIX_PUBLISH_FIRST"],
    expect="violation: FrozenCovers, the registration reads the count before the freezer "
           "increments it and inserts after the walk: s1 uses the frozen d2 unfrozen")
add("dtlive_no_deny", "dtlive", off=["FIX_DENY"],
    expect="violation: NoErr, without bdev_deny_freeze() the live add/remove of d2 races the "
           "freeze walk: a freeze through a refused or removed claim outlives the thaw")
add("dtdup_underflow", "dtdup", invs=["NoUnderflow"],
    expect="violation: NoUnderflow, the two live entries for (d2, s1): the first unregister takes "
           "the front one to zero, the second one's lookup still finds it first and puts it at zero")
add("dtdeg_no_unborn_wait", "dtdeg", off=["FIX_UNBORN_WAIT"],
    expect="violation: NoErr, a walk of d2 pins the entry of the refused registration and "
           "waits for SB_BORN while the mount goes on without d2: bdev_thaw()'s walk thaws s1 "
           "that was never frozen, -EINVAL, bd_fsfreeze_count stays 1 for good (or "
           "bdev_freeze()'s walk freezes s1 through a device it does not use)")
add("dtdrop_no_unborn_wait", "dtdrop", off=["FIX_UNBORN_WAIT"],
    expect="violation: NoErr, the freeze walk pins s1's d2 entry, s1 releases d2 before "
           "SB_BORN, the walk freezes s1 through d2 anyway and bdev_thaw(d2) never thaws it")
add("dtmultideg_no_unborn_wait", "dtmultideg", off=["FIX_UNBORN_WAIT"],
    expect="violation: NoErr, as dtdeg_no_unborn_wait; with d1 frozen as well a thaw of d2 can "
           "take d1's freeze")
add("dtdropfz_tree", "dtdropfz")
add("dtdegfz_tree", "dtdegfz")
add("dtdropfz_no_unborn_wait", "dtdropfz", off=["FIX_UNBORN_WAIT"],
    expect="violation: NoErr, as dtdrop_no_unborn_wait with s2 sharing d2")
add("dtdegfz_no_unborn_wait", "dtdegfz", off=["FIX_UNBORN_WAIT"],
    expect="violation: NoErr, as dtdeg_no_unborn_wait with s2 sharing d2")
add("dtdrop_reachwait", "dtdrop", invs=["NoUnbornWait"],
    expect="violation: NoUnbornWait, a witness: the freeze walk comes across unborn s1 and "
           "waits for it unpinned")
add("dtdropfz_reachprev", "dtdropfz", invs=["NoUnbornWaitFromPrev"],
    expect="violation: NoUnbornWaitFromPrev, a witness: the freeze walk has s2's entry pinned, "
           "comes across unborn s1 and waits to look again from s2's entry")
add("dtdegfz_reachprev", "dtdegfz", invs=["NoUnbornWaitFromPrev"],
    expect="violation: NoUnbornWaitFromPrev, a witness: as dtdropfz_reachprev for the refused "
           "registration")
add("dtreadd_tree", "dtreadd")
add("dtreadd_no_first_match", "dtreadd", off=["FIX_FIRST_MATCH"],
    expect="violation: NoErr, super_dev_lookup() returning the last match finds a dying older "
           "entry behind the live one")


def tla_str(x):
    return '"%s"' % x


def tla_set(xs):
    return "{" + ", ".join(tla_str(x) for x in xs) + "}"


def tla_fun(d):
    if not d:
        return "[x \\in {} |-> \"none\"]"
    return " @@ ".join("(%s :> %s)" % (tla_str(k), tla_str(v)) for k, v in d.items())


def dups_fun(d):
    if not d:
        return "[x \\in {} |-> [sb |-> \"none\", after |-> FALSE]]"
    return " @@ ".join("(%s :> [sb |-> %s, after |-> %s])" % (tla_str(k), tla_str(v[0]), tla_bool(v[1]))
                       for k, v in d.items())


def tla_bool(b):
    return "TRUE" if b else "FALSE"


def fs_rec(f):
    return ("[main |-> %s, xmode |-> %s, xdev |-> %s, onfail |-> %s, dropx |-> %s, "
            "umount |-> %s, mayfail |-> %s]" % (tla_str(f["main"]), tla_str(f["xmode"]),
                                                tla_str(f["xdev"]), tla_str(f["onfail"]),
                                                tla_str(f["dropx"]), tla_bool(f["umount"]),
                                                tla_bool(f["mayfail"])))


def write_dt_layout(name, lay):
    fsd = " @@ ".join("(%s :> %s)" % (tla_str(s), fs_rec(f)) for s, f in lay["fs"].items())
    txt = f"""---------------------------- MODULE MC_{name} ----------------------------
(* The layout for SuperDevTable: {lay['desc']}. *)
(* Generated by gen-cfgs.py. *)
EXTENDS SuperDevTable, TLC

DevsDef == {tla_set(lay['devs'])}
SbsDef == {tla_set(lay['sbs'])}
FsCfgDef == {fsd}
FreezersDef == {tla_fun(lay['freezers'])}
CursorsDef == {tla_fun(lay['cursors'])}
DupsDef == {dups_fun(lay['dups'])}
=============================================================================
"""
    (HERE / f"MC_{name}.tla").write_text(txt)


def write_dt_cfg(name, c):
    lay = DT_LAYOUTS[c["layout"]]
    invs = c["invs"] if c["invs"] is not None else DT_SAFETY
    lines = [f"\\* generated by gen-cfgs.py: SuperDevTable (work.super.fixes.core.claims 587d78169911), "
             f"expected: {c['expect']}"] + (["\\* deadlock: ignore"] if not c["deadlock"] else []) + [
             "SPECIFICATION Spec",
             "CONSTANTS",
             "  Devs <- DevsDef",
             "  Sbs <- SbsDef",
             f"  NSlots = {lay['slots']}",
             "  FsCfg <- FsCfgDef",
             "  Freezers <- FreezersDef",
             "  Cursors <- CursorsDef",
             "  Dups <- DupsDef"]
    for f in DT_FIXES:
        lines.append(f"  {f} = {'FALSE' if f in c['off'] else 'TRUE'}")
    lines.append("INVARIANTS")
    lines += [f"  {i}" for i in invs]
    (HERE / f"{name}.cfg").write_text("\n".join(lines) + "\n")


def main():
    for p in list(HERE.glob("MC_dt*.tla")) + list(HERE.glob("dt*.cfg")):
        p.unlink()
    for name, lay in DT_LAYOUTS.items():
        write_dt_layout(name, lay)
    for name, c in CONFIGS.items():
        write_dt_cfg(name, c)
    print(f"{len(CONFIGS)} configurations")


if __name__ == "__main__":
    main()

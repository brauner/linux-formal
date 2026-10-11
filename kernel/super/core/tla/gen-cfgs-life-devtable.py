#!/usr/bin/env python3
"""Generate the TLC configurations and the MC_* layout modules of the
SuperLife and SuperDevTable models of fs/super.c (work.super.fixes at
fc1c25014ff8).

A configuration is named <layout>_<what>; check.sh picks MC_<layout>.tla.
Layouts starting with "dt" are SuperDevTable layouts, "lf" SuperLife ones.
This script only writes MC_dt*.tla, MC_lf*.tla, dt*.cfg and lf*.cfg; the
SuperFreeze*/SuperHolder* files of this directory are not its business.
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

DT_FIXES = ["FIX_RCU_FREE", "FIX_NEXT_PIN", "FIX_PUBLISH_FIRST", "FIX_DENY", "FIX_FIRST_MATCH"]
DT_SAFETY = ["TypeOK", "NoErr", "ListOK", "RefLinked", "NoFreedReach", "PassLedger",
             "EntryKeepsSb", "FrozenCovers", "NoLeak"]

# --------------------------------------------------------------------------
# SuperLife layouts
# --------------------------------------------------------------------------
LF_LAYOUTS = {
    # get_tree_single(): the second mounter finds the first one's superblock (nascent, born,
    # dying or dead) and shares it or waits; both unmount
    "lfsingle": dict(
        desc="two mounters of a get_tree_single() filesystem (test() matches, dereferences "
             "s_fs_info), the first one's fill_super() may fail, both unmount, kill_anon_super(); "
             "iterate_supers_type(), user_get_super() and two shrinker callbacks",
        mnt={"m1": "S1", "m2": "S2"}, umount={"m1": True, "m2": True},
        fillfail={"m1": True, "m2": False}, test="single", deref=True, kill="anon",
        iter="type", ugs="S1", shrink=2),
    # the same with the iterator on super_blocks
    "lfsingleall": dict(
        desc="as lfsingle, with __iterate_supers() over super_blocks",
        mnt={"m1": "S1", "m2": "S2"}, umount={"m1": True, "m2": True},
        fillfail={"m1": True, "m2": False}, test="single", deref=True, kill="anon",
        iter="all", ugs="S1", shrink=1),
    # get_tree_nodev(): two independent superblocks, the iterator walks both
    "lfnodev": dict(
        desc="two mounters of a get_tree_nodev() filesystem (two superblocks), the first one's "
             "fill_super() may fail, both unmount; __iterate_supers(), user_get_super() and two "
             "shrinker callbacks",
        mnt={"m1": "S1", "m2": "S2"}, umount={"m1": True, "m2": True},
        fillfail={"m1": True, "m2": False}, test="none", deref=False, kill="anon",
        iter="all", ugs="S2", shrink=2),
    # two nodev superblocks on fs_supers: iterate_supers_type() across a teardown
    "lfnodevtype": dict(
        desc="as lfnodev, with iterate_supers_type() over fs_supers",
        mnt={"m1": "S1", "m2": "S2"}, umount={"m1": True, "m2": True},
        fillfail={"m1": True, "m2": False}, test="none", deref=False, kill="anon",
        iter="type", ugs="none", shrink=0),
    # three mounters: m1 and m2 share a key, m3 has its own superblock
    "lftriple": dict(
        desc="three mounters of a keyed filesystem (test() dereferences s_fs_info): m1 and m2 "
             "share a key, m3 has its own; m1's fill_super() may fail; all unmount; "
             "__iterate_supers(), user_get_super() of m1's superblock, a shrinker callback",
        mnt={"m1": "S1", "m2": "S2", "m3": "S3"}, umount={"m1": True, "m2": True, "m3": True},
        fillfail={"m1": True, "m2": False, "m3": False}, test="keyed",
        key={"m1": 1, "m2": 1, "m3": 2}, deref=True, kill="anon",
        iter="all", ugs="S1", shrink=1),
    # the same over fs_supers with the type iterator, m3 failing instead
    "lftripletype": dict(
        desc="as lftriple with iterate_supers_type(), m3's fill_super() may fail instead of m1's, "
             "no user_get_super()",
        mnt={"m1": "S1", "m2": "S2", "m3": "S3"}, umount={"m1": True, "m2": True, "m3": True},
        fillfail={"m1": False, "m2": False, "m3": True}, test="keyed",
        key={"m1": 1, "m2": 1, "m3": 2}, deref=True, kill="anon",
        iter="type", ugs="none", shrink=1),
    # a ->kill_sb() that frees s_fs_info before deactivate_locked_super()'s notify
    "lfblock": dict(
        desc="as lfsingle without the iterator and user_get_super(), with a ->kill_sb() that "
             "frees s_fs_info before kill_super_notify() (generic_shutdown_super() or "
             "kill_block_super() then kfree())",
        mnt={"m1": "S1", "m2": "S2"}, umount={"m1": True, "m2": True},
        fillfail={"m1": True, "m2": False}, test="single", deref=True, kill="block",
        iter="none", ugs="none", shrink=0),
}
LF_FIXES = ["FIX_DEAD_SKIP", "FIX_DEAD_LOCK", "FIX_UNLINK_LATE", "FIX_ITER_PIN",
            "FIX_SHRINK_FIRST", "FIX_RCU_SB"]
LF_SAFETY = ["TypeOK", "NoErr", "PassLedger", "ActLedger", "Lists", "Flags", "UmountSane",
             "NoLeak"]

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
    expect="violation: NoErr, a walk of d2 pins the entry of the refused registration and "
           "waits for SB_BORN while the mount goes on without d2: bdev_thaw()'s walk thaws s1 "
           "that was never frozen, -EINVAL, bd_fsfreeze_count stays 1 for good (or "
           "bdev_freeze()'s walk freezes s1 through a device it does not use)")
add("dtdrop_tree", "dtdrop",
    expect="violation: NoErr, the freeze walk pins s1's d2 entry, s1 releases d2 before "
           "SB_BORN, the walk freezes s1 through d2 anyway and bdev_thaw(d2) never thaws it")
add("dtmultideg_tree", "dtmultideg",
    expect="violation: NoErr, as dtdeg_tree; with d1 frozen as well a thaw of d2 can take d1's "
           "freeze")
add("dtdup_tree", "dtdup",
    expect="violation: NoErr, two live entries for (d2, s1); an unregister finds the one whose "
           "count already hit zero first: refcount underflow, use-after-free after the grace "
           "period, the other entry and s1's passive reference leak")

# ---- SuperLife: the tree -----------------------------------------------------
add("lfsingle_tree", "lfsingle")
add("lfsingleall_tree", "lfsingleall")
add("lfnodev_tree", "lfnodev")
add("lfnodevtype_tree", "lfnodevtype")
add("lftriple_tree", "lftriple")
add("lftripletype_tree", "lftripletype")
add("lfblock_tree", "lfblock",
    expect="violation: NoErr, test() runs on the dying superblock after ->kill_sb() freed "
           "s_fs_info and before SB_DEAD: the contract of a test() that dereferences s_fs_info "
           "is kill_anon_super() (or kill_super_notify()) before the free")
add("lfblock_noderef", "lfblock", extra={"TEST_DEREF": False},
    expect="pass: a test() that does not dereference s_fs_info (sget_dev()'s "
           "super_s_dev_test(), test_keyed_super()) is fine with any ->kill_sb()")

# ---- SuperLife: mutations ----------------------------------------------------
add("lfsingle_no_dead_skip", "lfsingle", off=["FIX_DEAD_SKIP"],
    expect="violation: NoErr, test() on a dead superblock whose s_fs_info is freed (in other "
           "interleavings grab_super()'s refcount_inc() of an s_passive that hit zero)")
add("lfsingle_no_dead_lock", "lfsingle", off=["FIX_DEAD_LOCK"],
    expect="violation: NoErr, SB_DEAD set while sget_fc() is between the SB_DEAD check and "
           "test(): the filesystem frees s_fs_info under the running test()")
add("lfnodevtype_no_unlink_late", "lfnodevtype", off=["FIX_UNLINK_LATE"],
    expect="violation: NoErr, the shape before 2d2a2d7aa987: iterate_supers_type() holds a "
           "passive reference, kill_super_notify() unlinks the node, the iterator advances "
           "from an unlinked node and misses the rest")
add("lfnodev_no_iter_pin", "lfnodev", off=["FIX_ITER_PIN"],
    expect="violation: NoErr, the iterator drops its reference before it advances: the node is "
           "unlinked (and freed) under it")
add("lfsingle_no_shrink_first", "lfsingle", off=["FIX_SHRINK_FIRST"],
    expect="violation: NoErr, a shrinker callback runs after ->kill_sb() freed the filesystem")
add("lfnodev_no_rcu_sb", "lfnodev", off=["FIX_RCU_SB"],
    expect="pass: nobody in these tasks reaches a superblock after its last put without "
           "sb_lock or a reference; the RCU delay of put_super() is not load-bearing for "
           "fs/super.c's own walkers")

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
(* Generated by gen-cfgs-life-devtable.py. *)
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
    lines = [f"\\* generated by gen-cfgs-life-devtable.py: SuperDevTable (work.super.fixes fc1c25014ff8), "
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


def write_lf_layout(name, lay):
    txt = f"""---------------------------- MODULE MC_{name} ----------------------------
(* The layout for SuperLife: {lay['desc']}. *)
(* Generated by gen-cfgs-life-devtable.py. *)
EXTENDS SuperLife, TLC

MntDef == {tla_set(lay['mnt'].keys())}
MntSbDef == {tla_fun(lay['mnt'])}
UmountDef == {' @@ '.join('(%s :> %s)' % (tla_str(k), tla_bool(v)) for k, v in lay['umount'].items())}
KeyDef == {' @@ '.join('(%s :> %d)' % (tla_str(k), lay.get('key', {}).get(k, 1)) for k in lay['mnt'])}
FillFailDef == {' @@ '.join('(%s :> %s)' % (tla_str(k), tla_bool(v)) for k, v in lay['fillfail'].items())}
=============================================================================
"""
    (HERE / f"MC_{name}.tla").write_text(txt)


def write_lf_cfg(name, c):
    lay = LF_LAYOUTS[c["layout"]]
    invs = c["invs"] if c["invs"] is not None else LF_SAFETY
    consts = dict(TEST=tla_str(lay["test"]), TEST_DEREF=tla_bool(lay["deref"]),
                  KILL=tla_str(lay["kill"]), ITER=tla_str(lay["iter"]), UGS=tla_str(lay["ugs"]),
                  SHRINK=str(lay["shrink"]))
    for k, v in c["extra"].items():
        consts[k] = tla_bool(v) if isinstance(v, bool) else str(v)
    lines = [f"\\* generated by gen-cfgs-life-devtable.py: SuperLife (work.super.fixes fc1c25014ff8), "
             f"expected: {c['expect']}"] + (["\\* deadlock: ignore"] if not c["deadlock"] else []) + [
             "SPECIFICATION Spec",
             "CONSTANTS",
             "  Mnt <- MntDef",
             "  MntSb <- MntSbDef",
             "  Umount <- UmountDef",
             "  FillFail <- FillFailDef",
             "  Key <- KeyDef"]
    for k, v in consts.items():
        lines.append(f"  {k} = {v}")
    for f in LF_FIXES:
        lines.append(f"  {f} = {'FALSE' if f in c['off'] else 'TRUE'}")
    lines.append("INVARIANTS")
    lines += [f"  {i}" for i in invs]
    (HERE / f"{name}.cfg").write_text("\n".join(lines) + "\n")


def main():
    for p in list(HERE.glob("MC_dt*.tla")) + list(HERE.glob("dt*.cfg")) + \
             list(HERE.glob("MC_lf*.tla")) + list(HERE.glob("lf*.cfg")):
        p.unlink()
    for name, lay in DT_LAYOUTS.items():
        write_dt_layout(name, lay)
    for name, lay in LF_LAYOUTS.items():
        write_lf_layout(name, lay)
    for name, c in CONFIGS.items():
        if c["layout"].startswith("dt"):
            write_dt_cfg(name, c)
        else:
            write_lf_cfg(name, c)
    print(f"{len(CONFIGS)} configurations")


if __name__ == "__main__":
    main()

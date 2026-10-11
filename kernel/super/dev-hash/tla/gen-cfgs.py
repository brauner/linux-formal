#!/usr/bin/env python3
"""Generate the TLC configurations and the MC_* layout modules of the
SuperDevHash model of work.super.dev_hash (de417b144a46 on 587d78169911):
the device table of fs/super.c as a hashtable under super_dev_lock, the
entry for s_dev embedded in the superblock and walks that keep their place
with a cursor.

A configuration is named <layout>_<what>; check.sh picks MC_<layout>.tla.
This script writes MC_dt*.tla and dt*.cfg.
"""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent

# --------------------------------------------------------------------------
# layouts
# fs: sb -> dict(main, xmode, xdev, onfail, dropx, umount, mayfail)
# --------------------------------------------------------------------------

def fs(main, xmode="none", xdev=None, onfail="fail", dropx="no", umount=False, mayfail=False):
    return dict(main=main, xmode=xmode, xdev=xdev or ("d2" if main == "d1" else "d1"),
                onfail=onfail, dropx=dropx, umount=umount, mayfail=mayfail)


LAYOUTS = {
    "dtbase": dict(
        desc="s1 on d1 (the embedded entry + setup_bdev_super's claim), mount may fail, "
             "unmounted; a freezer and a user_get_super() cursor on d1",
        devs=["d1"], sbs=["s1"],
        fs={"s1": fs("d1", umount=True, mayfail=True)},
        freezers={"F1": "d1"}, cursors={"C1": "d1"}, dups={}),
    "dtshare": dict(
        desc="s1 on d1 with extra member d2 registered during the mount (refused -> the mount "
             "fails), s2 on d2; both unmounted; a freezer and a cursor on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", umount=True),
            "s2": fs("d2", umount=True)},
        freezers={"F2": "d2"}, cursors={"C2": "d2"}, dups={}),
    "dtsharefz": dict(
        desc="s1 on d1 with extra member d2 (refused -> the mount fails), s2 on d2, nobody "
             "unmounts; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2"),
            "s2": fs("d2")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    "dtdeg": dict(
        desc="s1 on d1 with extra member d2 registered during the mount, refused -> the mount "
             "goes on without it (btrfs -o degraded); a freezer on d2",
        devs=["d1", "d2"], sbs=["s1"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    "dtdrop": dict(
        desc="s1 on d1 with extra member d2 accepted during the mount and released again "
             "before SB_BORN while the mount goes on (btrfs __btrfs_free_extra_devids()); "
             "a freezer on d2",
        devs=["d1", "d2"], sbs=["s1"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    "dtlive": dict(
        desc="s1 on d1, d2 added to the live superblock and removed again (btrfs device "
             "add/remove under bdev_deny_freeze()), unmounted; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1"],
        fs={"s1": fs("d1", xmode="live", xdev="d2", dropx="live", umount=True)},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    "dtdegc": dict(
        desc="s1 on d1 with extra member d2 refused and the mount going on (btrfs -o degraded), "
             "s2 on d2, both unmounted; a user_get_super() cursor on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded", umount=True),
            "s2": fs("d2", umount=True)},
        freezers={}, cursors={"C2": "d2"}, dups={}),
    "dtdropc": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, s2 on d2, both "
             "unmounted; a user_get_super() cursor on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early", umount=True),
            "s2": fs("d2", umount=True)},
        freezers={}, cursors={"C2": "d2"}, dups={}),
    "dtmulti": dict(
        desc="s1 on d1 with extra member d2 (refused -> the mount fails); a freezer on d1 and "
             "one on d2",
        devs=["d1", "d2"], sbs=["s1"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2")},
        freezers={"F1": "d1", "F2": "d2"}, cursors={}, dups={}),
    "dtmultideg": dict(
        desc="s1 on d1 with extra member d2, refused -> the mount goes on (btrfs -o degraded); "
             "a freezer on d1 and one on d2",
        devs=["d1", "d2"], sbs=["s1"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded")},
        freezers={"F1": "d1", "F2": "d2"}, cursors={}, dups={}),
    "dtwalk": dict(
        desc="s1 on d1 with extra member d2 (refused -> the mount fails) and s2 on d2, both "
             "unmounted, mount of s2 may fail; two user_get_super() cursors on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", umount=True),
            "s2": fs("d2", umount=True, mayfail=True)},
        freezers={}, cursors={"C1": "d2", "C2": "d2"}, dups={}),
    "dtdropfz": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, s2 on d2, "
             "nobody unmounts; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early"),
            "s2": fs("d2")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    "dtdegfz": dict(
        desc="s1 on d1 with extra member d2 refused and the mount going on (btrfs -o degraded), "
             "s2 on d2, nobody unmounts; a freezer on d2",
        devs=["d1", "d2"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", onfail="degraded"),
            "s2": fs("d2")},
        freezers={"F2": "d2"}, cursors={}, dups={}),
    "dtdup": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, plus a "
             "second concurrent fs_bdev_register()/fs_bdev_unregister() of (d2, s1)",
        devs=["d1", "d2"], sbs=["s1"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early")},
        freezers={}, cursors={}, dups={"D1": ("s1", False)}),
    "dtreadd": dict(
        desc="s1 on d1 with extra member d2 accepted and released before SB_BORN, then "
             "registered and released again by another task (a re-add)",
        devs=["d1", "d2"], sbs=["s1"],
        fs={"s1": fs("d1", xmode="mount", xdev="d2", dropx="early")},
        freezers={}, cursors={}, dups={"D1": ("s1", True)}),
    # erofs: two superblocks claim the same blob device next to their own main devices
    "dtblob": dict(
        desc="s1 on d1 and s2 on d2 both claim the blob d3 during the mount (erofs, refused -> "
             "the mount fails), both unmounted, s2's mount may fail; a freezer on d3",
        devs=["d1", "d2", "d3"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d3", umount=True),
            "s2": fs("d2", xmode="mount", xdev="d3", umount=True, mayfail=True)},
        freezers={"F3": "d3"}, cursors={}, dups={}),
    "dtblobc": dict(
        desc="s1 on d1 and s2 on d2 both claim the blob d3 during the mount (erofs, refused -> "
             "the mount fails), both unmounted; a freezer and a user_get_super() cursor on d3",
        devs=["d1", "d2", "d3"], sbs=["s1", "s2"],
        fs={"s1": fs("d1", xmode="mount", xdev="d3", umount=True),
            "s2": fs("d2", xmode="mount", xdev="d3", umount=True)},
        freezers={"F3": "d3"}, cursors={"C3": "d3"}, dups={}),
}

FIXES = ["FIX_RELOOK", "FIX_CURSOR", "FIX_CHECK_LOCKED", "FIX_ATOMIC_CLAIM", "FIX_DENY"]
SAFETY = ["TypeOK", "NoErr", "ChainOK", "UniquePair", "ClaimsOK", "PassLedger", "EntryKeepsSb",
          "NoFreedReach", "FrozenCovers", "NoLeak"]

CONFIGS = {}


def add(name, layout, off=(), invs=None, expect="pass", deadlock=True):
    assert name.startswith(layout + "_"), name
    CONFIGS[name] = dict(layout=layout, off=list(off), invs=invs, expect=expect, deadlock=deadlock)


# ---- the tree ---------------------------------------------------------------
for lay in LAYOUTS:
    if lay == "dtdup":
        continue
    add(lay + "_tree", lay)
add("dtdup_tree", "dtdup",
    expect="pass: the lookup and the insert happen under one hold of super_dev_lock, so two "
           "registrations of (d2, s1) share one entry (fc1c25014ff8: two live entries, a "
           "refcount underflow and a use-after-free)")

# ---- mutations ----------------------------------------------------------------
add("dtdrop_no_relook", "dtdrop", off=["FIX_RELOOK"],
    expect="violation: NoErr, the freeze walk commits to s1's d2 claim while s1 is unborn, s1 "
           "drops d2 before SB_BORN, the walk freezes s1 through d2 anyway and bdev_thaw(d2) "
           "never thaws it")
add("dtdropfz_no_relook", "dtdropfz", off=["FIX_RELOOK"],
    expect="violation: NoErr, as dtdrop_no_relook with s2 sharing d2")
add("dtdeg_no_relook", "dtdeg", off=["FIX_RELOOK"],
    expect="pass: a refused claim is never hashed, so no walk can commit to it; only claims "
           "dropped after they were taken need the second look")
add("dtmultideg_no_relook", "dtmultideg", off=["FIX_RELOOK"],
    expect="pass: as dtdeg_no_relook")
add("dtwalk_no_cursor", "dtwalk", off=["FIX_CURSOR"],
    expect="violation: NoErr, the walk resumes behind s2's entry which s2's unmount dropped "
           "while the walk slept")
add("dtblob_no_cursor", "dtblob", off=["FIX_CURSOR"],
    expect="violation: NoErr, the freeze or thaw walk over d3 resumes behind the blob claim "
           "of a superblock that was unmounted in the meantime")
add("dtsharefz_no_check_locked", "dtsharefz", off=["FIX_CHECK_LOCKED"],
    expect="violation: FrozenCovers, s1 reads d2's freeze count before the freezer raises it "
           "and hashes its claim after the walk: s1 uses the frozen d2 unfrozen")
add("dtdeg_no_check_locked", "dtdeg", off=["FIX_CHECK_LOCKED"],
    expect="violation: FrozenCovers, as dtsharefz_no_check_locked for btrfs -o degraded")
add("dtdup_no_atomic_claim", "dtdup", off=["FIX_ATOMIC_CLAIM"],
    expect="violation: UniquePair, both registrations miss in the lookup and both insert: two "
           "entries for (d2, s1)")
add("dtlive_no_deny", "dtlive", off=["FIX_DENY"],
    expect="violation: NoErr, without bdev_deny_freeze() the live add/remove of d2 races the "
           "freeze walk: a freeze through a removed claim outlives the thaw")

# ---- witnesses ------------------------------------------------------------------
add("dtdrop_reachwait", "dtdrop", invs=["NoUnbornWait"],
    expect="violation: NoUnbornWait, a witness: the freeze walk comes across unborn s1 and waits "
           "for it without committing")
add("dtwalk_reachcross", "dtwalk", invs=["NoCursorCrossed"],
    expect="violation: NoCursorCrossed, a witness: a cursor sits right behind s2's entry and "
           "s2's unmount drops it while the walk sleeps")
add("dtblob_reachcross", "dtblob", invs=["NoCursorCrossed"],
    expect="violation: NoCursorCrossed, a witness: the freezer's cursor sits behind a blob claim "
           "that an unmount drops")


def s(x):
    return '"%s"' % x


def tla_set(xs):
    return "{" + ", ".join(s(x) for x in xs) + "}"


def tla_fun(d, empty='"none"'):
    if not d:
        return "[x \\in {} |-> %s]" % empty
    return " @@ ".join("(%s :> %s)" % (s(k), v if isinstance(v, int) else s(v)) for k, v in d.items())


def b(x):
    return "TRUE" if x else "FALSE"


def dups_fun(d):
    if not d:
        return "[x \\in {} |-> [sb |-> \"none\", after |-> FALSE]]"
    return " @@ ".join("(%s :> [sb |-> %s, after |-> %s])" % (s(k), s(v[0]), b(v[1]))
                       for k, v in d.items())


def fs_rec(f):
    return ("[main |-> %s, xmode |-> %s, xdev |-> %s, onfail |-> %s, dropx |-> %s, "
            "umount |-> %s, mayfail |-> %s]" % (s(f["main"]), s(f["xmode"]), s(f["xdev"]),
                                                s(f["onfail"]), s(f["dropx"]), b(f["umount"]),
                                                b(f["mayfail"])))


def ids(lay):
    emb = {sb: i + 1 for i, sb in enumerate(lay["sbs"])}
    n = len(lay["sbs"])
    # every registration kzalloc()s before the lock: one per filesystem task and dup at a time,
    # plus the extra-device claims kept
    nalloc = 2 * n + len(lay["dups"])
    walkers = list(lay["freezers"]) + list(lay["cursors"])
    cur = {w: 101 + i for i, w in enumerate(walkers)}
    return emb, (n + 1, n + nalloc), cur


def write_layout(name, lay):
    emb, (a0, a1), cur = ids(lay)
    fsd = " @@ ".join("(%s :> %s)" % (s(sb), fs_rec(f)) for sb, f in lay["fs"].items())
    txt = f"""---------------------------- MODULE MC_{name} ----------------------------
(* The layout for SuperDevHash: {lay['desc']}. *)
(* Generated by gen-cfgs.py. *)
EXTENDS SuperDevHash, TLC

DevsDef == {tla_set(lay['devs'])}
SbsDef == {tla_set(lay['sbs'])}
EmbOfDef == {tla_fun(emb, '0')}
AllocDef == {a0}..{a1}
CurOfDef == {tla_fun(cur, '0')}
FsCfgDef == {fsd}
FreezersDef == {tla_fun(lay['freezers'])}
CursorsDef == {tla_fun(lay['cursors'])}
DupsDef == {dups_fun(lay['dups'])}
=============================================================================
"""
    (HERE / f"MC_{name}.tla").write_text(txt)


def write_cfg(name, c):
    invs = c["invs"] if c["invs"] is not None else SAFETY
    lines = [f"\\* generated by gen-cfgs.py: SuperDevHash (work.super.dev_hash de417b144a46), "
             f"expected: {c['expect']}"] + (["\\* deadlock: ignore"] if not c["deadlock"] else []) + [
             "SPECIFICATION Spec",
             "CONSTANTS",
             "  Devs <- DevsDef",
             "  Sbs <- SbsDef",
             "  EmbOf <- EmbOfDef",
             "  Alloc <- AllocDef",
             "  CurOf <- CurOfDef",
             "  FsCfg <- FsCfgDef",
             "  Freezers <- FreezersDef",
             "  Cursors <- CursorsDef",
             "  Dups <- DupsDef"]
    for f in FIXES:
        lines.append(f"  {f} = {'FALSE' if f in c['off'] else 'TRUE'}")
    lines.append("INVARIANTS")
    lines += [f"  {i}" for i in invs]
    (HERE / f"{name}.cfg").write_text("\n".join(lines) + "\n")


def main():
    for p in list(HERE.glob("MC_dt*.tla")) + list(HERE.glob("dt*.cfg")):
        p.unlink()
    for name, lay in LAYOUTS.items():
        write_layout(name, lay)
    for name, c in CONFIGS.items():
        write_cfg(name, c)
    print(f"{len(CONFIGS)} configurations")


if __name__ == "__main__":
    main()

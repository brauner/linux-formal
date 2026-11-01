#!/usr/bin/env python3
"""Generate the TLC configurations and the MC_* layout modules of the
OffsetReaddir model: readdir() of a tmpfs directory with stable offsets,
fs/libfs.c, as the d_children walk of b44341e39d85 and as the descending
walk of the offset tree of work.libfs.offset_readdir.v2 9ad16ae61045.

A configuration is named <layout>_<what>; check.sh picks MC_<layout>.tla.
This script writes MC_*.tla and *.cfg.
"""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
TREE = "work.libfs.offset_readdir.v2 9ad16ae61045"

ALLOPS = ["create", "unlink", "rename", "over", "exchange"]

# --------------------------------------------------------------------------
# layouts
# --------------------------------------------------------------------------

LAYOUTS = {
    "churn": dict(
        desc="names a-d, 5 offsets; up to 4 creates, unlinks, renames, renames over a name "
             "and exchanges before opendir() and 2 more while the listing runs",
        names=["a", "b", "c", "d"], noff=5, nd=5, setup=4, churn=2, ops=ALLOPS),
    "wo": dict(
        desc="names a-c, 5 offsets; creates, unlinks and RENAME_WHITEOUT renames, 3 before "
             "opendir() and 2 while the listing runs",
        names=["a", "b", "c"], noff=5, nd=5, setup=3, churn=2,
        ops=["create", "unlink", "whiteout"]),
    "wrap": dict(
        desc="names a-c, 3 offsets so the allocator wraps; 5 operations of every kind before "
             "opendir() and 2 while the listing runs",
        names=["a", "b", "c"], noff=3, nd=4, setup=5, churn=2, ops=ALLOPS),
    "rr": dict(
        desc="generic/736: up to 5 creates and unlinks, then every entry readdir() returns is "
             "renamed to a new name before the next readdir(); names a-d, 4 offsets so the "
             "renames wrap into the holes the unlinks left",
        names=["a", "b", "c", "d"], noff=4, nd=4, setup=5, churn=0, ops=["create", "unlink"],
        rename_on_read=True, track=True),
    "seek": dict(
        desc="names a-c, 4 offsets; 3 operations of every kind before opendir() and 2 while "
             "the listing runs; the lister may telldir() once and seekdir() back to it once, "
             "also after the listing ended",
        names=["a", "b", "c"], noff=4, nd=4, setup=3, churn=2, ops=ALLOPS, seeks=True),
    "far": dict(
        desc="names a-c, 4 offsets; 3 operations of every kind before opendir() and 1 while "
             "the listing runs; the lister may lseek() past DIR_OFFSET_EOD once, also after "
             "the listing ended",
        names=["a", "b", "c"], noff=4, nd=4, setup=3, churn=1, ops=ALLOPS, farseeks=True),
    "two": dict(
        desc="two listers with their own open files; names a-c, 4 offsets; 3 operations of "
             "every kind before the first opendir() and 2 after it",
        names=["a", "b", "c"], noff=4, nd=4, setup=3, churn=2, ops=ALLOPS, listers=2),
    "twoseek": dict(
        desc="two listers, each may telldir() and seekdir() back once; names a-c, 4 offsets; "
             "2 operations of every kind before the first opendir() and 2 after it",
        names=["a", "b", "c"], noff=4, nd=4, setup=2, churn=2, ops=ALLOPS, listers=2,
        seeks=True),
    "big": dict(
        desc="names a-d, 5 offsets; 4 operations of every kind including RENAME_WHITEOUT before "
             "opendir() and 2 while the listing runs",
        names=["a", "b", "c", "d"], noff=5, nd=6, setup=4, churn=2, ops=ALLOPS + ["whiteout"]),
    "conc": dict(
        desc="names a-c, 4 offsets; 3 operations of every kind before opendir() and 2 while "
             "the listing runs, which may run inside a getdents64() call where WRITERS_EXCL "
             "is off",
        names=["a", "b", "c"], noff=4, nd=4, setup=3, churn=2, ops=ALLOPS),
}

# switches: WALK, REFS, WRITERS_EXCL, RCU_TREE
V2 = dict(WALK="offset", REFS=False, WRITERS_EXCL=True, RCU_TREE=False, PAST_EOD="relist")    # 9ad16ae61045
V1 = dict(WALK="offset", REFS=True, WRITERS_EXCL=True, RCU_TREE=False, PAST_EOD="relist")     # bed62856dba3, also d31f7ea3e408
BASE = dict(WALK="list", REFS=True, WRITERS_EXCL=True, RCU_TREE=False, PAST_EOD="relist")     # b44341e39d85
EOD = dict(WALK="list_eod", REFS=True, WRITERS_EXCL=True, RCU_TREE=False, PAST_EOD="relist")  # the walk ending instead of restarting
ASCEND = dict(WALK="ascend", REFS=True, WRITERS_EXCL=True, RCU_TREE=False, PAST_EOD="relist")  # 6faddda69f62 (v6.6)

SAFETY = ["TypeOK", "DirOK", "NoDup", "Complete", "NoRepeat", "PastEODEmpty", "Bounded", "NoUAF",
          "NoStale"]

CONFIGS = {}


def add(name, layout, sw, invs=None, props=(), expect="pass"):
    assert name.startswith(layout + "_"), name
    CONFIGS[name] = dict(layout=layout, sw=sw, invs=invs or SAFETY, props=list(props),
                         expect=expect)


def but(sw, **kw):
    d = dict(sw)
    d.update(kw)
    return d


# ---- the fix ---------------------------------------------------------------
add("churn_v2", "churn", V2)
add("churn_v1", "churn", V1)
add("wo_v2", "wo", V2)
add("wrap_v2", "wrap", V2)
add("rr_v2", "rr", V2, invs=SAFETY + ["ReReturnNeedsWrap"], props=["Terminates"])
add("conc_v2", "conc", V2)
add("big_v2", "big", V2)

# ---- the code before -----------------------------------------------------
add("churn_base_dup", "churn", BASE, invs=["TypeOK", "DirOK", "NoDup"],
    expect="violation: NoDup, the entry ctx->pos points at is unlinked between two calls and "
           "no entry has a lower offset, so the walk restarts at the head of d_children and "
           "returns untouched entries again (Nickolai's report)")
add("churn_base_skip", "churn", BASE, invs=["TypeOK", "DirOK", "Complete"],
    expect="violation: Complete, the entry ctx->pos points at is unlinked and the next lower "
           "offset belongs to a dentry further down d_children, so the entries in between are "
           "never returned (the y t a b case of the commit message)")
add("churn_eod_skip", "churn", EOD, invs=["TypeOK", "DirOK", "NoDup", "Complete"],
    expect="violation: Complete, ending the listing where the walk would restart loses an "
           "untouched entry (the a b c case of the commit message)")
add("wo_base", "wo", BASE, invs=["TypeOK", "DirOK", "NoDup", "Complete"],
    expect="violation: NoDup or Complete, as churn_base_* with the offsets RENAME_WHITEOUT hands "
           "out")
add("wrap_base", "wrap", BASE, invs=["TypeOK", "DirOK", "NoDup", "Complete"],
    expect="violation: NoDup or Complete, as churn_base_*")
add("rr_ascend", "rr", ASCEND, invs=SAFETY + ["ReReturnNeedsWrap"], props=["Terminates"],
    expect="violation: ReReturnNeedsWrap, the ascending walk of 6faddda69f62: a renamed entry gets "
           "the next offset, ahead of the walk, and is returned again before the allocator ever "
           "wrapped, which with 2^31 offsets is how generic/736 broke it")
add("churn_ascend", "churn", ASCEND,
    expect="pass: the ascending walk returns every untouched entry exactly once, its problem "
           "was ending")
add("rr_base", "rr", BASE, invs=SAFETY + ["ReReturnNeedsWrap"], props=["Terminates"],
    expect="pass: generic/736 terminates with the list walk as well; renamed entries go to the "
           "head of d_children, behind the walk")

# ---- seeking, a position past the end, two listers ---------------------------
add("seek_v2", "seek", V2)
add("seek_base", "seek", BASE, invs=["TypeOK", "DirOK", "NoDup", "Complete", "NoRepeat"],
    expect="violation: NoDup, Complete or NoRepeat, as churn_base_* when the call after the "
           "seekdir() resumes at a cookie whose entry is gone")
add("seek_witness_seekback", "seek", V2, invs=["NoSeekBack"],
    expect="violation: NoSeekBack, a seekdir() back to a cookie taken after entries were "
           "returned, and the listing after it reaches its end")
add("far_v2", "far", V2, invs=["TypeOK", "DirOK", "PastEODEmpty"],
    expect="violation: PastEODEmpty, offset_readdir() walks for every position but "
           "DIR_OFFSET_EOD itself, so after an lseek() past it the walk starts at the "
           "highest offset and returns the whole directory again")
add("far_v2_eod", "far", but(V2, PAST_EOD="eod"),
    expect="pass: ending the listing for every position at or past DIR_OFFSET_EOD returns "
           "nothing after the lseek()")
add("far_base", "far", BASE, invs=["TypeOK", "DirOK", "PastEODEmpty"],
    expect="violation: PastEODEmpty, the d_children walk since b9b588f22a0c does the same")
add("far_ascend", "far", ASCEND, invs=["TypeOK", "DirOK", "PastEODEmpty"],
    expect="pass: the ascending walk of 6faddda69f62 found nothing above the position and "
           "ended the listing")
add("two_v2", "two", V2)
add("two_v1", "two", V1)
add("two_base", "two", BASE, invs=["TypeOK", "DirOK", "NoDup", "Complete"],
    expect="violation: NoDup or Complete, as churn_base_*")
add("two_witness_overlap", "two", V2, invs=["NoOverlap"],
    expect="violation: NoOverlap, both listers are inside getdents64() at the same time")
add("twoseek_v2", "twoseek", V2)

# ---- witnesses -------------------------------------------------------------
add("churn_witness_order", "churn", V2, invs=["OrdersAgree"],
    expect="violation: OrdersAgree, d_children order and offset order disagree when the "
           "listing starts")
add("churn_witness_cookie", "churn", V2, invs=["NoCookieGone"],
    expect="violation: NoCookieGone, a call resumes at an offset whose entry was unlinked or "
           "moved since the last call")
add("wrap_witness_wrap", "wrap", V2, invs=["NoWrap"],
    expect="violation: NoWrap, the offset allocator wraps")
add("rr_witness_rereturn", "rr", V2, invs=["NoReReturn"],
    expect="violation: NoReReturn, once the renames wrap a renamed entry gets an offset below "
           "ctx->pos and is returned again under its new name, and the listing still ends")

# ---- what v2 relies on: writers excluded while a call runs ------------------
CONC = but(V2, WRITERS_EXCL=False)
add("conc_noexcl_uaf", "conc", CONC, invs=["TypeOK", "DirOK", "NoUAF"],
    expect="violation: NoUAF, an unlink between the find and dir_emit() frees the dentry v2 "
           "emits without a reference")
add("conc_noexcl_stale", "conc", CONC, invs=["TypeOK", "DirOK", "NoStale"],
    expect="violation: NoStale, a writer changes the offset tree under the ma_state v2 carries "
           "across dir_emit()")
add("conc_noexcl_refs", "conc", but(CONC, REFS=True),
    invs=["TypeOK", "DirOK", "NoDup", "Complete", "Bounded", "NoUAF"],
    expect="pass: with a reference across dir_emit() the dentry stays alive, which is all the "
           "reference buys")
add("conc_noexcl_refs_stale", "conc", but(CONC, REFS=True), invs=["TypeOK", "DirOK", "NoStale"],
    expect="violation: NoStale, the reference doesn't keep the tree stable: without "
           "MT_FLAGS_USE_RCU the walk still reads a tree a writer changes")
add("conc_noexcl_rcu", "conc", but(CONC, RCU_TREE=True), invs=["TypeOK", "DirOK", "NoUAF"],
    expect="violation: NoUAF, an RCU tree doesn't help v2 either, dir_emit() runs outside the "
           "RCU read section")
add("two_noexcl_rcu_refs", "two", but(CONC, REFS=True, RCU_TREE=True),
    expect="pass: as conc_noexcl_rcu_refs with two listers holding references")
add("conc_noexcl_rcu_refs", "conc", but(CONC, REFS=True, RCU_TREE=True),
    expect="pass: writers inside a call would need both, a reference across dir_emit() and an "
           "RCU tree")


# --------------------------------------------------------------------------
# writers
# --------------------------------------------------------------------------

def tla_set(xs):
    return "{" + ", ".join('"%s"' % x for x in xs) + "}"


def tla_bool(b):
    return "TRUE" if b else "FALSE"


def write_layout(name, lay):
    body = [
        "---------------------------- MODULE MC_%s ----------------------------" % name,
        "(* The %s layout for OffsetReaddir: %s. *)" % (name, lay["desc"]),
        "(* Generated by gen-cfgs.py. *)",
        "EXTENDS OffsetReaddir",
        "",
        "NamesDef == %s" % tla_set(lay["names"]),
        "OpKindsDef == %s" % tla_set(lay["ops"]),
        "NOffDef == %d" % lay["noff"],
        "NDDef == %d" % lay["nd"],
        "SetupOpsDef == %d" % lay["setup"],
        "ChurnOpsDef == %d" % lay["churn"],
        "RenameOnReadDef == %s" % tla_bool(lay.get("rename_on_read", False)),
        "TrackDef == %s" % tla_bool(lay.get("track", False)),
        "ListersDef == 1..%d" % lay.get("listers", 1),
        "SeeksDef == %s" % tla_bool(lay.get("seeks", False)),
        "FarSeeksDef == %s" % tla_bool(lay.get("farseeks", False)),
        "=============================================================================",
        "",
    ]
    (HERE / ("MC_%s.tla" % name)).write_text("\n".join(body))


def write_cfg(name, c):
    sw = c["sw"]
    out = [
        "\\* generated by gen-cfgs.py: OffsetReaddir (%s), expected: %s" % (TREE, c["expect"]),
        "SPECIFICATION Spec",
        "CONSTANTS",
        "  Names <- NamesDef",
        "  OpKinds <- OpKindsDef",
        "  NOff <- NOffDef",
        "  ND <- NDDef",
        "  SetupOps <- SetupOpsDef",
        "  ChurnOps <- ChurnOpsDef",
        "  RenameOnRead <- RenameOnReadDef",
        "  Track <- TrackDef",
        "  Listers <- ListersDef",
        "  Seeks <- SeeksDef",
        "  FarSeeks <- FarSeeksDef",
        '  WALK = "%s"' % sw["WALK"],
        "  REFS = %s" % tla_bool(sw["REFS"]),
        "  WRITERS_EXCL = %s" % tla_bool(sw["WRITERS_EXCL"]),
        "  RCU_TREE = %s" % tla_bool(sw["RCU_TREE"]),
        '  PAST_EOD = "%s"' % sw["PAST_EOD"],
        "INVARIANTS",
    ]
    out += ["  " + i for i in c["invs"]]
    if c["props"]:
        out.append("PROPERTIES")
        out += ["  " + p for p in c["props"]]
    (HERE / ("%s.cfg" % name)).write_text("\n".join(out) + "\n")


def main():
    for p in HERE.glob("MC_*.tla"):
        p.unlink()
    for p in HERE.glob("*.cfg"):
        p.unlink()
    for name, lay in LAYOUTS.items():
        write_layout(name, lay)
    for name, c in CONFIGS.items():
        write_cfg(name, c)
    print("%d layouts, %d configurations" % (len(LAYOUTS), len(CONFIGS)))


if __name__ == "__main__":
    main()

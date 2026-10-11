#!/usr/bin/env python3
"""Run the CBMC configurations of mntput_harness.c and print a results table.

usage: run.py [-m sc|tso|both] [-j JOBS] [--mem GiB] [--timeout S] [name ...]
Results: results/<name>.<mm>.log (full CBMC output incl. traces), results.md.
Every CBMC invocation runs under `systemd-run --user --scope -p MemoryMax=...`
(fallback: ulimit -v) and `timeout`.
"""
import argparse, concurrent.futures, os, re, shutil, subprocess, sys, time, pathlib

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "mntput_harness.c"
RES = HERE / "results"
CBMC_FLAGS = ["--unwind", "4", "--unwindset", "__synchronize_rcu.0:4",
              "--unwinding-assertions", "--pointer-check", "--bounds-check",
              "--signed-overflow-check", "--unsigned-overflow-check", "--trace"]

# name: (cflags, expected failing properties (substrings), note)
# "NoFastFinal" is the witness: it MUST fail wherever the fast path is reachable.
CONFIGS = {
    # the series as written
    "sync":        ("-DSHAPE=0 -DBATCH=1", ["NoFastFinal"], "umount(2): do_umount(M, 0)"),
    "lazy":        ("-DSHAPE=1 -DBATCH=1", ["NoFastFinal"], "umount2(MNT_DETACH)"),
    "kern":        ("-DSHAPE=2 -DBATCH=1", ["NoFastFinal"], "kern_unmount_array({M}, 1)"),
    "kern2_o0_h0": ("-DSHAPE=2 -DBATCH=2 -DORDER=0 -DHELD=0", ["NoFastFinal"], "batch of 2, {M0,M1}, H holds M0"),
    "kern2_o1_h0": ("-DSHAPE=2 -DBATCH=2 -DORDER=1 -DHELD=0", ["NoFastFinal"], "batch of 2, {M1,M0}, H holds M0"),
    "kern2_o0_h1": ("-DSHAPE=2 -DBATCH=2 -DORDER=0 -DHELD=1", ["NoFastFinal"], "batch of 2, {M0,M1}, H holds M1"),
    "kern2_o1_h1": ("-DSHAPE=2 -DBATCH=2 -DORDER=1 -DHELD=1", ["NoFastFinal"], "batch of 2, {M1,M0}, H holds M1"),
    "lazy2_h0":    ("-DSHAPE=1 -DBATCH=2 -DHELD=0", ["NoFastFinal"], "MNT_DETACH of M0 with child M1, H holds M0"),
    "lazy2_h1":    ("-DSHAPE=1 -DBATCH=2 -DHELD=1", ["NoFastFinal"], "MNT_DETACH of M0 with child M1, H holds M1"),
    # mutations (must fail)
    "mut_nogp_lazy":   ("-DSHAPE=1 -DBATCH=1 -DMUT_NO_GP", ["NoFastFinal", "Freed"], "no grace period for held mounts: leak"),
    "mut_nogp_sync":   ("-DSHAPE=0 -DBATCH=1 -DMUT_NO_GP", ["NoFastFinal", "Freed"], "no grace period, sync: the walker's transient increment"),
    "mut_loose_lazy":  ("-DSHAPE=1 -DBATCH=1 -DMUT_PEEK_LOOSE", ["NoFastFinal", "DoomedIsLast"], "peek finishes at count 2: dooms under the holder"),
    "mut_loose_sync":  ("-DSHAPE=0 -DBATCH=1 -DMUT_PEEK_LOOSE", ["NoFastFinal"], "peek at 2, sync: only a transient walker can be the second (TLA+: pass)"),
    "mut_torn_sync":   ("-DSHAPE=0 -DBATCH=1 -DMUT_TORN_SUM -DGETS=1", ["NoFastFinal", "SyncClean"], "single counter, migrating holder: torn sum"),
    "mut_nodoomed_lazy": ("-DSHAPE=1 -DBATCH=1 -DMUT_NO_DOOMED", ["NoFastFinal", "DoomedIsLast|NoUAF|Freed|CleanupOnce"], "no MNT_DOOMED test in __legitimize_mnt()"),
    "mut_nomb_sync":   ("-DSHAPE=0 -DBATCH=1 -DMUT_NO_MB_LEGIT", ["NoFastFinal"], "no smp_mb() in __legitimize_mnt(): SC must stay green, TSO should not"),
    # exploratory
    "x_recheck_sync":  ("-DSHAPE=0 -DBATCH=1 -DMUT_PUT_RECHECK -DMUT_NO_GP", ["NoFastFinal"], "EXPLORATORY: fast path re-reads mnt_ns behind smp_mb(), no grace period at all"),
    "x_recheck_lazy":  ("-DSHAPE=1 -DBATCH=1 -DMUT_PUT_RECHECK -DMUT_NO_GP", ["NoFastFinal"], "EXPLORATORY: same, lazy"),
}
# for TSO the no-smp_mb mutation is expected to break
TSO_EXPECT = {"mut_nomb_sync": ["NoFastFinal", "SyncClean|DoomedIsLast|Freed"]}

PROP_RE = re.compile(r"^\[(?P<id>[^\]]+)\] (?:line \d+ |file \S+ line \d+ (?:function \S+ )?)?(?P<desc>.*?): (?P<st>SUCCESS|FAILURE|UNKNOWN)\s*$")


def env():
    e = dict(os.environ)
    fv = pathlib.Path.home() / "opt" / "fv"
    e["PATH"] = f"{fv}/usr/bin:" + e.get("PATH", "")
    e["LD_LIBRARY_PATH"] = f"{fv}/usr/lib/x86_64-linux-gnu:{fv}/usr/lib:" + e.get("LD_LIBRARY_PATH", "")
    return e


def capped(cmd, mem_gib, timeout_s):
    if shutil.which("systemd-run"):
        pre = ["systemd-run", "--user", "--scope", "-p", f"MemoryMax={mem_gib}G", "-p", "MemorySwapMax=0", "-q"]
        return pre + ["timeout", str(timeout_s)] + cmd
    return ["bash", "-c", f"ulimit -v {mem_gib * 1024 * 1024}; exec timeout {timeout_s} " + " ".join(cmd)]


def run_one(name, mm, mem_gib, timeout_s):
    cflags, expect, note = CONFIGS[name]
    if mm == "tso":
        expect = TSO_EXPECT.get(name, expect)
    RES.mkdir(exist_ok=True)
    goto = RES / f"{name}.goto"
    log = RES / f"{name}.{mm}.log"
    e = env()
    t0 = time.monotonic()
    r = subprocess.run(["goto-cc"] + cflags.split() + ["-o", str(goto), str(SRC)], env=e, capture_output=True, text=True)
    if r.returncode:
        log.write_text(r.stdout + r.stderr)
        return dict(name=name, mm=mm, status="COMPILE-ERROR", expect=expect, fails=[], wall=0, rss=0, note=note)
    target = goto
    if mm == "tso":
        target = RES / f"{name}.tso.goto"
        r = subprocess.run(["goto-instrument", "--mm", "tso", str(goto), str(target)], env=e, capture_output=True, text=True)
        if r.returncode:
            log.write_text(r.stdout + r.stderr)
            return dict(name=name, mm=mm, status="INSTRUMENT-ERROR", expect=expect, fails=[], wall=0, rss=0, note=note)
    cmd = capped(["python3", "-I", str(HERE / "measure.py"), "cbmc", str(target)] + CBMC_FLAGS, mem_gib, timeout_s)
    with open(log, "w") as f:
        r = subprocess.run(cmd, env=e, stdout=f, stderr=subprocess.STDOUT, text=True)
    out = log.read_text(errors="replace")
    m = re.search(r"MEASURE wall=([\d.]+) maxrss_kb=(\d+) rc=(-?\d+)", out)
    wall, rss, rc = (float(m.group(1)), int(m.group(2)), int(m.group(3))) if m else (time.monotonic() - t0, 0, r.returncode)
    props = {}
    for line in out.splitlines():
        pm = PROP_RE.match(line.strip())
        if pm:
            props[pm.group("id")] = (pm.group("desc"), pm.group("st"))
    fails = sorted({d for d, st in props.values() if st == "FAILURE"})
    if rc == 124 or "timeout" in out.lower() and not props:
        status = "TIMEOUT"
    elif rc in (137, -9) or "Killed" in out:
        status = "OOM/KILLED"
    elif not props:
        status = f"NO-RESULT(rc={rc})"
    else:
        unexpected = [d for d in fails if not any(re.search(x, d) for x in expect)]
        missing = [x for x in expect if not any(re.search(x, d) for d in fails)]
        status = "AS-EXPECTED" if not unexpected and not missing else "MISMATCH"
        if missing:
            status += f" missing={missing}"
        if unexpected:
            status += f" unexpected={unexpected}"
    return dict(name=name, mm=mm, status=status, expect=expect, fails=fails, wall=wall, rss=rss, note=note, nprops=len(props))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-m", "--mm", default="sc", choices=["sc", "tso", "both"])
    ap.add_argument("-j", "--jobs", type=int, default=1)
    ap.add_argument("--mem", type=int, default=10, help="MemoryMax per CBMC run, GiB")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    names = a.names or list(CONFIGS)
    mms = ["sc", "tso"] if a.mm == "both" else [a.mm]
    jobs = [(n, mm) for mm in mms for n in names]
    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for res in ex.map(lambda nm: run_one(nm[0], nm[1], a.mem, a.timeout), jobs):
            rows.append(res)
            print(f"{res['name']:18} {res['mm']:3} {res['status']:40} wall={res['wall']:.0f}s rss={res['rss']//1024}MB fails={res['fails']}", flush=True)
            append_results(res)


def append_results(res):
    md = HERE / "results.md"
    new = not md.exists()
    with open(md, "a") as f:
        if new:
            f.write("| config | mm | expected failures | actual failures | status | wall | peak RSS | note |\n|---|---|---|---|---|---|---|---|\n")
        f.write(f"| {res['name']} | {res['mm']} | {', '.join(res['expect']) or '-'} | {', '.join(res['fails']) or 'none'} | {res['status']} | {res['wall']:.0f} s | {res['rss']//1024} MB | {res['note']} |\n")


if __name__ == "__main__":
    main()

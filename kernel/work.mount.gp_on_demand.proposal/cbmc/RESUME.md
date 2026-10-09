# RESUME (CBMC harness for the gp-on-demand mntput protocol)

Started 2026-10-09 ~10:00 CEST. Laptop suspends ~11:45; report due ~11:35.

## State (11:24)
- [x] memo, kernel code (fs/namespace.c @ 4379d47fd314), TLA+ MntPut.tla read
- [x] CBMC 6.6.0-4 (Debian deb + minisat deb) extracted into ~/opt/fv
      PATH=~/opt/fv/usr/bin  LD_LIBRARY_PATH=~/opt/fv/usr/lib/x86_64-linux-gnu:~/opt/fv/usr/lib
- [ ] ESBMC: SKIPPED (GitHub release download: 0 B in 10 s on this link; 238 MB zip)
- [x] harness mntput_harness.c written; three CBMC limitations found and worked around:
      1. CBMC's threaded symex throws "pointer handling for concurrency is unsound"
         (goto_symex_state.cpp, `is_shared && lhs.type() == pointer`, issue #305) on
         ANY pointer-typed store to shared memory while threads exist.  Consequences:
         - mnt_ns is an int id, mnt_parent an index (WRITE_ONCE(mnt->mnt_ns, NULL) kept
           verbatim via `#define NULL 0`),
         - the kernel's intrusive hlist/list code cannot run in the threaded harness:
           the unmounted/held hlists are a fixed-position flag model that keeps the
           two-pass control flow of mntput_unmounted(); mnt_expire/mnt_covers/
           mnt_del_instance/next_mnt are dropped or ghost ints.  => the real hlist
           pointer code is NOT verified (would need a single-threaded CBMC run).
         - CBMC's own pthread_create() model trips the same check: threads are spawned
           with __CPROVER_ASYNC_n labels, joins are __CPROVER_assume(done[t]).
      2. nondeterministic pointers (walker's target) must be build-time constants (WALK=).
      3. no /usr/bin/time: measure.py (wall + ru_maxrss) instead.
- [x] harness symexes cleanly since ~11:05 (fixed-position hlist model, thread-local U state)
- [x] probe run (sync, SC, ALL checks incl. pointer/bounds/overflow): TIMEOUT at 900 s, 1.2 GB
      (results/probe_sync_sc.log).  The extra checks multiply the properties; use them later on jens.
- [x] quick runs v1 (nondet CPU per operation; results/quick_*.v1_nondetcpu.sc.log, 140-230 s, ~670 MB):
      ALL THREE reported 31 failures incl. the series as written (lazy, sync).  DIAGNOSED AS A
      HARNESS ARTEFACT: the trace shows mnt_get_count() = 268435457 and a counter slot written
      with 1275523073: the per-CPU update was `for (c) if (c == nondet_cpu) slot[c] += 1`, i.e.
      guarded shared writes, and CBMC's thread encoding lets a read pick a guarded write whose
      RHS came from the untaken path (garbage).  The "dead object" dereference failures are the
      same weakness on __CPROVER_dead_object.  Fix: thread-local constant this_cpu (U=0, H=HCPU,
      W=WCPU) with the holder's migration as a compile-time knob (MIGRATE=1), like TLA+ MIGRATE.
- [ ] quick runs v2 (constant CPUs), started 11:24, timeout 1200 s, 5 GiB cap each:
      results/quick_{lazy,sync,mut_nogp_lazy,mut_torn_sync}.sc.log; marker results/quick_done.txt
      expected: lazy/sync -> only "NoFastFinal" FAILURE; mut_nogp_lazy -> + "Freed";
      mut_torn_sync (MIGRATE=1) -> + "SyncClean"
- [x] README.md written (function mapping, modelling decisions)
- [ ] run.py matrix never run end to end; results.md does not exist yet
- [ ] copy to ~/src/git/linux-tla/kernel/work.mount.gp_on_demand.proposal/cbmc/ (its README.md exists) -- do at the end

## If the laptop was suspended mid-run
The CBMC processes above are plain local processes; a suspend freezes them and they
continue afterwards (timeout counts wall time, so they may be killed on resume).
Rerun with:  python3 run.py sync lazy mut_nogp_lazy        (SC, all checks)
Quick form:  cbmc results/q_sync.goto --unwind 4 --unwindset __synchronize_rcu.0:4 --unwinding-assertions --trace

## How to rerun
    export PATH=~/opt/fv/usr/bin:$PATH LD_LIBRARY_PATH=~/opt/fv/usr/lib/x86_64-linux-gnu:~/opt/fv/usr/lib
    cd <this dir> && ./run.sh                 # = python3 run.py (all configs, SC); results/*.log, results.md
    python3 run.py -m tso sync lazy           # TSO (goto-instrument --mm tso) for named configs
    python3 run.py -j 2 --mem 5               # two in parallel, 5 GiB cap each

## Running right now
quick v2: cbmc results/q_{lazy,sync,mut_nogp_lazy,mut_torn_sync}.goto -> results/quick_*.sc.log
Collect: cat results/quick_done.txt; grep -E "\] .*: FAILURE" results/quick_<name>.sc.log | sed 's/^\[[^]]*\] //' | sort | uniq -c
Trace:   python3 trace2.py results/quick_<name>.sc.log "<property substring>"

## FINAL STATE 11:32 (session stopped by the suspend deadline)
NO configuration has a trustworthy result.  Every run that finished (sync, lazy, mut_nogp_lazy,
mut_torn_sync, and the "c3" runs) reports the SAME ~31 failures, including the series as written.
CORRECTION: all of those runs used the nondeterministic-CPU-per-operation variant of percpu_add()
(guarded shared writes inside the atomic section); the constant-CPU patch had NOT been applied
(the shell applying it was killed by its own pkill).  The "quick runs v2" and "c3" entries above are
therefore the SAME harness as v1; -DHCPU/-DWCPU/-DNO_ATOMIC_PCP had no effect there.
The constant-CPU variant (this_cpu thread-local; HCPU/WCPU/MIGRATE knobs) was applied at 11:32 and
is the current mntput_harness.c; its first run is results/quick_lazy_v3_constcpu.sc.log (see below).  All of them are a CBMC artefact, not kernel
behaviour: the counterexamples contain `mounts[0].mnt_pcp[1].mnt_gets = 1275523073` produced by a
`+= 1` on a slot that only ever held 0/1/2 (see results/quick_lazy.sc.log, trace of
main.assertion "never cleaned up"; print with `python3 trace2.py results/quick_lazy.sc.log "never cleaned up"`),
and the same traces fail the pointer-check properties "dereference failure: dead object in
mnt->mnt_pcp".  Reading: CBMC does not resolve the `mnt` pointer that real_mount()/container_of()
derives from `&m->mnt` by (char *) arithmetic, so a dereference through it can take a
nondeterministic value in the threaded encoding.  NEXT STEP (not done): remove the pointer
arithmetic from the threaded harness -- pass `struct mount *` everywhere (make mntput()/mntget()/
legitimize_mnt() take struct mount * via macros) so every shared access is `mounts[const].field`,
then rerun `python3 run.py` (SC) and the TSO pass.  results/mntput_harness.c.broken-unguarded-patch is an aborted intermediate edit (ignore).
mntput_harness.c (11:32) compiles: constant CPUs, percpu_add() with unguarded writes, atomic section
(NO_ATOMIC_PCP drops it).  The TLA+ target ~/src/git/linux-tla/kernel/ did not exist at 11:31 (the whole
kernel/ directory was missing; another agent owns that tree), so nothing was copied there; an earlier
copy at 11:28 went into .../work.mount.gp_on_demand.proposal/cbmc/ while it existed.
Timings of the artefact runs (SC, user assertions only, MiniSat): 97-230 s wall, 0.67-0.85 GB RSS.
The run with --pointer-check --bounds-check --(un)signed-overflow-check did not finish in 900 s.
TSO: never run.  ESBMC: never installed.  BATCH=2 / kern configurations: never run.

## 11:38 lazy v3 (constant CPUs) STILL RUNNING when the session ended: results/quick_lazy_v3_constcpu.sc.log, marker results/quick_done.txt (timeout 900 s from 11:32). If it shows only "NoFastFinal" the artefact was the guarded per-CPU writes; if the 31 failures persist, the pointer-resolution theory stands.

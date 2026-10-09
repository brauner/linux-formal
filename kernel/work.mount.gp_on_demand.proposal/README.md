# work.mount.gp_on_demand.proposal: the grace period on demand

The series that lets namespace_unlock() finish an unmounted mount off
without a grace period when the count under mount_lock is one (branch
`work.mount.gp_on_demand.proposal`, on vfs-7.4.mount c947dc6ab4f4), checked
five ways. Each directory pins the tree it was run against.

| method | directory | what it covers |
|---|---|---|
| TLA+ model (TLC) | [`tla/`](tla/README.md) | two mounts unmounted as one batch, umount(2)/namespace death/kern_unmount_array(), holders, migrating holders, walkers, weakly ordered stores; 62 configurations |
| LKMM litmus tests (herd7), the same under the AArch64 and POWER models, klitmus7 on x86 | [`litmus/`](litmus/README.md) | the barrier pairings: holder get before put, walker increment against the seqcount, bail-out under MNT_DOOMED, kern_unmount's plain store, the grace period fallback, the Dekker alternative, the tree's shapes without the outer smp_mb()s; `upstream/` generates the Documentation/litmus-tests/ patch |
| Dartagnan (bounded model checking of C under LKMM, AArch64, POWER, TSO) | [`dat3m/`](dat3m/RESUME.md) | a C harness of the protocol, 102 checks, compared cell by cell with herd7 |
| CBMC (bounded model checking of the C functions) | [`cbmc/`](cbmc/README.md) | verbatim copies of the functions with per-CPU counters, seqlock and grace period modelled; the TLA+ invariants as assertions |
| TLA+ trace validation | [`trace/`](trace/RESUME.md) | a debug-only tracepoint patch, ftrace to NDJSON per mount, `MntPutTrace.tla` driving the model through real traces from the selftest and the stress runs |

`BARRIERS.md` is the argument, backed by the litmus tests, why the three
outer smp_mb() calls could go.

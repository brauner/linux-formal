# LKMM litmus tests of the reference count protocol

Linux kernel memory model tests (herd7 >= 7.58, run against the tree's
`tools/memory-model`: `cd tools/memory-model && herd7 -conf linux-kernel.cfg
<test>`) for the protocol of work.mount.gp_on_demand.proposal: holders on
the fast path of mntput_no_expire(), walkers in __legitimize_mnt(), and the
unmounter summing the split per-CPU counters under mount_lock in
mnt_get_count() before it finishes a mount off without a grace period.
`RESULTS-lkmm.txt` has the observations; `../BARRIERS.md` the argument they
back.

| group | tests | shape | expected |
|---|---|---|---|
| A0 | `MNT-A0-peek-can-miss-fastpath-put` | the peek misses a fast-path put even under sequential consistency: why the grace period branch exists | Sometimes |
| A1 | `MNT-A1-holder-get-before-put`, `MNT-A1m-{nowmb,nomb-in-sum,gets-first}` | holder get counted before its put: the fast path's smp_wmb() against the puts-first sum with the smp_mb() inside mnt_get_count() | Never / Sometimes for the three mutations |
| A2 | `MNT-A2-gp-fallback-sees-fastpath-put`, `MNT-A2k-gp-fallback-sync-rcu`, `MNT-A2m-nogp` | a put the peek missed is seen after synchronize_rcu(_expedited)(); an smp_mb() cannot replace the grace period | Never, Never / Sometimes |
| B1 | `MNT-B1-walker-inc-vs-peek`, `MNT-B1m-peek-no-outer-mb`, `MNT-B1m-walker-nomb` | walker increment against the seqcount write of the peek (store buffering); the peek without its outer smp_mb() (the shape of the tree) | Never, Never / Sometimes |
| B2 | `MNT-B2-walker-bail-sees-doomed-lazy`, `MNT-B2r-walker-bail-reduced`, `MNT-B2m-walker-flags-unlocked` | a bailing walker sees MNT_DOOMED under mount_lock; `B2r` is a reduced B2 small enough for the hardware models to finish | Never, Never / Sometimes |
| C | `MNT-C1-kern-unmount-get-before-put`, `MNT-C2-kern-unmount-gp-fallback` | kern_unmount_array(): plain store of mnt_ns, no lock, no seqcount bump | Never |
| D | `MNT-D1-dekker-fastpath-recheck`, `MNT-D1m-holder-wmb-only` | the Dekker alternative (fast path re-reads mnt_ns after its put, no grace period); exploratory, not the tree | Never / Sometimes |
| E | `MNT-E1-slowpath-no-outer-mb`, `MNT-E2-busycheck-no-outer-mb` | mntput_no_expire_slowpath() and do_umount()'s busy check without their outer smp_mb() (the shape of the tree after "fs: drop the smp_mb()s that mnt_get_count() made redundant") | Never |

Modelling: LKMM has no seqlock, the tests spell write_seqlock() out as the
kernel does (lock, seqcount store, smp_wmb(), ..., smp_wmb(), seqcount store,
unlock) and the reader side as READ_ONCE() plus smp_rmb(); per-CPU counters
are one variable per CPU and counter with the sum unrolled over two CPUs;
migration is the same test with the put aimed at the other CPU's variable.

## Under the AArch64 and POWER models

LKMM is the contract every architecture has to meet, so a "Never" there
holds everywhere. As an independent check on the weakest architectures
the load-bearing tests were also translated to AArch64 and POWER
assembly, with the instructions the kernel's barrier.h emits for each
barrier and an emulated spinlock, and run with herd7 under the
Arm architectural model (`aarch64.cat`) and `ppc.cat`. `gen-asm.py`
holds each test as an abstract program and writes both translations to
`aarch64/` and `ppc/`, `run-asm.sh`, `run-one.sh` and `run-some.sh` run
them, and `collect-results.sh` prints the table, which is
`RESULTS-hardware.txt`:

    ./run-asm.sh aarch64 aarch64.cat
    ./run-some.sh ppc ppc.cat false MNT-A1m-nowmb   # a full run instead of -speedcheck
    ./collect-results.sh

Every finished cell agrees with LKMM. Under `-speedcheck` herd7 stops at
the first witness and reports "Always 1 0", which the table shows as
"witnessed"; the `.full.out` files are full runs with the exact counts.
The full-size `MNT-B2-walker-bail-sees-doomed-lazy` did not finish under
the Arm model, `MNT-B2r-walker-bail-reduced` settles that shape under
all three models.

The first POWER translation emulated the lock acquisition with a branch
on the store-conditional alone. `ppc.cat` doesn't treat that branch as
depending on the load-reserve, so the `isync` after it isn't an acquire
and B2 produced a witness LKMM forbids. `ppc/probe-lock-acq-emul.litmus`
and `ppc/probe-lock-acq-kernel.litmus` show the difference in isolation.
`gen-asm.py` now emits the kernel's `lwarx; cmpwi; bne; stwcx.; bne;
isync` and every POWER test was rerun. The outputs of the first
emulation are kept in `ppc/old-emul/`.

## On x86 hardware

klitmus7 turns a litmus test into a kernel module that runs the test
millions of times on real CPUs. Fourteen of the tests were built as
modules against a 4379d47fd314 kernel and run in a KVM guest with eight
vCPUs. `x86-klitmus.txt` has the observations, `klitmus/` the driver
scripts of that run (they assume the build machine's layout) and the
notes klitmus7 writes next to each module.

Every test the code relies on is Never over two to four million
iterations, and the mutations x86 can exhibit at all were observed. Note
that x86 keeps loads in order with loads and stores in order with
stores, so `MNT-A1m-nowmb` and `MNT-A1m-nomb-in-sum` are Never on x86 no
matter how long the run is. An x86 run is not evidence for arm64 or
POWER, the architectural models above are.

## For the kernel tree

`upstream/gen.sh <kernel tree>` writes the tests the kernel can carry
into `Documentation/litmus-tests/fs/` of that tree, renamed and with a
comment that explains each one. `upstream/commit-msg.txt` is the commit
message of that patch.

## Notes

The two memos written while the tests were run are in `notes/`.
`lkmm-tooling.md` maps the constructs of the protocol onto LKMM, gives
every test with its result and surveys the tools (herd7, klitmus7,
Dartagnan, GenMC, CBMC and others). `hardware-models.md` covers the
translation to AArch64 and POWER, the spurious POWER witness, the
klitmus7 run, the argument for removing the outer smp_mb() calls on
every architecture, and why an emulated arm64 guest on x86 is no
substitute for arm64 hardware. They are working notes: the paths in them
refer to the machines the work was done on.

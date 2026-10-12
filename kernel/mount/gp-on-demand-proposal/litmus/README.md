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
| E | `MNT-E1-slowpath-no-outer-mb`, `MNT-E1u-slowpath-after-umount-tree`, `MNT-E2-busycheck-no-outer-mb`, `MNT-E{1,1u,2}m-{nomb-in-sum,walker-nomb}` | mntput_no_expire_slowpath() and do_umount()'s busy check without their outer smp_mb() (the shape of the tree after "fs: drop the smp_mb()s that mnt_get_count() made redundant"); E1u is E1 started after umount_tree(); the mutations take out the smp_mb() inside mnt_get_count() or the walker's | Never, Never, Never / Sometimes for the six mutations |
| F | `MNT-F1-late-walker-sees-new-pwd`, `MNT-F1m-{nowmb,nomb-in-sum}` | three processes: a walker that starts after the peek finished a mount off can't reach it through the old cwd of a holder whose put the peek counted; the smp_wmb() of set_fs_pwd()'s write_sequnlock() or of the fast path orders the new fs->pwd before the put, the smp_mb() inside mnt_get_count() orders the load of the put before the seqcount store of the unlock; the mutations take out both smp_wmb()s or the smp_mb() | Never / Sometimes for both mutations |

Modelling: LKMM has no seqlock, the tests spell write_seqlock() out as the
kernel does (lock, seqcount store, smp_wmb(), ..., smp_wmb(), seqcount store,
unlock) and the reader side as READ_ONCE() plus smp_rmb(); per-CPU counters
are one variable per CPU and counter with the sum unrolled over two CPUs;
migration is the same test with the put aimed at the other CPU's variable.

E1 keeps a walker whose seqcount read predates umount_tree(). The grace
period in namespace_unlock() keeps that walker from ever meeting the
final put, so the interleaving it models can't happen. E1u starts after
umount_tree() instead: P1() is only the slow path's critical section,
and flags=1 with a seqcount of 0 is the initial state. That is the shape
Documentation/litmus-tests/fs/ carries, `upstream/gen.sh` generates it
from E1u. Each of E1, E1u and E2 has two mutations, one without the
smp_mb() inside mnt_get_count() and one without the walker's, and all
six are Sometimes: both barriers are load-bearing.

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

## Under the RISC-V, MIPS and ARM models

The E family also went through the three weak models herd7 ships that
hadn't been used yet. `gen-asm.py` writes them from the same abstract
programs, with the instructions the kernel emits:

| directory | model | smp_mb() / smp_wmb() / smp_rmb() | spin_lock() / spin_unlock() |
|---|---|---|---|
| `riscv/` | `riscv.cat` | `fence rw,rw` / `fence w,w` / `fence r,r` | `amoswap.w.aq` / `fence rw,w; sw` |
| `riscv-lrsc/` | `riscv.cat` | the same | `lr.w; bne; sc.w; bne; fence r,rw`, the shape of arch_cmpxchg_acquire() behind qspinlock / the same |
| `mips/` | `mips.cat` | `sync` for all three | `sync; ll; bne; sc; beq; sync`, the shape of arch_cmpxchg() behind qspinlock / `sync; sw` |
| `mips-weak/` | `mips.cat` | `sync` / nothing / nothing | `ll; bne; sc; beq; sync` / `sync; sw` |
| `arm/` | `arm.cat` and `aarch32.cat` | `dmb ish` / `dmb ishst` / `dmb ish` | `ldrex; cmp; bne; strex; cmp; bne; dmb ish`, the ticket lock / `dmb ish; str` |

`collect-e.sh` prints the whole family under every model, which is
`RESULTS-E.txt`. The outputs are `<test>.out` for a `-speedcheck` run
and `<test>.full.out` for a full one, with the model in the name in
`arm/`: `<test>.armv7.out`, `<test>.aarch32.full.out`. The
`probe-*.litmus` files in `riscv/`, `arm/` and `mips/` check the
emulation: store buffering with the full fence on both sides is Never
and with a store fence on one side Sometimes, and two critical sections
can only both read zero with the lock filter in place.

Both tests the kernel carries are Never under every model, and the
mutations are witnessed wherever the kernel's own barriers don't mask
them:

- Every non-Octeon MIPS kernel emits the full `sync` for smp_rmb() and
  smp_wmb() as well (arch/mips/include/asm/sync.h), so under `mips/`
  the mutations are masked by the kernel's own barriers. `mips-weak/`
  is the lower bound for Cavium Octeon, where smp_wmb() is the lighter
  syncw and smp_rmb() is nothing: it emits no instruction for either
  and keeps only the smp_mb() syncs. Both tests stay Never there and
  all six mutations are witnessed, so the smp_mb() pairing carries the
  result on its own.
- On arm32 smp_rmb() is `dmb ish`. The walker's smp_mb() is redundant
  with the read_seqretry() barrier right after it, which masks the
  `-walker-nomb` mutations. The unlock and lock between E1's two
  critical sections are two `dmb ish` as well and mask
  `E1m-nomb-in-sum`; E1u has no such pair and its mutation is
  witnessed. herd7's ARM frontend has R0-R12, LR and SP, so where a
  thread needs more the own-counter loads r2 and r4, whose values
  nothing reads, share a register.
- With the lock emulated as `amoswap.w.aq`, `E1m-nomb-in-sum` is masked
  on RISC-V: the AMO's store is coherence-after the unlock store of the
  first critical section and `.aq` orders the AMO before every later
  load, so the first section's seqcount stores reach the sum's loads
  through the lock word. Dropping `.aq` unmasks it, dropping the
  release fence does not. The kernel's qspinlock is lr.w/sc.w with
  `fence r,rw`, which orders only the lr, and under `riscv-lrsc/` the
  mutation is witnessed while every Never holds. So an acquire AMO is
  the right stand-in for CASA on arm64 but stronger than the lock
  RISC-V actually has.

Alpha has no herd7 model. Its `mb` is a full barrier and READ_ONCE()
carries one too, and nothing here relies on dependency ordering, so the
LKMM result is what covers it.

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

`MNT-E1u-slowpath-after-umount-tree` went through the same pipeline
later, `klitmus/run-E1u.sh` drives one test through it: Never over
2097130 iterations.

F1 is the last part of the argument for the peek: once the sum came
out at one nobody can find the mount anymore. A walker whose seqcount
sample postdates the peek would get through __legitimize_mnt(), so it
must not be able to read a pointer to the mount at all. The kernel tree
carries F1 and its two mutations as
`Documentation/litmus-tests/fs/mnt-walker-late-sees-new-pwd{,-nowmb,-nomb}.litmus`,
they were written there and copied here. They only ran under LKMM.

## For the kernel tree

`upstream/gen.sh <kernel tree>` writes the tests the kernel can carry
into `Documentation/litmus-tests/fs/` of that tree, renamed and with a
comment that explains each one. `upstream/commit-msg.txt` is the commit
message of that patch. The slow path test it writes is E1u.

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

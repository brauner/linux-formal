# Dartagnan harness of the mount reference count protocol

Tree: work.mount.gp_on_demand.proposal at 4379d47fd314, fs/namespace.c.

Dartagnan, the model checker of Dat3M
(https://github.com/hernanponcedeleon/Dat3M), checks C programs under a
weak memory model written in cat, the language herd7 uses. It works on
LLVM IR, so the program goes through clang first. That makes it a
useful second opinion on the litmus tests in `../litmus/`: those are
small programs written by hand in LKMM syntax, the harness here is C
code shaped like the kernel functions.

`mnt_gp.c` has one struct mount, one per-CPU counter slot per thread
and mount_lock as a spinlock plus a seqcount, spelled out the way the
litmus tests do it:

    write_seqlock()   = spin_lock(); seq++; smp_wmb();
    write_sequnlock() = smp_wmb(); seq++; spin_unlock();
    read_seqbegin()   = READ_ONCE(seq); smp_rmb();
    read_seqretry()   = smp_rmb(); READ_ONCE(seq) != start

The holder, the walker and the unmounter are threads running the fast
path of mntput_no_expire(), __legitimize_mnt() and mnt_get_count() with
mntput_unheld(). Exactly one `-DSCEN_*` picks the scenario and the
`MUT_*` switches take one barrier or one check out. The scenarios mirror
the exists clauses of the litmus tests, so `A1` here is
`MNT-A1-holder-get-before-put` there. The header comment of `mnt_gp.c`
lists every scenario, mutation and target.

## Files

| File | What it is |
|---|---|
| `mnt_gp.c` | the harness |
| `run.sh` | compiles every variant with clang and checks it under one target, appending to `results.tsv` |
| `results.tsv` | target, variant, verdict, seconds and log of the 102 checks below |
| `witness/` | the violation graphs of `lkmm-A1m-nomb-in-sum` and `arm8-B1m-walker-nomb` |
| `dat3m-linux-kernel.cat`, `dat3m-linux-kernel.bell`, `dat3m-lock.cat` | the LKMM cat files from Dat3M's `cat/` directory, as the runs used them, for reference |

## Targets

| Target | Model | Harness built with |
|---|---|---|
| `lkmm` | `cat/linux-kernel.cat` | `-DTARGET_LKMM`: Dat3M's lkmm.h and rcu.h, grace periods included |
| `arm8` | `cat/aarch64.cat` | `-DTARGET_LKMM_HW -DGP_AS_NOP`: lkmm.h without RCU, hardware has none |
| `power` | `cat/power.cat` | the same |
| `tso` | `cat/tso.cat` | `-DTARGET_C11 -DGP_AS_NOP`: the `__atomic` builtins as the x86 mapping |
| `arm8-c11`, `power-c11` | `cat/aarch64.cat`, `cat/power.cat` | the C11 route with smp_rmb() and smp_wmb() as acquire and release fences |

The hardware targets have no RCU. Where an assertion depends on the
grace period (`A2`, `C2`) they run it with a full barrier standing in
for it (`-gp-as-mb`), which is the `A2m-nogp` mutation under another
name and has to fail.

## Results

Dartagnan master b81ec6c55 (4.4.1-73), `--bound=2`, every check PASS or
FAIL, none UNKNOWN. PASS means the assertion holds in every execution
the model allows. For a mutation FAIL is the expected answer.

| variant | lkmm | arm8 | power | tso | arm8-c11 | power-c11 |
|---|---|---|---|---|---|---|
| `A0` | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| `A1` | PASS | PASS | PASS | PASS | PASS | PASS |
| `A1m-nowmb` | FAIL | FAIL | FAIL | PASS | FAIL | FAIL |
| `A1m-nomb-in-sum` | FAIL | FAIL | FAIL | PASS | FAIL | FAIL |
| `A1m-gets-first` | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| `A1mig` | PASS | PASS | PASS | PASS | PASS | PASS |
| `A2` | PASS | - | - | - | - | - |
| `A2-gp-as-mb` | - | FAIL | FAIL | FAIL | FAIL | FAIL |
| `A2m-nogp` | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| `B1` | PASS | PASS | PASS | PASS | PASS | PASS |
| `B1m-walker-nomb` | FAIL | FAIL | PASS | FAIL | FAIL | FAIL |
| `B1m-peek-no-outer-mb` | PASS | PASS | PASS | PASS | PASS | PASS |
| `B2` | PASS | PASS | PASS | PASS | PASS | PASS |
| `B2m-flags-unlocked` | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL |
| `C1` | PASS | PASS | PASS | PASS | PASS | PASS |
| `C2` | PASS | - | - | - | - | - |
| `C2-gp-as-mb` | - | FAIL | FAIL | FAIL | FAIL | FAIL |
| `D1` | PASS | PASS | PASS | PASS | PASS | PASS |
| `D1m-holder-wmb-only` | FAIL | FAIL | PASS | FAIL | PASS | FAIL |

Under LKMM every code shape passes and every barrier mutation fails,
cell by cell what herd7 says about the litmus tests. The peek without
its outer smp_mb() (`B1m-peek-no-outer-mb`) passes under every model.

The cells that differ from LKMM are explained by the targets, not by
the code:

- `tso` passes `A1m-nowmb` and `A1m-nomb-in-sum`. x86 keeps stores in
  order with stores and loads in order with loads, so those two
  barriers are compiler barriers there anyway.
- `power` passes `B1m-walker-nomb` and `D1m-holder-wmb-only` because
  Dartagnan's lowering of lkmm.h turns smp_rmb() and smp_wmb() into a
  full `sync` on POWER, where the kernel emits `lwsync`. The C11 route
  uses `lwsync` and fails both, as it should.
- `arm8-c11` passes `D1m-holder-wmb-only` because a C11 release fence is
  `dmb ish` on arm64 while the kernel's smp_wmb() is `dmb ishst`. The
  lkmm.h route fails it.

## Running

`run.sh` is the driver as it ran on the build machine. It expects a
Dat3M checkout and its build under `~/tmp/dat3m/`, the harness in
`~/tmp/dat3m/harness/`, a JDK 21 under `~/opt/jdk21` and clang-19, and
it pins Dartagnan to CPUs 256-511 of that machine. Adjust the top of the
script first:

    ./run.sh lkmm                       # every variant under one target, bound 2
    ./run.sh power-c11 2 'B1m|D1m'      # a subset

One variant by hand:

    clang-19 -I $DAT3M_HOME/include -Xclang -disable-O0-optnone -S -emit-llvm \
        -g -gcolumn-info -DTARGET_LKMM -DSCEN_A1 mnt_gp.c -o A1.ll
    java -jar $DAT3M_HOME/dartagnan/target/dartagnan.jar cat/linux-kernel.cat \
        --target=lkmm A1.ll --bound=2 --property=program_spec,cat_spec

Higher bounds buy nothing here: no check came back UNKNOWN at bound 2,
the only loops are the lock spins.

## Not done

- A combined scenario with holder, walker and unmounter at once and both
  the A1 and the B assertions. The threads exist in `mnt_gp.c`, only the
  wiring in main() is missing.
- RCU under the hardware models. Dat3M's rcu.h has a reference
  implementation (`RCU_IMP`) that would let `A2` and `C2` run there with
  a modelled grace period instead of a barrier.

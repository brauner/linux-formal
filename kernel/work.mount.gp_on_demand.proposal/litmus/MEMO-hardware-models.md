# Follow-up: the ordering argument under the Arm and POWER architectural models, and on x86 hardware

Companion to research-weak-memory.md (same scratchpad).  Tree: work.mount.gp_on_demand.proposal at
4379d47fd314, untouched.  Everything here lives in scratchpad/litmus/ (`aarch64/`, `ppc/`, `gen-asm.py`,
`collect-results.sh`, `x86-klitmus.txt`, `RESUME.md`) and on jens in `~/tmp/klitmus/`.

## 0. Summary

1. The load-bearing LKMM litmus tests (A1 + 3 mutations, B1 + 2 mutations, B2 + mutation, C1, D1 + mutation,
   and the two new tests E1/E2 for the removal of the outer smp_mb() calls) were translated to AArch64 and
   POWER assembly with the barriers the kernel really emits and run with herd7 7.58 under the Arm official
   model (`aarch64.cat`, the ArmARM snapshot herdtools7 ships) and `ppc.cat`.  Every result that has finished
   agrees with LKMM: every "Never" is Never under both architectural models, every "Sometimes" has a witness
   under both.  No divergence.  (The B-family AArch64/POWER runs are slow -- minutes each -- and some were
   still running at hand-off; `collect-results.sh` regenerates the table.  Table in section 1.)
2. klitmus7 on hardware: a kernel of 4379d47fd314 was built on jens (52 s), 14 klitmus7 modules built against
   it, and run in a KVM guest (8 vcpus pinned to host CPUs 256-263).  All 14 ran.  Every test the code relies
   on is Never over 2.1-4 million iterations; the three mutations x86-TSO can exhibit at all (store->load
   reordering or a plain interleaving) were observed: B1m-walker-nomb 988 hits, D1m 4252, B2m 646,
   A1m-gets-first 21.  The mutations that need store->store or load->load reordering (A1m-nowmb,
   A1m-nomb-in-sum) are Never on x86 as they must be -- which is exactly why an x86 run is not evidence for
   arm64/POWER; the architectural-model runs are.
3. The three outer smp_mb() removals (E1 slow path, E2 busy check, B1m-peek the peek) are Never under LKMM,
   Never on x86 (2.1M iterations each), Never under the Arm model (E1, E2, B1m-peek all finished) and under
   the POWER model (E2 finished; E1 and B1m-peek were still running at hand-off, see the table and
   collect-results.sh).  Section 3 states the
   cross-architecture argument.
4. A VM cannot stand in for weak hardware unless it is KVM on that hardware: qemu TCG with an aarch64 guest
   on an x86 host shows at most x86-TSO behaviour.  Section 4.  A TCG functional run was not done
   (no evidentiary value, ~1 h of arm64 kernel/busybox plumbing); recipe given.

## 1. Hardware-model runs (herd7 7.58, `-model aarch64.cat` / `-model ppc.cat`)

### Translation

`litmus/gen-asm.py` holds each test as an abstract program and emits both architectures; the mapping is
what the kernel emits (from arch/*/include/asm/barrier.h in this tree):

| kernel | AArch64 (arm64 barrier.h) | POWER (powerpc barrier.h, 64-bit) | x86 (for reference) |
|---|---|---|---|
| READ_ONCE/WRITE_ONCE | LDR / STR | lwz / stw | mov |
| smp_wmb() | DMB ISHST | lwsync (SMPWMB=LWSYNC) | barrier() (compiler only) |
| smp_rmb() | DMB ISHLD | lwsync | barrier() (compiler only) |
| smp_mb() | DMB ISH | sync | lock addl $0,-4(%rsp) |
| spin_lock() | SWPA (acquire RMW; qspinlock's fast path is atomic_try_cmpxchg_acquire(), CASA on LSE) | lwarx/stwcx. + beq + isync (PPC_ACQUIRE_BARRIER) | -- |
| spin_unlock() | STLR WZR (smp_store_release()) | lwsync; stw (PPC_RELEASE_BARRIER) | -- |

Approximations, stated: (a) the lock is emulated without a spin loop; a herd7 `filter` clause keeps only
executions in which every acquisition found the lock free (SWPA read 0; on POWER a failed stwcx. sets the
register to 1 and is filtered out), the trick documented in tools/memory-model/Documentation/litmus-tests.txt
for emulated locks; (b) `this_cpu_inc()` is a plain store of the final value, as in the LKMM tests; (c) the
seqcount is modelled as seqlock.h does it (store; DMB ISHST / lwsync); (d) `DMB ISH*` makes herd7 flag
"Assuming-common-inner-shareable-domain", i.e. the model treats all observers as one inner-shareable domain,
which is what SMP CPUs are; (e) `-speedcheck true` was used for the slow tests: it stops at the first witness
and then prints "Always 1 0", which means "witnessed" (allowed); where a full run exists (`.full.out`) the
exact Sometimes counts are shown.  AArch64 runs are 20-400x slower than POWER ones because SWPA/STLR
generate more candidate executions in that model.

### Results

Table at hand-off (09:01 UTC; regenerate with `litmus/collect-results.sh`, which reads `aarch64/*.out`,
`ppc/*.out` and `x86-klitmus.txt`):

| test | LKMM | AArch64 (Arm official model) | POWER (ppc.cat) | x86 hardware (klitmus7, KVM on EPYC 9754) |
|------|------|------------------------------|-----------------|-------------------------------------------|
| MNT-A1-holder-get-before-put | Never | Never | Never | Never 0/4000000 |
| MNT-A1m-gets-first | Sometimes | Sometimes 1 5 | Sometimes 1 5 | Sometimes 21/3999979 |
| MNT-A1m-nomb-in-sum | Sometimes | Sometimes 1 5 | Sometimes 1 5 | Never 0/4000000 (unobservable on TSO) |
| MNT-A1m-nowmb | Sometimes | Sometimes 1 5 | Sometimes 1 5 | Never 0/4000000 (unobservable on TSO) |
| MNT-B1-walker-inc-vs-peek | Never | still running at hand-off | still running at hand-off | Never 0/2103442 |
| MNT-B1m-walker-nomb | Sometimes | still running at hand-off | still running at hand-off | Sometimes 988/2100421 |
| MNT-B1m-peek-no-outer-mb | Never | Never | still running at hand-off | Never 0/2122844 |
| MNT-B2-walker-bail-sees-doomed-lazy | Never | still running at hand-off | still running at hand-off | Never 0/2073085 |
| MNT-B2m-walker-flags-unlocked | Sometimes | still running at hand-off | witnessed | Sometimes 646/2130850 |
| MNT-C1-kern-unmount-get-before-put | Never | Never | Never | Never 0/4000000 |
| MNT-D1-dekker-fastpath-recheck | Never | Never | Never | Never 0/4000000 |
| MNT-D1m-holder-wmb-only | Sometimes | witnessed | Sometimes 1 4 | Sometimes 4252/3995748 |
| MNT-E1-slowpath-no-outer-mb | Never | Never | still running at hand-off | Never 0/2096720 |
| MNT-E2-busycheck-no-outer-mb | Never | Never | Never | Never 0/2123015 |

Divergences: none among the finished cells.  The only "disagreements" are the x86 Never results for
A1m-nomb-in-sum and A1m-nowmb, which are not disagreements: x86-TSO never reorders two loads or two stores,
so those two mutations cannot be observed on x86 no matter how long the run; LKMM, the Arm model and the
POWER model all say the reorderings exist on weaker machines.  That is the concrete demonstration that an
x86 "Never" says nothing about arm64/POWER, and the concrete demonstration that mnt_get_count()'s inner
smp_mb() is load-bearing on those architectures (A1m-nomb-in-sum), the point the TLA+ model cannot make.

Reading the x86 counts: klitmus7 ran each module with nruns=10 size=100000 on 8 vcpus; the walker tests have
a `filter` so about half of the 4M iterations are counted.  The hits for B1m-walker-nomb and D1m are x86's one
permitted reordering, store->load (a store still in the store buffer while a later load executes); the hits
for B2m and A1m-gets-first are plain interleavings allowed even under sequential consistency (the walker reads
`flags` before the unmounter's store; the sum reads `gets` before the holder's get and `puts` after its put).

## 2. klitmus7 on jens: what was done and what an x86 observation can mean

Pipeline (all on jens, tmux `klitmus`, logs in `~/tmp/klitmus/`): `build-kernel.sh -r 4379d47fd314 -c perf
-C 256-511 -j 64` built 7.3.0-rc2-g4379d47fd314 in 52 s; `make modules_prepare`; klitmus7 7.58 (the
root-less install from the first memo) generated one module per test from `~/tmp/lkmm/litmus/`, built with
`KBUILD_MODPOST_WARN=1 make -C ~/tmp/klitmus/build M=<dir> modules` (there is no Module.symvers without an
in-tree `make modules`; the symbols resolve at insmod against vmlinux, and this config has no MODVERSIONS);
`mkinitrd.py --init init.sh --add <ko>:/klitmus/<ko>` packed them with the bench busybox; qemu-system-x86_64
`-enable-kvm -cpu host -smp 8 -m 4G -nographic -no-reboot`, `taskset -c 256-263`, `console=ttyS0 panic=-1
klitmus_nruns=10 klitmus_size=100000`; init.sh insmods each module with `size=100000 nruns=10 stride=1
avail=0`, cats /proc/litmus (the herd-style result block) and powers off.  The whole guest run took 7 s.
The build tree was removed afterwards (step5); `~/tmp/klitmus` is 29 MB: bzImage, config, kmod/<test>.ko with
sources, logs, the scripts.  The klitmus7 7.58 modules build and run fine on a 7.3 kernel (the compat table in
tools/memory-model/README ends at 5.17).

One trap for the record: the first VM run hung silently for five minutes.  `timeout` without `--foreground`
puts qemu in a background process group and qemu `-nographic` reads the terminal, so it was stopped by SIGTTIN
(state "Tl").  step4-vm.sh now uses `timeout --foreground ... < /dev/null`.

Can x86 observe the bad outcome at all?  x86-TSO reorders only a store with a later load to a different
address; everything else is program order, and any interleaving allowed under SC is of course possible.

| test | shape | observable on x86? | observed |
|------|-------|--------------------|----------|
| A1, C1 | MP: W gets; wmb; W puts vs R puts; mb; R gets | no (code correct) | Never |
| A1m-nowmb | needs store->store reordering | no, never on TSO | Never (but Sometimes on Arm/POWER models) |
| A1m-nomb-in-sum | needs load->load reordering | no, never on TSO | Never (but Sometimes on Arm/POWER models) |
| A1m-gets-first | SC interleaving (sum reads gets before the get, puts after the put) | yes | Sometimes 21 |
| B1, E1, E2, B1m-peek | SB with full barriers on both sides | no (code correct) | Never |
| B1m-walker-nomb | SB, walker side lacks the full barrier: store->load | yes | Sometimes 988 |
| B2 | lock-ordered | no (code correct) | Never |
| B2m-walker-flags-unlocked | SC interleaving (flags read racing the finish-off) | yes | Sometimes 646 |
| D1 | SB with full barriers | no (code correct) | Never |
| D1m-holder-wmb-only | SB, holder side has only wmb: store->load | yes | Sometimes 4252 |

So the x86 run is a genuine hardware check for the SB-shaped claims (B1, E1, E2, B1m-peek, D1: the pairing
that was removed-and-replaced is store->load, exactly what x86 reorders, and the positive controls
B1m-walker-nomb and D1m show the rig does see such reorderings when the barrier is missing).  For the
MP-shaped claims (A1 family) x86 proves nothing; the Arm and POWER model runs do.

## 3. The cross-architecture argument for removing the three outer smp_mb() calls

The three calls (fs/namespace.c at 4379d47fd314; the worktree meanwhile carries the removal as
e0d99540489b "fs: drop the smp_mb()s that mnt_get_count() made redundant", found by the same `git log -S`):

1. mntput_no_expire_slowpath(): `smp_mb()` right after lock_mount_hash(), before mnt_dec_count() and
   mnt_get_count(); comment "make sure that if __legitimize_mnt() has not seen us grab mount_lock, we'll see
   their refcount increment here".  Added by 119e1ef80ecf "fix __legitimize_mnt()/mntput() race"
   (2018-08-09, `git log -S'has not seen us grab'`).
2. do_umount(): `smp_mb(); // paired with __legitimize_mnt()` before shrink_submounts() and
   propagate_mount_busy(), after lock_mount_hash(); added by 65781e19dcfc "do_umount(): add missing barrier
   before refcount checks in sync case" (2025-04-28).
3. mntput_unmounted(): `smp_mb(); /* see __legitimize_mnt() and mntput_no_expire() */` after
   lock_mount_hash(), before the mntput_unheld() loop; introduced by this series (754381fa6d6c).

All three are smp_mb(): a full barrier, ordering every earlier access before every later one including the
store->load case, on every architecture (arm64 `dmb ish`, POWER `sync`, x86 `lock addl $0,-4(%rsp)`, riscv
`fence rw,rw`, s390 a serializing `bcr`).  smp_wmb() and smp_rmb() are not: they order store->store and
load->load only (arm64 `dmb ishst`/`dmb ishld`, POWER `lwsync`, x86 nothing but a compiler barrier).  The
only store->load pairing those three barriers served is the store-buffering pattern with __legitimize_mnt()
(`mnt_inc_count(); smp_mb(); read_seqretry()`): the sum side needs a full barrier between the seqcount store
of lock_mount_hash() (write_seqlock: `seq++; smp_wmb()`) and its loads of the gets.  mnt_get_count() already
contains `smp_mb()` between its puts pass and its gets pass -- a full barrier, in program order after the
seqcount store and before every gets load -- so the pairing is intact without the outer call.  The puts pass
needs no full barrier in front of it: a walker's put is under mount_lock and ordered by the lock acquire; a
holder's fast-path put is ordered after its get by smp_wmb(), which pairs with the inner smp_mb(); the slow
path's own mnt_dec_count() is a store by the same CPU to a location it reads back (coherence).  That is what
E1 (slow path), E2 (busy check) and B1m-peek-no-outer-mb (the peek) encode, and they are Never under LKMM.

Why a "Never" under tools/memory-model carries to every architecture: LKMM is the contract.  Every
architecture's implementation of READ_ONCE/WRITE_ONCE, smp_*mb(), the acquire/release of spinlocks and the
RCU primitives must be at least as strong as LKMM's semantics for them; the mapping was validated against the
hardware models (and hardware) in the ASPLOS 2018 paper that defines LKMM, and an architecture whose barriers
were weaker than LKMM would be the bug, not the code written to LKMM.  LKMM is in fact weaker than any
architecture (the qspinlock-under-LKMM episode went the other way: LKMM allowed what no hardware does), so an
LKMM "Never" is the strongest statement available at the source level, and it is the standard the memory-model
maintainers hold kernel code to.  The AArch64 and POWER runs here are the independent check on the two
weakest mainstream architectures, with the instructions the kernel emits there (DMB ISH and `sync` for the
inner smp_mb()); x86 adds a hardware sanity run that can, in principle, see a violation of exactly this
store->load pairing and did not in 2.1M iterations per test, while seeing the positive controls.

Obligation that comes with the removal, to be kept in a comment at the inner barrier: the pairing now rests
on mnt_get_count() keeping a *full* smp_mb() (not smp_rmb(), which would still do for the holders' MP pairing
but not for the walkers' SB pairing) between its two passes, and on every caller that depends on it having
performed the seqcount write (lock_mount_hash()) before calling mnt_get_count().  may_umount_tree(),
may_umount() and the MNT_EXPIRE check in do_umount() already sum under lock_mount_hash() without an outer
barrier, so they have been relying on this silently all along.

## 4. Can a VM stand in for weak hardware?

Only when it is hardware virtualization on that hardware.  A KVM guest executes guest code natively; its
memory model is the host CPU's, so the x86 KVM run above is a real x86-TSO test (vcpu preemption even widens
the race windows), and an arm64 KVM guest on an arm64 host would be a real arm64 test.  TCG is different:
qemu-system-aarch64 on an x86 host translates guest instructions to host code, performs guest loads and stores
as host loads and stores, turns guest barriers into host barriers and guest atomics into host cmpxchg
(MTTCG, see QEMU's docs/devel/multi-thread-tcg.rst, "Memory Consistency"); when the guest's model is weaker
than the host's nothing extra is inserted, because the host is already stricter.  An emulated arm64 guest on
x86 therefore exhibits at most x86-TSO behaviour: store->load reordering with alien timing, and never the
load->load, store->store or load->store reorderings arm64 permits -- precisely the ones A1m-nomb-in-sum and
A1m-nowmb hinge on.  A TCG run of the klitmus modules is a functional check (the arm64 build loads and the
harness runs) and nothing more: a TCG "Never" is not evidence, and anything TCG can show, the x86 KVM run
shows more cheaply.  Not done: it needs an arm64 kernel (`make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
defconfig Image modules_prepare`), the klitmus modules cross-built the same way, an arm64 static busybox
(`curl` the Debian busybox-static arm64 .deb and `dpkg -x`, no root), mkinitrd.py with `--busybox`, and
`qemu-system-aarch64 -M virt -cpu cortex-a72 -smp 8` pinned to 256-263; the toolchain and qemu exist on jens
(`/usr/bin/aarch64-linux-gnu-gcc`, `/usr/bin/qemu-system-aarch64`); about an hour, for no evidentiary value.
Real arm64 evidence needs arm64 silicon (a Pi 4/5, Apple Silicon under Asahi, an arm64 cloud box); the Arm
architectural model via herd7 is exhaustive for the test and is the better evidence anyway.

## 5. State left behind, and how to collect

- jens `~/tmp/klitmus/` (29 MB): bzImage, config, `kmod/<test>.ko` (+ generated sources and make logs),
  `vm.log` (the 14 result blocks), `run-all.log`, `run-all.log.1`, `run-vm.log`, the step scripts; the build
  tree and its worktree were removed by step5 (`git worktree prune` done).  Rerun the VM with other
  parameters: `KLITMUS_NRUNS=50 KLITMUS_SIZE=200000 bash ~/tmp/klitmus/step4-vm.sh > ~/tmp/klitmus/vm2.log`
  (checks nothing about the lock: use `run-vm-only.sh` for that).  jens `~/tmp/lkmm/litmus/` has all 16+2
  LKMM tests, `~/.local/herdtools7` the tools.
- Local scratchpad `litmus/`: `aarch64/`, `ppc/` (`<test>.litmus`, `<test>.out`, `<test>.full.out`),
  `gen-asm.py`, `run-one.sh`, `run-some.sh`, `collect-results.sh`, `x86-klitmus.txt`, `RESUME.md`.  herd7
  processes for the B-family and E1 were still running at hand-off (one per test); their `.out` files get the
  Observation line when they finish; `collect-results.sh` prints the table.  Any `.out` without an Observation
  line after wake-up: `herd7 -model aarch64.cat -speedcheck true aarch64/<test>.litmus`.

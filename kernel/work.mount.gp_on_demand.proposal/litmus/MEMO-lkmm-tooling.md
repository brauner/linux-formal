# Checking the gp-on-demand ordering argument under LKMM and hardware models

Scope: work.mount.gp_on_demand.proposal, tip 4379d47fd314, fs/namespace.c.
Parties: holder fast path in mntput_no_expire(), walker in __legitimize_mnt(),
unmounter in umount_tree() + mntput_unmounted()/mntput_unheld(), plus the
kern_unmount_array() feeder (mnt_make_shortterm()).  The TLA+ model in
~/src/git/linux-tla/kernel/mount-gp-on-demand/ reorders *stores* only (FIFO or
WEAK_STORES buffers); it never reorders loads and its RCU/seqlock are
abstractions, so it cannot check the barrier pairing under LKMM.

Nothing in the kernel tree was modified.  Everything produced lives in the
scratchpad: `litmus/` (16 tests + herd7 outputs), `klitmus/` (generated module
sources), `deb-test/` (throwaway).  On jens I installed herdtools7 user-locally
(details in section 5; nothing outside ~/.local/herdtools7 and ~/tmp).

## 0. Result in one paragraph

herd7 7.58 with the worktree's own tools/memory-model (LKMM, variant lkmmv2) is
installed locally (Debian herdtools7 7.58-2) and I ran 16 litmus tests that
encode the series' ordering claims.  Every claim the code makes comes out
"Never" (forbidden bad outcome) and every barrier I removed as a mutation
comes out "Sometimes", in under 0.5 s each.  The one thing this proves that
TLA+ structurally cannot: the smp_mb() *inside* mnt_get_count(), between the
puts pass and the gets pass, is load-bearing (read-read reordering, test
MNT-A1m-nomb-in-sum: Sometimes).  The RCU fallback (count != 1 -> expedited
grace period -> plain put) and the walker's seqcount/MNT_DOOMED protocol hold
under LKMM's actual rcu-fence and lock.cat axioms, not an abstraction.  The
same suite reproduces identically on jens.

Results (herd7 7.58, LKMM from the worktree; identical on jens):

| test | expected | result | what it checks |
|------|----------|--------|----------------|
| MNT-A0-peek-can-miss-fastpath-put | Sometimes | Sometimes 1 2 | documents *why* the GP branch exists: the peek may miss a fast-path put even under SC |
| MNT-A1-holder-get-before-put | Never | Never 0 5 | smp_wmb() before the put vs. puts-then-smp_mb()-then-gets sum: a counted put has its get counted (7eb84d54fac5's invariant, now load-bearing for the peek) |
| MNT-A1m-nowmb (mutation) | Sometimes | Sometimes 1 5 | without the holder's smp_wmb() the put overtakes the get |
| MNT-A1m-nomb-in-sum (mutation) | Sometimes | Sometimes 1 5 | without mnt_get_count()'s inner smp_mb() the two passes reorder; **TLA+ cannot represent this** (it never reorders loads) |
| MNT-A1m-gets-first (mutation) | Sometimes | Sometimes 1 5 | gets summed before puts (TLA+ SPLIT_GETS_FIRST) |
| MNT-A2-gp-fallback-sees-fastpath-put | Never | Never 0 3 | holder saw ->mnt_ns non-NULL inside rcu_read_lock(); after synchronize_rcu_expedited() the plain put's slow path must see its put |
| MNT-A2m-nogp (mutation) | Sometimes | Sometimes 1 3 | a full barrier is no substitute for the grace period (allowed even under SC) |
| MNT-B1-walker-inc-vs-peek | Never | Never 0 13 | SB: walker inc; smp_mb(); seqcount re-read vs. peek seqcount write; smp_mb(); gets read: not both "walker keeps the reference" and "peek finishes the mount" |
| MNT-B1m-walker-nomb (mutation) | Sometimes | Sometimes 1 15 | drop __legitimize_mnt()'s smp_mb() (TLA+ FIX_MB_LEGIT off) |
| MNT-B1m-peek-no-outer-mb (mutation) | ? | Never 0 13 | informational: mntput_unmounted()'s explicit smp_mb() is not load-bearing in this shape because mnt_get_count()'s inner smp_mb() already sits between the seqcount write and the gets pass. Do not act on it: it documents the pairing, and the inner barrier is mnt_get_count()'s business |
| MNT-B2-walker-bail-sees-doomed-lazy | Never | Never 0 13 | lazy unmount (no MNT_SYNC_UMOUNT): a walker that saw the seqcount change and takes mount_lock either had its increment seen (peek does not finish) or sees MNT_DOOMED |
| MNT-B2m-walker-flags-unlocked (mutation) | Sometimes | Sometimes 2 11 | the flags check must be under mount_lock |
| MNT-C1-kern-unmount-get-before-put | Never | Never 0 5 | A1 with mnt_make_shortterm()'s bare WRITE_ONCE(->mnt_ns, NULL): no lock, no seqcount bump |
| MNT-C2-kern-unmount-gp-fallback | Never | Never 0 3 | A2 likewise |
| MNT-D1-dekker-fastpath-recheck | Never | Never 0 4 | Dekker alternative (put; smp_mb(); re-read ->mnt_ns vs. store NULL; smp_mb(); sum): not both "holder stays on the fast path" and "peek misses the put" |
| MNT-D1m-holder-wmb-only (mutation) | Sometimes | Sometimes 1 4 | the Dekker needs a full barrier on the holder side |

Files: scratchpad/litmus/MNT-*.litmus and MNT-*.out; on jens ~/tmp/lkmm/litmus/.

## 1. Ranked recommendation (effort vs. what it proves beyond TLA+)

1. **Keep and ship the herd7/LKMM litmus tests (done; 1-2 h to polish).**
   LKMM is the kernel's normative model: code that is wrong under LKMM is
   considered wrong even if hardware happens to be stronger (the qspinlock
   discussion below).  The tests pin down exactly which barrier pairs with
   which, including the read-read case TLA+ cannot express.  Options: add them
   as Documentation/litmus-tests/fs/ (precedent: the SRCU fastpath litmus
   tests moved to Documentation/litmus-tests/srcu/ at Paul McKenney's request,
   Sept 2026, same shape: a per-CPU counter scan vs. a reader), or keep them
   next to the TLA+ model in linux-tla.  Either way, Cc lkmm@lists.linux.dev /
   the LKMM maintainers (Stern, Parri, Feng, McKenney, Fernandes) when the
   series goes out; litmus tests are the currency that group reviews in.
   Cheap follow-ups: a migration variant of A1 (get on cpu0's variable, put on
   cpu1's; same process, same answer), a two-holder variant, and a plain-access
   variant to exercise LKMM's data-race flag (my tests use marked accesses
   everywhere; the kernel's `s->sequence++` and the cross-CPU counter reads are
   plain).

2. **Run the barrier tests under the Arm architectural model with herd7
   (1-2 h).**  The Debian package ships Arm's official aarch64.cat (the
   herdtools7 tags ArmARM-M.a..M.d are those snapshots).  herd7 cannot run C
   litmus tests against hardware models, so A1/B1/D1 have to be hand-translated
   to AArch64 assembly litmus (READ_ONCE/WRITE_ONCE -> LDR/STR, smp_wmb ->
   DMB ISHST, smp_rmb -> DMB ISHLD, smp_mb -> DMB ISH; drop the spinlock, it
   is not load-bearing for these pairings).  Proves the barrier pairings under
   the architecture's own model rather than LKMM; cannot do RCU (no asm
   analogue), and the compiler is out of the picture.  `herd7 -model aarch64.cat`.

3. **klitmus7 on x86 (low value, ~1 h if a module build tree is at hand).**
   klitmus7 7.58 compiles A1/B1/B2/C1/D1 to kernel modules but refuses every
   test containing synchronize_rcu()/synchronize_rcu_expedited() ("Test not
   compiled"), so the GP tests cannot be run on hardware this way.  x86-TSO
   only ever reorders a store with a later load, so of the mutations only the
   SB-shaped ones (B1m-walker-nomb, D1m) could show "Sometimes" on jens; the
   MP-shaped A1 mutations come out "Never" on x86 regardless of the code.  A
   "Never" from klitmus7 on x86 therefore proves nothing for arm64/POWER.
   There is no arm64 hardware on jens or locally.  qemu-system-aarch64 (TCG)
   on an x86 host is useless for this: guest loads/stores become host
   loads/stores and guest barriers become host barriers, so an emulated arm64
   guest exhibits at most x86-TSO behaviour.  If hardware evidence is wanted:
   a Raspberry Pi 4/5, Apple Silicon under Asahi, or an arm64 cloud box
   (Hetzner CAX, AWS Graviton); the LKMM folks also run tests on POWER/arm64
   when asked.

4. **Dartagnan C harness under LKMM and under arm8/power (1-2 days).**  The
   only tool that takes C with Linux barrier macros and checks it under LKMM
   *and* under hardware cat models, with real control flow and bounded loops,
   so the composition (N holders, M walkers, one unmounter, the integer
   counts) can be checked rather than pairwise fragments.  Beyond TLA+: the
   real memory model instead of store buffers, plus data-race detection.
   Beyond herd7: more than 2-3 processes with code structure.  Cost: build
   from source (Maven; no binaries in the 4.4.1 release of 2026-05-22; no mvn
   on jens or locally; jens has Java 25 and podman, so the project's
   Dockerfile is the realistic route), hand-model this_cpu ops and the
   seqlock, bounded unrolling, and triage of LKMM-only counterexamples (see
   qspinlock).  Worth it only if the pairwise litmus results are not
   considered enough.

5. **Not applicable:** GenMC (LKMM support removed in 0.10.0, 2023-10-25),
   Nidhugg (SC/TSO/PSO, POWER/ARMv7 partial and only with LLVM < 15, no LKMM,
   no RCU), CDSChecker (C11 only, dormant since ~2015), CBMC (its weak-memory
   modes are TSO/PSO/RMO/Power for pthreads, no LKMM; the Tree RCU work used
   it under SC).  Iris/Coq-style proofs (Tassarotti et al. 2015, OOPSLA 2023,
   PLDI 2025) are the gold standard for RCU/refcount "last reference" protocols
   under weak memory but are months of work and out of scope.

## 2. How LKMM covers the constructs in this code

Checked against tools/memory-model/linux-kernel.{def,bell,cat} in the worktree
and Documentation/litmus-tests.txt ("LIMITATIONS"):

- **RCU**: rcu_read_lock()/rcu_read_unlock()/synchronize_rcu()/
  synchronize_rcu_expedited() are first-class (fences rcu-lock, rcu-unlock,
  sync-rcu; the `rcu-order`/`rcu-fence` axioms).  SRCU too.  call_rcu() is
  *not* modelled; emulate with an extra process doing an acquire of a flag,
  synchronize_rcu(), then the callback body (litmus-tests.txt "Asynchronous
  RCU Grace Periods").  The final delayed_free_vfsmnt() is irrelevant to the
  ordering claims here, so I did not model it.
- **Seqlocks**: no primitive.  Model what include/linux/seqlock.h does:
  write_seqlock = spin_lock(); seq++; smp_wmb();  write_sequnlock = smp_wmb();
  seq++; spin_unlock();  read_seqbegin = READ_ONCE(seq); smp_rmb();
  read_seqretry = smp_rmb(); READ_ONCE(seq) != start.  (Verified in the
  worktree: do_raw_write_seqcount_begin/end, do_read_seqcount_retry.)  The
  kernel's `s->sequence++` is a plain access; I used WRITE_ONCE to keep LKMM's
  data-race flag quiet, a harmless strengthening for ordering questions.
  smp_load_acquire would be the wrong stand-in: the seqcount readers rely on
  rmb, not acquire, and the writer on wmb.
- **Spinlocks**: spin_lock()/spin_unlock() are modelled (lock.cat: LKR has
  acquire, UL release, plus the lock-passing po-unlock-lock-po ordering).
  `lock` is a reserved word in herd7's C parser; name the variable `mlock`.
- **Per-CPU counters**: this_cpu_inc() does not exist in LKMM, and
  for_each_possible_cpu() loops do not either (no loops at all).  Stand-in:
  one variable per (CPU, counter) and a WRITE_ONCE of the final value by the
  one process that owns that CPU's counter; the sum is unrolled over two CPUs.
  This is faithful for ordering: on x86 this_cpu_inc is an unlocked `incl
  %gs:`, i.e. an ordinary store; on arm64 it is a relaxed LSE/LL-SC RMW.  LKMM
  has no CPUs, only processes: a holder's get and put are ordered by its own
  fences wherever it runs, which is exactly the "migration" case of the TLA+
  model, so migration is the same litmus test with the put aimed at another
  CPU's variable.
- **smp_wmb/smp_mb/smp_rmb**: all modelled; the wmb->mb (MP) and mb<->mb (SB)
  pairings this code relies on are the textbook ones
  (MP+fencewmbonceonce+fencermbonceonce, SB+fencembonceonces).
- **Control flow**: `if` only, no loops, no `&&`/`||` (nest ifs), no function
  calls; register arithmetic and register-to-register comparison work;
  `filter` discards executions (I use it to pin the walker's read_seqbegin()
  value to 0); `locations` prints extra variables.
- **Compilers are not modelled** (litmus-tests.txt limitation 1); the control
  dependency from READ_ONCE(->mnt_ns) to the put store is honoured by LKMM
  (rwdep) and is real in the kernel because the branch exists.

## 3. The litmus tests (LKMM syntax, ready for herd7)

Run from the worktree's tools/memory-model directory:
`herd7 -conf linux-kernel.cfg <file>.litmus`.  Shared state: mnt_ns (1 =
non-NULL), gets_h/puts_h (the holder's CPU), gets_u/puts_u (the unmounter's
CPU; gets_u=1 is the mount's own reference), gets_w/puts_w (the walker's CPU),
seq, flags (1 = MNT_SYNC_UMOUNT, 3 = +MNT_DOOMED), freed, mlock = mount_lock.

### (a1) holder fast path vs. the peek: a counted put has its get counted

```
C MNT-A1-holder-get-before-put

(*
 * Expected: Never.  The smp_wmb() before the put of mntput_no_expire()
 * pairs with the smp_mb() of mnt_get_count() between the puts pass and
 * the gets pass: a put the sum counted has its get counted too.
 *
 * P0: holder with a long-lived reference (gets_h=1) does a transient
 *     mntget() (gets_h=2) and the fast-path mntput().
 * P1: unmount, then the peek.  Bad outcome: the peek sees puts_h=1 but
 *     gets_h=1, i.e. count = (1+1) - (1+0) = 1 with the long-lived
 *     reference still held -> the mount would be finished off under the
 *     holder.
 *)

{
	mnt_ns=1;
	gets_h=1;
	puts_h=0;
	gets_u=1;
	puts_u=0;
}

P0(int *mnt_ns, int *gets_h, int *puts_h)
{
	int r0;

	WRITE_ONCE(*gets_h, 2);
	rcu_read_lock();
	r0 = READ_ONCE(*mnt_ns);
	if (r0) {
		smp_wmb();
		WRITE_ONCE(*puts_h, 1);
	}
	rcu_read_unlock();
}

P1(spinlock_t *mlock, int *seq, int *mnt_ns, int *gets_h, int *puts_h, int *gets_u, int *puts_u)
{
	int r1;
	int r2;
	int r3;
	int r4;

	spin_lock(mlock);
	WRITE_ONCE(*seq, 1);
	smp_wmb();
	WRITE_ONCE(*mnt_ns, 0);
	smp_wmb();
	WRITE_ONCE(*seq, 2);
	spin_unlock(mlock);

	spin_lock(mlock);
	WRITE_ONCE(*seq, 3);
	smp_wmb();
	smp_mb();
	r1 = READ_ONCE(*puts_h);
	r2 = READ_ONCE(*puts_u);
	smp_mb();
	r3 = READ_ONCE(*gets_h);
	r4 = READ_ONCE(*gets_u);
	smp_wmb();
	WRITE_ONCE(*seq, 4);
	spin_unlock(mlock);
}

exists (0:r0=1 /\ 1:r1=1 /\ 1:r3=1)
```

Confirms the code if "Never".  Mutations: delete P0's smp_wmb() (A1m-nowmb),
delete the smp_mb() between the two passes (A1m-nomb-in-sum), swap the passes
(A1m-gets-first): each must be "Sometimes", and is.
MNT-A0 is P0 without the mntget() and `exists (0:r0=1 /\ 1:r1=0)`: "Sometimes"
is correct and is the reason the peek has a grace-period branch.

### (a2) the fallback: a put the peek missed is seen after the grace period

```
C MNT-A2-gp-fallback-sees-fastpath-put

(*
 * Expected: Never.  When the peek finds a count other than one,
 * mntput_unmounted() does synchronize_rcu_expedited() and a plain
 * mntput(); its slow path under mount_lock must then see the put of
 * every holder that took the fast path, because that holder read
 * ->mnt_ns non-NULL inside rcu_read_lock() before the store of NULL,
 * so its read-side critical section ends before the grace period does.
 *)

{
	mnt_ns=1;
	gets_h=1;
	puts_h=0;
	gets_u=1;
	puts_u=0;
}

P0(int *mnt_ns, int *gets_h, int *puts_h)
{
	int r0;

	rcu_read_lock();
	r0 = READ_ONCE(*mnt_ns);
	if (r0) {
		smp_wmb();
		WRITE_ONCE(*puts_h, 1);
	}
	rcu_read_unlock();
}

P1(spinlock_t *mlock, int *seq, int *mnt_ns, int *gets_h, int *puts_h, int *gets_u, int *puts_u)
{
	int r1;
	int r3;
	int r5;
	int r6;

	spin_lock(mlock);
	WRITE_ONCE(*seq, 1);
	smp_wmb();
	WRITE_ONCE(*mnt_ns, 0);
	smp_wmb();
	WRITE_ONCE(*seq, 2);
	spin_unlock(mlock);

	spin_lock(mlock);
	WRITE_ONCE(*seq, 3);
	smp_wmb();
	smp_mb();
	r1 = READ_ONCE(*puts_h);
	smp_mb();
	r3 = READ_ONCE(*gets_h);
	smp_wmb();
	WRITE_ONCE(*seq, 4);
	spin_unlock(mlock);

	synchronize_rcu_expedited();

	spin_lock(mlock);
	WRITE_ONCE(*seq, 5);
	smp_wmb();
	smp_mb();
	WRITE_ONCE(*puts_u, 1);
	r5 = READ_ONCE(*puts_h);
	smp_mb();
	r6 = READ_ONCE(*gets_h);
	smp_wmb();
	WRITE_ONCE(*seq, 6);
	spin_unlock(mlock);
}

exists (0:r0=1 /\ 1:r5=0)
```

Confirms the code if "Never".  Mutation A2m-nogp replaces the grace period by
smp_mb(): "Sometimes", showing the GP rather than any barrier carries this.
(The herd7 run does not branch on r1; the property is simply that r5=0 is
impossible once the holder was on the fast path.)

### (b) walker increment vs. the peek, with seqcount and MNT_DOOMED

```
C MNT-B1-walker-inc-vs-peek

(*
 * Expected: Never.  __legitimize_mnt() increments, smp_mb(), re-reads
 * the seqcount; the peek bumps the seqcount under mount_lock, smp_mb(),
 * sums.  Store buffering: not both the walker seeing the old seqcount
 * (it keeps the reference) and the peek missing the increment (it
 * finishes the mount off).
 *
 * P0: rcu-walk: read_seqbegin(), __legitimize_mnt().  Only r0=0 is of
 *     interest (the walk started before the unmount).
 * P1: umount_tree() with MNT_SYNC_UMOUNT (flags=1) under write_seqlock(),
 *     then mntput_unmounted(): count == 1 iff the walker's increment is
 *     unseen, or seen together with its decrement -> MNT_DOOMED (flags=3)
 *     and freed=1.
 *)

{
	mnt_ns=1;
	gets_w=0;
	puts_w=0;
	gets_u=1;
	puts_u=0;
	flags=0;
	seq=0;
	freed=0;
}

P0(spinlock_t *mlock, int *seq, int *gets_w, int *puts_w, int *flags)
{
	int r0;
	int r1;
	int r2;
	int r3;

	r0 = READ_ONCE(*seq);
	smp_rmb();
	smp_rmb();
	r1 = READ_ONCE(*seq);
	if (r1 == 0) {
		WRITE_ONCE(*gets_w, 1);
		smp_mb();
		smp_rmb();
		r2 = READ_ONCE(*seq);
		if (r2 != 0) {
			spin_lock(mlock);
			r3 = READ_ONCE(*flags);
			if (r3 != 0) {
				WRITE_ONCE(*puts_w, 1);
			}
			spin_unlock(mlock);
		}
	}
}

P1(spinlock_t *mlock, int *seq, int *mnt_ns, int *flags, int *gets_w, int *puts_w, int *gets_u, int *puts_u, int *freed)
{
	int r1;
	int r2;
	int r3;
	int r4;

	spin_lock(mlock);
	WRITE_ONCE(*seq, 1);
	smp_wmb();
	WRITE_ONCE(*mnt_ns, 0);
	WRITE_ONCE(*flags, 1);
	smp_wmb();
	WRITE_ONCE(*seq, 2);
	spin_unlock(mlock);

	spin_lock(mlock);
	WRITE_ONCE(*seq, 3);
	smp_wmb();
	smp_mb();
	r1 = READ_ONCE(*puts_w);
	r2 = READ_ONCE(*puts_u);
	smp_mb();
	r3 = READ_ONCE(*gets_w);
	r4 = READ_ONCE(*gets_u);
	if (r3 == 0) {
		WRITE_ONCE(*flags, 3);
		WRITE_ONCE(*freed, 1);
	}
	if (r3 == 1) {
		if (r1 == 1) {
			WRITE_ONCE(*flags, 3);
			WRITE_ONCE(*freed, 1);
		}
	}
	smp_wmb();
	WRITE_ONCE(*seq, 4);
	spin_unlock(mlock);
}

filter (0:r0=0)
exists (0:r1=0 /\ 0:r2=0 /\ freed=1)
```

Confirms the code if "Never" (the walker legitimized and the mount was
finished off cannot both happen).  Mutation B1m-walker-nomb deletes the
walker's smp_mb(): "Sometimes".  B1m-peek-no-outer-mb deletes the explicit
smp_mb() of mntput_unmounted(): still "Never" (see the table; informational).
MNT-B2-walker-bail-sees-doomed-lazy is B1 without the flags=1 store (lazy
unmount) and `exists (0:r1=0 /\ ~(0:r2=0) /\ 0:r3=0 /\ freed=1)`: a walker that
bailed on the seqcount must find MNT_DOOMED under mount_lock if the peek
finished the mount off: "Never"; B2m-walker-flags-unlocked reads flags without
the lock: "Sometimes".

### (c) kern_unmount_array(): plain store, no seqcount bump

C1/C2 are A1/A2 with P1's first critical section replaced by a bare
`WRITE_ONCE(*mnt_ns, 0);` (mnt_make_shortterm()).  Both "Never": the holder
side never looks at the seqcount, so the lock/seqcount around the NULL store
buys the walkers something, not the holders.  Premise the test takes for
granted: such mounts have no rcu-walk walkers (not checked here).

### (d) the Dekker alternative

```
C MNT-D1-dekker-fastpath-recheck

(*
 * Expected: Never.  The alternative without any grace period: the fast
 * path puts, smp_mb(), re-reads ->mnt_ns and falls back to mount_lock if
 * it is NULL; the unmounter stores NULL, smp_mb() (under mount_lock),
 * sums.  Store buffering: not both the holder staying on the fast path
 * (both reads non-NULL) and the peek missing the put.  What the holder's
 * slow path then does (it has already put) is protocol design, not
 * memory ordering: model it in TLA+.
 *)

{
	mnt_ns=1;
	gets_h=1;
	puts_h=0;
	gets_u=1;
	puts_u=0;
}

P0(int *mnt_ns, int *gets_h, int *puts_h)
{
	int r0;
	int r1;

	rcu_read_lock();
	r0 = READ_ONCE(*mnt_ns);
	if (r0) {
		smp_wmb();
		WRITE_ONCE(*puts_h, 1);
		smp_mb();
		r1 = READ_ONCE(*mnt_ns);
	}
	rcu_read_unlock();
}

P1(spinlock_t *mlock, int *seq, int *mnt_ns, int *gets_h, int *puts_h, int *gets_u, int *puts_u)
{
	int r1;
	int r2;
	int r3;
	int r4;

	spin_lock(mlock);
	WRITE_ONCE(*seq, 1);
	smp_wmb();
	WRITE_ONCE(*mnt_ns, 0);
	smp_wmb();
	WRITE_ONCE(*seq, 2);
	spin_unlock(mlock);

	spin_lock(mlock);
	WRITE_ONCE(*seq, 3);
	smp_wmb();
	smp_mb();
	r1 = READ_ONCE(*puts_h);
	r2 = READ_ONCE(*puts_u);
	smp_mb();
	r3 = READ_ONCE(*gets_h);
	r4 = READ_ONCE(*gets_u);
	smp_wmb();
	WRITE_ONCE(*seq, 4);
	spin_unlock(mlock);
}

exists (0:r0=1 /\ 0:r1=1 /\ 1:r1=0)
```

"Never" means the Dekker shape is sound as far as ordering goes; D1m with
smp_wmb() instead of smp_mb() on the holder: "Sometimes".  The hard part of
the Dekker variant (the holder has already decremented when it enters the
slow path; double finish-off vs. MNT_DOOMED; walkers) is protocol, i.e. TLA+.

### What TLA+ did or could not catch, per mutation

| mutation | TLA+ | note |
|----------|------|------|
| A1m-nowmb | catches (WEAK_STORES, FIX_PUT_WMB off) | store-store reordering is what WEAK_STORES models |
| A1m-gets-first | catches (SPLIT_GETS_FIRST) | |
| A1m-nomb-in-sum | **cannot** | TLA+ executes loads in order against visible memory; its README says the smp_mb() "orders two loads, which TSO does anyway, so it has no step here" -- true for TSO, false for arm64/POWER, and herd7 shows it is load-bearing there |
| A2m-nogp | catches (FIX_RCU_DELAY off) | SC-level |
| B1m-walker-nomb | catches (mntput_ondemand_no_mb_legit) | store-load, TSO-visible |
| B2m-walker-flags-unlocked | partially (FIX_DOOMED_FLAG) | TLA+ has the flag but the lock-ordering of the flag read is implicit |
| D1m | catches | store-load, TSO-visible |

## 4. Tool survey (status as of 2026-10)

### herd7 + tools/memory-model (LKMM)
- Status: herdtools7 7.58 (opam release 2025-02-13; Debian package 7.58-2).
  The kernel README requires >= 7.58, matching.  The herdtools7 GitHub
  releases page nowadays lists Arm model snapshots (ArmARM-M.a..M.d, ASLRef)
  rather than numbered versions; numbered versions are on opam.
  https://github.com/herd/herdtools7, https://opam.ocaml.org/packages/herdtools7/
- Input: C-flavoured litmus tests, see section 2.  The worktree's
  tools/memory-model is complete (bell/cat/def/cfg, lock.cat, litmus-tests/,
  Documentation/, scripts/checkalllitmus.sh etc.).
- Scale: exponential; 2-3 process tests here take < 0.5 s; 10-process RCU tests
  take seconds, 16-process tests minutes (litmus-tests.txt "Performance";
  `-speedcheck true` helps).
- Limits for this code: no this_cpu ops, no loops (unroll the CPU sum), no
  seqlock primitive (model it), no call_rcu() (emulate), compiler not
  modelled, data-race flag only if you use plain accesses.
- Install: already on the laptop (/usr/bin/herd7); jens root-less in 1 min
  (section 5).  opam route if ever needed: `opam init` + switch (builds OCaml)
  + `opam install herdtools7` is 15-25 min; deps ocaml >= 4.08, dune >= 2.7,
  menhir, zarith >= 1.13.  Not needed.

### klitmus7
- Same package.  Converts a litmus test into a kernel module that spawns
  kthreads bound to CPUs (kthread_create/kthread_bind, proc_create_single,
  module_param, wait_event_interruptible; the only version guard in the
  generated code is LINUX_VERSION_CODE >= 4.18).  README compat table ends at
  "5.17 -- : 7.56.1 --"; the last known breakage was do_exit() unexport in
  5.17 (https://github.com/herd/herdtools7/issues/372).  Whether 7.58 output
  builds against a 7.x kernel is unverified; the API surface it uses is small
  and stable, so I expect it to.
- Refuses synchronize_rcu()/synchronize_rcu_expedited(): "Test not compiled"
  (verified with A2 and a minimal RCU test).  rcu_read_lock/unlock, spinlocks,
  all fences are fine.  So only the barrier tests are hardware-runnable.
- Build/run: `mkdir mod && klitmus7 -o mod a.litmus b.litmus && make -C mod`
  (Makefile uses /lib/modules/$(uname -r)/build; on jens that directory is not
  readable for the user, so point M= at your own VM kernel's build tree), then
  `sh run.sh` as root inside the VM; results go to /proc/litmus and the script
  prints herd-style Positive/Negative counts.
- Hardware: jens is x86-64 (2x EPYC 9754, 512 threads) -> x86-TSO only (see
  recommendation 3).  No arm64 hardware anywhere here; qemu TCG does not
  reproduce arm64 reorderings.  Arm's own guidance on hardware litmus runs:
  https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/running-litmus-tests-on-hardware-litmus7

### Dartagnan (Dat3M)
- https://github.com/hernanponcedeleon/Dat3M -- active (~5k commits); latest
  release 4.4.1 on 2026-05-22 with no binary assets (checked with gh), so build
  with Maven (Java 17+, Maven 3.8+; GraalVM 22+ optional for a native image)
  or `docker build . -t dartagnan`.  Neither mvn nor docker locally or on
  jens; jens has Java 25 and podman (rootless), so the Dockerfile route is the
  practical one (~15-30 min including the Maven dependency download).
- Input: `.c` (compiled through clang to LLVM IR; `DAT3M_COMPILER_OPTIONS`),
  `.ll`, `.litmus` (LKMM C litmus accepted directly, target taken from the
  header) and `.spvasm`.  `dartagnan <cat> --target=lkmm prog.c --bound=N
  --property=program_spec|termination|cat_spec --method=lazy|eager`.
  cat/linux-kernel.cat carries the RCU/SRCU/lock.cat/data-race sections.
  include/lkmm.h gives READ_ONCE/WRITE_ONCE, smp_mb/wmb/rmb, acquire/release,
  spin_lock/unlock, atomics, xchg/cmpxchg; include/rcu.h gives
  rcu_read_lock()/rcu_read_unlock()/synchronize_rcu() as
  __LKMM_FENCE(rcu_lock|rcu_unlock|rcu_sync) (or a reference implementation
  under RCU_IMP).  No this_cpu ops: model per-CPU counters as arrays.
  benchmarks/lkmm/ holds qspinlock.c, qspinlock-fixed.c, qspinlock-liveness.c,
  rcu*.c and C translations of LKMM litmus tests.
- Harness sketch: pthreads; H holders doing a bounded number of
  mntget()/fast-path mntput() pairs on their own counter slots (migration =
  switching slot index after a full barrier), W walkers doing the
  __legitimize_mnt() sequence with the modelled seqcount, one unmounter doing
  umount_tree() + mntput_unmounted() with the two-branch decision; assert no
  finish-off while a holder's or legitimized walker's reference is live, and
  at the end exactly one finish-off and sum == 0.  Run under
  `--target=lkmm`, then under arm8 and power with Dartagnan's compilation
  schemes (how the CNA paper did qspinlock).
- Limits: bounded unrolling and thread count; the LKMM it ships may lag the
  kernel's (4.3.0 notes "updating LKMM to latest version"; diff against
  tools/memory-model before trusting); LKMM-only counterexamples need triage.
- Track record: "BMC for Weak Memory Models: Relation Analysis for Compact SMT
  Encodings" (CAV 2019) https://hernanponcedeleon.github.io/pdfs/cav2019.pdf;
  SV-COMP contribution (TACAS 2020)
  https://link.springer.com/chapter/10.1007/978-3-030-45237-7_24; "Verifying
  and Optimizing Compact NUMA-Aware Locks on Weak Memory Models"
  https://arxiv.org/abs/2111.15240 found that under LKMM qspinlock "guarantees
  neither mutual exclusion nor await termination, and it contains a data
  race", while being correct under ARMv8/Power -- discussed on LKML
  (https://lkml.org/lkml/2022/9/12/408, https://lkml.org/lkml/2022/8/26/857);
  the lesson for us is that an LKMM "Sometimes" may be unobservable on
  hardware but still counts upstream.

### GenMC
- https://github.com/MPI-SWS/genmc; CHANGELOG: "[0.6] 2021.05.30 Support for
  LKMM (experimental)", "[0.10.0] 2023.10.25 ... Removed Support for LKMM,
  Persevere"; current 0.19.0 (2026-09-24) supports SC, TSO, RA, RC11, IMM;
  LLVM 19-22.  The project page still advertises LKMM but the code does not
  have it.  Not usable for this; a C11-atomics translation under IMM would not
  be the kernel's model (no smp_wmb/rmb analogue, no RCU).

### Nidhugg, CDSChecker, CBMC, others
- Nidhugg https://github.com/nidhugg/nidhugg: SC/TSO/PSO, POWER and ARMv7
  partial and only with LLVM < 15, v0.3.1 the last with those; no LKMM, no
  RCU.  Was used for Tree RCU (Kokologiannakis & Sagonas, SPIN 2017,
  https://dl.acm.org/doi/10.1145/3092282.3092287) under SC.
- CDSChecker https://github.com/computersforpeace/model-checker: C11/C++11
  atomics only, last substantive work ~2015.
- CBMC: weak-memory modes exist (`--mm tso|pso|rmo|power`, from Alglave/
  Kroening/Tautschnig's partial-order encoding) but no LKMM; the Tree RCU
  verification (Liang, McKenney, Kroening, Melham, DATE 2018,
  https://arxiv.org/abs/1610.03052) ran under SC with hand-modelled RCU.
- VSync / vsyncer (Huawei open-s4c, https://github.com/open-s4c; ASPLOS 2021
  https://dl.acm.org/doi/10.1145/3445814.3446748): drives Dartagnan/GenMC to
  find minimal barrier sets; LKMM only via Dartagnan.  Not needed on top of
  Dartagnan itself.
- Isla/isla-axiomatic and herd7's aarch64.cat: ISA-level checking of
  assembly litmus tests under Arm's official model (recommendation 2); no C
  front-end for hardware models.

## 5. Install/run recipes

Local (laptop, Debian forky): herd7/klitmus7/litmus7 7.58 at /usr/bin.
```
cd ~/src/git/linux/vfs/work.mount.gp_on_demand.proposal/tools/memory-model
herd7 -conf linux-kernel.cfg <scratchpad>/litmus/MNT-A1-holder-get-before-put.litmus
for t in <scratchpad>/litmus/MNT-*.litmus; do herd7 -conf linux-kernel.cfg $t | grep ^Observation; done
```

jens (Debian forky/sid, no root, no opam/ocaml): done, root-less, ~1 min.
```
mkdir -p ~/tmp/herdtools7-deb ~/.local/herdtools7
cd ~/tmp/herdtools7-deb && apt-get download herdtools7     # 38.9 MB, no root
dpkg -x herdtools7_7.58-2_amd64.deb ~/.local/herdtools7
H=~/.local/herdtools7/usr/bin/herd7
L=~/.local/herdtools7/usr/share/herdtools7/herd             # -set-libdir is mandatory here
cd ~/tmp/lkmm/memory-model                                   # copy of the worktree's tools/memory-model
$H -set-libdir $L -conf linux-kernel.cfg ~/tmp/lkmm/litmus/MNT-A1-holder-get-before-put.litmus
# klitmus7 needs the litmus libdir instead:
~/.local/herdtools7/usr/bin/klitmus7 -set-libdir ~/.local/herdtools7/usr/share/herdtools7/litmus \
    -o ~/tmp/lkmm/kmod ~/tmp/lkmm/litmus/MNT-A1-holder-get-before-put.litmus ~/tmp/lkmm/litmus/MNT-B1-walker-inc-vs-peek.litmus
make -C <your VM kernel build tree> M=~/tmp/lkmm/kmod modules   # then insmod/run.sh as root in the VM
```
Only libgmp.so.10 is needed at runtime (present).  Without `-set-libdir`
herd7 dies with "Fatal error: exception Misc.Exit" (it looks for
/usr/share/herdtools7/herd).  State left on jens: ~/.local/herdtools7,
~/tmp/herdtools7-deb (the .deb), ~/tmp/lkmm/{memory-model,litmus,kmod}.
The full 16-test suite ran there with results identical to the laptop.

Dartagnan on jens (not done): `git clone https://github.com/hernanponcedeleon/Dat3M
&& cd Dat3M && podman build . -t dartagnan && podman run -v $PWD:/work -it dartagnan`;
inside: `java -jar dartagnan/target/dartagnan.jar cat/linux-kernel.cat --target=lkmm
/work/<file>.litmus` for the same litmus tests, `--bound=2 --property=program_spec,cat_spec`
for a C harness compiled with `-I include` (lkmm.h, rcu.h).  Local clang 23's
IR may be newer than what the 4.4.1 parser expects; master or the image's
own clang avoids that.

## 6. Caveats, per tool

- herd7/LKMM: proves ordering under the *model*, not on silicon or through a
  compiler; no loops, so the per-CPU sum is unrolled to two CPUs (fine for
  the pairwise claims, not for integer arithmetic of many holders, which is
  TLA+'s job); seqlock and this_cpu ops are hand-modelled (section 2); marked
  accesses hide data-race questions; 2-6 processes is the practical ceiling.
  A mismatch between herd7 version and the model is possible in the future
  (README warns); 7.58 + this tree is consistent today.
- klitmus7: no synchronize_rcu*() in tests; x86 can only witness SB-shaped
  reorderings; module ABI compatibility with 7.x untested; needs root in the
  VM; a "Never" on hardware is statistical, not a proof.
- Dartagnan: bounded; its LKMM copy may lag; RCU via fences in its own
  header; counterexamples under LKMM may be hardware-unobservable; build
  effort.
- TLA+ (for contrast): operational store buffers, loads never reordered, RCU
  and seqlock as abstractions; what it does well is the integer protocol over
  many holders/walkers/migrations, which none of the above do.

## 7. Prior art

- LKMM: Alglave, Maranget, McKenney, Parri, Stern, "Frightening small children
  and disconcerting grown-ups: Concurrency in the Linux kernel", ASPLOS 2018,
  DOI 10.1145/3173162.3177156, open access https://discovery.ucl.ac.uk/10070727/,
  slides http://www2.rdrop.com/~paulmck/scalability/paper/slides-asplos18.pdf;
  tools/memory-model/Documentation/{explanation,litmus-tests,recipes,locking}.txt
  in the worktree; thousands of generated RCU litmus tests at
  https://github.com/paulmckrcu/litmus; LPC 2025 BoF "Installing and Using
  the LKMM" (Feng, Fernandes, McKenney) https://lpc.events/event/19/contributions/2292/.
- In-kernel precedent for litmus-testing a per-CPU counter scan against
  readers: the SRCU fastpath tests (Kunwu Chan, Sept 2026, moved to
  Documentation/litmus-tests/srcu/ at Paul McKenney's suggestion; a Never/
  Sometimes pair for anchor-before-scan vs. scan-before-anchor)
  https://ratatoskr.run/linux-doc/2026/09/17556771/t; and the comments around
  srcu_readers_active_idx_check() in kernel/rcu/srcutree.c, the origin of the
  "sum unlocks before locks with smp_mb() in between" idiom this series
  borrows.  Documentation/RCU/rcuref.rst and lib/percpu-refcount.c are the
  kernel's own RCU+refcount designs (percpu-ref never elides the grace period;
  it switches to atomic mode after one).
- RCU implementation verification: Liang/McKenney/Kroening/Melham (CBMC, DATE
  2018) https://arxiv.org/abs/1610.03052; Kokologiannakis/Sagonas (Nidhugg,
  SPIN 2017); McKenney's Promela/SPIN models in perfbook's formal verification
  chapter https://mirrors.edge.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html.
- RCU/refcount "last reference" under weak memory, deductive: Tassarotti,
  Dreyer, Vafeiadis, "Verifying Read-Copy-Update in a Logic for Weak Memory",
  PLDI 2015 https://people.mpi-sws.org/~dreyer/papers/rcu/paper.pdf; "Modular
  Verification of Safe Memory Reclamation in Concurrent Separation Logic",
  OOPSLA 2023 https://iris-project.org/pdfs/2023-oopsla-reclamation.pdf;
  "Verifying General-Purpose RCU for Reclamation in Relaxed Memory", PLDI 2025
  https://iris-project.org/pdfs/2025-pldi-weak-smr.pdf.
- Kernel locks under LKMM with Dartagnan: CNA/qspinlock paper and LKML thread
  cited in section 4; VSync (ASPLOS 2021).
- Tool pages: herdtools7 https://github.com/herd/herdtools7; Dat3M
  https://github.com/hernanponcedeleon/Dat3M; GenMC
  https://github.com/MPI-SWS/genmc (CHANGELOG.md for the LKMM removal), project
  page https://plv.mpi-sws.org/genmc/, CAV 2021 paper
  https://plv.mpi-sws.org/genmc/cav21-paper.pdf; Nidhugg
  https://github.com/nidhugg/nidhugg; CDSChecker
  https://github.com/computersforpeace/model-checker.

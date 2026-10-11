/*
 * mnt_gp.c - Dartagnan (Dat3M) harness for the gp-on-demand mount
 * reference-counting protocol of fs/namespace.c at 4379d47fd314:
 * mnt_get_count(), mntput_no_expire() (+ slow path), __legitimize_mnt(),
 * mntput_unheld()/mntput_unmounted(), umount_tree(), mnt_make_shortterm().
 *
 * One struct mount, NR_CPUS per-CPU counter slots, mount_lock = spinlock +
 * seqcount modelled exactly like the herd7 litmus tests MNT-*.litmus:
 *   write_seqlock   = spin_lock(); seq++ ; smp_wmb();
 *   write_sequnlock = smp_wmb(); seq++; spin_unlock();
 *   read_seqbegin   = READ_ONCE(seq); smp_rmb();
 *   read_seqretry   = smp_rmb(); READ_ONCE(seq) != start
 * Per-CPU counters: one slot per thread (LKMM has no CPUs; a thread's own
 * fences order its get and put wherever it "runs"); this_cpu_inc() is a
 * READ_ONCE + WRITE_ONCE on the own slot (an unlocked RMW, the weakest
 * faithful model: x86 incl %gs:, arm64 relaxed LSE/LL-SC).
 *
 * Scenarios (exactly one -DSCEN_*), mirroring the litmus exists clauses:
 *   SCEN_A0    peek can miss a fast-path put (expected FAIL: documents why
 *              the grace-period branch exists; allowed even under SC)
 *   SCEN_A1    holder with a long-lived ref does mntget()+fast mntput();
 *              never finished at count 1 while its ref is counted
 *   SCEN_A1MIG A1 with the put on another CPU's slot (migration), NR_CPUS=3
 *   SCEN_A2    holder drops its ref on the fast path; the GP fallback's
 *              slow put must see that put (never a leak)
 *   SCEN_B1    sync umount vs walker: never "walker legitimized" and
 *              "peek finished the mount"
 *   SCEN_B2    lazy umount: a walker that bailed on the seqcount and takes
 *              mount_lock must see MNT_DOOMED if the peek finished the mount
 *   SCEN_C1    A1 with kern_unmount_array()'s bare WRITE_ONCE(mnt_ns, NULL)
 *   SCEN_C2    A2 likewise
 *   SCEN_D1    EXPLORATORY Dekker alternative: fast path puts, smp_mb(),
 *              re-reads mnt_ns; no grace period at all; never "holder stays
 *              on the fast path" and "peek missed the put"
 * Mutations (must produce FAIL where the barrier is load-bearing):
 *   MUT_NOWMB          drop the holder's smp_wmb() before the put
 *   MUT_NOMB_IN_SUM    drop the smp_mb() between the puts and gets passes
 *   MUT_GETS_FIRST     sum gets before puts
 *   MUT_NOGP           synchronize_rcu_expedited() -> smp_mb()
 *   MUT_WALKER_NOMB    drop __legitimize_mnt()'s smp_mb()
 *   MUT_FLAGS_UNLOCKED walker reads mnt_flags without mount_lock
 *   MUT_DEKKER_WMB     D1 with smp_wmb() instead of smp_mb() on the holder
 *   MUT_PEEK_NO_OUTER_MB drop mntput_unmounted()'s explicit smp_mb()
 *                      (informational: expected to still PASS)
 * Targets:
 *   TARGET_LKMM (default) lkmm.h + rcu.h, run with --target=lkmm
 *   TARGET_LKMM_HW        lkmm.h, RCU read-side fences dropped (nothing on
 *                         hardware), synchronize_rcu*() not expressible:
 *                         GP_AS_MB (exploratory, equals MUT_NOGP) or
 *                         GP_AS_NOP (where the assertion does not depend on
 *                         the grace period: A1, B1, B2, C1); --target=arm8/power
 *   TARGET_C11            __atomic builtins for --target=tso: READ_ONCE/
 *                         WRITE_ONCE relaxed, smp_mb() seq_cst fence
 *                         (mfence), smp_rmb/wmb nothing (compiler barriers
 *                         on x86), spin_lock() = locked xchg assumed to
 *                         read 0, spin_unlock() release store (plain mov).
 *                         With C11_HW_FENCES (for --target=power/arm8):
 *                         smp_rmb()/smp_wmb() become acquire/release fences,
 *                         i.e. lwsync on POWER (the kernel mapping; the
 *                         lkmm.h route maps them to a full sync there)
 */
#include <pthread.h>
#include <assert.h>
#include <dat3m.h>

#ifndef NR_CPUS
#define NR_CPUS 2
#endif
#define HCPU 0			/* holder runs on CPU 0 */
#define UCPU 1			/* unmounter on CPU 1, the mount's own reference lives here */
#ifndef WCPU
#define WCPU 0			/* walker on CPU 0 (no holder in the B scenarios) */
#endif
#ifndef HPUTCPU
#define HPUTCPU HCPU		/* A1MIG: put goes to another CPU's slot */
#endif

#if defined(TARGET_C11)
#define READ_ONCE(x)		__atomic_load_n(&(x), __ATOMIC_RELAXED)
#define WRITE_ONCE(x, v)	__atomic_store_n(&(x), (v), __ATOMIC_RELAXED)
#define smp_mb()		__atomic_thread_fence(__ATOMIC_SEQ_CST)
#ifdef C11_HW_FENCES
/* arm8/power via C11: acquire fence = dmb ishld / lwsync, release fence = dmb ish / lwsync */
#define smp_rmb()		__atomic_thread_fence(__ATOMIC_ACQUIRE)
#define smp_wmb()		__atomic_thread_fence(__ATOMIC_RELEASE)
#else
#define smp_rmb()		do { } while (0)
#define smp_wmb()		do { } while (0)
#endif
typedef struct { int v; } spinlock_t;
/*
 * Lock acquisition is assumed to succeed (the xchg reads 0), exactly what
 * Dartagnan's own lowering does for LKMM spin_lock() on arm8/power: every
 * lock order is still explored, only liveness (spinning) is not modelled.
 * On x86 the locked xchg is a full barrier, the release store a plain mov.
 */
static void spin_lock(spinlock_t *l)
{
	int old = __atomic_exchange_n(&l->v, 1, __ATOMIC_ACQUIRE);

	__VERIFIER_assume(old == 0);
}
static void spin_unlock(spinlock_t *l)
{
	__atomic_store_n(&l->v, 0, __ATOMIC_RELEASE);
}
#define rcu_read_lock()		do { } while (0)
#define rcu_read_unlock()	do { } while (0)
#define HAVE_GP 0
#else
#include <lkmm.h>
#if defined(TARGET_LKMM_HW)
#define rcu_read_lock()		do { } while (0)
#define rcu_read_unlock()	do { } while (0)
#define HAVE_GP 0
#else
#include <rcu.h>
#define HAVE_GP 1
#endif
#endif

#if HAVE_GP && !defined(MUT_NOGP)
#define synchronize_rcu_expedited()	synchronize_rcu()
#elif defined(MUT_NOGP) || defined(GP_AS_MB)
#define synchronize_rcu_expedited()	smp_mb()	/* NOT a grace period */
#elif defined(GP_AS_NOP)
/* only for scenarios whose assertion does not depend on the grace period */
#define synchronize_rcu_expedited()	do { } while (0)
#else
#error "no grace period on this target: -DGP_AS_MB (exploratory, = MUT_NOGP) or -DGP_AS_NOP"
#endif

#define MNT_SYNC_UMOUNT	1
#define MNT_DOOMED	2

enum { PUT_NONE, PUT_FAST, PUT_SLOW_HELD, PUT_SLOW_DOOMED, PUT_SLOW_FINAL };

struct mount {
	int gets[NR_CPUS];
	int puts[NR_CPUS];
	int mnt_ns;		/* 1: attached, 0: NULL */
	int flags;
	int freed;		/* times mntput_final_locked() ran */
};

static struct mount mnt;
static spinlock_t mount_lock;	/* spinlock component of the seqlock */
static int mount_seq;		/* seqcount component */

/* what each thread saw, read in main() after the joins */
static int h_path, h_ns2, h_slow_count;
static int u_peek_count, u_peek_finished, u_took_fallback, u_slow_path, u_slow_count;
static int w_res, w_r1, w_r2, w_flags;

/* seqlock */
static void lock_mount_hash(void)
{
	spin_lock(&mount_lock);
	WRITE_ONCE(mount_seq, READ_ONCE(mount_seq) + 1);
	smp_wmb();
}

static void unlock_mount_hash(void)
{
	smp_wmb();
	WRITE_ONCE(mount_seq, READ_ONCE(mount_seq) + 1);
	spin_unlock(&mount_lock);
}

static int read_seqbegin(void)
{
	int s = READ_ONCE(mount_seq);
	smp_rmb();
	return s;
}

static int read_seqretry(int start)
{
	smp_rmb();
	return READ_ONCE(mount_seq) != start;
}

/* per-CPU counters */
static void mnt_inc_count(struct mount *m, int cpu)
{
	WRITE_ONCE(m->gets[cpu], READ_ONCE(m->gets[cpu]) + 1);
}

static void mnt_dec_count(struct mount *m, int cpu)
{
	WRITE_ONCE(m->puts[cpu], READ_ONCE(m->puts[cpu]) + 1);
}

static int sum_slots(const int *a)
{
	int s = READ_ONCE(a[0]) + READ_ONCE(a[1]);
#if NR_CPUS > 2
	s += READ_ONCE(a[2]);
#endif
	return s;
}

/* mount_lock must be held for write */
static int mnt_get_count(struct mount *m)
{
	int gets, puts;

#ifdef MUT_GETS_FIRST
	gets = sum_slots(m->gets);
	smp_mb();
	puts = sum_slots(m->puts);
#else
	puts = sum_slots(m->puts);
#ifndef MUT_NOMB_IN_SUM
	smp_mb();	/* pairs with the smp_wmb() in mntput_no_expire() */
#endif
	gets = sum_slots(m->gets);
#endif
	return gets - puts;
}

static void mntput_final_locked(struct mount *m)
{
	WRITE_ONCE(m->flags, READ_ONCE(m->flags) | MNT_DOOMED);
	WRITE_ONCE(m->freed, READ_ONCE(m->freed) + 1);
}

static int mntput_no_expire(struct mount *m, int cpu)
{
	int count;

	rcu_read_lock();
	if (READ_ONCE(m->mnt_ns)) {
#ifndef MUT_NOWMB
		smp_wmb();	/* pairs with the smp_mb() in mnt_get_count() */
#endif
		mnt_dec_count(m, cpu);
#ifdef SCEN_D1
#ifdef MUT_DEKKER_WMB
		smp_wmb();
#else
		smp_mb();
#endif
		h_ns2 = READ_ONCE(m->mnt_ns);
#endif
		rcu_read_unlock();
		return PUT_FAST;
	}
	/* mntput_no_expire_slowpath() */
	lock_mount_hash();
	smp_mb();
	mnt_dec_count(m, cpu);
	count = mnt_get_count(m);
	if (cpu == UCPU)
		u_slow_count = count;
	else
		h_slow_count = count;
	if (count != 0) {
		rcu_read_unlock();
		unlock_mount_hash();
		return PUT_SLOW_HELD;
	}
	if (READ_ONCE(m->flags) & MNT_DOOMED) {
		rcu_read_unlock();
		unlock_mount_hash();
		return PUT_SLOW_DOOMED;
	}
	mntput_final_locked(m);
	rcu_read_unlock();
	unlock_mount_hash();
	return PUT_SLOW_FINAL;
}

/* call under rcu_read_lock */
static int __legitimize_mnt(struct mount *m, int seq)
{
	int f;

	if (read_seqretry(seq)) {
		w_r1 = 1;
		return 1;
	}
	mnt_inc_count(m, WCPU);
#ifndef MUT_WALKER_NOMB
	smp_mb();	/* see mntput_no_expire_slowpath(), mntput_unheld() */
#endif
	if (!read_seqretry(seq))
		return 0;
	w_r2 = 1;
#ifdef MUT_FLAGS_UNLOCKED
	f = READ_ONCE(m->flags);
	w_flags = f;
	if (f & (MNT_SYNC_UMOUNT | MNT_DOOMED)) {
		mnt_dec_count(m, WCPU);
		return 1;
	}
	return -1;
#else
	lock_mount_hash();
	f = READ_ONCE(m->flags);
	w_flags = f;
	if (f & (MNT_SYNC_UMOUNT | MNT_DOOMED)) {
		mnt_dec_count(m, WCPU);
		unlock_mount_hash();
		return 1;
	}
	unlock_mount_hash();
	return -1;	/* caller will mntput() */
#endif
}

/* called under mount_lock */
static int mntput_unheld(struct mount *m)
{
	int count = mnt_get_count(m);

	u_peek_count = count;
	if (count != 1)
		return 0;
	mnt_dec_count(m, UCPU);
	mntput_final_locked(m);
	return 1;
}

static void mntput_unmounted(struct mount *m)
{
	int unheld;

	lock_mount_hash();
#ifndef MUT_PEEK_NO_OUTER_MB
	smp_mb();	/* see __legitimize_mnt() and mntput_no_expire() */
#endif
	unheld = mntput_unheld(m);
	unlock_mount_hash();
	if (unheld) {
		u_peek_finished = 1;
		return;
	}
	u_took_fallback = 1;
	synchronize_rcu_expedited();
	u_slow_path = mntput_no_expire(m, UCPU);
}

static void umount_tree(struct mount *m, int sync)
{
	lock_mount_hash();
	WRITE_ONCE(m->mnt_ns, 0);
	if (sync)
		WRITE_ONCE(m->flags, READ_ONCE(m->flags) | MNT_SYNC_UMOUNT);
	unlock_mount_hash();
}

static void mnt_make_shortterm(struct mount *m)
{
	WRITE_ONCE(m->mnt_ns, 0);
}

/* the Dekker variant's unmounter: no grace period, the peek only */
static void dekker_peek(struct mount *m)
{
	lock_mount_hash();
	smp_mb();
	u_peek_count = mnt_get_count(m);
	unlock_mount_hash();
}

/* threads */
static void *holder(void *arg)
{
#if defined(SCEN_A1) || defined(SCEN_A1MIG) || defined(SCEN_C1)
	mnt_inc_count(&mnt, HCPU);	/* transient mntget(): the long-lived ref stays */
#endif
	h_path = mntput_no_expire(&mnt, HPUTCPU);
	return NULL;
}

static void *walker(void *arg)
{
	int s;

	rcu_read_lock();
	s = read_seqbegin();
	__VERIFIER_assume(s == 0);	/* the walk started before the unmount (litmus: filter 0:r0=0) */
	w_res = __legitimize_mnt(&mnt, s);
	rcu_read_unlock();
	return NULL;
}

static void *unmounter(void *arg)
{
#if defined(SCEN_C1) || defined(SCEN_C2)
	mnt_make_shortterm(&mnt);
#elif defined(SCEN_B1)
	umount_tree(&mnt, 1);
#else
	umount_tree(&mnt, 0);
#endif
#if defined(SCEN_D1)
	dekker_peek(&mnt);
#else
	mntput_unmounted(&mnt);
#endif
	return NULL;
}

int main(void)
{
	pthread_t t0, t1;

	mnt.mnt_ns = 1;
	mnt.gets[UCPU] = 1;		/* the mount's own reference */
#if defined(SCEN_B1) || defined(SCEN_B2)
	pthread_create(&t0, NULL, walker, NULL);
#else
	mnt.gets[HCPU] = 1;		/* the holder's reference */
	pthread_create(&t0, NULL, holder, NULL);
#endif
	pthread_create(&t1, NULL, unmounter, NULL);
	pthread_join(t0, NULL);
	pthread_join(t1, NULL);

#if defined(SCEN_A0)
	/* MNT-A0: exists (0:r0=1 /\ 1:r1=0): expected to FAIL, see above */
	assert(!(h_path == PUT_FAST && u_peek_count == 2));
#elif defined(SCEN_A1) || defined(SCEN_A1MIG) || defined(SCEN_C1)
	/* MNT-A1/C1: the holder never dropped its long-lived reference */
	assert(mnt.freed == 0);
#elif defined(SCEN_A2) || defined(SCEN_C2)
	/* MNT-A2/C2: exists (0:r0=1 /\ 1:r5=0): the slow put after the GP misses the fast-path put */
	assert(!(h_path == PUT_FAST && u_took_fallback && u_slow_count != 0));
#if HAVE_GP
	assert(mnt.freed == 1);		/* both references dropped: finished exactly once */
#endif
#elif defined(SCEN_B1)
	/* MNT-B1: exists (0:r1=0 /\ 0:r2=0 /\ freed=1) */
	assert(!(w_res == 0 && mnt.freed));
#elif defined(SCEN_B2)
	/* MNT-B2: exists (0:r1=0 /\ ~(0:r2=0) /\ 0:r3=0 /\ freed=1) */
	assert(!(w_r1 == 0 && w_r2 == 1 && w_flags == 0 && mnt.freed));
#elif defined(SCEN_D1)
	/* MNT-D1: exists (0:r0=1 /\ 0:r1=1 /\ 1:r1=0) */
	assert(!(h_path == PUT_FAST && h_ns2 == 1 && u_peek_count == 2));
#else
#error "select a scenario"
#endif
	return 0;
}

/*
 * mntput_harness.c -- CBMC harness for the grace-period-on-demand mntput()
 * protocol of fs/namespace.c, vfs/work.mount.gp_on_demand.proposal at
 * 4379d47fd314.
 *
 * Every function marked "COPIED" is a byte-for-byte copy of the kernel
 * function (diff it against fs/namespace.c), with these exceptions, each
 * marked in place:
 *   - the __percpu plumbing (this_cpu_inc(), per_cpu_ptr(),
 *     for_each_possible_cpu()) is replaced by an array indexed by a
 *     nondeterministic CPU per operation (see percpu_add()),
 *   - lines marked "ghost:" update or check the ghost state,
 *   - CBMC does not support __attribute__((cleanup)) (diffblue/cbmc#8676),
 *     so the `__free(mntput_no_expire)` of do_umount() is expanded by hand
 *     on every exit path (DROP_REF()),
 *   - functions marked "REDUCED" keep the kernel's control flow for the
 *     parts the protocol can see and drop the rest (propagation, covers,
 *     the namespace rbtree, notifications, dentries, superblocks).
 *
 * Threads: U (the umounter, the main thread), H (a holder of a counted
 * reference, an open file), W (an RCU path walker).  See README.md.
 *
 * CBMC's multi-threaded symex refuses ("pointer handling for concurrency is
 * unsound") any dereference of a pointer loaded from shared memory and any
 * write through a pointer with two candidate targets.  The kernel's intrusive
 * hlist/list code does exactly that, so the `unmounted`/`held` hlists are
 * modelled as fixed-position membership flags that keep the two-pass control
 * flow of mntput_unmounted() (every mount pointer stays a constant), and the
 * lists that the protocol never reads (mnt_mounts, mnt_child, mnt_expire,
 * mnt_covers, the superblock's mount list) are reduced to ghost counters or
 * dropped.  The real hlist code is therefore NOT verified by this harness.
 */
#include <stddef.h>
/*
 * Threads are spawned with CBMC's native __CPROVER_ASYNC_n labels: the
 * bundled pthread_create() model stores a pointer to shared memory, which
 * CBMC's threaded symex refuses (see below), and pthread_join() is modelled
 * by CBMC as an assumption on a "done" flag anyway.
 */

/*
 * CBMC refuses pointer-typed stores to shared memory in a threaded program
 * (goto_symex_state.cpp: "pointer handling for concurrency is unsound",
 * issue #305).  ->mnt_ns is therefore an integer id here (0 = NULL, see
 * NS_INIT/NS_INTERNAL) and ->mnt_parent an index; NULL is the integer 0 so
 * that the copied `WRITE_ONCE(mnt->mnt_ns, NULL)` stays verbatim.
 */
#undef NULL
#define NULL 0

#ifndef NCPU
#define NCPU 2
#endif
#ifndef BATCH
#define BATCH 1		/* mounts unmounted in one go: 1, or 2 */
#endif
#ifndef SHAPE
#define SHAPE 0		/* 0: do_umount(M, 0); 1: do_umount(M, MNT_DETACH); 2: kern_unmount_array() */
#endif
#ifndef HELD
#define HELD 0		/* the mount the holder H has a reference to */
#endif
#ifndef ORDER
#define ORDER 0		/* kern_unmount_array(): 0 = {M0, M1}, 1 = {M1, M0} */
#endif
#ifndef GETS
#define GETS 1		/* extra mntget()/mntput() pairs the holder may do (GetBudget) */
#endif
#ifndef WALKER
#define WALKER 1	/* 0 drops the walker thread */
#endif
#ifndef WALK
#define WALK HELD	/* the mount the walker looks up */
#endif
#ifndef HCPU
#define HCPU (NCPU - 1)	/* the holder's CPU (U runs on CPU 0) */
#endif
#ifndef WCPU
#define WCPU 0		/* the walker's CPU */
#endif
#ifndef MIGRATE
#define MIGRATE 0	/* 1: the holder migrates to CPU 0 between its extra get and its puts (TLA+ MIGRATE) */
#endif

#if SHAPE == 0 && BATCH != 1
#error "a synchronous umount of a mount with a child is -EBUSY in the kernel: BATCH=2 needs SHAPE=1 or 2"
#endif

enum { U = 0, H = 1, W = 2, NTHREADS = 3 };

/* ------------------------------------------------------------------ */
/* kernel vocabulary                                                   */
/* ------------------------------------------------------------------ */

typedef _Bool bool;
#define true 1
#define false 0
#define likely(x) (x)
#define unlikely(x) (x)
#define noinline
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))

#define EINVAL 22
#define EBUSY 16
#define EPERM 1

/* include/linux/mount.h */
#define MNT_INTERNAL	0x4000
#define MNT_LOCKED	0x800000
#define MNT_DOOMED	0x1000000
#define MNT_SYNC_UMOUNT	0x2000000
#define MNT_UMOUNT	0x8000000
/* include/uapi/linux/fs.h */
#define MNT_DETACH	0x00000002

/* the kernel's WARN_ON()/VFS_WARN_ON_ONCE()/VFS_BUG_ON() become assertions */
#define WARN_ON(c) ({ int __c = !!(c); __CPROVER_assert(!__c, "WARN_ON(" #c ")"); __c; })
#define VFS_WARN_ON_ONCE(c) ((void)WARN_ON(c))
#define VFS_BUG_ON(c) ((void)WARN_ON(c))

__CPROVER_thread_local int tid;		/* U, H or W: the running task */
__CPROVER_thread_local int this_cpu;	/* the CPU the task runs on; constant between the migration points */

int nondet_int(void);
bool nondet_bool(void);

static inline int nondet_cpu(void)
{
	int cpu = nondet_int();
	__CPROVER_assume(cpu >= 0 && cpu < NCPU);
	return cpu;
}

/*
 * Memory barriers.  Without --mm the fences are no-ops; goto-instrument
 * --mm tso turns them into the corresponding store-buffer flushes.
 */
#define smp_mb()  __CPROVER_fence("WWfence", "RRfence", "RWfence", "WRfence")
#define smp_wmb() __CPROVER_fence("WWfence")
#define smp_rmb() __CPROVER_fence("RRfence")

/* ---- lists ---------------------------------------------------------- */

/*
 * The shrink lists (dentries to drop) are only passed to stubs here, so
 * list_head carries no pointers: an address-taken local initialised with
 * its own address would be a pointer store to shared memory for CBMC.
 */
struct list_head { int unused; };
struct hlist_node { struct hlist_node *next, **pprev; };
/*
 * `static __CPROVER_thread_local`: CBMC marks an address-taken local dead at function exit by
 * storing its address into the global __CPROVER_dead_object, which is a
 * pointer store to shared memory and hence refused in a threaded program;
 * a plain static would be shared and its reads nondeterministic.
 * These heads are only ever used by U, once per run.
 */
#define LIST_HEAD(name) static __CPROVER_thread_local struct list_head name = { 0 }

/*
 * MODEL of the hlist of unmounted mounts: fixed positions (the mount index),
 * membership flags, and the traversal order hlist_add_head() produces (last
 * added first).  `order`/`n` are only ever written with constants, so every
 * mount pointer derived from them is a constant for CBMC.
 */
struct hlist_head {
	int on[BATCH];		/* on[i]: mounts[i] is on this list */
};
#define HLIST_HEAD_INIT { { 0 } }
/*
 * The insertion order is fixed by construction: umount_tree() walks the tree
 * mounts[0], mounts[1]; kern_unmount_array() walks its array (ORDER).
 * INSERTED(k) is the k-th mount added, so hlist_add_head()'s traversal is
 * INSERTED(BATCH-1) ... INSERTED(0).  A compile-time permutation keeps every
 * mount pointer constant, which CBMC's threaded symex requires.
 */
#if SHAPE == 2 && ORDER
#define INSERTED(k) (BATCH - 1 - (k))
#else
#define INSERTED(k) (k)
#endif
#define HLIST_HEAD(name) static __CPROVER_thread_local struct hlist_head name = HLIST_HEAD_INIT	/* static thread-local: see LIST_HEAD() */

static inline int hlist_empty(const struct hlist_head *h)
{
	int i, any = 0;
	for (i = 0; i < BATCH; i++)
		any |= h->on[i];
	return !any;
}

static inline void hlist_move_list(struct hlist_head *old, struct hlist_head *new)
{
	int i;
	for (i = 0; i < BATCH; i++) {
		new->on[i] = old->on[i];
		old->on[i] = 0;
	}
}

/* ---- the structures: fs/mount.h, include/linux/mount.h ------------ */

struct rcu_head { void (*func)(struct rcu_head *); };
struct mnt_namespace { int unused; };
struct dentry { int unused; };
struct super_block {
	struct mount *s_mounts;
	int idx;			/* ghost: which mount's superblock */
};

struct vfsmount {
	struct dentry *mnt_root;	/* root of the mounted tree */
	struct super_block *mnt_sb;	/* pointer to superblock */
	int mnt_flags;
};

#ifdef MUT_TORN_SUM
/* the single counter of before 7eb84d54fac5 */
struct mnt_pcp {
	int mnt_count;
	int mnt_writers;
};
#else
struct mnt_pcp {
	unsigned int mnt_gets;
	unsigned int mnt_puts;
	int mnt_writers;
};
#endif

struct mount {
	int mnt_parent;			/* MODEL: the index of the parent, or the own index (no pointer stores to shared memory for CBMC) */
	struct dentry *mnt_mountpoint;
	struct vfsmount mnt;
	struct rcu_head mnt_rcu;	/* the kernel unions this with mnt_node/mnt_llist */
	struct mnt_pcp mnt_pcp[NCPU];	/* __percpu pointer in the kernel: mnt->mnt_pcp->f is CPU 0's copy, per_cpu_ptr() indexes it */
	int nr_children;		/* MODEL of mnt_mounts: the children still attached */
	int mnt_ns;			/* containing namespace: MODEL as an id, 0 is NULL */
	int mnt_expiry_mark;		/* true if marked for expiry */
	struct hlist_node *mnt_pins;	/* mnt_pins.first: always NULL here */
};

static inline struct mount *real_mount(struct vfsmount *mnt)
{
	return container_of(mnt, struct mount, mnt);
}

static inline int mnt_idx(struct mount *mnt);

static inline int mnt_has_parent(const struct mount *mnt)
{
	return mnt_idx((struct mount *)mnt) != mnt->mnt_parent;	/* mnt != mnt->mnt_parent */
}

/* ------------------------------------------------------------------ */
/* the objects                                                         */
/* ------------------------------------------------------------------ */

static struct mount mounts[BATCH];
static struct super_block sbs[BATCH];
static struct dentry dentries[BATCH];
#define NS_INIT 1		/* current->nsproxy->mnt_ns */
#define MNT_NS_INTERNAL 2	/* distinct from any mnt_namespace */

static inline int mnt_idx(struct mount *mnt)
{
	return (int)(mnt - mounts);
}

/* ------------------------------------------------------------------ */
/* ghost state (mirrors the TLA+ variables of MntPut.tla)              */
/* ------------------------------------------------------------------ */

static int ghost_refs[NTHREADS][BATCH];	/* refs[t]: the ledger of counted references; U's includes the mount's own */
static int ghost_transient[NTHREADS];	/* Transient(t): a walker inside legitimize_mnt() */
static int ghost_hashed[BATCH];		/* m.hashed: __lookup_mnt() finds the mount */
static int ghost_cleaned[BATCH];	/* cleanup_mnt() ran */
static int ghost_cleaner[BATCH];	/* who ran it */
static int ghost_freed[BATCH];		/* m.freed: delayed_free_vfsmnt() ran */
static int ghost_sb_torn[BATCH];	/* deactivate_super() ran */
static int ghost_fast_final[BATCH];	/* mntput_unheld() finished the mount off: no grace period */
static int ghost_gps;			/* synchronize_rcu_expedited() calls in mntput_unmounted() */
static int ghost_caller_put;		/* do_umount() dropped the caller's reference */
static int ghost_umounted[BATCH];	/* the mount left its namespace */

/* NoUAF: every access to a struct mount in the copied code goes through here */
#define TOUCH(m) __CPROVER_assert(!ghost_freed[mnt_idx(m)], "NoUAF: struct mount touched after it was freed")

static inline int ghost_real_refs(struct mount *mnt)
{
	int idx = mnt_idx(mnt), t, sum = 0;
	for (t = 0; t < NTHREADS; t++)
		sum += ghost_transient[t] ? 0 : ghost_refs[t][idx];
	return sum;
}

/* ------------------------------------------------------------------ */
/* per-CPU counters                                                    */
/* ------------------------------------------------------------------ */

/*
 * this_cpu_inc(mnt->mnt_pcp->field) bumps the running CPU's copy.  The CPU
 * is the thread-local this_cpu (U: 0, H: HCPU, W: WCPU), constant between
 * the explicit migration points (MIGRATE), so that no shared write is
 * guarded by a nondeterministic condition.  The RMW is atomic as the real
 * one is on its CPU.  The ghost ledger is updated in the same atomic step;
 * for a put the ledger goes first, for a get second, so that whoever sees
 * the counter also sees a consistent ledger under FIFO store buffers.
 */
static inline void percpu_add(struct mount *mnt, int is_puts, int cnt_delta, int ghost_delta)
{
	int idx = mnt_idx(mnt);

	TOUCH(mnt);
#ifndef NO_ATOMIC_PCP
	__CPROVER_atomic_begin();
#endif
	/* unguarded writes only: CBMC's thread encoding may resolve a guarded shared write to garbage */
	ghost_refs[tid][idx] += ghost_delta < 0 ? ghost_delta : 0;
#ifdef MUT_TORN_SUM
	mnt->mnt_pcp[this_cpu].mnt_count += cnt_delta;
#else
	mnt->mnt_pcp[this_cpu].mnt_puts += is_puts ? cnt_delta : 0;
	mnt->mnt_pcp[this_cpu].mnt_gets += is_puts ? 0 : cnt_delta;
#endif
	ghost_refs[tid][idx] += ghost_delta > 0 ? ghost_delta : 0;
	/* ghost: a reference taken on a doomed mount can only be a walker's transient one */
	__CPROVER_assert(ghost_delta < 0 || !(mnt->mnt.mnt_flags & MNT_DOOMED) || ghost_transient[tid],
			 "DoomedIsLast: a non-transient get on a doomed mount");
#ifndef NO_ATOMIC_PCP
	__CPROVER_atomic_end();
#endif
}

#define for_each_possible_cpu(cpu) for ((cpu) = 0; (cpu) < NCPU; (cpu)++)
#define per_cpu_ptr(ptr, cpu) (&(ptr)[cpu])
#ifdef MUT_TORN_SUM
#define this_cpu_inc(pcp) percpu_add(mnt, 0, +1, +1)
#define this_cpu_dec(pcp) percpu_add(mnt, 0, -1, -1)
#else
/* both counters only ever go up; which one it is tells the ledger the sign */
#define IS_PUTS(pcp) ((char *)&(pcp) - (char *)mnt->mnt_pcp == (long)offsetof(struct mnt_pcp, mnt_puts))
#define this_cpu_inc(pcp) percpu_add(mnt, IS_PUTS(pcp), +1, IS_PUTS(pcp) ? -1 : +1)
#endif
#define CONFIG_SMP 1

/* ------------------------------------------------------------------ */
/* mount_lock: a seqlock                                               */
/* ------------------------------------------------------------------ */

typedef struct {
	unsigned int sequence;
	bool locked;
} seqlock_t;

static seqlock_t mount_lock;

static inline void write_seqlock(seqlock_t *sl)
{
	/* spin_lock(): an atomic RMW, a full barrier on x86 */
	__CPROVER_atomic_begin();
	__CPROVER_assume(!sl->locked);
	sl->locked = true;
	__CPROVER_atomic_end();
	smp_mb();
	/* write_seqcount_begin() */
	sl->sequence++;
	smp_wmb();
}

static inline void write_sequnlock(seqlock_t *sl)
{
	/* write_seqcount_end() */
	smp_wmb();
	sl->sequence++;
	/* spin_unlock(): a release, a plain store on x86 */
	smp_wmb();
	sl->locked = false;
}

/* read_seqbegin() spins while a writer is in; the harness only lets the reader in when none is */
static inline unsigned read_seqbegin(const seqlock_t *sl)
{
	unsigned ret = READ_ONCE(sl->sequence);
	__CPROVER_assume(!(ret & 1));
	smp_rmb();
	return ret;
}

static inline unsigned read_seqretry(const seqlock_t *sl, unsigned start)
{
	smp_rmb();
	return READ_ONCE(sl->sequence) != start;
}

/* COPIED fs/namespace.c */
static inline void lock_mount_hash(void)
{
	write_seqlock(&mount_lock);
}

/* COPIED fs/namespace.c */
static inline void unlock_mount_hash(void)
{
	write_sequnlock(&mount_lock);
}

/* namespace_sem: only the umounter takes it in this harness */
static inline void namespace_lock(void) { }
static inline void namespace_sem_up(void) { }

/* ------------------------------------------------------------------ */
/* RCU                                                                 */
/* ------------------------------------------------------------------ */

static bool in_rcu[NTHREADS];

#define rcu_read_lock()   (in_rcu[tid] = true)
#define rcu_read_unlock() (in_rcu[tid] = false)

/*
 * A grace period ends once every other task has been seen outside a read
 * section after it began: the harness keeps exactly the schedules in which
 * that is so (an assumption, so nothing is said about liveness).  A grace
 * period is a full barrier on every CPU.
 */
static void __synchronize_rcu(void)
{
	int t;

	smp_mb();
	for (t = 0; t < NTHREADS; t++) {
		if (t == tid)
			continue;
		__CPROVER_atomic_begin();
		__CPROVER_assume(!in_rcu[t]);
		__CPROVER_atomic_end();
	}
	smp_mb();
}

static void synchronize_rcu_expedited(void)
{
	ghost_gps++;	/* ghost: the grace periods of mntput_unmounted() */
	__synchronize_rcu();
}

/* call_rcu(): the callback runs once a grace period has elapsed; here as early as it may */
#define call_rcu(head, fn) do { __synchronize_rcu(); (fn)(head); } while (0)

/* ------------------------------------------------------------------ */
/* task work                                                           */
/* ------------------------------------------------------------------ */

struct task_struct { unsigned int flags; };
#define PF_KTHREAD 0x00200000
static struct task_struct tasks[NTHREADS];	/* none of them a kernel thread */
#define current (&tasks[tid])
#define TWA_RESUME 1

/* the task's pending work: one flag per mount (TWA_RESUME on current only), so every pointer stays constant */
__CPROVER_thread_local int task_work_pending[BATCH];

static void __cleanup_mnt(struct rcu_head *head);

static inline void init_task_work(struct rcu_head *twork, void (*func)(struct rcu_head *))
{
	__CPROVER_assert(func == __cleanup_mnt, "task work is always __cleanup_mnt()");
}

static inline int task_work_add(struct task_struct *task, struct rcu_head *twork, int notify)
{
	int idx = mnt_idx(container_of(twork, struct mount, mnt_rcu));
	__CPROVER_assert(task == current, "TWA_RESUME on current");
	__CPROVER_assert(!task_work_pending[idx], "task_work_add(): the same mount queued twice");
	task_work_pending[idx] = 1;
	return 0;
}

/* the TWA_RESUME work runs on the way back to userspace: at the end of the thread's syscall */
static void run_task_work(void)
{
	int i;
	for (i = 0; i < BATCH; i++) {
		if (task_work_pending[i]) {
			task_work_pending[i] = 0;
			__cleanup_mnt(&mounts[i].mnt_rcu);
		}
	}
}

/* the kernel-thread fallback: unreachable here, none of the tasks is one */
#define llist_add(n, l) (__CPROVER_assert(0, "kthread cleanup path"), 0)
#define schedule_delayed_work(w, d) do { } while (0)
#define delayed_mntput_work 0
#define delayed_mntput_list 0
#define mnt_llist mnt_rcu

/* ------------------------------------------------------------------ */
/* stubs for what the protocol does not touch                          */
/* ------------------------------------------------------------------ */

struct mnt_cover { struct hlist_node node; };
static int event;
__CPROVER_thread_local struct hlist_head unmounted = HLIST_HEAD_INIT;	/* namespace_sem-protected: only U touches it */

static inline int mnt_get_writers(struct mount *mnt) { return 0; }
static inline void mnt_pin_kill(struct mount *mnt) { __CPROVER_assert(0, "mnt_pins is empty"); }
static inline void fsnotify_vfsmount_delete(struct vfsmount *mnt) { }
static inline void dput(struct dentry *d) { }
static inline void deactivate_super(struct super_block *sb) { }	/* ghost_sb_torn is set in cleanup_mnt() */
static inline void mnt_free_id(struct mount *mnt) { }
static inline void shrink_dentry_list(struct list_head *l) { }
static inline void shrink_submounts(struct mount *mnt) { }
static inline void drop_cover(struct mnt_cover *c, struct list_head *l) { __CPROVER_assert(0, "no covers"); }
static inline int security_sb_umount(struct vfsmount *mnt, int flags)
{
	return nondet_bool() ? 0 : -EPERM;	/* an LSM may refuse: exercises the early return */
}
#define retain_and_null_ptr(p) ((void)((p) = NULL))

/* the superblock's mount list (mnt_del_instance()): pointer juggling by U only, not modelled */
static inline void mnt_del_instance(struct mount *m) { }

/* COPIED fs/namespace.c */
static inline int check_mnt(const struct mount *mnt)
{
	return mnt->mnt_ns == NS_INIT;	/* current->nsproxy->mnt_ns */
}

static void cleanup_mnt(struct mount *mnt);

/* ================================================================== */
/* COPIED fs/namespace.c: the protocol                                 */
/* ================================================================== */

static inline void mnt_inc_count(struct mount *mnt)
{
#ifdef CONFIG_SMP
#ifdef MUT_TORN_SUM
	this_cpu_inc(mnt->mnt_pcp->mnt_count);
#else
	this_cpu_inc(mnt->mnt_pcp->mnt_gets);
#endif
#else
	preempt_disable();
	mnt->mnt_count++;
	preempt_enable();
#endif
}

static inline void mnt_dec_count(struct mount *mnt)
{
#ifdef CONFIG_SMP
#ifdef MUT_TORN_SUM
	this_cpu_dec(mnt->mnt_pcp->mnt_count);
#else
	this_cpu_inc(mnt->mnt_pcp->mnt_puts);
#endif
#else
	preempt_disable();
	mnt->mnt_count--;
	preempt_enable();
#endif
}

/*
 * vfsmount lock must be held for write
 */
int mnt_get_count(struct mount *mnt)
{
#ifdef CONFIG_SMP
#ifdef MUT_TORN_SUM
	/* the single counter of before 7eb84d54fac5 */
	int count = 0;
	int cpu;

	TOUCH(mnt);	/* ghost */
	for_each_possible_cpu(cpu) {
		count += per_cpu_ptr(mnt->mnt_pcp, cpu)->mnt_count;
	}

	return count;
#else
	unsigned int gets = 0, puts = 0;
	int cpu;

	TOUCH(mnt);	/* ghost */
	/* puts first, so a put counted here has its get counted below */
	for_each_possible_cpu(cpu)
		puts += per_cpu_ptr(mnt->mnt_pcp, cpu)->mnt_puts;
	smp_mb();	/* pairs with the smp_wmb() in mntput_no_expire() */
	for_each_possible_cpu(cpu)
		gets += per_cpu_ptr(mnt->mnt_pcp, cpu)->mnt_gets;

	return gets - puts;
#endif
#else
	return mnt->mnt_count;
#endif
}

static void free_vfsmnt(struct mount *mnt)
{
	int idx = mnt_idx(mnt);
	/* ghost: Freed, exactly once */
	__CPROVER_assert(!ghost_freed[idx], "FreedOnce: struct mount freed twice");
	__CPROVER_assert(ghost_cleaned[idx], "freed without cleanup_mnt()");
	ghost_freed[idx] = 1;
}

static void delayed_free_vfsmnt(struct rcu_head *head)
{
	free_vfsmnt(container_of(head, struct mount, mnt_rcu));
}

/* call under rcu_read_lock */
int __legitimize_mnt(struct vfsmount *bastard, unsigned seq)
{
	struct mount *mnt;
	if (read_seqretry(&mount_lock, seq))
		return 1;
	if (bastard == NULL)
		return 0;
	mnt = real_mount(bastard);
	mnt_inc_count(mnt);
#ifndef MUT_NO_MB_LEGIT
	smp_mb();	/* see mntput_no_expire_slowpath(), mntput_unheld() and do_umount() */
#endif
	if (likely(!read_seqretry(&mount_lock, seq)))
		return 0;
	lock_mount_hash();
	TOUCH(mnt);	/* ghost */
#ifdef MUT_NO_DOOMED
	if (unlikely(bastard->mnt_flags & (MNT_SYNC_UMOUNT))) {
#else
	if (unlikely(bastard->mnt_flags & (MNT_SYNC_UMOUNT | MNT_DOOMED))) {
#endif
		mnt_dec_count(mnt);
		unlock_mount_hash();
		return 1;
	}
	unlock_mount_hash();
	/* caller will mntput() */
	return -1;
}

static void mntput(struct vfsmount *mnt);

/* call under rcu_read_lock */
static bool legitimize_mnt(struct vfsmount *bastard, unsigned seq)
{
	int res = __legitimize_mnt(bastard, seq);
	if (likely(!res))
		return true;
	if (unlikely(res < 0)) {
		rcu_read_unlock();
		mntput(bastard);
		rcu_read_lock();
	}
	return false;
}

static void cleanup_mnt(struct mount *mnt)
{
	int idx = mnt_idx(mnt);

	TOUCH(mnt);	/* ghost */
	/* ghost: cleanup exactly once, and only of a doomed mount */
	__CPROVER_assert(!ghost_cleaned[idx], "CleanupOnce: cleanup_mnt() twice for one mount");
	__CPROVER_assert(mnt->mnt.mnt_flags & MNT_DOOMED, "cleanup_mnt() of a mount that is not doomed");
	ghost_cleaned[idx] = 1;
	ghost_cleaner[idx] = tid;

	/*
	 * The warning here probably indicates that somebody messed
	 * up a mnt_want/drop_write() pair.  If this happens, the
	 * filesystem was probably unable to make r/w->r/o transitions.
	 * The locking used to deal with mnt_count decrement provides barriers,
	 * so mnt_get_writers() below is safe.
	 */
	WARN_ON(mnt_get_writers(mnt));
	if (unlikely(mnt->mnt_pins))	/* mnt->mnt_pins.first */
		mnt_pin_kill(mnt);
	fsnotify_vfsmount_delete(&mnt->mnt);
	dput(mnt->mnt.mnt_root);
	deactivate_super(mnt->mnt.mnt_sb);
	ghost_sb_torn[idx] = 1;	/* ghost: the filesystem is shut down, freed without a grace period */
	mnt_free_id(mnt);
	call_rcu(&mnt->mnt_rcu, delayed_free_vfsmnt);
}

static void __cleanup_mnt(struct rcu_head *head)
{
	cleanup_mnt(container_of(head, struct mount, mnt_rcu));
}

/*
 * The count reached zero under mount_lock so we doom the mount and
 * cleanup everything.
 */
static void mntput_final_locked(struct mount *mnt, struct list_head *shrink)
{
	TOUCH(mnt);	/* ghost */
	/* ghost: DoomedIsLast -- nobody but a transient walker holds a counted reference */
	__CPROVER_assert(ghost_real_refs(mnt) == 0, "DoomedIsLast: doomed while a counted reference exists");

	VFS_WARN_ON_ONCE(mnt->mnt.mnt_flags & MNT_DOOMED);
	mnt->mnt.mnt_flags |= MNT_DOOMED;

	mnt_del_instance(mnt);
	/* list_del(&mnt->mnt_expire): the expiry list is not modelled */

	/* nothing stays attached to an unmounted mount */
	VFS_WARN_ON_ONCE(mnt->nr_children);	/* !list_empty(&mnt->mnt_mounts) */
	/* the covers (drop_cover()) are not modelled */
}

/* cleanup_mnt() sleeps: from task work, or the workqueue for kernel threads */
static void mntput_queue_cleanup(struct mount *mnt)
{
	if (likely(!(mnt->mnt.mnt_flags & MNT_INTERNAL))) {
		struct task_struct *task = current;
		if (likely(!(task->flags & PF_KTHREAD))) {
			init_task_work(&mnt->mnt_rcu, __cleanup_mnt);
			if (!task_work_add(task, &mnt->mnt_rcu, TWA_RESUME))
				return;
		}
		if (llist_add(&mnt->mnt_llist, &delayed_mntput_list))
			schedule_delayed_work(&delayed_mntput_work, 1);
		return;
	}
	cleanup_mnt(mnt);
}

static void noinline mntput_no_expire_slowpath(struct mount *mnt)
{
	LIST_HEAD(list);
	int count;

	TOUCH(mnt);	/* ghost */
	VFS_BUG_ON(mnt->mnt_ns);
	lock_mount_hash();
	/*
	 * make sure that if __legitimize_mnt() has not seen us grab
	 * mount_lock, we'll see their refcount increment here.
	 */
	smp_mb();
	mnt_dec_count(mnt);
	count = mnt_get_count(mnt);
	if (count != 0) {
		WARN_ON(count < 0);
		rcu_read_unlock();
		unlock_mount_hash();
		return;
	}
	if (unlikely(mnt->mnt.mnt_flags & MNT_DOOMED)) {
		rcu_read_unlock();
		unlock_mount_hash();
		return;
	}
	mntput_final_locked(mnt, &list);
	rcu_read_unlock();
	unlock_mount_hash();
	shrink_dentry_list(&list);
	mntput_queue_cleanup(mnt);
}

#ifdef MUT_PUT_RECHECK
/*
 * EXPLORATORY MUTATION: the fast path re-reads ->mnt_ns after its decrement
 * behind a full barrier and takes the locked look if it went NULL; the
 * locked look is the slow path without the decrement (it already happened).
 */
static void noinline mntput_recheck_locked_look(struct mount *mnt)
{
	LIST_HEAD(list);
	int count;

	TOUCH(mnt);	/* ghost */
	VFS_BUG_ON(mnt->mnt_ns);
	lock_mount_hash();
	smp_mb();
	count = mnt_get_count(mnt);
	if (count != 0) {
		WARN_ON(count < 0);
		rcu_read_unlock();
		unlock_mount_hash();
		return;
	}
	if (unlikely(mnt->mnt.mnt_flags & MNT_DOOMED)) {
		rcu_read_unlock();
		unlock_mount_hash();
		return;
	}
	mntput_final_locked(mnt, &list);
	rcu_read_unlock();
	unlock_mount_hash();
	shrink_dentry_list(&list);
	mntput_queue_cleanup(mnt);
}
#endif

static void mntput_no_expire(struct mount *mnt)
{
	rcu_read_lock();
	TOUCH(mnt);	/* ghost */
	if (likely(READ_ONCE(mnt->mnt_ns))) {
		/*
		 * Since we don't do lock_mount_hash() here,
		 * ->mnt_ns can change under us.  However, if it's
		 * non-NULL, then there's a reference that won't
		 * be dropped until after turning ->mnt_ns NULL and
		 * either an RCU delay or a look under mount_lock
		 * that found it to be the only one left, which it
		 * isn't while ours is counted (mntput_unheld()).
		 * So if we observe it non-NULL under rcu_read_lock(),
		 * the reference we are dropping is not the final one.
		 */
		smp_wmb();	/* pairs with the smp_mb() in mnt_get_count() */
		mnt_dec_count(mnt);
#ifdef MUT_PUT_RECHECK
		smp_mb();
		if (likely(READ_ONCE(mnt->mnt_ns))) {
			rcu_read_unlock();
			return;
		}
		mntput_recheck_locked_look(mnt);
		return;
#else
		rcu_read_unlock();
		return;
#endif
	}
	mntput_no_expire_slowpath(mnt);
}

/*
 * Drop the own reference of a mount that has left its namespace without
 * waiting for a grace period, if the count under mount_lock says it is
 * the only one: a holder's get is visible before its put, a walker's
 * increment is visible unless the walker sees the seqcount change and
 * drops it under mount_lock, and nobody can find the mount anymore.
 * Called under mount_lock, the cleanup of the mount is left to the caller.
 * Returns false if somebody else still references the mount.
 */
static bool mntput_unheld(struct mount *mnt, struct list_head *shrink)
{
	VFS_BUG_ON(mnt->mnt_ns);
#ifdef MUT_PEEK_LOOSE
	{
		int count = mnt_get_count(mnt);	/* MUTATION: a count of two is good enough */
		if (count != 1 && count != 2)
			return false;
	}
#else
	if (mnt_get_count(mnt) != 1)
		return false;
#endif
	mnt_dec_count(mnt);
	mntput_final_locked(mnt, shrink);
	/* ghost: the witness NoFastFinal -- the mount was finished off without a grace period */
	ghost_fast_final[mnt_idx(mnt)] = 1;
	__CPROVER_assert(0, "NoFastFinal (witness: this MUST fail, it shows the fast path)");
	return true;
}

/*
 * Put the mounts umount_tree() collected. The ones nothing else holds are
 * finished under one mount_lock hold, wherever they sit in the batch, and
 * their cleanup is queued. The ones somebody holds go after the one grace
 * period their holders' puts rely on.
 */
static void mntput_unmounted(struct hlist_head *head)
{
	struct mount *m;
	HLIST_HEAD(held);
	LIST_HEAD(shrink);
	int k, i;

	lock_mount_hash();
	smp_mb();	/* see __legitimize_mnt() and mntput_no_expire() */
	/* hlist_for_each_entry_safe(m, p, head, mnt_umount): last added first */
	for (k = BATCH - 1; k >= 0; k--) {
		i = INSERTED(k);
		if (!head->on[i])
			continue;
		m = &mounts[i];
		if (mntput_unheld(m, &shrink))
			continue;
		head->on[i] = 0;		/* hlist_del(&m->mnt_umount) */
		held.on[i] = 1;			/* hlist_add_head(&m->mnt_umount, &held) */
	}
	unlock_mount_hash();
	shrink_dentry_list(&shrink);

	/* hlist_for_each_entry_safe(m, p, head, mnt_umount) */
	for (k = BATCH - 1; k >= 0; k--) {
		i = INSERTED(k);
		if (!head->on[i])
			continue;
		m = &mounts[i];
		head->on[i] = 0;		/* hlist_del(&m->mnt_umount) */
		mntput_queue_cleanup(m);
	}

	if (hlist_empty(&held))
		return;

#ifndef MUT_NO_GP
	synchronize_rcu_expedited();
#endif
	/* hlist_for_each_entry_safe(m, p, &held, mnt_umount): prepended in head order, so head order reversed */
	for (k = 0; k < BATCH; k++) {
		i = INSERTED(k);
		if (!held.on[i])
			continue;
		m = &mounts[i];
		held.on[i] = 0;			/* hlist_del(&m->mnt_umount) */
		mntput(&m->mnt);
	}
}

static void mntput(struct vfsmount *mnt)
{
	if (mnt) {
		struct mount *m = real_mount(mnt);
		TOUCH(m);	/* ghost */
		/* avoid cacheline pingpong */
		if (unlikely(m->mnt_expiry_mark))
			WRITE_ONCE(m->mnt_expiry_mark, 0);
		mntput_no_expire(m);
	}
}

static struct vfsmount *mntget(struct vfsmount *mnt)
{
	if (mnt)
		mnt_inc_count(real_mount(mnt));
	return mnt;
}

/*
 * Make a mount point inaccessible to new lookups.
 * Because there may still be current users, the caller MUST WAIT
 * for an RCU grace period before destroying the mount point, unless
 * it finds under mount_lock that it holds the only reference left,
 * see mntput_unheld().
 */
static void mnt_make_shortterm(struct vfsmount *mnt)
{
	if (mnt)
		WRITE_ONCE(real_mount(mnt)->mnt_ns, NULL);
}

/* ---- umount_tree() and friends ------------------------------------ */

enum umount_tree_flags {
	UMOUNT_SYNC = 1,
	UMOUNT_PROPAGATE = 2,
	UMOUNT_CONNECTED = 4,
	UMOUNT_COVER = 8,
};

/* hlist_add_head(&p->mnt_umount, &unmounted): @k is the insertion position, see INSERTED() */
static inline void unmounted_add(struct hlist_head *h, struct mount *p, int k)
{
	int i = mnt_idx(p);
	__CPROVER_assert(!h->on[i], "a mount is put on the unmounted list twice");
	__CPROVER_assert(i == INSERTED(k), "insertion order differs from the compile-time one");
	h->on[i] = 1;
}

/* REDUCED __umount_mnt()/umount_mnt(): what the walker and the count can see */
static void umount_mnt(struct mount *mnt)
{
	mnt->mnt_parent = mnt_idx(mnt);	/* mnt->mnt_parent = mnt */
	/* hlist_del_init_rcu(&mnt->mnt_hash): __lookup_mnt() no longer finds it */
	WRITE_ONCE(ghost_hashed[mnt_idx(mnt)], 0);
}

/*
 * REDUCED fs/namespace.c umount_tree(): the tree walk (next_mnt()) over the
 * mounts of the harness, no propagation, no peer groups, no covers, no
 * namespace rbtree, no notifications.  mounts[1], if present, is mounted on
 * mounts[0], so the walk is mounts[0], mounts[1] and the list order is the
 * reverse (hlist_add_head()).
 * mount_lock must be held
 * namespace_sem must be held for write
 */
static void umount_tree(struct mount *mnt, enum umount_tree_flags how)
{
	struct mount *p;
	int i;

	__CPROVER_assert(mnt == &mounts[0], "the harness unmounts the tree at mounts[0]");
	/* Gather the mounts to umount: for (p = mnt; p; p = next_mnt(p, mnt)) */
	for (i = 0; i < BATCH; i++) {
		p = &mounts[i];
		/* A mount is unmounted once. */
		VFS_WARN_ON_ONCE(p->mnt.mnt_flags & MNT_UMOUNT);
		p->mnt.mnt_flags |= MNT_UMOUNT;
	}

	/* Hide the mounts from mnt_mounts: list_del_init(&p->mnt_child) */
	for (i = 0; i < BATCH; i++)
		mounts[i].nr_children = 0;

	/* while (!list_empty(&tmp_list)): in tree order */
	for (i = 0; i < BATCH; i++) {
		p = &mounts[i];
		WRITE_ONCE(p->mnt_ns, NULL);
		ghost_umounted[mnt_idx(p)] = 1;	/* ghost */
		if (how & UMOUNT_SYNC)
			p->mnt.mnt_flags |= MNT_SYNC_UMOUNT;

		if (mnt_has_parent(p)) {
			umount_mnt(p);
		}
		unmounted_add(&unmounted, p, i);	/* hlist_add_head(&p->mnt_umount, &unmounted) */
	}
}

/* REDUCED fs/pnode.c: no propagation, so only the mount itself is checked */
static inline int do_refcount_check(struct mount *mnt, int count)
{
	return mnt_get_count(mnt) > count;
}

static int propagate_mount_busy(struct mount *mnt, int refcnt)
{
	if (mnt->nr_children || do_refcount_check(mnt, refcnt))	/* !list_empty(&mnt->mnt_mounts) */
		return 1;
	return 0;
}

/* REDUCED fs/namespace.c namespace_unlock(): the unmounted list and its puts */
static void namespace_unlock(void)
{
	static __CPROVER_thread_local struct hlist_head head;	/* static thread-local: see LIST_HEAD() */

	hlist_move_list(&unmounted, &head);

	namespace_sem_up();	/* up_write(&namespace_sem) */

	if (likely(hlist_empty(&head)))
		return;

	mntput_unmounted(&head);
}

/*
 * COPIED fs/namespace.c do_umount(), lock-section core.  Elided before the
 * lock section: MNT_EXPIRE, MNT_FORCE/->umount_begin() and the root special
 * case (the harness passes flags 0 or MNT_DETACH).
 *
 * The kernel declares `struct mount *ref __free(mntput_no_expire) = mnt;`.
 * CBMC does not support __attribute__((cleanup)) (diffblue/cbmc#8676), so
 * the cleanup is expanded by hand as DROP_REF() before every return: it runs
 * after the return value is computed, i.e. after namespace_unlock().
 */
#define DROP_REF() do { if (ref) { ghost_caller_put++; mntput_no_expire(ref); } } while (0)

/* Unmount @mnt, dropping the reference the caller holds to it on every path. */
static int do_umount(struct mount *mnt, int flags)
{
	struct mount *ref = mnt;	/* __free(mntput_no_expire): see DROP_REF() */
	struct super_block *sb = mnt->mnt.mnt_sb;
	int retval;

	retval = security_sb_umount(&mnt->mnt, flags);
	if (retval) {
		DROP_REF();
		return retval;
	}

	namespace_lock();
	lock_mount_hash();

	/* Repeat the earlier racy checks, now that we are holding the locks */
	retval = -EINVAL;
	if (!check_mnt(mnt))
		goto out;

	if (mnt->mnt.mnt_flags & MNT_LOCKED)
		goto out;

	if (!mnt_has_parent(mnt)) /* not the absolute root */
		goto out;

	event++;
	if (flags & MNT_DETACH) {
		umount_tree(mnt, UMOUNT_PROPAGATE);
		retval = 0;
	} else {
		smp_mb(); // paired with __legitimize_mnt()
		shrink_submounts(mnt);
		retval = -EBUSY;
		if (!propagate_mount_busy(mnt, 2)) {
			umount_tree(mnt, UMOUNT_PROPAGATE|UMOUNT_SYNC);
			retval = 0;
		}
	}
	if (!retval) {
		/*
		 * By definition the caller's reference isn't the last
		 * one, so drop it.
		 */
		mnt_dec_count(mnt);
		ghost_caller_put++;	/* ghost */
		retain_and_null_ptr(ref);
	}
out:
	unlock_mount_hash();
	namespace_unlock();
	DROP_REF();
	(void)sb;
	return retval;
}

/* COPIED fs/namespace.c */
static void kern_unmount_array(struct vfsmount *mnt[], unsigned int num)
{
	HLIST_HEAD(head);
	unsigned int i;

	for (i = 0; i < num; i++) {
		if (!mnt[i])
			continue;
		mnt_make_shortterm(mnt[i]);
		unmounted_add(&head, real_mount(mnt[i]), i);	/* hlist_add_head(&real_mount(mnt[i])->mnt_umount, &head) */
	}
	mntput_unmounted(&head);
}

/* ================================================================== */
/* the harness                                                         */
/* ================================================================== */

static void init_mount(struct mount *m, int idx)
{
	m->mnt.mnt_sb = &sbs[idx];
	m->mnt.mnt_root = &dentries[idx];
	m->mnt_mountpoint = &dentries[idx];
	sbs[idx].idx = idx;
	/* the mount's own reference (alloc_vfsmnt()), taken on CPU 0 */
#ifdef MUT_TORN_SUM
	m->mnt_pcp[0].mnt_count = 1;
#else
	m->mnt_pcp[0].mnt_gets = 1;
#endif
	ghost_refs[U][idx] = 1;
#if SHAPE == 2
	/* kern_mount(): MNT_INTERNAL, mnt_ns = MNT_NS_INTERNAL, never in a namespace or the hash */
	m->mnt.mnt_flags = MNT_INTERNAL;
	m->mnt_ns = MNT_NS_INTERNAL;
	m->mnt_parent = idx;		/* no parent */
	ghost_hashed[idx] = 0;
#else
	m->mnt_ns = NS_INIT;
	m->mnt_parent = -1;		/* root_mnt, never unmounted */
	ghost_hashed[idx] = 1;
#endif
}

static void init(void)
{
	int i;

	for (i = 0; i < BATCH; i++)
		init_mount(&mounts[i], i);
#if SHAPE != 2
	/* the caller's reference (the path lookup of umount(2)), on CPU 0 */
#ifdef MUT_TORN_SUM
	mounts[0].mnt_pcp[0].mnt_count++;
#else
	mounts[0].mnt_pcp[0].mnt_gets++;
#endif
	ghost_refs[U][0]++;
#if BATCH == 2
	/* mounts[1] is mounted on mounts[0] */
	mounts[1].mnt_parent = 0;
	mounts[0].nr_children = 1;
#endif
#endif
	/* the holder's reference (an open file), taken on the last CPU */
#ifdef MUT_TORN_SUM
	mounts[HELD].mnt_pcp[HCPU].mnt_count++;
#else
	mounts[HELD].mnt_pcp[HCPU].mnt_gets++;
#endif
	ghost_refs[H][HELD] = 1;
}

static bool thread_done[NTHREADS];

/* H: a task that holds a reference from the start, path_get()/path_put() pairs, then the final put */
static void holder(void)
{
	struct mount *m = &mounts[HELD];
	int i;

	tid = H;
	this_cpu = HCPU;
	for (i = 0; i < GETS; i++) {
		if (!nondet_bool())
			break;
		mntget(&m->mnt);
		TOUCH(m);
#if MIGRATE
		this_cpu = 0;	/* the scheduler moves the task: HMigrate */
#endif
		mntput(&m->mnt);
		run_task_work();
	}
	mntput(&m->mnt);
	run_task_work();	/* close(2) returns */
	thread_done[H] = true;
}

/* W: path_init() under RCU, __lookup_mnt(), __legitimize_mnt(), use the mount, mntput() */
static void walker(void)
{
	int idx = WALK;		/* a constant: CBMC cannot dereference a nondeterministic pointer in a threaded program */
	struct mount *m = &mounts[idx];
	unsigned seq;
	int found;

	tid = W;
	this_cpu = WCPU;
	rcu_read_lock();
	seq = read_seqbegin(&mount_lock);
	/*
	 * __lookup_mnt() finds the mount while it is hashed; a walk may also
	 * start from a holder's fs->pwd (read under fs->seq with no reference of
	 * its own), i.e. while the holder has a reference.  Both are lockless
	 * reads of state that changes under the lock.
	 */
	found = READ_ONCE(ghost_hashed[idx]) || READ_ONCE(ghost_refs[H][idx]) > 0;
	if (found) {
		ghost_transient[W] = 1;
		if (legitimize_mnt(&m->mnt, seq)) {
			ghost_transient[W] = 0;
			rcu_read_unlock();
			/* the walker uses the mount it legitimized */
			TOUCH(m);
			__CPROVER_assert(!ghost_sb_torn[idx], "NoUAF: a legitimized walker uses a shut-down filesystem");
			__CPROVER_assert(!(m->mnt.mnt_flags & MNT_DOOMED), "DoomedIsLast: a legitimized walker holds a doomed mount");
			mntput(&m->mnt);
			run_task_work();
			thread_done[W] = true;
			return;
		}
		ghost_transient[W] = 0;
	}
	rcu_read_unlock();
	run_task_work();	/* legitimize_mnt()'s own mntput() may have finished the mount off */
	thread_done[W] = true;
}

int main(void)
{
	int retval = 0, i;

	tid = U;
	this_cpu = 0;
	init();

__CPROVER_ASYNC_1: holder();
#if WALKER
__CPROVER_ASYNC_2: walker();
#else
	thread_done[W] = true;
#endif

#if SHAPE == 0
	retval = do_umount(&mounts[0], 0);
#elif SHAPE == 1
	retval = do_umount(&mounts[0], MNT_DETACH);
#else
	{
		static __CPROVER_thread_local struct vfsmount *arr[BATCH];
		for (i = 0; i < BATCH; i++)
			arr[i] = &mounts[ORDER ? BATCH - 1 - i : i].mnt;
		kern_unmount_array(arr, BATCH);
	}
#endif
	run_task_work();	/* umount(2) / kern_unmount() returns */

#if SHAPE != 2
	/* the caller's reference is dropped exactly once on every path */
	__CPROVER_assert(ghost_caller_put == 1, "CallerPutOnce: do_umount() dropped the caller's reference once");
	__CPROVER_assert(ghost_refs[U][0] == (retval ? 1 : 0), "ledger: U holds the own reference iff the umount was refused");
#endif
#if SHAPE == 0
	if (retval == 0) {
		/* SyncClean: the fs is shut down from the caller before umount(2) returns, nobody else holds it */
		__CPROVER_assert(ghost_refs[H][0] == 0, "SyncClean: the holder still has a reference");
		__CPROVER_assert(ghost_transient[W] || ghost_refs[W][0] == 0, "SyncClean: the walker still has a reference");
		__CPROVER_assert(ghost_cleaned[0] == 1 && ghost_cleaner[0] == U, "SyncClean: cleanup_mnt() did not run from umount(2)");
		__CPROVER_assert(ghost_sb_torn[0], "SyncClean: the superblock is still up after umount(2)");
	}
#endif

	/* pthread_join(): wait for both */
	__CPROVER_assume(thread_done[H]);
	__CPROVER_assume(thread_done[W]);

	/* Freed / no leak: every unmounted mount was cleaned up and freed exactly once; a refused umount leaves everything intact */
	for (i = 0; i < BATCH; i++) {
		if (ghost_umounted[i]) {
			__CPROVER_assert(ghost_cleaned[i] == 1, "Freed: an unmounted mount was never cleaned up (leak)");
			__CPROVER_assert(ghost_freed[i] == 1, "Freed: an unmounted mount was never freed (leak)");
			__CPROVER_assert(ghost_refs[U][i] == 0 && ghost_refs[H][i] == 0 && ghost_refs[W][i] == 0,
					 "ledger: a reference to an unmounted mount survives");
		} else {
			__CPROVER_assert(!ghost_cleaned[i] && !ghost_freed[i], "a mounted mount was cleaned up");
			__CPROVER_assert(mnt_get_count(&mounts[i]) == 1, "a mounted mount does not hold exactly its own reference");
			__CPROVER_assert(ghost_refs[U][i] == 1 && ghost_refs[H][i] == 0 && ghost_refs[W][i] == 0,
					 "ledger: a mounted mount is held by somebody other than itself");
		}
	}
	__CPROVER_assert(ghost_gps <= 1, "more than one grace period for one batch");
	return 0;
}

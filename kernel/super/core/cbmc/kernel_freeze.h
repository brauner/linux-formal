/* SPDX-License-Identifier: GPL-2.0 */
/*
 * kernel_freeze.h - the freeze/thaw state machine of fs/super.c and the
 * bd_fsfreeze_count handling of block/bdev.c, copied from
 * vfs/work.super.fixes @ fc1c25014ff8, for sequential CBMC harnesses.
 *
 * Rule: everything between "BEGIN COPY" and "END COPY" is the kernel text
 * with only these mechanical substitutions (each marked STUB where it is
 * not obvious):
 *
 *   WARN_ON_ONCE(c)        -> WARN_ON_ONCE(SITE, c): records + asserts per site
 *   WARN_ONCE(1, msg)      -> WARN_ONCE(SITE, 1, msg)
 *   s_umount rw_semaphore  -> int owner flag; down_write()/up_write() assert
 *                             balance (every modelled user takes it exclusive)
 *   percpu_rw_semaphore    -> int write-held flag (percpu_down_write() asserts
 *                             it is free: only one freezer may own a level)
 *   lockdep_*()            -> assert() or nothing
 *   wake_up_var()          -> no-op (waiters are resumed by the scheduler)
 *   wait_var_event*()      -> resume points, see freeze_super_co()
 *   atomic_t               -> int (the harness is sequential: every
 *                             operation step runs atomically)
 *   sync_filesystem(), ->freeze_fs(), ->unfreeze_fs(), sync_blockdev()
 *                          -> nondeterministic success/-EIO (per config)
 *   deactivate_locked_super() last ref -> model_kill_sb(): SB_DYING, drop
 *                             s_umount, release the device claims, sb dead
 *
 * freeze_super() and wait_for_partially_frozen() drop s_umount and sleep.
 * They are turned into one resumable coroutine, freeze_super_co(): the code
 * between two resume points is the kernel code, unchanged, and runs as one
 * atomic step; other operations interleave at the resume points only.  The
 * same is done for the callers that sit on top of freeze_super()
 * (fs_bdev_freeze() inside bdev_freeze()).
 */
#ifndef KERNEL_FREEZE_H
#define KERNEL_FREEZE_H

/* ------------------------------------------------------------------ */
/* environment                                                         */
/* ------------------------------------------------------------------ */

typedef _Bool bool;
#define true	1
#define false	0
#define NULL	((void *)0)
#define BIT(nr)	(1UL << (nr))

#define EIO		5
#define EBUSY		16
#define EINVAL		22
#define EOPNOTSUPP	95
#define ERESTARTSYS	512

_Bool nondet_bool(void);
int nondet_int(void);
unsigned int nondet_uint(void);

#define assume(c)	__CPROVER_assume(c)
#define kassert(c, msg)	__CPROVER_assert((c), msg)

/* Failure injection, enabled per run with -D. */
#ifndef CFG_FAIL_SYNC_FS
#define CFG_FAIL_SYNC_FS	1	/* sync_filesystem() in freeze_super() */
#endif
#ifndef CFG_FAIL_FREEZE_FS
#define CFG_FAIL_FREEZE_FS	1	/* ->freeze_fs() */
#endif
#ifndef CFG_FAIL_UNFREEZE_FS
#define CFG_FAIL_UNFREEZE_FS	1	/* ->unfreeze_fs() (only jfs can, in-tree) */
#endif
#ifndef CFG_KILL_WAIT
#define CFG_KILL_WAIT		1	/* fatal signal in wait_for_partially_frozen() */
#endif
#ifndef CFG_FAIL_SYNC_BLOCKDEV
#define CFG_FAIL_SYNC_BLOCKDEV	0	/* sync_blockdev() in fs_bdev_freeze() */
#endif

static bool inject(int enabled)
{
	return enabled && nondet_bool();
}

/* WARN sites.  Every WARN is an assertion so CBMC reports which one fires. */
enum warn_site {
	W_FREEZE_DYING,		/* fs/super.c:2253 freeze_super() "Dying superblock while freezing!" */
	W_THAW_DYING,		/* fs/super.c:2420 thaw_super()   "Dying superblock while thawing!" */
	W_INC_FLAGS,		/* fs/super.c:2083 freeze_inc() who & ~FREEZE_FLAGS */
	W_INC_HOLDERS,		/* fs/super.c:2084 freeze_inc() two holders */
	W_DEC_FLAGS,		/* fs/super.c:2095 freeze_dec() who & ~FREEZE_FLAGS */
	W_DEC_HOLDERS,		/* fs/super.c:2096 freeze_dec() two holders */
	W_MAYF_FLAGS,		/* fs/super.c:2110 may_freeze() */
	W_MAYF_HOLDERS,		/* fs/super.c:2111 may_freeze() */
	W_MAYF_X_NOTK,		/* fs/super.c:2114 may_freeze() EXCL without KERNEL */
	W_MAYF_X_EXTRA,		/* fs/super.c:2116 may_freeze() EXCL with other flags */
	W_MAYF_X_NOOWNER,	/* fs/super.c:2118 may_freeze() EXCL without owner */
	W_MAYU_FLAGS,		/* fs/super.c:2147 may_unfreeze() */
	W_MAYU_HOLDERS,		/* fs/super.c:2148 may_unfreeze() */
	W_MAYU_X_NOTK,		/* fs/super.c:2151 may_unfreeze() EXCL without KERNEL */
	W_MAYU_X_EXTRA,		/* fs/super.c:2153 may_unfreeze() EXCL with other flags */
	W_MAYU_X_NOOWNER,	/* fs/super.c:2155 may_unfreeze() EXCL without owner */
	W_MAYU_X_KCOUNT0,	/* fs/super.c:2157 may_unfreeze() EXCL thaw, freeze_kcount == 0 */
	W_FREEZE_COMPLETE_INC1,	/* fs/super.c:2261 freeze_super() COMPLETE but no holder */
	W_FREEZE_RDONLY_INC,	/* fs/super.c:2281 freeze_super() sb_rdonly() path, holder exists */
	W_FREEZE_FULL_INC,	/* fs/super.c:2329 freeze_super() full path, holder exists */
	W_ALLOW_FREEZE,		/* block/bdev.c:408 bdev_allow_freeze() without deny */
	W_NR
};

static int warned[W_NR];

static int warn_on(int site, int cond)
{
	if (cond)
		warned[site] = 1;
	return cond;
}

/*
 * One assertion per site.  A failing WARN does not stop the path: CBMC keeps
 * checking every other property on it, like the kernel keeps running.
 */
#define WARN_SITE_ASSERT(site, cond)						\
	{									\
		switch (site) {							\
		case W_FREEZE_DYING:	 kassert(!(cond), "WARN freeze_super: dying superblock (super.c:2253)"); break; \
		case W_THAW_DYING:	 kassert(!(cond), "WARN thaw_super: dying superblock (super.c:2420)"); break; \
		case W_INC_FLAGS:	 kassert(!(cond), "WARN freeze_inc: bad flags (super.c:2083)"); break; \
		case W_INC_HOLDERS:	 kassert(!(cond), "WARN freeze_inc: two holders (super.c:2084)"); break; \
		case W_DEC_FLAGS:	 kassert(!(cond), "WARN freeze_dec: bad flags (super.c:2095)"); break; \
		case W_DEC_HOLDERS:	 kassert(!(cond), "WARN freeze_dec: two holders (super.c:2096)"); break; \
		case W_MAYF_FLAGS:	 kassert(!(cond), "WARN may_freeze: bad flags (super.c:2110)"); break; \
		case W_MAYF_HOLDERS:	 kassert(!(cond), "WARN may_freeze: two holders (super.c:2111)"); break; \
		case W_MAYF_X_NOTK:	 kassert(!(cond), "WARN may_freeze: EXCL without KERNEL (super.c:2114)"); break; \
		case W_MAYF_X_EXTRA:	 kassert(!(cond), "WARN may_freeze: EXCL extra flags (super.c:2116)"); break; \
		case W_MAYF_X_NOOWNER:	 kassert(!(cond), "WARN may_freeze: EXCL without owner (super.c:2118)"); break; \
		case W_MAYU_FLAGS:	 kassert(!(cond), "WARN may_unfreeze: bad flags (super.c:2147)"); break; \
		case W_MAYU_HOLDERS:	 kassert(!(cond), "WARN may_unfreeze: two holders (super.c:2148)"); break; \
		case W_MAYU_X_NOTK:	 kassert(!(cond), "WARN may_unfreeze: EXCL without KERNEL (super.c:2151)"); break; \
		case W_MAYU_X_EXTRA:	 kassert(!(cond), "WARN may_unfreeze: EXCL extra flags (super.c:2153)"); break; \
		case W_MAYU_X_NOOWNER:	 kassert(!(cond), "WARN may_unfreeze: EXCL without owner (super.c:2155)"); break; \
		case W_MAYU_X_KCOUNT0:	 kassert(!(cond), "WARN may_unfreeze: EXCL thaw with freeze_kcount == 0 (super.c:2157)"); break; \
		case W_FREEZE_COMPLETE_INC1: kassert(!(cond), "WARN freeze_super: COMPLETE without holder (super.c:2261)"); break; \
		case W_FREEZE_RDONLY_INC: kassert(!(cond), "WARN freeze_super: rdonly path found a holder (super.c:2281)"); break; \
		case W_FREEZE_FULL_INC:	 kassert(!(cond), "WARN freeze_super: full path found a holder (super.c:2329)"); break; \
		case W_ALLOW_FREEZE:	 kassert(!(cond), "WARN bdev_allow_freeze: no deny held (bdev.c:408)"); break; \
		}								\
	}

static int warn_check(int site, int cond)
{
	cond = !!cond;
	WARN_SITE_ASSERT(site, cond);
	return warn_on(site, cond);
}

#define WARN_ON_ONCE(site, cond)	warn_check(site, (cond))
#define WARN_ONCE(site, cond, msg)	warn_check(site, (cond))

/* ------------------------------------------------------------------ */
/* types (include/linux/fs/super_types.h, reduced)                     */
/* ------------------------------------------------------------------ */

enum {
	SB_UNFROZEN		= 0,	/* FS is unfrozen */
	SB_FREEZE_WRITE		= 1,	/* Writes, dir ops, ioctls frozen */
	SB_FREEZE_PAGEFAULT	= 2,	/* Page faults stopped as well */
	SB_FREEZE_FS		= 3,	/* For internal FS use (e.g. to stop internal threads if needed) */
	SB_FREEZE_COMPLETE	= 4,	/* ->freeze_fs finished successfully */
};

#define SB_FREEZE_LEVELS (SB_FREEZE_COMPLETE - 1)

enum freeze_holder {
	FREEZE_HOLDER_KERNEL	= (1U << 0),
	FREEZE_HOLDER_USERSPACE	= (1U << 1),
	FREEZE_MAY_NEST		= (1U << 2),
	FREEZE_EXCL		= (1U << 3),
};

#define SB_RDONLY	BIT(0)
#define SB_DEAD		BIT(21)
#define SB_DYING	BIT(24)
#define SB_BORN		BIT(29)
#define SB_ACTIVE	BIT(30)

/* STUB: struct percpu_rw_semaphore -> write-held flag */
struct percpu_rw_semaphore {
	int wheld;
};

struct sb_writers {
	unsigned short			frozen;		/* Is sb frozen? */
	int				freeze_kcount;	/* How many kernel freeze requests? */
	int				freeze_ucount;	/* How many userspace freeze requests? */
	const void			*freeze_owner;	/* Owner of the freeze */
	struct percpu_rw_semaphore	rw_sem[SB_FREEZE_LEVELS];
};

struct super_block;

struct super_operations {
	int (*freeze_fs)(struct super_block *);
	int (*unfreeze_fs)(struct super_block *);
};

struct super_block {
	unsigned long			s_flags;
	int				s_active;	/* atomic_t */
	int				s_umount;	/* STUB: rw_semaphore, 1 = held exclusive */
	struct sb_writers		s_writers;
	const struct super_operations	*s_op;

	/* model-only state */
	int				m_dead;		/* ->kill_sb() ran */
	int				m_registered;	/* claim on the modelled device(s) still held */
	int				g_froze_rdonly;	/* ghost: COMPLETE reached via the sb_rdonly() branch */
};

/* ------------------------------------------------------------------ */
/* primitive stubs                                                      */
/* ------------------------------------------------------------------ */

static void down_write(int *sem)
{
	kassert(!*sem, "s_umount: acquired while held (self-deadlock)");
	*sem = 1;
}

static void up_write(int *sem)
{
	kassert(*sem, "s_umount: released while not held");
	*sem = 0;
}

#define lockdep_assert_held(sem)	kassert(*(sem), "lockdep_assert_held(s_umount)")
#define lockdep_assert_not_held(sem)	kassert(!*(sem), "lockdep_assert_not_held(s_umount)")

static void percpu_down_write(struct percpu_rw_semaphore *sem)
{
	kassert(!sem->wheld, "percpu_down_write: level already write-held");
	sem->wheld = 1;
}

static void percpu_up_write(struct percpu_rw_semaphore *sem)
{
	kassert(sem->wheld, "percpu_up_write: level not write-held");
	sem->wheld = 0;
}

#define percpu_rwsem_release(sem, ip)		((void)0)
#define percpu_rwsem_acquire(sem, r, ip)	((void)0)
#define _THIS_IP_				0
#define wake_up_var(var)			((void)0)
#define smp_load_acquire(p)			(*(p))
#define pr_err(...)				((void)0)
#define printk(...)				((void)0)
#define pr_warn(...)				((void)0)

static void atomic_inc(int *v)
{
	(*v)++;
}

static bool atomic_dec_and_test(int *v)
{
	kassert(*v > 0, "s_active: decrement below zero");
	return --(*v) == 0;
}

static bool atomic_inc_not_zero(int *v)
{
	if (*v == 0)
		return false;
	(*v)++;
	return true;
}

/* atomic_add_unless(v, a, u): add a unless *v == u; true if added */
static bool atomic_add_unless(int *v, int a, int u)
{
	if (*v == u)
		return false;
	*v += a;
	return true;
}

static bool atomic_inc_unless_negative(int *v)
{
	if (*v < 0)
		return false;
	(*v)++;
	return true;
}

static void atomic_dec(int *v)
{
	(*v)--;
}

static int atomic_read(const int *v)
{
	return *v;
}

/*
 * STUB: hweight32().  Every call site passes who & FREEZE_HOLDERS (bits 0-1),
 * so a two-bit popcount is exact; the assertion keeps it honest.  (The SWAR
 * version with its 32-bit multiply costs a multiplier circuit per call.)
 */
static unsigned int hweight32(unsigned int w)
{
	kassert(w < 4, "hweight32 stub: argument wider than FREEZE_HOLDERS");
	return (w & 1) + ((w >> 1) & 1);
}

static inline bool sb_rdonly(const struct super_block *sb)
{
	return sb->s_flags & SB_RDONLY;
}

/* injected filesystem behaviour */
static int sync_filesystem(struct super_block *sb)
{
	(void)sb;
	return inject(CFG_FAIL_SYNC_FS) ? -EIO : 0;
}

static int model_freeze_fs(struct super_block *sb)
{
	(void)sb;
	return inject(CFG_FAIL_FREEZE_FS) ? -EIO : 0;
}

static int model_unfreeze_fs(struct super_block *sb)
{
	(void)sb;
	return inject(CFG_FAIL_UNFREEZE_FS) ? -EIO : 0;
}

static const struct super_operations ops_freeze_fs = {
	.freeze_fs	= model_freeze_fs,
	.unfreeze_fs	= model_unfreeze_fs,
};

static const struct super_operations ops_no_freeze_fs = {
	.freeze_fs	= NULL,
	.unfreeze_fs	= NULL,
};

/* the harness provides this: release the dead sb's device claims */
static void model_release_claims(struct super_block *sb);

/*
 * STUB for the last-reference branch of deactivate_locked_super():
 * shrinker_free(); fs->kill_sb(s) [generic_shutdown_super(): SB_DYING,
 * super_unlock_excl(); kill_block_super(): fs_bdev_file_release()];
 * kill_super_notify(); put_super().
 */
static void model_kill_sb(struct super_block *s)
{
	kassert(s->s_writers.frozen == SB_UNFROZEN,
		"kill_sb on a superblock that is not SB_UNFROZEN");
	kassert(s->s_writers.freeze_kcount == 0 && s->s_writers.freeze_ucount == 0,
		"kill_sb with freeze holders left");
	s->s_flags |= SB_DYING;
	up_write(&s->s_umount);			/* super_unlock_excl() in generic_shutdown_super() */
	model_release_claims(s);
	s->s_flags |= SB_DEAD;			/* kill_super_notify() */
	s->m_dead = 1;
}

/* ------------------------------------------------------------------ */
/* BEGIN COPY fs/super.c                                               */
/* ------------------------------------------------------------------ */

static inline void __super_lock(struct super_block *sb, bool excl)
{
	if (excl)
		down_write(&sb->s_umount);
	else
		kassert(0, "shared s_umount not modelled");	/* STUB: down_read() */
}

static inline void super_unlock(struct super_block *sb, bool excl)
{
	if (excl)
		up_write(&sb->s_umount);
	else
		kassert(0, "shared s_umount not modelled");	/* STUB: up_read() */
}

static inline void __super_lock_excl(struct super_block *sb)
{
	__super_lock(sb, true);
}

static inline void super_unlock_excl(struct super_block *sb)
{
	super_unlock(sb, true);
}

static bool super_flags(const struct super_block *sb, unsigned int flags)
{
	/*
	 * Pairs with smp_store_release() in super_wake() and ensures
	 * that we see @flags after we're woken.
	 */
	return smp_load_acquire(&sb->s_flags) & flags;
}

static bool super_lock(struct super_block *sb, bool excl)
{
	lockdep_assert_not_held(&sb->s_umount);

	/* wait until the superblock is ready or dying */
	/* STUB: wait_var_event(): every modelled superblock is SB_BORN */
	assume(super_flags(sb, SB_BORN | SB_DYING));

	/* Don't pointlessly acquire s_umount. */
	if (super_flags(sb, SB_DYING))
		return false;

	__super_lock(sb, excl);

	/*
	 * Has gone through generic_shutdown_super() in the meantime.
	 * @sb->s_root is NULL and @sb->s_active is 0. No one needs to
	 * grab a reference to this. Tell them so.
	 */
	if (sb->s_flags & SB_DYING) {
		super_unlock(sb, excl);
		return false;
	}

	kassert(sb->s_flags & SB_BORN, "super_lock: !SB_BORN");
	return true;
}

static inline bool super_lock_excl(struct super_block *sb)
{
	return super_lock(sb, true);
}

void deactivate_locked_super(struct super_block *s)
{
	if (atomic_dec_and_test(&s->s_active)) {
		model_kill_sb(s);	/* STUB, see above */
	} else {
		super_unlock_excl(s);
	}
}

void deactivate_super(struct super_block *s)
{
	if (!atomic_add_unless(&s->s_active, -1, 1)) {
		__super_lock_excl(s);
		deactivate_locked_super(s);
	}
}

static inline bool get_active_super(struct super_block *sb)
{
	bool active = false;

	if (super_lock_excl(sb)) {
		active = atomic_inc_not_zero(&sb->s_active);
		super_unlock_excl(sb);
	}
	return active;
}

static void sb_wait_write(struct super_block *sb, int level)
{
	percpu_down_write(sb->s_writers.rw_sem + level-1);
}

static void lockdep_sb_freeze_release(struct super_block *sb)
{
	int level;

	for (level = SB_FREEZE_LEVELS - 1; level >= 0; level--)
		percpu_rwsem_release(sb->s_writers.rw_sem + level, _THIS_IP_);
}

static void lockdep_sb_freeze_acquire(struct super_block *sb)
{
	int level;

	for (level = 0; level < SB_FREEZE_LEVELS; ++level)
		percpu_rwsem_acquire(sb->s_writers.rw_sem + level, 0, _THIS_IP_);
}

static void sb_freeze_unlock(struct super_block *sb, int level)
{
	for (level--; level >= 0; level--)
		percpu_up_write(sb->s_writers.rw_sem + level);
}

#define FREEZE_HOLDERS (FREEZE_HOLDER_KERNEL | FREEZE_HOLDER_USERSPACE)
#define FREEZE_FLAGS (FREEZE_HOLDERS | FREEZE_MAY_NEST | FREEZE_EXCL)

static inline int freeze_inc(struct super_block *sb, enum freeze_holder who)
{
	WARN_ON_ONCE(W_INC_FLAGS, (who & ~FREEZE_FLAGS));
	WARN_ON_ONCE(W_INC_HOLDERS, hweight32(who & FREEZE_HOLDERS) > 1);

	if (who & FREEZE_HOLDER_KERNEL)
		++sb->s_writers.freeze_kcount;
	if (who & FREEZE_HOLDER_USERSPACE)
		++sb->s_writers.freeze_ucount;
	return sb->s_writers.freeze_kcount + sb->s_writers.freeze_ucount;
}

static inline int freeze_dec(struct super_block *sb, enum freeze_holder who)
{
	WARN_ON_ONCE(W_DEC_FLAGS, (who & ~FREEZE_FLAGS));
	WARN_ON_ONCE(W_DEC_HOLDERS, hweight32(who & FREEZE_HOLDERS) > 1);

	if ((who & FREEZE_HOLDER_KERNEL) && sb->s_writers.freeze_kcount)
		--sb->s_writers.freeze_kcount;
	if ((who & FREEZE_HOLDER_USERSPACE) && sb->s_writers.freeze_ucount)
		--sb->s_writers.freeze_ucount;
	return sb->s_writers.freeze_kcount + sb->s_writers.freeze_ucount;
}

static inline bool may_freeze(struct super_block *sb, enum freeze_holder who,
			      const void *freeze_owner)
{
	lockdep_assert_held(&sb->s_umount);

	WARN_ON_ONCE(W_MAYF_FLAGS, (who & ~FREEZE_FLAGS));
	WARN_ON_ONCE(W_MAYF_HOLDERS, hweight32(who & FREEZE_HOLDERS) > 1);

	if (who & FREEZE_EXCL) {
		if (WARN_ON_ONCE(W_MAYF_X_NOTK, !(who & FREEZE_HOLDER_KERNEL)))
			return false;
		if (WARN_ON_ONCE(W_MAYF_X_EXTRA, who & ~(FREEZE_EXCL | FREEZE_HOLDER_KERNEL)))
			return false;
		if (WARN_ON_ONCE(W_MAYF_X_NOOWNER, !freeze_owner))
			return false;
		/* This freeze already has a specific owner. */
		if (sb->s_writers.freeze_owner)
			return false;
		/*
		 * This is already frozen multiple times so we're just
		 * going to take a reference count and mark the freeze as
		 * being owned by the caller.
		 */
		if (sb->s_writers.freeze_kcount + sb->s_writers.freeze_ucount)
			sb->s_writers.freeze_owner = freeze_owner;
		return true;
	}

	if (who & FREEZE_HOLDER_KERNEL)
		return (who & FREEZE_MAY_NEST) ||
		       sb->s_writers.freeze_kcount == 0;
	if (who & FREEZE_HOLDER_USERSPACE)
		return (who & FREEZE_MAY_NEST) ||
		       sb->s_writers.freeze_ucount == 0;
	return false;
}

static inline bool may_unfreeze(struct super_block *sb, enum freeze_holder who,
				const void *freeze_owner)
{
	lockdep_assert_held(&sb->s_umount);

	WARN_ON_ONCE(W_MAYU_FLAGS, (who & ~FREEZE_FLAGS));
	WARN_ON_ONCE(W_MAYU_HOLDERS, hweight32(who & FREEZE_HOLDERS) > 1);

	if (who & FREEZE_EXCL) {
		if (WARN_ON_ONCE(W_MAYU_X_NOTK, !(who & FREEZE_HOLDER_KERNEL)))
			return false;
		if (WARN_ON_ONCE(W_MAYU_X_EXTRA, who & ~(FREEZE_EXCL | FREEZE_HOLDER_KERNEL)))
			return false;
		if (WARN_ON_ONCE(W_MAYU_X_NOOWNER, !freeze_owner))
			return false;
#ifndef PATCH_9ae90f06a813
		if (WARN_ON_ONCE(W_MAYU_X_KCOUNT0, sb->s_writers.freeze_kcount == 0))
			return false;
#endif
		/* This isn't exclusively frozen. */
		if (!sb->s_writers.freeze_owner)
			return false;
		/* This isn't exclusively frozen by us. */
		if (sb->s_writers.freeze_owner != freeze_owner)
			return false;
#ifdef PATCH_9ae90f06a813
		/*
		 * work.super.fixes 9ae90f06a813 ("super: don't warn when resume
		 * thaws a userspace freeze"), committed after fc1c25014ff8:
		 * An exclusive freeze always holds a kernel reference.
		 */
		if (WARN_ON_ONCE(W_MAYU_X_KCOUNT0, sb->s_writers.freeze_kcount == 0))
			return false;
#endif
		/*
		 * This is still frozen multiple times so we're just
		 * going to drop our reference count and undo our
		 * exclusive freeze.
		 */
		if ((sb->s_writers.freeze_kcount + sb->s_writers.freeze_ucount) > 1)
			sb->s_writers.freeze_owner = NULL;
		return true;
	}

	if (who & FREEZE_HOLDER_KERNEL) {
		/*
		 * Someone's trying to steal the reference belonging to
		 * @sb->s_writers.freeze_owner.
		 */
		if (sb->s_writers.freeze_kcount == 1 &&
		    sb->s_writers.freeze_owner)
			return false;
		return sb->s_writers.freeze_kcount > 0;
	}

	if (who & FREEZE_HOLDER_USERSPACE)
		return sb->s_writers.freeze_ucount > 0;

	return false;
}

/*
 * freeze_super() (super.c:2248-2336) with wait_for_partially_frozen()
 * (super.c:2060-2076) inlined, as a coroutine.  Resume points:
 *
 *   FPC_WFPF:  wait_for_partially_frozen(): after up_write(&sb->s_umount),
 *              in wait_var_event_killable().  The scheduler resumes the
 *              waiter only when "frozen != old" holds (the wait returns 0)
 *              or, if CFG_KILL_WAIT, when it does not hold and a fatal
 *              signal arrives (-ERESTARTSYS): wait_var_event_killable()
 *              tests the condition before the signal.
 *   FPC_WRITE: freeze_super(): after super_unlock_excl(sb), before
 *              sb_wait_write(sb, SB_FREEZE_WRITE).
 *
 * Returns 1 when freeze_super() has returned (result in f->ret), 0 when the
 * caller has to yield.
 */
enum { FPC_START = 0, FPC_WFPF, FPC_WRITE };

struct freezer {
	int			pc;
	struct super_block	*sb;
	enum freeze_holder	who;
	const void		*freeze_owner;
	unsigned short		old;	/* wait_for_partially_frozen()'s local */
	int			ret;
};

static int freeze_super_co(struct freezer *f, bool killed)
{
	struct super_block *sb = f->sb;
	enum freeze_holder who = f->who;
	const void *freeze_owner = f->freeze_owner;
	int ret;

	if (f->pc == FPC_WFPF)
		goto wfpf_resume;
	if (f->pc == FPC_WRITE)
		goto write_resume;

	if (!super_lock_excl(sb)) {
		WARN_ONCE(W_FREEZE_DYING, 1, "Dying superblock while freezing!");
		f->ret = -EINVAL;
		return 1;
	}
	atomic_inc(&sb->s_active);

retry:
	if (sb->s_writers.frozen == SB_FREEZE_COMPLETE) {
		if (may_freeze(sb, who, freeze_owner))
			ret = !!WARN_ON_ONCE(W_FREEZE_COMPLETE_INC1, freeze_inc(sb, who) == 1);
		else
			ret = -EBUSY;
		/* All freezers share a single active reference. */
		deactivate_locked_super(sb);
		f->ret = ret;
		return 1;
	}

	if (sb->s_writers.frozen != SB_UNFROZEN) {
		/* ret = wait_for_partially_frozen(sb); */
		ret = 0;
		do {
			f->old = sb->s_writers.frozen;	/* unsigned short old = sb->s_writers.frozen; */

			up_write(&sb->s_umount);
			f->pc = FPC_WFPF;
			return 0;			/* ---- resume point ---- */
wfpf_resume:
			f->pc = FPC_START;
			/* ret = wait_var_event_killable(&sb->s_writers.frozen, sb->s_writers.frozen != old); */
			if (sb->s_writers.frozen != f->old) {
				ret = 0;
			} else {
				kassert(killed, "scheduler resumed a sleeping waiter");
				ret = -ERESTARTSYS;
			}
			down_write(&sb->s_umount);
		} while (ret == 0 &&
			 sb->s_writers.frozen != SB_UNFROZEN &&
			 sb->s_writers.frozen != SB_FREEZE_COMPLETE);
		/* end of wait_for_partially_frozen() */
		if (ret) {
			deactivate_locked_super(sb);
			f->ret = ret;
			return 1;
		}

		goto retry;
	}

	if (sb_rdonly(sb)) {
		/* Nothing to do really... */
		WARN_ON_ONCE(W_FREEZE_RDONLY_INC, freeze_inc(sb, who) > 1);
		sb->s_writers.freeze_owner = freeze_owner;
		sb->s_writers.frozen = SB_FREEZE_COMPLETE;
		sb->g_froze_rdonly = 1;			/* GHOST */
		wake_up_var(&sb->s_writers.frozen);
		super_unlock_excl(sb);
		f->ret = 0;
		return 1;
	}

	sb->s_writers.frozen = SB_FREEZE_WRITE;
	/* Release s_umount to preserve sb_start_write -> s_umount ordering */
	super_unlock_excl(sb);
	f->pc = FPC_WRITE;
	return 0;					/* ---- resume point ---- */
write_resume:
	f->pc = FPC_START;
	sb_wait_write(sb, SB_FREEZE_WRITE);
	__super_lock_excl(sb);

	/* Now we go and block page faults... */
	sb->s_writers.frozen = SB_FREEZE_PAGEFAULT;
	sb_wait_write(sb, SB_FREEZE_PAGEFAULT);

	/* All writers are done so after syncing there won't be dirty data */
	ret = sync_filesystem(sb);
	if (ret) {
		sb->s_writers.frozen = SB_UNFROZEN;
		sb_freeze_unlock(sb, SB_FREEZE_PAGEFAULT);
		wake_up_var(&sb->s_writers.frozen);
		deactivate_locked_super(sb);
		f->ret = ret;
		return 1;
	}

	/* Now wait for internal filesystem counter */
	sb->s_writers.frozen = SB_FREEZE_FS;
	sb_wait_write(sb, SB_FREEZE_FS);

	if (sb->s_op->freeze_fs) {
		ret = sb->s_op->freeze_fs(sb);
		if (ret) {
			printk(KERN_ERR
				"VFS:Filesystem freeze failed\n");
			sb->s_writers.frozen = SB_UNFROZEN;
			sb_freeze_unlock(sb, SB_FREEZE_FS);
			wake_up_var(&sb->s_writers.frozen);
			deactivate_locked_super(sb);
			f->ret = ret;
			return 1;
		}
	}
	/*
	 * For debugging purposes so that fs can warn if it sees write activity
	 * when frozen is set to SB_FREEZE_COMPLETE, and for thaw_super().
	 */
	WARN_ON_ONCE(W_FREEZE_FULL_INC, freeze_inc(sb, who) > 1);
	sb->s_writers.freeze_owner = freeze_owner;
	sb->s_writers.frozen = SB_FREEZE_COMPLETE;
	sb->g_froze_rdonly = 0;				/* GHOST */
	wake_up_var(&sb->s_writers.frozen);
	lockdep_sb_freeze_release(sb);
	super_unlock_excl(sb);
	f->ret = 0;
	return 1;
}

static int thaw_super_locked(struct super_block *sb, enum freeze_holder who,
			     const void *freeze_owner)
{
	int error = -EINVAL;

	if (sb->s_writers.frozen != SB_FREEZE_COMPLETE)
		goto out_unlock;

	if (!may_unfreeze(sb, who, freeze_owner))
		goto out_unlock;

	/*
	 * All freezers share a single active reference. If other freezers
	 * remain, drop our hold and report success; the superblock stays
	 * frozen until the last holder thaws it.
	 */
	if (freeze_dec(sb, who)) {
		error = 0;
		goto out_unlock;
	}

	if (sb_rdonly(sb)) {
		sb->s_writers.frozen = SB_UNFROZEN;
		sb->s_writers.freeze_owner = NULL;
		wake_up_var(&sb->s_writers.frozen);
		goto out_deactivate;
	}

	lockdep_sb_freeze_acquire(sb);

	if (sb->s_op->unfreeze_fs) {
		error = sb->s_op->unfreeze_fs(sb);
		if (error) {
			pr_err("VFS: Filesystem thaw failed\n");
			freeze_inc(sb, who);
			lockdep_sb_freeze_release(sb);
			goto out_unlock;
		}
	}

	sb->s_writers.frozen = SB_UNFROZEN;
	sb->s_writers.freeze_owner = NULL;
	wake_up_var(&sb->s_writers.frozen);
	sb_freeze_unlock(sb, SB_FREEZE_FS);
out_deactivate:
	deactivate_locked_super(sb);
	return 0;

out_unlock:
	super_unlock_excl(sb);
	return error;
}

int thaw_super(struct super_block *sb, enum freeze_holder who,
	       const void *freeze_owner)
{
	if (!super_lock_excl(sb)) {
		WARN_ONCE(W_THAW_DYING, 1, "Dying superblock while thawing!");
		return -EINVAL;
	}
	return thaw_super_locked(sb, who, freeze_owner);
}

/* super.c:1242 */
static const char *filesystems_freeze_ptr = "filesystems_freeze";

/* ------------------------------------------------------------------ */
/* END COPY fs/super.c                                                 */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* block device side                                                   */
/* ------------------------------------------------------------------ */

#ifndef MAX_SB_PER_DEV
#define MAX_SB_PER_DEV 3
#endif

static int run_freezer(struct freezer *f, bool killed);
static int checked_thaw_super(struct super_block *sb, enum freeze_holder who,
			      const void *owner);

/*
 * STUB: struct block_device, reduced.  The super_dev_table rows for this
 * device are an array in table order; sd_linked[i] is "entry i can still be
 * pinned" (sd_ref > 0).  Entry lifetime is the subject of devtable.c; here
 * a cursor pin is "the walk reached index i while it was linked".
 */
struct block_device {
	int			bd_fsfreeze_count;	/* atomic_t */
	int			bd_fsfreeze_mutex;	/* STUB: mutex, 1 = held */
	int			bd_holder_lock;		/* STUB: mutex, 1 = held */
	int			bd_holder_ops;		/* STUB: == &fs_holder_ops */
	int			nsd;
	struct super_block	*sd_sb[MAX_SB_PER_DEV];
	int			sd_linked[MAX_SB_PER_DEV];
};

static void mutex_lock(int *m)
{
	kassert(!*m, "mutex: acquired while held");
	*m = 1;
}

static void mutex_unlock(int *m)
{
	kassert(*m, "mutex: released while not held");
	*m = 0;
}

static int sync_blockdev(struct block_device *bdev)
{
	(void)bdev;
	return inject(CFG_FAIL_SYNC_BLOCKDEV) ? -EIO : 0;
}

/* super_dev_first()/super_dev_next(): next linked row at or after @i, or -1 */
static int sd_cursor_from(const struct block_device *bdev, int i)
{
	if (i <= 0 && bdev->nsd > 0 && bdev->sd_linked[0])
		return 0;
	if (i <= 1 && bdev->nsd > 1 && bdev->sd_linked[1])
		return 1;
	if (i <= 2 && bdev->nsd > 2 && bdev->sd_linked[2])
		return 2;
	return -1;
}

enum { R_NONE = 0, R_SKIP, R_OK, R_ERR };	/* per-row outcome of a walk */
enum { BPC_START = 0, BPC_IN_SB, BPC_NEXT };

/*
 * bdev_freeze() (block/bdev.c:300-332) with fs_bdev_freeze() (super.c:1549-1581)
 * and fs_super_freeze() (super.c:1476-1482) inlined, as a coroutine:
 *   BPC_IN_SB: inside freeze_super() of row i (see freeze_super_co())
 *   BPC_NEXT:  the walk pinned row i and has not visited it yet; nothing is
 *              locked in the kernel at this point except bd_fsfreeze_mutex,
 *              so anything that does not need that mutex can run here.
 * Locals that live across a resume point are kept in the frame.
 */
struct bdev_walk {
	int			pc;
	struct block_device	*bdev;
	int			yield_between;	/* model a resume point between rows */
	int			i;		/* pinned row */
	unsigned int		count;		/* fs_bdev_freeze()/fs_bdev_thaw() count */
	int			fs_error;	/* fs_bdev_freeze()/fs_bdev_thaw() error */
	struct freezer		f;
	int			holder_ran;	/* model: the holder op was called */
	int			ret;
	int			res[MAX_SB_PER_DEV];
};

static int bdev_freeze_co(struct bdev_walk *w, bool killed)
{
	struct block_device *bdev = w->bdev;
	struct super_block *sb;
	int error = 0, err;

	if (w->pc == BPC_IN_SB)
		goto in_sb;
	if (w->pc == BPC_NEXT)
		goto next_row;

	/* ---- bdev_freeze() ---- */
	mutex_lock(&bdev->bd_fsfreeze_mutex);

	/* A device being removed from its filesystem refuses freezes. */
	if (!atomic_inc_unless_negative(&bdev->bd_fsfreeze_count)) {
		mutex_unlock(&bdev->bd_fsfreeze_mutex);
		w->ret = -EBUSY;
		return 1;
	}
	if (atomic_read(&bdev->bd_fsfreeze_count) > 1) {
		mutex_unlock(&bdev->bd_fsfreeze_mutex);
		w->ret = 0;
		return 1;
	}

	mutex_lock(&bdev->bd_holder_lock);
	if (bdev->bd_holder_ops) {
		/* error = bdev->bd_holder_ops->freeze(bdev); */
		w->holder_ran = 1;
		/* ---- fs_bdev_freeze() ---- */
		w->count = 0;
		w->fs_error = 0;

		/* lockdep_assert_held(&bdev->bd_fsfreeze_mutex); */
		kassert(bdev->bd_fsfreeze_mutex, "fs_bdev_freeze without bd_fsfreeze_mutex");

		mutex_unlock(&bdev->bd_holder_lock);

		/* for (sb_dev = super_dev_first(dev); sb_dev; sb_dev = super_dev_next(sb_dev)) { */
		w->i = sd_cursor_from(bdev, 0);
		while (w->i >= 0) {
			sb = bdev->sd_sb[w->i];
			if (!get_active_super(sb)) {
				w->res[w->i] = R_SKIP;
				goto continue_row;
			}
			/* err = fs_super_freeze(sb_dev->sd_sb); */
			w->f.pc = FPC_START;
			w->f.sb = sb;
			w->f.who = FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE;
			w->f.freeze_owner = NULL;
in_sb:
			sb = bdev->sd_sb[w->i];
			if (!run_freezer(&w->f, killed)) {
				w->pc = BPC_IN_SB;
				return 0;			/* ---- resume point ---- */
			}
			w->pc = BPC_START;
			err = w->f.ret;
			w->res[w->i] = err ? R_ERR : R_OK;
			if (err && !w->fs_error)
				w->fs_error = err;
			deactivate_super(sb);
			w->count++;
continue_row:
			w->i = sd_cursor_from(bdev, w->i + 1);
			if (w->i >= 0 && w->yield_between) {
				w->pc = BPC_NEXT;
				return 0;			/* ---- resume point ---- */
			}
next_row:
			w->pc = BPC_START;
		}

		/*
		 * When several superblocks share the device, keep it frozen even if some
		 * of them failed to freeze and swallow the error: rolling the rest back
		 * via thaw_super() can fail too, so neither is a clear win. A single
		 * filesystem (count == 1) still reports its error.
		 */
		if (w->fs_error && w->count > 1)
			w->fs_error = 0;
#ifndef PATCH_e7552629ff47
		if (!w->fs_error)
			w->fs_error = sync_blockdev(bdev);
#else
		/* e7552629ff47 ("fs: don't fail fs_bdev_freeze() once a superblock is frozen") */
		if (!w->fs_error) {
			w->fs_error = sync_blockdev(bdev);
			if (w->count)
				w->fs_error = 0;
		}
#endif
		/* return error; (fs_bdev_freeze) */
		error = w->fs_error;
		/* ---- back in bdev_freeze() ---- */
		kassert(!bdev->bd_holder_lock, "lockdep_assert_not_held(&bdev->bd_holder_lock)");
	} else {
		mutex_unlock(&bdev->bd_holder_lock);
		error = sync_blockdev(bdev);
	}

	if (error)
		atomic_dec(&bdev->bd_fsfreeze_count);

	mutex_unlock(&bdev->bd_fsfreeze_mutex);
	w->ret = error;
	return 1;
}

/*
 * bdev_thaw() (block/bdev.c:341-372) with fs_bdev_thaw() (super.c:1594-1619)
 * and fs_super_thaw() (super.c:1484-1490) inlined.  thaw_super() does not
 * sleep with s_umount dropped, so the only resume point is BPC_NEXT.
 */
static int bdev_thaw_co(struct bdev_walk *w)
{
	struct block_device *bdev = w->bdev;
	struct super_block *sb;
	int error = -EINVAL, nr_freeze, err;

	if (w->pc == BPC_NEXT)
		goto next_row;

	/* ---- bdev_thaw() ---- */
	mutex_lock(&bdev->bd_fsfreeze_mutex);

	/* <= 0: not frozen (0) or a freeze deny is held (< 0); leave it. */
	nr_freeze = atomic_read(&bdev->bd_fsfreeze_count);
	if (nr_freeze <= 0)
		goto out;

	error = 0;
	if (nr_freeze > 1) {
		atomic_dec(&bdev->bd_fsfreeze_count);
		goto out;
	}

	/* Keep the count positive across the thaw so a deny is refused. */
	mutex_lock(&bdev->bd_holder_lock);
	if (bdev->bd_holder_ops) {
		/* error = bdev->bd_holder_ops->thaw(bdev); */
		w->holder_ran = 1;
		/* ---- fs_bdev_thaw() ---- */
		w->count = 0;
		w->fs_error = 0;

		kassert(bdev->bd_fsfreeze_mutex, "fs_bdev_thaw without bd_fsfreeze_mutex");

		mutex_unlock(&bdev->bd_holder_lock);

		w->i = sd_cursor_from(bdev, 0);
		while (w->i >= 0) {
			sb = bdev->sd_sb[w->i];
			if (!get_active_super(sb)) {
				w->res[w->i] = R_SKIP;
				goto continue_row;
			}
			/* err = fs_super_thaw(sb_dev->sd_sb); */
			err = checked_thaw_super(sb, FREEZE_MAY_NEST | FREEZE_HOLDER_USERSPACE, NULL);
#ifdef PATCH_86d692e754a8
			/* 86d692e754a8 ("fs: don't keep a device frozen when its freeze is already gone") */
			if (err == -EINVAL)
				err = 0;
#endif
			w->res[w->i] = err ? R_ERR : R_OK;
			if (err && !w->fs_error)
				w->fs_error = err;
			deactivate_super(sb);
			w->count++;
continue_row:
			w->i = sd_cursor_from(bdev, w->i + 1);
			if (w->i >= 0 && w->yield_between) {
				w->pc = BPC_NEXT;
				return 0;			/* ---- resume point ---- */
			}
next_row:
			w->pc = BPC_START;
			bdev = w->bdev;
		}

		/* Shared device: swallow per-superblock errors, like fs_bdev_freeze(). */
		if (w->fs_error && w->count > 1)
			w->fs_error = 0;
		/* return error; (fs_bdev_thaw) */
		error = w->fs_error;
		/* ---- back in bdev_thaw() ---- */
		kassert(!bdev->bd_holder_lock, "lockdep_assert_not_held(&bdev->bd_holder_lock)");
	} else {
		mutex_unlock(&bdev->bd_holder_lock);
	}

	if (!error)
		atomic_dec(&bdev->bd_fsfreeze_count);
out:
	mutex_unlock(&bdev->bd_fsfreeze_mutex);
	w->ret = error;
	return 1;
}

/* exactness checks around every freeze/thaw that returns */
struct holds_snap {
	int k, u;
	const void *owner;
	unsigned short frozen;
};

static struct holds_snap snap_holds(const struct super_block *sb)
{
	struct holds_snap s;

	s.k = sb->s_writers.freeze_kcount;
	s.u = sb->s_writers.freeze_ucount;
	s.owner = sb->s_writers.freeze_owner;
	s.frozen = sb->s_writers.frozen;
	return s;
}

/* @pre was taken at the start of the atomic step in which freeze_super() returned */
static void check_freeze_result(const struct super_block *sb, struct holds_snap pre,
				enum freeze_holder who, int ret)
{
	int k = sb->s_writers.freeze_kcount, u = sb->s_writers.freeze_ucount;

	kassert(ret <= 0, "freeze_super returned a positive value");
	if (ret == 0) {
		if (who & FREEZE_HOLDER_KERNEL)
			kassert(k == pre.k + 1 && u == pre.u,
				"freeze_super==0 did not add exactly one kernel hold");
		else
			kassert(u == pre.u + 1 && k == pre.k,
				"freeze_super==0 did not add exactly one userspace hold");
		kassert(sb->s_writers.frozen == SB_FREEZE_COMPLETE,
			"freeze_super==0 but not SB_FREEZE_COMPLETE");
	} else {
		kassert(k == pre.k && u == pre.u && sb->s_writers.freeze_owner == pre.owner,
			"failed freeze_super changed the holds or the owner");
	}
}

static void check_thaw_result(const struct super_block *sb, struct holds_snap pre,
			      enum freeze_holder who, int ret)
{
	int k = sb->s_writers.freeze_kcount, u = sb->s_writers.freeze_ucount;

	kassert(ret <= 0, "thaw returned a positive value");
	if (ret == 0) {
		if (who & FREEZE_HOLDER_KERNEL)
			kassert(k == pre.k - 1 && u == pre.u,
				"thaw==0 did not remove exactly one kernel hold");
		else
			kassert(u == pre.u - 1 && k == pre.k,
				"thaw==0 did not remove exactly one userspace hold");
	} else {
		kassert(k == pre.k && u == pre.u && sb->s_writers.freeze_owner == pre.owner &&
			sb->s_writers.frozen == pre.frozen,
			"failed thaw changed the freeze state");
	}
}

static int checked_thaw_super(struct super_block *sb, enum freeze_holder who,
			      const void *owner)
{
	struct holds_snap pre = snap_holds(sb);
	int ret = thaw_super(sb, who, owner);

	check_thaw_result(sb, pre, who, ret);
	return ret;
}

static int checked_thaw_super_locked(struct super_block *sb, enum freeze_holder who,
				     const void *owner)
{
	struct holds_snap pre = snap_holds(sb);
	int ret = thaw_super_locked(sb, who, owner);

	check_thaw_result(sb, pre, who, ret);
	return ret;
}

/* run one atomic step of a freezer; check the result if freeze_super() returned */
static int run_freezer(struct freezer *f, bool killed)
{
	struct holds_snap pre = snap_holds(f->sb);
	int done = freeze_super_co(f, killed);

	if (done)
		check_freeze_result(f->sb, pre, f->who, f->ret);
	return done;
}

/* Structural invariants of one superblock, valid between atomic steps. */
static void check_sb_invariants(const struct super_block *sb, int expected_active)
{
	int k = sb->s_writers.freeze_kcount, u = sb->s_writers.freeze_ucount;
	unsigned short frozen = sb->s_writers.frozen;
	int wheld = sb->s_writers.rw_sem[0].wheld + sb->s_writers.rw_sem[1].wheld +
		    sb->s_writers.rw_sem[2].wheld;

	kassert(sb->s_umount == 0, "s_umount held between steps");
	kassert(k >= 0, "freeze_kcount < 0");
	kassert(u >= 0, "freeze_ucount < 0");
	if (sb->m_dead) {
		kassert(sb->s_active == 0, "dead sb with active refs");
		return;
	}
	kassert(sb->s_active == expected_active,
		"s_active != mounts + (frozen==COMPLETE) + in-flight refs");
	kassert((frozen == SB_FREEZE_COMPLETE) == (k + u > 0),
		"frozen==COMPLETE <=> kcount+ucount>0 violated");
	kassert(frozen == SB_FREEZE_COMPLETE || sb->s_writers.freeze_owner == NULL,
		"freeze_owner set while not SB_FREEZE_COMPLETE");
	kassert(sb->s_writers.freeze_owner == NULL ||
		sb->s_writers.freeze_owner == filesystems_freeze_ptr,
		"unknown freeze_owner");
	if (frozen == SB_UNFROZEN || frozen == SB_FREEZE_WRITE)
		kassert(wheld == 0, "sb_writers rwsem write-held while SB_UNFROZEN (leaked by thaw)");
	if (frozen == SB_FREEZE_COMPLETE)
		kassert(wheld == (sb->g_froze_rdonly ? 0 : 3),
			"sb_writers rwsems do not match the path that froze the sb");
	kassert(frozen != SB_FREEZE_PAGEFAULT && frozen != SB_FREEZE_FS,
		"intermediate freeze level visible between steps");
}

#endif /* KERNEL_FREEZE_H */

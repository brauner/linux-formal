// SPDX-License-Identifier: GPL-2.0
/*
 * devtable.c - CBMC harness for the claim counting of the super_dev table
 * (fs/super.c @ work.super.fixes.core.claims 587d78169911): sget_fc()'s set()
 * registration and kill_super_notify()'s put,
 * fs_bdev_register()/fs_bdev_unregister(), cursor pins
 * (super_dev_first()/super_dev_next()/user_get_super()), and the passive
 * reference every table row holds on its superblock.
 *
 * A copy of the device table harness written for the review of
 * work.super.fixes (fc1c25014ff8), extended with SB_BORN and the unborn-wait
 * cursor.  The table code it copies is the same in both trees except for
 * super_dev_get()/super_dev_first()/super_dev_next().
 *
 * The rhltable is an array of rows; the chain of a device is "linked rows
 * with that sd_dev, newest first" (rhltable inserts a duplicate key at the
 * head of the key's list: __rhashtable_insert_fast() and
 * rhashtable_lookup_one() set list->next = plist; resizes move a key's list
 * as a unit).  -DCFG_INSERT_TAIL=1 flips that to show what depends on it.
 *
 * super_dev_put() that drops the last reference leaves the row linked with
 * sd_ref == 0 until rhltable_remove(); with CFG_DYING_WINDOW, when that put
 * comes from a cursor, the tail runs as a separate PUT_FINISH step so other
 * operations - including the filesystem's own register/unregister of the
 * same pair - can run in between.  (The cursor's own continuation touches
 * nothing in the table.)  A put issued by the filesystem finishes in place:
 * under CFG_SERIAL nothing else on that pair can overlap it, and other pairs
 * never look at the row (lookups match sd_sb, cursors skip sd_ref == 0).
 *
 * Serialisation assumption (CFG_SERIAL=1): operations of the filesystem on
 * one (dev, sb) pair - register, unregister - do not overlap each other.
 * Every in-tree caller opens/releases a given device for a given superblock
 * from one context at a time (fill_super, kill_sb, btrfs device add/remove
 * under its exclusive-operation lock).  Cursors (fs_holder_ops walkers,
 * user_get_super()) and operations on other pairs interleave freely.
 * CFG_SERIAL=0 drops the assumption.
 *
 * SB_BORN: an OP_BORN step is vfs_get_tree()'s super_wake(sb, SB_BORN) after
 * fill_super() returned.  The filesystem registers and unregisters devices
 * before it (fill_super(): btrfs_open_devices(), btrfs_free_extra_devids(),
 * error paths) and after it (btrfs device add/remove).
 *
 * Cursor: CFG_UNBORN_WAIT=1 (default) is the unborn-wait super_dev_get() of
 * work.super.fixes.core.claims (eca07e8969d8 "super: don't act on
 * superblocks that dropped their device claim" at 587d78169911), which was
 * not merged; the sd_claims fix was kept instead and is not modelled.  It
 * pins only entries of superblocks that are born or dying.  For an entry of
 * an unborn superblock it takes a passive reference on the superblock
 * instead, sleeps in wait_var_event() until SB_BORN or SB_DYING, drops the
 * reference and looks again from @prev (still pinned) or from the head of the
 * chain.  The sleep is a resume point: the cursor leaves its step holding the
 * passive reference (cursor_wait[]) and, in super_dev_next(), the pin on
 * @prev (cursor_prev[]); an OP_CUR_WAKE step resumes it once that superblock
 * is born or dying, so the filesystem's unregister, SB_BORN, the kill etc.
 * interleave with the sleep.
 *
 * CFG_UNBORN_WAIT=0 reproduces the fc1c25014ff8 cursor.  It pins the first
 * entry with sd_ref > 0 and the walker waits for SB_BORN in super_lock() or
 * get_active_super() with the pin held, so a claim dropped before SB_BORN
 * leaves the entry linked and the walk acts on it.
 */
typedef _Bool bool;
#define true	1
#define false	0
#define NULL	((void *)0)
#define ENOMEM	12
#define EBUSY	16

_Bool nondet_bool(void);
int nondet_int(void);
#define assume(c)	__CPROVER_assume(c)
#define kassert(c, m)	__CPROVER_assert((c), m)

#ifndef NSTEPS
#define NSTEPS 8
#endif
#ifndef CFG_SERIAL
#define CFG_SERIAL 1
#endif
#ifndef CFG_INSERT_TAIL
#define CFG_INSERT_TAIL 0
#endif
#ifndef CFG_DYING_WINDOW
#define CFG_DYING_WINDOW 1
#endif
#ifndef CFG_FAIL_INSERT
#define CFG_FAIL_INSERT 1	/* rhltable_insert() -ENOMEM/-E2BIG, kzalloc failure */
#endif
#ifndef NDEV
#define NDEV 1			/* dev_t values 1..NDEV */
#endif
#ifndef CFG_UNBORN_WAIT
#define CFG_UNBORN_WAIT 1	/* 0: the fc1c25014ff8 cursor */
#endif
#ifndef CHECK_REACH
#define CHECK_REACH 0		/* 1: add "reach:" probes, each must FAIL (vacuity check) */
#endif
#if CHECK_REACH
#define reach(c, m)	kassert(!(c), "reach: " m)
#else
#define reach(c, m)	((void)0)
#endif

#define NSB	2
#define NENT	5
#define NCUR	1

typedef unsigned int dev_t;

/* ------------------------------------------------------------------ */
/* model of the objects                                                */
/* ------------------------------------------------------------------ */

struct super_block;

struct super_dev {
	dev_t			sd_dev;
	struct super_block	*sd_sb;
	int			sd_ref;		/* refcount_t */
	/* model */
	int			m_used;		/* allocated */
	int			m_linked;	/* in super_dev_table */
	int			m_seq;		/* insertion order */
	int			m_dying;	/* sd_ref hit 0, removal pending */
	int			m_passive;	/* holds a passive ref on sd_sb (ghost) */
};

enum { SB_FRESH = 0, SB_LIVE, SB_DYINGST, SB_DEADST, SB_RELEASED, SB_GONE };

#define SB_DEAD		(1UL << 21)
#define SB_DYING	(1UL << 24)
#define SB_BORN		(1UL << 29)

struct super_block {
	int			s_passive;	/* refcount_t */
	dev_t			s_dev;
	unsigned long		s_flags;
	struct super_dev	*s_super_dev;
	/* model */
	int			m_state;
	int			m_freed;
};

/*
 * Separate objects behind constant pointer tables, not arrays of structs: a
 * pointer whose value set is a few objects is a field-level mux for CBMC; a
 * pointer into an array of structs with a symbolic offset becomes byte-level
 * updates of the whole array (that ran out of memory at 10 steps).
 */
static struct super_dev E0, E1, E2, E3, E4;
static struct super_dev *const ROW[NENT] = { &E0, &E1, &E2, &E3, &E4 };
static struct super_block S0, S1;
static struct super_block *const SBP[NSB] = { &S0, &S1 };
static int seq;

/* ghost */
static int claims[NSB][NDEV + 1];	/* fs_bdev claims held by the filesystem */
static int sget_claim[NSB];		/* sget_fc()'s claim (registered, not yet killed) */
static int user_refs[NSB];		/* user_get_super() passive refs not yet dropped */
static struct super_dev *cursor[NCUR];	/* pinned row, NULL = idle */
static int cursor_dev[NCUR];
static int cursor_taken[NCUR];		/* user_get_super() returned this sb (needs drop_super) */
static struct super_block *cursor_sb[NCUR];
/*
 * A cursor asleep in super_dev_get()'s wait_var_event(): cursor_wait[] is the
 * unborn superblock it holds a passive ref on, cursor_prev[] the @prev that
 * super_dev_next() keeps pinned meanwhile (NULL: super_dev_first()).
 */
static struct super_block *cursor_wait[NCUR];
static struct super_dev *cursor_prev[NCUR];
/*
 * unborn_drop[s][d]: the last claim of the pair went away while the
 * superblock was neither born nor dying (btrfs_free_extra_devids(), the
 * -EBUSY rollback in fs_bdev_register(), a fill_super() error path), and the
 * pair has not claimed the device again since.  A walk must not act on it.
 */
static int was_claimed[NSB][NDEV + 1];
static int unborn_drop[NSB][NDEV + 1];
/*
 * In-flight multi-step operations (slots).  fs_bdev_register():
 * RS_INSERT = lookup missed, alloc+insert pending (only split when
 * !CFG_SERIAL); RS_CHECK = inserted, bd_fsfreeze_count test pending.
 * fs_bdev_unregister(): looked up, put pending.
 */
#define NREG	2
enum { RS_IDLE = 0, RS_INSERT, RS_CHECK };
static int reg_state[NREG];
static int reg_sb[NREG];
static dev_t reg_dev[NREG];
static struct super_dev *reg_row[NREG];
static int unreg_busy;
static int unreg_sb;
static dev_t unreg_dev;
static struct super_dev *unreg_row;

static int log_op[NSTEPS], log_arg[NSTEPS], log_ret[NSTEPS];

static int sb_idx(const struct super_block *sb)
{
	return sb == &S1;
}

/* ------------------------------------------------------------------ */
/* stubs: refcount_t, rhltable, RCU, allocation                        */
/* ------------------------------------------------------------------ */

static void refcount_set(int *r, int v)
{
	*r = v;
}

static void refcount_inc(int *r)
{
	kassert(*r > 0, "refcount_t: addition on 0; use-after-free");
	(*r)++;
}

static bool refcount_inc_not_zero(int *r)
{
	if (*r == 0)
		return false;
	(*r)++;
	return true;
}

static bool refcount_dec_and_test(int *r)
{
	kassert(*r > 0, "refcount_t: underflow; use-after-free");
	return --(*r) == 0;
}

#define rcu_read_lock()		((void)0)
#define rcu_read_unlock()	((void)0)
#define smp_mb()		((void)0)

static int alloc_fail(void)
{
	return CFG_FAIL_INSERT && nondet_bool();
}

/* kzalloc_obj(*fsd) */
static struct super_dev *kzalloc_super_dev(void)
{
	int i;

	if (alloc_fail())
		return NULL;
	struct super_dev *e = NULL;

	for (i = 0; i < NENT; i++)
		if (!e && !ROW[i]->m_used)
			e = ROW[i];
	assume(e != NULL);		/* model bound, not a kernel failure */
	e->sd_dev = 0;
	e->sd_sb = NULL;
	e->sd_ref = 0;
	e->m_used = 1;
	e->m_linked = 0;
	e->m_seq = 0;
	e->m_dying = 0;
	e->m_passive = 0;
	return e;
}

static void kfree(struct super_dev *fsd)
{
	if (!fsd)
		return;
	kassert(fsd->m_used, "kfree of a free super_dev");
	kassert(!fsd->m_linked, "kfree of a linked super_dev");
	kassert(!fsd->m_passive, "super_dev freed while still holding a passive ref");
	fsd->m_used = 0;
}

#define kfree_rcu(fsd, field)	kfree(fsd)

static int rhltable_insert(struct super_dev *fsd)
{
	if (alloc_fail())
		return -ENOMEM;
	kassert(fsd->m_used && !fsd->m_linked, "rhltable_insert of a bad row");
	fsd->m_linked = 1;
	fsd->m_seq = CFG_INSERT_TAIL ? -(++seq) : ++seq;
	return 0;
}

static void rhltable_remove(struct super_dev *fsd)
{
	kassert(fsd->m_used && fsd->m_linked, "rhltable_remove of an unlinked row");
	fsd->m_linked = 0;
}

/* head of the chain for @dev: linked row with the largest m_seq */
static struct super_dev *chain_after(dev_t dev, int below, bool bounded)
{
	struct super_dev *best = NULL;
	int i;

	for (i = 0; i < NENT; i++) {
		struct super_dev *e = ROW[i];

		if (!e->m_used || !e->m_linked || e->sd_dev != dev)
			continue;
		if (bounded && e->m_seq >= below)
			continue;
		if (!best || e->m_seq > best->m_seq)
			best = e;
	}
	return best;
}

static struct super_dev *rhltable_lookup(dev_t dev)
{
	return chain_after(dev, 0, false);
}

/* pos->next of the rhlist: next older linked row of the same key */
static struct super_dev *rhl_next(struct super_dev *pos)
{
	return chain_after(pos->sd_dev, pos->m_seq, true);
}

/* ------------------------------------------------------------------ */
/* superblock passive refs                                             */
/* ------------------------------------------------------------------ */

/* put_super(), super.c:419: the unlink/free part reduced to ghost state */
static void put_super(struct super_block *s)
{
	int i;

	if (refcount_dec_and_test(&s->s_passive)) {
		for (i = 0; i < NENT; i++)
			kassert(!(ROW[i]->m_used && ROW[i]->m_linked && ROW[i]->sd_sb == s),
				"superblock freed while a table row points to it");
		kassert(user_refs[sb_idx(s)] == 0, "superblock freed under a user_get_super() ref");
		for (i = 0; i < NCUR; i++)
			kassert(cursor_wait[i] != s, "superblock freed under a sleeping cursor's passive ref");
		s->m_freed = 1;
	}
}

/* super_flags(): smp_load_acquire(&sb->s_flags) & flags */
static bool super_flags(const struct super_block *sb, unsigned long flags)
{
	kassert(!sb->m_freed, "super_flags() on a freed superblock");
	return (sb->s_flags & flags) != 0;
}

/* ------------------------------------------------------------------ */
/* BEGIN COPY fs/super.c                                               */
/* ------------------------------------------------------------------ */

static struct super_dev *super_dev_alloc(dev_t dev, struct super_block *sb)
{
	struct super_dev *fsd;

	fsd = kzalloc_super_dev();		/* kzalloc_obj(*fsd); */
	if (!fsd)
		return NULL;
	fsd->sd_dev = dev;
	fsd->sd_sb = sb;
	refcount_set(&fsd->sd_ref, 1);
	return fsd;
}

static void super_dev_put_finish(struct super_dev *fsd);

/*
 * MODEL: set while a cursor (fs_holder_ops walker, user_get_super()) drops
 * its pin.  Only then can the row's own (dev, sb) pair observe the window
 * between refcount_dec_and_test() and rhltable_remove(): a put issued by the
 * filesystem itself (unregister, register rollback, kill_super_notify())
 * finishes before the filesystem's next operation on that pair starts.
 */
static int put_from_cursor;

static void super_dev_put(struct super_dev *fsd)
{
	/* Unlink only once unpinned, so a cursor never resumes from a removed node. */
	if (fsd && refcount_dec_and_test(&fsd->sd_ref)) {
		kassert(fsd->m_linked, "super_dev_put() dropped the last ref of an unlinked row");
		fsd->m_dying = 1;
		if (!CFG_DYING_WINDOW || !put_from_cursor)
			super_dev_put_finish(fsd);
		/* else: rhltable_remove() + put_super() + kfree_rcu() in a PUT_FINISH step */
	}
}

static void super_dev_put_finish(struct super_dev *fsd)
{
	kassert(fsd->m_dying && fsd->sd_ref == 0, "PUT_FINISH on a live row");
	fsd->m_dying = 0;
		rhltable_remove(fsd);			/* rhltable_remove(&super_dev_table, &fsd->sd_node, ...) */
		kassert(fsd->m_passive, "row dropped its passive ref twice");
		fsd->m_passive = 0;			/* GHOST */
		put_super(fsd->sd_sb);
		kfree_rcu(fsd, sd_rcu);
}

static int super_dev_insert(struct super_dev *fsd)
{
	int err;

	err = rhltable_insert(fsd);		/* rhltable_insert(&super_dev_table, &fsd->sd_node, ...) */
	if (!err) {
		refcount_inc(&fsd->sd_sb->s_passive);
		fsd->m_passive = 1;		/* GHOST */
	}
	return err;
}

/* Register @sb under @sb->s_dev as the final fallible act of a set callback. */
static int super_dev_register(struct super_block *sb)
{
	struct super_dev *fsd = sb->s_super_dev;
	int err;

	/* lockdep_assert_held(&sb_lock); */
	kassert(sb->s_dev, "VFS_WARN_ON_ONCE(!sb->s_dev)");
	kassert(fsd && !fsd->sd_dev, "VFS_WARN_ON_ONCE(!fsd || fsd->sd_dev)");

	fsd->sd_dev = sb->s_dev;
	err = super_dev_insert(fsd);
	if (err)
		fsd->sd_dev = 0;
	return err;
}

/*
 * MODEL: the cursor running super_dev_get().  Its wait_var_event() is a resume
 * point: going to sleep parks the passive reference in cursor_wait[cur] and
 * returns NULL; OP_CUR_WAKE calls super_dev_first()/super_dev_next() again
 * with the same arguments, which continues after the wait (put_super(), then
 * the next iteration of the do-while loop).
 *
 * CFG_UNBORN_WAIT=0 is the fc1c25014ff8 super_dev_get(): the loop pins the
 * first entry with sd_ref > 0 whatever its superblock's state, and
 * super_dev_first()/super_dev_next() wrap it in rcu_read_lock().  The text
 * and comment below are eca07e8969d8's (CFG_UNBORN_WAIT=1, not merged).
 */
static int cur;

/*
 * Pin the entry after @prev or the first one for @dev. Don't pin the entry of
 * a superblock that isn't born yet: the mount may still drop its claim on @dev
 * and the pin would make the walk act on a superblock that doesn't use @dev
 * anymore. Wait for it to be born or to die and look again. @prev stays
 * pinned and thus linked in the meantime.
 */
static struct super_dev *super_dev_get(dev_t dev, struct super_dev *prev)
{
	struct super_block *sb, *unborn;
	struct super_dev *sb_dev;
	struct super_dev *pos;			/* struct rhlist_head *pos; */
	int n;

	/* MODEL: resumed after wait_var_event() below */
	unborn = cursor_wait[cur];
	if (unborn) {
		kassert(super_flags(unborn, SB_BORN | SB_DYING),
			"cursor resumed before SB_BORN/SB_DYING");
		cursor_wait[cur] = NULL;	/* GHOST */
		put_super(unborn);
	}

	/* do { */
		unborn = NULL;
		/* scoped_guard(rcu) { */
			if (prev) {
				kassert(prev->m_used && prev->m_linked && prev->sd_ref > 0,
					"super_dev_get: @prev not pinned (unlinked or freed)");
				pos = rhl_next(prev);	/* rcu_dereference_all(prev->sd_node.next) */
			} else {
				pos = rhltable_lookup(dev);	/* rhltable_lookup(&super_dev_table, &dev, ...) */
			}

			/* for (; pos; pos = rcu_dereference_all(pos->next)) { */
			for (n = 0; pos && n < NENT; pos = rhl_next(pos), n++) {
				sb_dev = pos;	/* container_of(pos, struct super_dev, sd_node) */
				sb = sb_dev->sd_sb;
				if (!CFG_UNBORN_WAIT || super_flags(sb, SB_BORN | SB_DYING)) {
					if (refcount_inc_not_zero(&sb_dev->sd_ref))
						return sb_dev;
				} else if (refcount_inc_not_zero(&sb->s_passive)) {
					unborn = sb;
					break;
				}
			}
			kassert(!pos || unborn, "super_dev_get: chain longer than NENT");
		/* } */
		if (unborn) {
			/*
			 * wait_var_event(&unborn->s_flags,
			 *		  super_flags(unborn, SB_BORN | SB_DYING));
			 * put_super(unborn);
			 */
			cursor_wait[cur] = unborn;	/* MODEL: asleep until OP_CUR_WAKE */
			return NULL;
		}
	/* } while (unborn); */

	return NULL;
}

static struct super_dev *super_dev_first(dev_t dev)
{
	return super_dev_get(dev, NULL);
}

static struct super_dev *super_dev_next(struct super_dev *prev)
{
	struct super_dev *sb_dev = super_dev_get(prev->sd_dev, prev);

	if (cursor_wait[cur])			/* MODEL: asleep in super_dev_get() */
		return NULL;
	super_dev_put(prev);
	return sb_dev;
}

static void kill_super_notify(struct super_block *sb)
{
	/* lockdep_assert_not_held(&sb->s_umount); */

	/* already notified earlier */
	if (sb->s_flags & SB_DEAD)
		return;

	kassert(sb->s_super_dev != NULL, "kill_super_notify: NULL s_super_dev before SB_DEAD");
	/* Drop sget_fc()'s claim; a never-registered entry stays with the sb. */
	if (sb->s_super_dev->sd_dev) {
		super_dev_put(sb->s_super_dev);
		sb->s_super_dev = NULL;
	}

	/* spin_lock(&sb_lock); super_wake(sb, SB_DEAD); spin_unlock(&sb_lock); */
	sb->s_flags |= SB_DEAD;
}

static struct super_dev *super_dev_lookup(dev_t dev, struct super_block *sb)
{
	struct super_dev *it;
	int n = 0;

	kassert(dev, "VFS_WARN_ON_ONCE(!dev)");
	kassert(sb, "VFS_WARN_ON_ONCE(!sb)");

	/* list = rhltable_lookup(...); rhl_for_each_entry_rcu(it, pos, list, sd_node) { */
	for (it = rhltable_lookup(dev); it && n < NENT; it = rhl_next(it), n++) {
		if (it->sd_sb == sb)
			return it;
	}

	return NULL;
}

/* ------------------------------------------------------------------ */
/* END COPY                                                            */
/* ------------------------------------------------------------------ */

/*
 * fs_bdev_register(), super.c:1701-1732, split into the lookup (RCU), the
 * alloc+insert, and the bd_fsfreeze_count test after smp_mb().  A freeze
 * walker can pin the new row between insert and test; with !CFG_SERIAL a
 * second operation on the same pair can also run between lookup and insert.
 */
static int fs_bdev_register_lookup(struct super_block *sb, dev_t dev)
{
	struct super_dev *sb_dev = NULL;	/* __free(kfree) */

	/* scoped_guard(rcu) { */
	sb_dev = super_dev_lookup(dev, sb);
	if (sb_dev && refcount_inc_not_zero(&sb_dev->sd_ref)) {
		/* retain_and_null_ptr(sb_dev); */
		return 0;
	}
	/* } */
	return 1;				/* model: go on with the insert */
}

static int fs_bdev_register_insert(struct super_block *sb, dev_t dev, int r)
{
	struct super_dev *sb_dev = NULL;	/* __free(kfree) */
	int err;

	sb_dev = super_dev_alloc(dev, sb);
	if (!sb_dev)
		return -ENOMEM;

	err = super_dev_insert(sb_dev);
	if (err) {
		kfree(sb_dev);			/* __free(kfree) on return */
		return err;
	}
	reg_row[r] = sb_dev;
	return 0;
}

static int fs_bdev_register_check(int r)
{
	struct super_dev *sb_dev = reg_row[r];
	int err = 0;

	/* Publish the entry before reading the count; pairs with bdev_freeze(). */
	smp_mb();
	if (nondet_bool()) {		/* atomic_read(&file_bdev(bdev_file)->bd_fsfreeze_count) > 0 */
		err = -EBUSY;
		super_dev_put(sb_dev);
	}

	/* retain_and_null_ptr(sb_dev); */
	return err;
}

enum op {
	OP_SGET_SET, OP_KILL_NOTIFY, OP_PUT_SUPER, OP_REGISTER, OP_REGISTER_STEP,
	OP_UNREGISTER, OP_UNREG_LOOKUP, OP_UNREG_PUT, OP_CUR_FIRST, OP_CUR_NEXT,
	OP_CUR_TAKE, OP_DROP_SUPER, OP_PUT_FINISH, OP_BORN, OP_CUR_WAKE, OP_NR
};

/* an operation of the filesystem on (s, dev) is in flight */
static int pair_busy(int s, dev_t dev)
{
	int r, n = 0;

	for (r = 0; r < NREG; r++)
		n += reg_state[r] != RS_IDLE && reg_sb[r] == s && reg_dev[r] == dev;
	n += unreg_busy && unreg_sb == s && unreg_dev == dev;
	return n;
}

static int sb_busy(int s)
{
	int r, n = 0;

	for (r = 0; r < NREG; r++)
		n += reg_state[r] != RS_IDLE && reg_sb[r] == s;
	n += unreg_busy && unreg_sb == s;
	return n;
}

/* rows of (s, dev) that are inserted but not yet counted as a claim */
static int pair_pending(int s, dev_t dev)
{
	int r, n = 0;

	for (r = 0; r < NREG; r++)
		n += reg_state[r] == RS_CHECK && reg_sb[r] == s && reg_dev[r] == dev;
	return n;
}

/* the pair holds a claim: fs_bdev claims, sget_fc()'s, rows inserted by a pending register */
static int pair_claimed(int s, dev_t d)
{
	return claims[s][d] + (sget_claim[s] && SBP[s]->s_dev == d) + pair_pending(s, d) > 0;
}

/* after every step: a claim dropped in this step while unborn sets unborn_drop[][] */
static void track_claims(void)
{
	int s;
	dev_t d;

	for (s = 0; s < NSB; s++)
		for (d = 1; d <= NDEV; d++) {
			int now = pair_claimed(s, d);

			if (now)
				unborn_drop[s][d] = 0;
			else if (was_claimed[s][d] && !(SBP[s]->s_flags & (SB_BORN | SB_DYING)))
				unborn_drop[s][d] = 1;
			was_claimed[s][d] = now;
		}
}

/*
 * A pinned row.  The walkers act on a pinned row's superblock once their
 * super_lock()/get_active_super() succeeds, i.e. when it is born and not
 * dying, so the second assertion is "the walk acts on a superblock that no
 * longer uses the device".
 */
static void check_pin(struct super_dev *p)
{
	struct super_block *sb;

	if (!p)
		return;
	kassert(p->m_used && p->m_linked && p->sd_ref > 0,
		"cursor pin on a freed, unlinked or unreferenced super_dev");
	sb = p->sd_sb;
	if ((sb->s_flags & SB_BORN) && !(sb->s_flags & SB_DYING))
		kassert(!unborn_drop[sb_idx(sb)][p->sd_dev],
			"walk acts on a superblock that dropped its claim on the device before SB_BORN");
#if CFG_UNBORN_WAIT
	/* the unborn-wait cursor's own invariant; the fc1c25014ff8 one pins unborn entries */
	kassert(sb->s_flags & (SB_BORN | SB_DYING),
		"cursor pins the entry of a superblock that is neither born nor dying");
#endif
}

static void check_invariants(void)
{
	int s, i, c;
	dev_t d;

	for (c = 0; c < NCUR; c++) {
		check_pin(cursor[c]);
		check_pin(cursor_prev[c]);
	}

	for (i = 0; i < NENT; i++) {
		struct super_dev *e = ROW[i];

		if (!e->m_used)
			continue;
		kassert(e->sd_ref >= 0, "sd_ref < 0");
		if (e->m_linked)
			kassert(e->sd_ref > 0 || e->m_dying, "linked row with sd_ref 0 and no removal pending");
		if (e->m_linked)
			kassert(e->m_passive, "linked row without its passive ref");
		if (e->m_passive)
			kassert(!e->sd_sb->m_freed, "row points to a freed superblock");
	}

	for (s = 0; s < NSB; s++) {
		struct super_block *sb = SBP[s];
		int rows = 0, base, sleepers = 0;

		if (sb->m_state == SB_GONE || sb->m_state == SB_FRESH)
			continue;
		for (i = 0; i < NENT; i++)
			rows += ROW[i]->m_used && ROW[i]->m_passive && ROW[i]->sd_sb == sb;
		for (c = 0; c < NCUR; c++)
			sleepers += cursor_wait[c] == sb;
		base = sb->m_state != SB_RELEASED;
		kassert(sb->m_freed || sb->s_passive == base + rows + user_refs[s] + sleepers,
			"s_passive != base + rows + user_get_super refs + sleeping cursors");
		kassert(!sb->m_freed || (sb->s_passive == 0 && rows == 0 && sleepers == 0),
			"freed superblock still referenced");

		/* claims: the refs of a pair's live rows = claims + pins + in-flight */
		if (CFG_SERIAL) {
			for (d = 1; d <= NDEV; d++) {
				int refs = 0, pins = 0, want;

				for (i = 0; i < NENT; i++)
					if (ROW[i]->m_used && ROW[i]->m_linked && ROW[i]->sd_sb == sb && ROW[i]->sd_dev == d)
						refs += ROW[i]->sd_ref;
				for (c = 0; c < NCUR; c++) {
					if (cursor[c] && cursor[c]->sd_sb == sb && cursor[c]->sd_dev == d)
						pins++;
					if (cursor_prev[c] && cursor_prev[c]->sd_sb == sb && cursor_prev[c]->sd_dev == d)
						pins++;
				}
				want = claims[s][d] + (sget_claim[s] && sb->s_dev == d) + pins +
				       pair_pending(s, d);
				if (!(unreg_busy && unreg_sb == s && unreg_dev == d))
					kassert(refs == want, "row refs of a (dev, sb) pair != claims + pins");
			}
		}
	}
}

/* trace encoding of a cursor step: pinned row 0..NENT-1, 10 + sb it sleeps on, -1 walk done */
static int cur_ret(int c)
{
	int i;

	if (cursor_wait[c])
		return 10 + sb_idx(cursor_wait[c]);
	for (i = 0; i < NENT; i++)
		if (cursor[c] == ROW[i])
			return i;
	return -1;
}

/* super_dev_next() on cursor @c; asleep, @prev stays pinned in cursor_prev[] */
static void cur_next(int c, struct super_dev *prev)
{
	cur = c;
	put_from_cursor = 1;
	cursor[c] = super_dev_next(prev);
	put_from_cursor = 0;
	if (cursor_wait[c])
		cursor_prev[c] = prev;
}

int main(void)
{
	int step, s, i, c;

	/* alloc_super() for both superblocks: s_passive 1, unregistered s_super_dev */
	for (s = 0; s < NSB; s++) {
		SBP[s]->s_passive = 1;
		SBP[s]->s_super_dev = super_dev_alloc(0, SBP[s]);
		assume(SBP[s]->s_super_dev != NULL);
		SBP[s]->m_state = SB_FRESH;
	}

	for (step = 0; step < NSTEPS; step++) {
		int op = nondet_int();
		int sa = nondet_int();
		int da = nondet_int();
		int xa = nondet_int();		/* slot / row index */
		int ret = 0;
		struct super_block *sb;
		dev_t dev;

		assume(op >= 0 && op < OP_NR);
		assume(sa >= 0 && sa < NSB);
		assume(da >= 1 && da <= NDEV);
		sb = SBP[sa];
		dev = da;
		log_op[step] = op;
		log_arg[step] = sa * 10 + da;

		switch (op) {
		case OP_SGET_SET:	/* sget_fc(): set() == set_anon_super()/super_s_dev_set() */
			assume(sb->m_state == SB_FRESH);
			sb->s_dev = dev;
			ret = super_dev_register(sb);
			if (ret) {
				/* destroy_unused_super() -> destroy_super_work(): kfree(s->s_super_dev) */
				kassert(!sb->s_super_dev->sd_dev, "VFS_WARN_ON_ONCE(s->s_super_dev->sd_dev)");
				kfree(sb->s_super_dev);
				sb->s_super_dev = NULL;
				sb->m_state = SB_GONE;
				sb->m_freed = 1;
				sb->s_passive = 0;
			} else {
				sget_claim[sa] = 1;
				sb->m_state = SB_LIVE;
			}
			break;
		case OP_KILL_NOTIFY:	/* generic_shutdown_super() done; kill_super_notify(), idempotent */
			assume(sb->m_state == SB_LIVE || sb->m_state == SB_DEADST);
			assume(!(sget_claim[sa] && pair_busy(sa, sb->s_dev)));
			assume(sb->m_state == SB_DEADST || !sb_busy(sa));	/* ->kill_sb() runs after fill_super() */
			if (!(sb->s_flags & SB_DEAD))
				sget_claim[sa] = 0;
			sb->s_flags |= SB_DYING;
			kill_super_notify(sb);
			sb->m_state = SB_DEADST;
			break;
		case OP_PUT_SUPER:	/* deactivate_locked_super()'s put_super(), after ->kill_sb() */
			assume(sb->m_state == SB_DEADST);
			for (i = 1; i <= NDEV; i++)
				assume(claims[sa][i] == 0);
			assume(!sb_busy(sa));
			sb->m_state = SB_RELEASED;
			put_super(sb);
			break;
		case OP_REGISTER: {	/* fs_bdev_file_open_by_*() -> fs_bdev_register() */
			int r = reg_state[0] == RS_IDLE ? 0 : 1;

			assume(reg_state[r] == RS_IDLE);
			assume(sb->m_state == SB_LIVE);
			assume(!CFG_SERIAL || !pair_busy(sa, dev));
			ret = fs_bdev_register_lookup(sb, dev);
			if (ret == 0) {
				claims[sa][dev]++;
				break;
			}
			ret = 0;
			reg_sb[r] = sa;
			reg_dev[r] = dev;
			reg_state[r] = RS_INSERT;
			if (CFG_SERIAL) {	/* nothing on this pair can run in between */
				ret = fs_bdev_register_insert(sb, dev, r);
				reg_state[r] = ret ? RS_IDLE : RS_CHECK;
			}
			break;
		}
		case OP_REGISTER_STEP: {
			int r = xa;

			assume(r >= 0 && r < NREG && reg_state[r] != RS_IDLE);
			sb = SBP[reg_sb[r]];
			if (reg_state[r] == RS_INSERT) {
				ret = fs_bdev_register_insert(sb, reg_dev[r], r);
				reg_state[r] = ret ? RS_IDLE : RS_CHECK;
				break;
			}
			ret = fs_bdev_register_check(r);
			if (ret == 0)
				claims[reg_sb[r]][reg_dev[r]]++;
			reg_state[r] = RS_IDLE;
			break;
		}
		case OP_UNREGISTER:	/* fs_bdev_unregister(), atomic */
			assume(claims[sa][dev] > 0);
			assume(!CFG_SERIAL || !pair_busy(sa, dev));
			assume(sb->m_state == SB_LIVE || sb->m_state == SB_DEADST);
			{
				struct super_dev *sb_dev;

				rcu_read_lock();
				sb_dev = super_dev_lookup(dev, sb);
				rcu_read_unlock();
				kassert(sb_dev != NULL, "fs_bdev_unregister: claimed (dev, sb) row not found (claim leaked)");
				super_dev_put(sb_dev);
			}
			claims[sa][dev]--;
			break;
#if !CFG_SERIAL
		/*
		 * Under CFG_SERIAL the split adds nothing: between the lookup and
		 * the put only cursors and other pairs run, and neither can drop
		 * the row the caller's own claim keeps above zero.
		 */
		case OP_UNREG_LOOKUP:	/* fs_bdev_unregister(), lookup half */
			assume(claims[sa][dev] > 0 && !unreg_busy);
			assume(!CFG_SERIAL || !pair_busy(sa, dev));
			assume(sb->m_state == SB_LIVE || sb->m_state == SB_DEADST);
			rcu_read_lock();
			unreg_row = super_dev_lookup(dev, sb);
			rcu_read_unlock();
			unreg_busy = 1;
			unreg_sb = sa;
			unreg_dev = dev;
			claims[sa][dev]--;
			break;
		case OP_UNREG_PUT:	/* ... super_dev_put(sb_dev) after rcu_read_unlock() */
			assume(unreg_busy);
			kassert(unreg_row != NULL, "fs_bdev_unregister: claimed (dev, sb) row not found (claim leaked)");
			super_dev_put(unreg_row);
			unreg_busy = 0;
			break;
#endif
		case OP_CUR_FIRST:	/* fs_holder_ops walker / user_get_super(): super_dev_first() */
			c = 0;
			assume(cursor[c] == NULL && !cursor_taken[c]);
			assume(cursor_wait[c] == NULL && cursor_prev[c] == NULL);
			cur = c;
			cursor_dev[c] = dev;
			cursor[c] = super_dev_first(dev);
			ret = cur_ret(c);
			break;
		case OP_CUR_NEXT:	/* super_dev_next() */
			c = 0;
			assume(cursor[c] != NULL);
			cur_next(c, cursor[c]);
			ret = cur_ret(c);
			break;
		case OP_CUR_WAKE: {	/* super_dev_get()'s wait_var_event() returns */
			struct super_dev *prev;
			int dropped;

			c = 0;
			sb = cursor_wait[c];
			assume(sb != NULL);
			/* super_wake(SB_BORN or SB_DYING) -> wake_up_var() */
			assume(sb->s_flags & (SB_BORN | SB_DYING));
			log_arg[step] = 200 + sb_idx(sb);
			prev = cursor_prev[c];
			dropped = unborn_drop[sb_idx(sb)][cursor_dev[c]];
			if (prev) {
				cursor_prev[c] = NULL;
				cur_next(c, prev);
			} else {
				cur = c;
				cursor[c] = super_dev_first(cursor_dev[c]);
			}
			ret = cur_ret(c);
			reach(!prev && dropped, "super_dev_first() resumes after the unborn sb dropped its claim");
			reach(prev && dropped, "super_dev_next() resumes after the unborn sb dropped its claim");
			reach(prev && cursor[c], "super_dev_next() resumes and pins a later entry");
			reach(sb->m_freed, "the resumed cursor dropped the superblock's last passive ref");
			reach(cursor_wait[c] != NULL, "the resumed cursor sleeps again");
			break;
		}
		case OP_BORN:		/* vfs_get_tree(): fill_super() returned 0, super_wake(sb, SB_BORN) */
			assume(sb->m_state == SB_LIVE && !(sb->s_flags & SB_BORN));
			assume(!sb_busy(sa));	/* fill_super()'s own registrations have returned */
			sb->s_flags |= SB_BORN;
			break;
		case OP_CUR_TAKE:	/* user_get_super(): super_lock() ok, refcount_inc(); super_dev_put() */
			c = 0;
			assume(cursor[c] != NULL);
			sb = cursor[c]->sd_sb;
			/* super_lock() waits for SB_BORN or SB_DYING and fails on SB_DYING */
			assume(sb->m_state == SB_LIVE && (sb->s_flags & SB_BORN));
			/* The pinned entry holds a passive reference, take our own. */
			refcount_inc(&sb->s_passive);
			user_refs[sb_idx(sb)]++;
			put_from_cursor = 1;
			super_dev_put(cursor[c]);
			put_from_cursor = 0;
			cursor[c] = NULL;
			cursor_taken[c] = 1;
			cursor_sb[c] = sb;
			break;
		case OP_DROP_SUPER:	/* drop_super(): put_super() */
			c = 0;
			assume(cursor_taken[c]);
			sb = cursor_sb[c];
			user_refs[sb_idx(sb)]--;
			put_super(sb);
			cursor_taken[c] = 0;
			break;
		case OP_PUT_FINISH:	/* tail of super_dev_put() */
			assume(CFG_DYING_WINDOW && xa >= 0 && xa < NENT);
			assume(ROW[xa]->m_used && ROW[xa]->m_dying);
			log_arg[step] = 100 + xa;
			super_dev_put_finish(ROW[xa]);
			break;
		default:		/* compiled out in this configuration */
			assume(0);
		}
		log_ret[step] = ret;
		track_claims();
		check_invariants();
	}

	/* quiescent end state: everything released */
	for (s = 0; s < NSB; s++)
		assume(SBP[s]->m_state == SB_FRESH || SBP[s]->m_state == SB_GONE ||
		       SBP[s]->m_state == SB_RELEASED);
	for (s = 0; s < NSB; s++)
		assume(!sb_busy(s) && user_refs[s] == 0);
	for (c = 0; c < NCUR; c++)
		assume(cursor[c] == NULL && !cursor_taken[c] &&
		       cursor_wait[c] == NULL && cursor_prev[c] == NULL);
	for (i = 0; i < NENT; i++)
		assume(!ROW[i]->m_dying);

	for (i = 0; i < NENT; i++) {
		kassert(!ROW[i]->m_linked, "quiescent: table not empty");
		kassert(!ROW[i]->m_used || (ROW[i]->sd_sb->m_state == SB_FRESH && ROW[i]->sd_sb->s_super_dev == ROW[i]),
			"quiescent: super_dev leaked");
	}
	for (s = 0; s < NSB; s++)
		if (SBP[s]->m_state == SB_RELEASED)
			kassert(SBP[s]->m_freed && SBP[s]->s_passive == 0, "quiescent: superblock not freed");
	return 0;
}

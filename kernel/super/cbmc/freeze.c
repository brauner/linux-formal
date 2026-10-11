// SPDX-License-Identifier: GPL-2.0
/*
 * freeze.c - CBMC harness for the freeze/thaw state machine of one
 * superblock (fs/super.c @ fc1c25014ff8).
 *
 * Concurrency is a nondeterministic sequence of NSTEPS atomic steps.  A step
 * either starts one caller operation or resumes one that is asleep with
 * s_umount dropped (freeze_super() at sb_wait_write(SB_FREEZE_WRITE), or in
 * wait_for_partially_frozen()).  Up to NSLOT freezers can be asleep at once.
 *
 * Callers, with the flags they really pass (git grep at fc1c25014ff8):
 *
 *   FIFREEZE  ioctl_fsfreeze()           freeze_super(USERSPACE, NULL)
 *             (also gfs2 sysfs freeze=1, gfs2_freeze_func())
 *   FITHAW    ioctl_fsthaw()             thaw_super(USERSPACE, NULL)
 *             (also gfs2 sysfs freeze=0, xfs_dax_notify_failure_thaw()'s
 *             unconditional thaw_super(USERSPACE), gfs2_freeze_func())
 *   KFREEZE   xchk_fsfreeze(), xfs_dax_notify_failure_freeze(),
 *             btrfs_ioctl_shutdown(), f2fs_ioc_resize_fs():
 *                                        freeze_super(KERNEL, NULL)
 *   KTHAW     their thaws                thaw_super(KERNEL, NULL)
 *   PMFREEZE  filesystems_freeze_callback() (suspend/hibernate):
 *             get_active_super(); freeze_super(EXCL|KERNEL, filesystems_freeze_ptr)
 *             skipped unless freeze_filesystems=1 or FS_POWER_FREEZE (efivarfs)
 *   PMTHAW    filesystems_thaw_callback(), on every resume, for every sb with
 *             ->freeze_fs: thaw_super(EXCL|KERNEL, filesystems_freeze_ptr)
 *   BDEVFREEZE bdev_freeze() -> fs_bdev_freeze() -> freeze_super(MAY_NEST|USERSPACE, NULL)
 *             (dm suspend, ext4/xfs/f2fs/exfat/ntfs/ntfs3 shutdown ioctls)
 *   BDEVTHAW  bdev_thaw() -> fs_bdev_thaw() -> thaw_super(MAY_NEST|USERSPACE, NULL)
 *   EMERG1/2  do_thaw_all_callback(): bdev_thaw(sb->s_bdev) loop, then
 *             thaw_super_locked(USERSPACE, NULL)
 *   REMOUNT   reconfigure_super(): flips SB_RDONLY, -EBUSY unless SB_UNFROZEN
 *   FSERR_RO  (CFG_FS_ERROR_RO) a filesystem error path doing
 *             sb->s_flags |= SB_RDONLY without s_umount (fat, exfat, ext2,
 *             hfs, hfsplus, affs, jfs, nilfs2, ...)
 *   UMOUNT/MOUNT  drop/take a struct mount's active reference
 *
 * The superblock may use up to NDEV block devices (data + log/member), each
 * of which can be frozen through the block layer.
 */
#include "kernel_freeze.h"

#ifndef NSTEPS
#define NSTEPS 6
#endif
#define NSLOT 2
#define NDEV 2

#ifndef CFG_ANON_US_THAW
#define CFG_ANON_US_THAW 0	/* USERSPACE thaws by callers that hold no USERSPACE freeze */
#endif
#ifndef CFG_EMERGENCY
#define CFG_EMERGENCY 0		/* SysRq-j */
#endif
#ifndef CFG_FS_ERROR_RO
#define CFG_FS_ERROR_RO 0
#endif
#ifndef CFG_PM
#define CFG_PM 1		/* filesystems_freeze()/filesystems_thaw() */
#endif
#ifndef CFG_K
#define CFG_K 1			/* in-kernel KERNEL freezer (xfs scrub, btrfs/f2fs ioctls) */
#endif
#ifndef CFG_BDEV
#define CFG_BDEV 1		/* bdev_freeze()/bdev_thaw() */
#endif
#ifndef CFG_MULTIDEV
#define CFG_MULTIDEV 1		/* the sb may use a second (log/member) device */
#endif
#ifndef CFG_REMOUNT
#define CFG_REMOUNT 1
#endif
#ifndef CFG_MOUNTS
#define CFG_MOUNTS 1
#endif
#ifndef CHECK_ACCOUNTING
#define CHECK_ACCOUNTING 1	/* attribute every hold to a caller (needs !ANON && !EMERGENCY) */
#endif

static struct super_block SB;
/*
 * Separate objects, not arrays: a pointer with a two-element value set is a
 * cheap mux for CBMC, a symbolic index into an array of structs is not.
 */
static struct block_device BDEV0, BDEV1;
static int ndev;

static struct block_device *bdev_of(int d)
{
	return d ? &BDEV1 : &BDEV0;
}

/* ghost: callers and what they believe they hold */
static int mounts;		/* struct mounts (each holds an active ref) */
static int fif_hold;		/* FIFREEZE returned 0, matching FITHAW not yet 0 */
static int kh;			/* in-kernel freezer holds its KERNEL freeze */
static int pm_hold;		/* filesystems_freeze() froze this sb */
static int pm_cycle;		/* between filesystems_freeze() and filesystems_thaw() */
static int believers[NDEV];	/* bdev_freeze()==0 callers that have not called bdev_thaw() */
static int devheld[NDEV];	/* the sb holds a USERSPACE freeze on behalf of device d */
static int orphan_u;		/* USERSPACE holds left by a bdev_freeze() that failed */
static int emerg_busy;		/* emergency thaw between its two steps */
static int emerg_ref;		/* ... and the active ref it holds meanwhile */

/* operation log, for condensed traces */
static int log_op[NSTEPS];
static int log_arg[NSTEPS];
static int log_ret[NSTEPS];

enum op {
	OP_FIFREEZE, OP_FITHAW, OP_KFREEZE, OP_KTHAW, OP_PMFREEZE, OP_PMTHAW,
	OP_BDEVFREEZE, OP_BDEVTHAW, OP_EMERG1, OP_EMERG2, OP_REMOUNT,
	OP_FSERR_RO, OP_UMOUNT, OP_MOUNT, OP_RESUME, OP_NR
};

enum caller { C_NONE = 0, C_FIFREEZE, C_KFREEZE, C_PMFREEZE, C_BDEVFREEZE };

struct frame {
	int		caller;
	int		caller_ref;	/* get_active_super() ref of the caller */
	int		dev;
	struct freezer	f;		/* C_FIFREEZE, C_KFREEZE, C_PMFREEZE */
	struct bdev_walk w;		/* C_BDEVFREEZE */
};

static struct frame FR0, FR1;

static struct frame *fr_of(int j)
{
	return j ? &FR1 : &FR0;
}

static void model_release_claims(struct super_block *sb)
{
	/* kill_block_super() and the fs's ->kill_sb() release every claim */
	BDEV0.sd_linked[0] = 0;
	BDEV1.sd_linked[0] = 0;
	sb->m_registered = 0;
}

static bool freezer_runnable(const struct freezer *f, bool killed)
{
	if (f->pc == FPC_WFPF)
		return f->sb->s_writers.frozen != f->old || (CFG_KILL_WAIT && killed);
	return true;
}

static bool frame_runnable(const struct frame *fr, bool killed)
{
	if (fr->caller == C_BDEVFREEZE)
		return fr->w.pc != BPC_IN_SB || freezer_runnable(&fr->w.f, killed);
	return freezer_runnable(&fr->f, killed);
}

/* active refs held by one operation that is asleep between steps */
static int frame_refs(const struct frame *fr)
{
	int n;

	if (fr->caller == C_NONE)
		return 0;
	n = fr->caller_ref;
	if (fr->caller == C_BDEVFREEZE) {
		if (fr->w.pc == BPC_IN_SB)
			n += 1 + (fr->w.f.pc != FPC_START);	/* get_active_super + freeze_super's inc */
	} else if (fr->f.pc != FPC_START) {
		n += 1;						/* freeze_super's atomic_inc() */
	}
	return n;
}

static int inflight_refs(void)
{
	return emerg_ref + frame_refs(&FR0) + frame_refs(&FR1);
}

static int frames_of(int caller)
{
	return (FR0.caller == caller) + (FR1.caller == caller);
}

static int bdev_frame_on(int d)
{
	return (FR0.caller == C_BDEVFREEZE && FR0.dev == d) +
	       (FR1.caller == C_BDEVFREEZE && FR1.dev == d);
}

static void check_invariants(void)
{
	struct super_block *sb = &SB;
	int k = sb->s_writers.freeze_kcount, u = sb->s_writers.freeze_ucount;
	int complete = sb->s_writers.frozen == SB_FREEZE_COMPLETE;
	int d;

	check_sb_invariants(sb, mounts + (complete ? 1 : 0) + inflight_refs());

	/* EXCL: filesystems_freeze()'s hold is protected by the owner */
	if (!sb->m_dead) {
		kassert((sb->s_writers.freeze_owner == filesystems_freeze_ptr) == (pm_hold == 1),
			"EXCL: freeze_owner does not match the outstanding filesystems_freeze() hold");
		kassert(!pm_hold || (complete && k >= 1),
			"EXCL: filesystems_freeze() hold undone by someone else");
	}

	/* block layer view */
	for (d = 0; d < NDEV; d++) {
		struct block_device *bdev = bdev_of(d);

		if (d >= ndev)
			continue;

		kassert(bdev->bd_fsfreeze_count <= believers[d] + bdev_frame_on(d),
			"bd_fsfreeze_count stuck above the number of bdev_freeze() holders");
		if (!CFG_EMERGENCY)	/* emergency thaw drops counts behind the holders' backs, by design */
			kassert(bdev->bd_fsfreeze_count >= believers[d] + bdev_frame_on(d),
				"bd_fsfreeze_count below the number of bdev_freeze() holders");
		if (!CFG_EMERGENCY && believers[d] > 0 && bdev->sd_linked[0])
			kassert(complete && u >= 1,
				"bdev_freeze() holder exists but the sb is thawed / has no USERSPACE hold");
	}

	kassert(orphan_u == 0, "failed bdev_freeze() left the sb frozen with an orphaned hold");

	if (CHECK_ACCOUNTING && !sb->m_dead) {
		kassert(k == pm_hold + kh, "kernel holds != kernel freezers");
		kassert(u == fif_hold + devheld[0] + devheld[1] + orphan_u,
			"userspace holds != FIFREEZE + bdev holders");
	}
}

int main(void)
{
	int step, d, j;

	/* ---- initial state: one born, mounted, unfrozen superblock ---- */
	SB.s_flags = SB_BORN | SB_ACTIVE | (nondet_bool() ? SB_RDONLY : 0);
	SB.s_active = 1;
	SB.s_op = nondet_bool() ? &ops_freeze_fs : &ops_no_freeze_fs;
	SB.m_registered = 1;
	mounts = 1;
	ndev = (CFG_BDEV && CFG_MULTIDEV && nondet_bool()) ? 2 : 1;
	BDEV0.bd_holder_ops = 1;
	BDEV0.nsd = 1;
	BDEV0.sd_sb[0] = &SB;
	BDEV0.sd_linked[0] = 1;
	BDEV1.bd_holder_ops = 1;
	BDEV1.nsd = 1;
	BDEV1.sd_sb[0] = &SB;
	BDEV1.sd_linked[0] = ndev > 1;

	for (step = 0; step < NSTEPS; step++) {
		int op = nondet_int();
		int arg = nondet_int();
		bool killed = nondet_bool();
		int ret = 0;
		struct frame *run = NULL;
		int new_frame = 0;

		assume(op >= 0 && op < OP_NR);
		log_op[step] = op;

		switch (op) {
		case OP_FIFREEZE:	/* ioctl_fsfreeze() */
			assume(mounts > 0 && !SB.m_dead);
			if (SB.s_op->freeze_fs == NULL) {	/* && ->freeze_super == NULL */
				ret = -EOPNOTSUPP;
				break;
			}
			new_frame = C_FIFREEZE;
			break;
		case OP_FITHAW: {	/* ioctl_fsthaw() and the other thaw_super(USERSPACE) callers */
			int owned = fif_hold > 0;

			assume(mounts > 0 && !SB.m_dead);
			assume(owned || CFG_ANON_US_THAW);
			log_arg[step] = owned;
			ret = checked_thaw_super(&SB, FREEZE_HOLDER_USERSPACE, NULL);
			if (owned && ret == 0)
				fif_hold--;
			break;
		}
#if CFG_K
		case OP_KFREEZE:
			assume(mounts > 0 && !SB.m_dead && !kh && !frames_of(C_KFREEZE));
			assume(SB.s_op->freeze_fs != NULL);	/* xfs, btrfs, f2fs */
			new_frame = C_KFREEZE;
			break;
		case OP_KTHAW:
			assume(mounts > 0 && kh);
			ret = checked_thaw_super(&SB, FREEZE_HOLDER_KERNEL, NULL);
			if (ret == 0)
				kh = 0;
			break;
#endif
#if CFG_PM
		case OP_PMFREEZE:	/* filesystems_freeze_callback() */
			assume(CFG_PM && !pm_cycle && !SB.m_dead);
			pm_cycle = 1;
			if (!SB.s_op->freeze_fs)
				break;
			if (nondet_bool()) {	/* !freeze_all && !(fs_flags & FS_POWER_FREEZE) */
				log_arg[step] = 1;
				break;
			}
			if (!get_active_super(&SB))
				break;
			new_frame = C_PMFREEZE;
			break;
		case OP_PMTHAW:		/* filesystems_thaw_callback() */
			assume(CFG_PM && pm_cycle && !frames_of(C_PMFREEZE));
			pm_cycle = 0;
			if (SB.m_dead || !SB.s_op->freeze_fs)
				break;
			if (!get_active_super(&SB))
				break;
			ret = checked_thaw_super(&SB, FREEZE_EXCL | FREEZE_HOLDER_KERNEL,
						 filesystems_freeze_ptr);
			deactivate_super(&SB);
			if (ret == 0)
				pm_hold = 0;
			break;
#endif
#if CFG_BDEV
		case OP_BDEVFREEZE:
			assume(arg >= 0 && arg < ndev);
			assume(!bdev_of(arg)->bd_fsfreeze_mutex && believers[arg] < 2);
			log_arg[step] = arg;
			new_frame = C_BDEVFREEZE;
			break;
		case OP_BDEVTHAW: {
			struct bdev_walk w = { 0 };

			assume(arg >= 0 && arg < ndev);
			assume(!bdev_of(arg)->bd_fsfreeze_mutex && believers[arg] > 0);
			log_arg[step] = arg;
			w.bdev = bdev_of(arg);
			bdev_thaw_co(&w);	/* one row: never yields */
			ret = w.ret;
			/* dm's unlock_fs() and the shutdown ioctls ignore the result */
			believers[arg]--;
			if (w.holder_ran && w.res[0] == R_OK)
				devheld[arg] = 0;
			break;
		}
#endif
#if CFG_EMERGENCY && CFG_BDEV
		case OP_EMERG1: {	/* do_thaw_all_callback(), first half */
			int it;

			assume(CFG_EMERGENCY && !emerg_busy && !SB.m_dead);
			assume(!BDEV0.bd_fsfreeze_mutex);
			if (!get_active_super(&SB))
				break;
			emerg_busy = 1;
			emerg_ref = 1;
			/* while (sb->s_bdev && !bdev_thaw(sb->s_bdev)) */
			for (it = 0; it < 3; it++) {
				struct bdev_walk w = { 0 };

				w.bdev = &BDEV0;
				bdev_thaw_co(&w);
				if (w.ret)
					break;
				if (w.holder_ran && w.res[0] == R_OK)
					devheld[0] = 0;
			}
			kassert(it < 3, "emergency thaw loop bound");
			break;
		}
		case OP_EMERG2:		/* do_thaw_all_callback(), second half */
			assume(emerg_busy);
			if (super_lock_excl(&SB))
				ret = checked_thaw_super_locked(&SB, FREEZE_HOLDER_USERSPACE, NULL);
			deactivate_super(&SB);
			emerg_busy = 0;
			emerg_ref = 0;
			break;
#endif
#if CFG_REMOUNT
		case OP_REMOUNT:	/* reconfigure_super() under s_umount */
			assume(CFG_REMOUNT && mounts > 0 && !SB.m_dead);
			down_write(&SB.s_umount);
			if (SB.s_writers.frozen != SB_UNFROZEN) {
				ret = -EBUSY;
			} else if (nondet_bool()) {
				SB.s_flags |= SB_RDONLY;
			} else {
				SB.s_flags &= ~SB_RDONLY;
			}
			up_write(&SB.s_umount);
			break;
#endif
#if CFG_FS_ERROR_RO
		case OP_FSERR_RO:
			assume(CFG_FS_ERROR_RO && !SB.m_dead);
			SB.s_flags |= SB_RDONLY;
			break;
#endif
#if CFG_MOUNTS
		case OP_UMOUNT:
			/* an fd keeps its mount: no ioctl in flight or holding a freeze */
			assume(CFG_MOUNTS && mounts > 0 && !kh &&
			       !frames_of(C_FIFREEZE) && !frames_of(C_KFREEZE));
			mounts--;
			deactivate_super(&SB);
			break;
		case OP_MOUNT:		/* sget_fc() -> grab_super() on the extant sb */
			assume(CFG_MOUNTS && mounts < 2 && !SB.m_dead);
			if (super_lock_excl(&SB)) {
				if (atomic_inc_not_zero(&SB.s_active))
					mounts++;
				super_unlock_excl(&SB);
			}
			break;
#endif
		case OP_RESUME:
			assume(arg >= 0 && arg < NSLOT);
			assume(fr_of(arg)->caller != C_NONE && frame_runnable(fr_of(arg), killed));
			log_arg[step] = arg;
			run = fr_of(arg);
			break;
		default:			/* operation compiled out in this configuration */
			assume(0);
		}

		if (new_frame) {
			j = FR0.caller == C_NONE ? 0 : 1;
			assume(fr_of(j)->caller == C_NONE);
			run = fr_of(j);
			run->caller = new_frame;
			run->caller_ref = new_frame == C_PMFREEZE;
			run->f.pc = FPC_START;
			run->f.sb = &SB;
			run->f.freeze_owner = NULL;
			if (new_frame == C_FIFREEZE)
				run->f.who = FREEZE_HOLDER_USERSPACE;
			else if (new_frame == C_KFREEZE)
				run->f.who = FREEZE_HOLDER_KERNEL;
			else if (new_frame == C_PMFREEZE) {
				run->f.who = FREEZE_EXCL | FREEZE_HOLDER_KERNEL;
				run->f.freeze_owner = filesystems_freeze_ptr;
			} else {
				struct bdev_walk w0 = { 0 };

				run->w = w0;
				run->dev = arg;
				run->w.bdev = bdev_of(arg);
			}
		}

		if (run) {
			int done;

#if CFG_BDEV
			if (run->caller == C_BDEVFREEZE)
				done = bdev_freeze_co(&run->w, killed);
			else
#endif
				done = run_freezer(&run->f, killed);

			if (done) {
				switch (run->caller) {
				case C_FIFREEZE:
					ret = run->f.ret;
					if (ret == 0)
						fif_hold++;
					break;
				case C_KFREEZE:
					ret = run->f.ret;
					if (ret == 0)
						kh = 1;
					break;
				case C_PMFREEZE:	/* return value ignored by the caller */
					ret = run->f.ret;
					deactivate_super(&SB);
					if (ret == 0)
						pm_hold = 1;
					break;
				case C_BDEVFREEZE:
					ret = run->w.ret;
					d = run->dev;
					if (ret == 0)
						believers[d]++;
					if (run->w.holder_ran && run->w.res[0] == R_OK) {
						if (ret == 0)
							devheld[d] = 1;
						else
							orphan_u++;
					}
					break;
				}
				run->caller = C_NONE;
			}
		}
		log_ret[step] = ret;

		check_invariants();
	}
	return 0;
}

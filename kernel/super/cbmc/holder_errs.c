// SPDX-License-Identifier: GPL-2.0
/*
 * holder_errs.c - CBMC harness for fs_bdev_freeze()/fs_bdev_thaw() error
 * aggregation over 1..3 superblocks on one block device, combined with
 * bdev_freeze()/bdev_thaw()'s bd_fsfreeze_count (block/bdev.c) and
 * bdev_deny_freeze()/bdev_allow_freeze() (fs/super.c, block/bdev.c @
 * fc1c25014ff8; the copied code is in kernel_freeze.h).
 *
 * Only erofs registers one device for several superblocks in-tree (blob
 * devices opened with holder = sb->s_type); erofs superblocks are always
 * SB_RDONLY.  The harness does not assume that: per superblock it picks
 * ->freeze_fs present or not and SB_RDONLY or not, so the generic
 * aggregation logic is checked; the results say which outcomes need a
 * writable shared superblock.
 *
 * Steps: the bdev freeze and thaw walks resume between rows (only
 * bd_fsfreeze_mutex is held there) and inside freeze_super() (with
 * s_umount dropped).  A FIFREEZE on one of the superblocks can be in flight
 * at the same time, so the walk's freeze_super() can wait for it in
 * wait_for_partially_frozen().  Emergency thaw runs as one atomic step
 * (its bdev_thaw() loop and its thaw_super_locked()), an
 * under-approximation of its interleavings.
 */
#include "kernel_freeze.h"

#ifndef NSTEPS
#define NSTEPS 8
#endif
#ifndef NSB
#define NSB 3			/* superblocks on the device: nondeterministic 1..NSB */
#endif

#ifndef CFG_ANON_US_THAW
#define CFG_ANON_US_THAW 0	/* USERSPACE thaws by callers without a USERSPACE freeze */
#endif
#ifndef CFG_EMERGENCY
#define CFG_EMERGENCY 0
#endif
#ifndef CFG_DENY
#define CFG_DENY 1
#endif
#ifndef CFG_UMOUNT
#define CFG_UMOUNT 1
#endif
#ifndef CFG_SHARED_RDONLY
#define CFG_SHARED_RDONLY 0	/* in-tree shape: a shared device's sbs are erofs (SB_RDONLY, no ->freeze_fs) */
#endif

static struct super_block SB0, SB1, SB2;
static struct block_device BDEV;
static int nsb;			/* rows on the device */
static int sb0_main;		/* SB0->s_bdev == &BDEV (emergency thaw walks it) */

/* ghost */
static int mounts[NSB];
static int fif[NSB];		/* FIFREEZE()==0 not yet matched by FITHAW()==0 */
static int devheld[NSB];	/* sb i holds the device's MAY_NEST|USERSPACE freeze */
static int believers;		/* bdev_freeze()==0 callers that have not called bdev_thaw() */
static int deniers;		/* bdev_deny_freeze()==0 not yet allowed */

/* in-flight operations */
static int wf_busy, wt_busy;	/* bdev freeze / thaw walk */
static struct bdev_walk WF, WT;
static int ff_busy, ff_sb;	/* FIFREEZE asleep in freeze_super() */
static struct freezer FF;

static int log_op[NSTEPS], log_arg[NSTEPS], log_ret[NSTEPS];

enum op {
	OP_BDEVFREEZE, OP_BDEVTHAW, OP_RESUME, OP_FIFREEZE, OP_FITHAW,
	OP_EMERG, OP_UMOUNT, OP_DENY, OP_ALLOW, OP_NR
};

static struct super_block *sb_of(int i)
{
	return i == 0 ? &SB0 : i == 1 ? &SB1 : &SB2;
}

static int idx_of(const struct super_block *sb)
{
	return sb == &SB0 ? 0 : sb == &SB1 ? 1 : 2;
}

static void model_release_claims(struct super_block *sb)
{
	BDEV.sd_linked[idx_of(sb)] = 0;		/* the fs releases its claim in ->kill_sb() */
	sb->m_registered = 0;
}

static bool freezer_runnable(const struct freezer *f, bool killed)
{
	if (f->pc == FPC_WFPF)
		return f->sb->s_writers.frozen != f->old || (CFG_KILL_WAIT && killed);
	return true;
}

static int inflight_refs(int i)
{
	int n = 0;

	if (wf_busy && WF.pc == BPC_IN_SB && WF.i == i)
		n += 1 + (WF.f.pc != FPC_START);	/* get_active_super() + freeze_super()'s inc */
	if (ff_busy && ff_sb == i && FF.pc != FPC_START)
		n += 1;
	return n;
}

static void check_invariants(void)
{
	int i;

	for (i = 0; i < NSB; i++) {
		struct super_block *sb = sb_of(i);
		int complete = sb->s_writers.frozen == SB_FREEZE_COMPLETE;

		if (i >= nsb)
			continue;
		check_sb_invariants(sb, mounts[i] + complete + inflight_refs(i));
		if (!CFG_ANON_US_THAW && !CFG_EMERGENCY && !sb->m_dead)
			kassert(sb->s_writers.freeze_ucount == fif[i] + devheld[i],
				"userspace holds of an sb != FIFREEZE + device hold");
		/* the device believes it froze sb i: sb i must still be frozen */
		if (!CFG_EMERGENCY && devheld[i] && !sb->m_dead)
			kassert(complete && sb->s_writers.freeze_ucount >= 1,
				"device hold recorded but the sb is thawed");
	}
	kassert(BDEV.bd_fsfreeze_count <= believers - deniers + wf_busy,
		"bd_fsfreeze_count stuck above the bdev_freeze() holders");
	if (!CFG_EMERGENCY)
		kassert(BDEV.bd_fsfreeze_count >= believers - deniers + wf_busy,
			"bd_fsfreeze_count below the bdev_freeze() holders");
}

int main(void)
{
	int step, i;

	nsb = nondet_int();
	assume(nsb >= 1 && nsb <= NSB);
	sb0_main = nondet_bool();
	BDEV.bd_holder_ops = 1;
	BDEV.nsd = nsb;
	for (i = 0; i < NSB; i++) {
		struct super_block *sb = sb_of(i);

		sb->s_flags = SB_BORN | SB_ACTIVE | (nondet_bool() ? SB_RDONLY : 0);
		sb->s_active = 1;
		sb->s_op = nondet_bool() ? &ops_freeze_fs : &ops_no_freeze_fs;
		if (CFG_SHARED_RDONLY && nsb > 1) {
			sb->s_flags |= SB_RDONLY;
			sb->s_op = &ops_no_freeze_fs;
		}
		sb->m_registered = i < nsb;
		mounts[i] = 1;
		BDEV.sd_sb[i] = sb;
		BDEV.sd_linked[i] = i < nsb;
	}

	for (step = 0; step < NSTEPS; step++) {
		int op = nondet_int();
		int arg = nondet_int();
		bool killed = nondet_bool();
		bool pick_ff = nondet_bool();	/* OP_RESUME: which in-flight operation */
		int ret = 0;
		struct super_block *sb;

		assume(op >= 0 && op < OP_NR);
		assume(arg >= 0 && arg < nsb);
		sb = sb_of(arg);
		log_op[step] = op;
		log_arg[step] = arg;

		switch (op) {
		case OP_BDEVFREEZE: {
			struct bdev_walk w0 = { 0 };

			assume(!BDEV.bd_fsfreeze_mutex && !wf_busy && !wt_busy && believers < 2);
			WF = w0;
			WF.bdev = &BDEV;
			WF.yield_between = 1;
			wf_busy = 1;
			break;
		}
		case OP_BDEVTHAW: {
			struct bdev_walk w0 = { 0 };

			assume(!BDEV.bd_fsfreeze_mutex && !wf_busy && !wt_busy && believers > 0);
			WT = w0;
			WT.bdev = &BDEV;
			WT.yield_between = 1;
			wt_busy = 1;
			break;
		}
		case OP_RESUME:
			assume(wf_busy || wt_busy || ff_busy);
			break;
		case OP_FIFREEZE:	/* ioctl_fsfreeze() */
			assume(!ff_busy && mounts[arg] > 0 && !sb->m_dead);
			if (!sb->s_op->freeze_fs) {
				ret = -EOPNOTSUPP;
				break;
			}
			FF.pc = FPC_START;
			FF.sb = sb;
			FF.who = FREEZE_HOLDER_USERSPACE;
			FF.freeze_owner = NULL;
			ff_busy = 1;
			ff_sb = arg;
			break;
		case OP_FITHAW: {	/* ioctl_fsthaw() and friends */
			int owned = fif[arg] > 0;

			assume(mounts[arg] > 0 && !sb->m_dead);
			assume(owned || CFG_ANON_US_THAW);
			ret = checked_thaw_super(sb, FREEZE_HOLDER_USERSPACE, NULL);
			if (owned && ret == 0)
				fif[arg]--;
			break;
		}
		case OP_EMERG: {	/* do_thaw_all_callback(sb), one atomic step */
			int it;

			assume(CFG_EMERGENCY && !sb->m_dead && !BDEV.bd_fsfreeze_mutex);
			if (!get_active_super(sb))
				break;
			if (arg == 0 && sb0_main) {
				/* while (sb->s_bdev && !bdev_thaw(sb->s_bdev)) */
				for (it = 0; it < 3; it++) {
					struct bdev_walk w = { 0 };
					int r;

					w.bdev = &BDEV;
					w.yield_between = 0;
					bdev_thaw_co(&w);
					if (w.ret)
						break;
					if (w.holder_ran)
						for (r = 0; r < NSB; r++)
							if (w.res[r] == R_OK)
								devheld[r] = 0;
				}
				kassert(it < 3, "emergency thaw loop bound");
			}
			if (super_lock_excl(sb))
				ret = checked_thaw_super_locked(sb, FREEZE_HOLDER_USERSPACE, NULL);
			deactivate_super(sb);
			break;
		}
		case OP_UMOUNT:
			assume(CFG_UMOUNT && mounts[arg] > 0 && !(ff_busy && ff_sb == arg));
			mounts[arg]--;
			deactivate_super(sb);
			break;
		case OP_DENY:		/* bdev_deny_freeze() (btrfs device add/remove/replace) */
			assume(CFG_DENY && deniers < 1);
			/* return atomic_dec_unless_positive(&bdev->bd_fsfreeze_count) ? 0 : -EBUSY; */
			if (BDEV.bd_fsfreeze_count <= 0) {
				BDEV.bd_fsfreeze_count--;
				deniers++;
				ret = 0;
			} else {
				ret = -EBUSY;
			}
			break;
		case OP_ALLOW:		/* bdev_allow_freeze() */
			assume(deniers > 0);
			/* A deny must be held, i.e. the count must be negative. */
			WARN_ON_ONCE(W_ALLOW_FREEZE, atomic_read(&BDEV.bd_fsfreeze_count) >= 0);
			atomic_inc(&BDEV.bd_fsfreeze_count);
			deniers--;
			break;
		}

		/* run (or resume) at most one in-flight operation per step */
		if (op == OP_RESUME)
			assume(pick_ff ? ff_busy : (wf_busy || wt_busy));
		if (op == OP_BDEVFREEZE || (op == OP_RESUME && !pick_ff && wf_busy)) {
			assume(WF.pc != BPC_IN_SB || freezer_runnable(&WF.f, killed));
			if (bdev_freeze_co(&WF, killed)) {
				ret = WF.ret;
				if (ret == 0)
					believers++;
				for (i = 0; i < NSB; i++) {
					if (!WF.holder_ran || i >= nsb)
						continue;
					if (ret == 0) {
						if (WF.res[i] == R_OK)
							devheld[i] = 1;
						/* every superblock alive at the walk got the hold */
						kassert(WF.res[i] != R_ERR,
							"bdev_freeze()==0 but a live sb on the device is not frozen (swallowed error)");
					} else {
						kassert(WF.res[i] != R_OK,
							"bdev_freeze() failed but left an sb frozen with an orphaned hold");
						if (WF.res[i] == R_OK)
							devheld[i] = 1;		/* keep the accounting honest */
					}
				}
				wf_busy = 0;
			}
		} else if (op == OP_BDEVTHAW || (op == OP_RESUME && !pick_ff && wt_busy)) {
			if (bdev_thaw_co(&WT)) {
				ret = WT.ret;
				/* dm's unlock_fs() and the shutdown ioctls ignore the result */
				believers--;
				for (i = 0; i < NSB; i++) {
					if (!WT.holder_ran || i >= nsb)
						continue;
					if (WT.res[i] == R_OK)
						devheld[i] = 0;
					/* (a stolen hold leaves devheld set: only meaningful without anonymous thaws) */
					if (ret == 0 && !CFG_ANON_US_THAW && !CFG_EMERGENCY)
						kassert(!devheld[i] || sb_of(i)->m_dead,
							"bdev_thaw()==0 but an sb keeps the device's hold (swallowed error)");
				}
				wt_busy = 0;
			}
		} else if (op == OP_FIFREEZE || (op == OP_RESUME && pick_ff)) {
			if (ff_busy) {
				assume(freezer_runnable(&FF, killed));
				if (run_freezer(&FF, killed)) {
					ret = FF.ret;
					if (ret == 0)
						fif[ff_sb]++;
					ff_busy = 0;
				}
			}
		}
		log_ret[step] = ret;

		check_invariants();
	}
	return 0;
}

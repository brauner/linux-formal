#!/bin/bash
set -e
SRC=/home/brauner/src/git/linux-formal/kernel/work.mount.gp_on_demand.proposal/litmus
DST=/home/brauner/src/git/linux/vfs/work.mount.gp_on_demand.litmus/Documentation/litmus-tests/fs
mkdir -p "$DST"
mk() {
	local src="$1" name="$2" out="$DST/$2.litmus"
	{
		printf 'C %s\n\n(*\n' "$name"
		cat
		printf ' *)\n\n'
		awk 'f||/^\{$/{f=1;print}' "$SRC/$src.litmus"
	} > "$out"
	echo "$src -> $name"
}

mk MNT-A0-peek-can-miss-fastpath-put mnt-sum-misses-fastpath-put <<'EOF'
 * Result: Sometimes
 *
 * A holder drops its reference on the fast path of mntput_no_expire():
 * READ_ONCE(->mnt_ns) non-NULL under rcu_read_lock(), smp_wmb(), the
 * put.  umount_tree() clears ->mnt_ns under write_seqlock() and
 * mntput_unheld() sums the counters with mnt_get_count() under the
 * lock.  The holder read ->mnt_ns before it was cleared (0:r0=1) and
 * the sum still does not count its put (1:r1=0): the put is simply
 * later.  The sum comes out at two, so mntput_unmounted() has to wait
 * for the holder's read-side critical section before the plain
 * mntput() that drops the own reference, see
 * mnt-gp-sees-fastpath-put.litmus.  This is why the grace period
 * branch exists, not a bug.
EOF

mk MNT-A1-holder-get-before-put mnt-holder-get-before-put <<'EOF'
 * Result: Never
 *
 * A holder with a reference of its own (gets_h=1) does a transient
 * mntget() and drops it on the fast path of mntput_no_expire(): the
 * store to its gets counter, READ_ONCE(->mnt_ns) non-NULL, smp_wmb(),
 * the store to its puts counter.  umount_tree() clears ->mnt_ns under
 * write_seqlock() and mntput_unheld() sums with mnt_get_count(): the
 * puts pass, smp_mb(), the gets pass.  The smp_wmb() pairs with that
 * smp_mb(), so a put the sum counts has its get counted too.  The bad
 * outcome is the sum counting the put (1:r1=1) but not the get
 * (1:r3=1): a count of one, and the mount finished off under the
 * reference the holder still has.  Message passing, smp_wmb() on the
 * holder's side and smp_mb() on the sum's.  The sum is modelled with
 * an smp_mb() ahead of the puts pass as well; it takes no part in
 * this, see the -nomb variant.  A put that lands on another CPU's
 * counter after a migration is the same test, the model has no CPUs.
EOF

mk MNT-A1m-nowmb mnt-holder-get-before-put-nowmb <<'EOF'
 * Result: Sometimes
 *
 * mnt-holder-get-before-put.litmus without the smp_wmb() between the
 * get and the fast-path put in mntput_no_expire().  Nothing orders the
 * two stores: the sum counts the put but not the get and finishes the
 * mount off under the holder.
EOF

mk MNT-A1m-nomb-in-sum mnt-holder-get-before-put-nomb <<'EOF'
 * Result: Sometimes
 *
 * mnt-holder-get-before-put.litmus without the smp_mb() between the
 * puts pass and the gets pass of mnt_get_count().  The smp_mb() ahead
 * of the puts pass is still there and does not help: the barrier that
 * pairs with the holder's smp_wmb() has to sit between the two loads.
EOF

mk MNT-A1m-gets-first mnt-holder-get-before-put-getsfirst <<'EOF'
 * Result: Sometimes
 *
 * mnt-holder-get-before-put.litmus with mnt_get_count() summing the
 * gets before the puts, the smp_mb() still between the two passes.
 * The order of the passes is part of the pairing: read first, the
 * gets pass can predate a get whose put is then counted.
EOF

mk MNT-A2-gp-fallback-sees-fastpath-put mnt-gp-sees-fastpath-put <<'EOF'
 * Result: Never
 *
 * The sum of mntput_unheld() can miss the put of a holder on the fast
 * path of mntput_no_expire(), see mnt-sum-misses-fastpath-put.litmus.
 * mntput_unmounted() then waits in synchronize_rcu_expedited() and
 * drops the own reference with a plain mntput(), which sums again in
 * mntput_no_expire_slowpath() under mount_lock.  The holder read
 * ->mnt_ns non-NULL inside rcu_read_lock() before umount_tree() stored
 * NULL, so its read-side critical section, and the put inside it, ends
 * before the grace period does.  The first sum may miss the put
 * (1:r1), the second one never does (1:r5=1).
EOF

mk MNT-A2k-gp-fallback-sync-rcu mnt-gp-sees-fastpath-put-sync-rcu <<'EOF'
 * Result: Never
 *
 * mnt-gp-sees-fastpath-put.litmus with synchronize_rcu() in place of
 * synchronize_rcu_expedited().  To the memory model the two are the
 * same fence.
EOF

mk MNT-A2m-nogp mnt-gp-sees-fastpath-put-nogp <<'EOF'
 * Result: Sometimes
 *
 * mnt-gp-sees-fastpath-put.litmus with an smp_mb() in place of the
 * grace period.  A barrier orders the unmounter's own accesses and
 * waits for nothing: the holder's read-side critical section may still
 * be running and the second sum misses the put like the first one.
 * Only a grace period covers a fast-path put the sum missed.
EOF

mk MNT-B1-walker-inc-vs-peek mnt-walker-get-vs-seqcount <<'EOF'
 * Result: Never
 *
 * A walker in __legitimize_mnt() increments its gets counter, does
 * smp_mb() and re-reads the seqcount of mount_lock with
 * read_seqretry(); if it changed, the walker takes mount_lock and
 * drops the reference again when it finds MNT_SYNC_UMOUNT or
 * MNT_DOOMED.  umount_tree() stores the seqcount when it takes
 * write_seqlock(), clears ->mnt_ns and sets MNT_SYNC_UMOUNT;
 * mntput_unheld() takes the lock again and sums with mnt_get_count():
 * the puts pass, smp_mb(), the gets pass.  Store buffering between the
 * walker's increment and the unmounter's seqcount store: not both the
 * walker seeing the seqcount unchanged (0:r1=0, 0:r2=0, it keeps the
 * reference) and the sum missing the increment (freed=1, the mount is
 * finished off).  The walker's smp_mb() and the smp_mb() of
 * mnt_get_count() are the two full barriers that takes.  The sum is
 * modelled with a further smp_mb() ahead of the puts pass, which the
 * -no-outer-mb variant drops.
EOF

mk MNT-B1m-peek-no-outer-mb mnt-walker-get-vs-seqcount-no-outer-mb <<'EOF'
 * Result: Never
 *
 * mnt-walker-get-vs-seqcount.litmus with the sum as mntput_unheld()
 * has it: write_seqlock(), the puts pass, the smp_mb() of
 * mnt_get_count(), the gets pass, and no smp_mb() between taking the
 * lock and the sum.  The inner smp_mb() comes after the seqcount store
 * and before the gets loads in program order, which is all store
 * buffering asks of the unmounter's side.
EOF

mk MNT-B1m-walker-nomb mnt-walker-get-vs-seqcount-nomb <<'EOF'
 * Result: Sometimes
 *
 * mnt-walker-get-vs-seqcount.litmus without the smp_mb() between the
 * increment and the re-read of the seqcount in __legitimize_mnt().
 * The smp_rmb() of read_seqretry() does not order a store against a
 * later load: the walker sees the seqcount unchanged and keeps its
 * reference while the sum misses the increment and finishes the mount
 * off.
EOF

mk MNT-B2-walker-bail-sees-doomed-lazy mnt-walker-bail-sees-doomed <<'EOF'
 * Result: Never
 *
 * A lazy unmount: umount_tree() clears ->mnt_ns under write_seqlock()
 * without setting MNT_SYNC_UMOUNT, and mntput_unheld() sets MNT_DOOMED
 * (flags=3) when the sum says nothing else holds the mount.  A walker
 * in __legitimize_mnt() that sees the seqcount change takes mount_lock
 * and reads ->mnt_flags there.  Not both the walker finding no flag
 * set (0:r3=0, it keeps the reference) and the mount being finished
 * off (freed=1).  mount_lock orders the two critical sections: either
 * the walker's comes first and the sum counts its increment, or the
 * sum's does and the walker finds MNT_DOOMED.
EOF

mk MNT-B2m-walker-flags-unlocked mnt-walker-bail-sees-doomed-nolock <<'EOF'
 * Result: Sometimes
 *
 * mnt-walker-bail-sees-doomed.litmus with the walker reading
 * ->mnt_flags outside mount_lock.  Nothing orders that read against
 * the sum's critical section: the walker can read the flags before
 * MNT_DOOMED is set and keep a reference to a mount the sum has
 * finished off.  This is why __legitimize_mnt() looks under the lock.
EOF

mk MNT-C1-kern-unmount-get-before-put mnt-kern-unmount-holder-get-before-put <<'EOF'
 * Result: Never
 *
 * mnt-holder-get-before-put.litmus for kern_unmount_array(), where
 * mnt_make_shortterm() clears ->mnt_ns with a plain WRITE_ONCE(),
 * outside mount_lock and without a seqcount write, before
 * mntput_unmounted() sums under the lock.  The pairing is unchanged:
 * the holder's smp_wmb() against the smp_mb() of mnt_get_count(),
 * neither of which needs the lock or the seqcount.  Only holders are
 * modelled.
EOF

mk MNT-C2-kern-unmount-gp-fallback mnt-kern-unmount-gp-sees-fastpath-put <<'EOF'
 * Result: Never
 *
 * mnt-gp-sees-fastpath-put.litmus for kern_unmount_array(), where
 * mnt_make_shortterm() clears ->mnt_ns with a plain WRITE_ONCE()
 * outside mount_lock.  The holder still read it non-NULL inside
 * rcu_read_lock() before the store, so its read-side critical section
 * ends before the grace period of mntput_unmounted() does and the
 * plain mntput() that follows sees its put.
EOF

mk MNT-E1-slowpath-no-outer-mb mnt-slowpath-sum-no-outer-mb <<'EOF'
 * Result: Never
 *
 * mntput_no_expire_slowpath() against a walker in __legitimize_mnt():
 * lock_mount_hash() stores the seqcount, mnt_dec_count() drops the own
 * reference, mnt_get_count() sums the puts, does smp_mb() and sums the
 * gets, and a count of zero finishes the mount off.  There is no
 * smp_mb() between taking the lock and the sum.  The smp_mb() of
 * mnt_get_count() sits after the seqcount store and before the gets
 * loads in program order, which is what store buffering against the
 * walker's smp_mb() needs.  Not both the walker keeping its reference
 * (0:r1=0, 0:r2=0) and the slow path freeing the mount (freed=1).  The
 * own decrement ahead of the sum is a store of the running CPU, read
 * back in program order.
EOF

mk MNT-E2-busycheck-no-outer-mb mnt-umount-busy-sum-no-outer-mb <<'EOF'
 * Result: Never
 *
 * The busy check of do_umount() against a walker in __legitimize_mnt():
 * lock_mount_hash() stores the seqcount and propagate_mount_busy() sums
 * with mnt_get_count(), the puts pass, smp_mb(), the gets pass.  When
 * the sum finds no reference the caller does not account for,
 * umount_tree() clears ->mnt_ns and sets MNT_SYNC_UMOUNT under the
 * same lock (freed=1 marks the unmount going ahead).  There is no
 * smp_mb() between taking the lock and the sum; the smp_mb() of
 * mnt_get_count() is the full barrier store buffering needs on this
 * side.  Not both the walker keeping its reference (0:r1=0, 0:r2=0)
 * and the unmount going ahead.
EOF

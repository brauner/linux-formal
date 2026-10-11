// SPDX-License-Identifier: GPL-2.0
/*
 * Exhaustive check of the close_range() code of vfs-7.4.sync_close
 * (02de8d0c3512, fs/file.c) on emulated W-bit words: every table of up
 * to NW words, every range over 0..W*NW and ~0U, every flag combination,
 * shared or not.  The functions marked VERBATIM are copied from fs/file.c,
 * the others follow it without the locking; the helpers below emulate the
 * bitmap primitives for W-bit words.
 * The expected outcome is the meaning of the flags, as in FdTable.tla.
 */
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#ifndef W
#define W 3
#endif
#ifndef NW
#define NW 2
#endif

#define BITS_PER_LONG W
#define NR_OPEN_DEFAULT BITS_PER_LONG
#define WORDMASK ((1UL << W) - 1)
#define GENMASK(h, l) (((1UL << ((h) - (l) + 1)) - 1) << (l))
#define BIT_MASK(nr) (1UL << ((nr) % BITS_PER_LONG))
#define BITMAP_LAST_WORD_MASK(nbits) (((nbits) % W) ? ((1UL << ((nbits) % W)) - 1) : WORDMASK)
#define ALIGN(x, a) ((((x) + (a) - 1) / (a)) * (a))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))

#define FD_RANGE_EXCEPT		(1U << 0)
#define FD_RANGE_CLOEXEC_ONLY	(1U << 1)

struct fd_range {
	unsigned int from, to;
	unsigned int flags;
};

struct fdtable {
	unsigned int max_fds;
	unsigned long open_fds[NW];
	unsigned long close_on_exec[NW];
	int fd[NW * W];		/* 1: a struct file is installed */
};

static unsigned int fdt_words(struct fdtable *fdt) { return fdt->max_fds / BITS_PER_LONG; }

/* find_last_bit(): the last set bit below size, or size */
static unsigned long find_last_bit(const unsigned long *addr, unsigned long size)
{
	for (long b = (long)size - 1; b >= 0; b--)
		if (addr[b / W] & (1UL << (b % W)))
			return b;
	return size;
}

static unsigned int __fls(unsigned long word)
{
	for (int b = W - 1; b >= 0; b--)
		if (word & (1UL << b))
			return b;
	return 0;
}

static unsigned int last_fd(struct fdtable *fdt) { return fdt->max_fds - 1; }

/* VERBATIM */
static unsigned long fd_range_word(struct fd_range *range, unsigned int i)
{
	unsigned int first = i * BITS_PER_LONG;
	unsigned int last = first + BITS_PER_LONG - 1;

	if (range->to < first || range->from > last)
		return 0;
	return GENMASK(min(range->to, last) - first,
		       max(range->from, first) - first);
}

/* VERBATIM */
static unsigned long dup_fd_dropped_word(struct fdtable *fdt, unsigned int i,
					 struct fd_range *range)
{
	unsigned long dropped;

	if (!range)
		return 0;
	dropped = fd_range_word(range, i);
	if (range->flags & FD_RANGE_EXCEPT)
		dropped = ~dropped;
	if (range->flags & FD_RANGE_CLOEXEC_ONLY)
		dropped &= fdt->close_on_exec[i];
	return dropped;
}

/* VERBATIM */
static unsigned int sane_fdtable_size(struct fdtable *fdt, struct fd_range *range)
{
	unsigned int last = find_last_bit(fdt->open_fds, fdt->max_fds);
	unsigned int i;

	if (last == fdt->max_fds)
		return NR_OPEN_DEFAULT;
	if (!range)
		return ALIGN(last + 1, BITS_PER_LONG);

	if (range->flags & FD_RANGE_CLOEXEC_ONLY) {
		/* The close-on-exec bits decide what is dropped, walk the words. */
		i = last / BITS_PER_LONG + 1;
		while (i--) {
			unsigned long dropped = dup_fd_dropped_word(fdt, i, range);

			if (fdt->open_fds[i] & ~dropped)
				return (i + 1) * BITS_PER_LONG;
		}
		return NR_OPEN_DEFAULT;
	}

	if (range->flags & FD_RANGE_EXCEPT) {
		/* Only the range is carried over. */
#ifdef MUT_SIZE_NO_EXCEPT_CLAMP
		if (0) {
#else
		if (last > range->to) {
#endif
			last = find_last_bit(fdt->open_fds, range->to + 1);
			if (last > range->to)
				return NR_OPEN_DEFAULT;
		}
		if (last < range->from)
			return NR_OPEN_DEFAULT;
	} else if (last >= range->from && last <= range->to) {
		/* The last open descriptor goes, the kept ones sit below the range. */
		last = find_last_bit(fdt->open_fds, range->from);
		if (last == range->from)
			return NR_OPEN_DEFAULT;
	}
	return ALIGN(last + 1, BITS_PER_LONG);
}

/* VERBATIM */
static inline unsigned int last_fd_to_close(struct fdtable *fdt, unsigned int n,
					    struct fd_range *range)
{
	unsigned int i, lo = 0;

	if (!(range->flags & FD_RANGE_EXCEPT))
		lo = range->from / BITS_PER_LONG;
	for (i = n ? (n - 1) / BITS_PER_LONG + 1 : 0; i-- > lo; ) {
		unsigned long set = fdt->open_fds[i];

		if (!set) {
			/* Skip the empty stretch at find_last_bit() speed. */
			unsigned int last = find_last_bit(fdt->open_fds, i * BITS_PER_LONG);

			if (last >= i * BITS_PER_LONG)
				break;
			i = last / BITS_PER_LONG + 1;
			continue;
		}
		/* Hop below the kept window in one step. */
		if ((range->flags & FD_RANGE_EXCEPT) &&
		    i * BITS_PER_LONG >= range->from &&
		    i * BITS_PER_LONG + BITS_PER_LONG - 1 <= range->to) {
			if (!range->from)
				break;
#ifdef MUT_HOP_OFF_BY_ONE
			i = (range->from - 1) / BITS_PER_LONG;
#else
			i = (range->from - 1) / BITS_PER_LONG + 1;
#endif
			continue;
		}
		set &= dup_fd_dropped_word(fdt, i, range);
#ifndef MUT_NO_LAST_WORD_MASK
		if (i == (n - 1) / BITS_PER_LONG)
			set &= BITMAP_LAST_WORD_MASK(n);
#endif
		if (set)
			return i * BITS_PER_LONG + __fls(set);
	}
	return n;
}

/* file_close_fd_locked(): the pointer goes, __put_unused_fd() clears the open bit */
static int file_close_fd_locked(struct fdtable *fdt, unsigned int fd)
{
	int file = fdt->fd[fd];

	if (file) {
		fdt->fd[fd] = 0;
		fdt->open_fds[fd / W] &= ~(1UL << (fd % W));
	}
	return file;
}

/* __range_close() with nothing running next to it: the bound and the loop head
   are VERBATIM, the lock is never dropped */
static void __range_close(struct fdtable *fdt, struct fd_range *range)
{
	unsigned int fd, n;

	if (range->flags & FD_RANGE_EXCEPT)
		/* Outside of the range means the whole table. */
		n = fdt->max_fds;
	else
		n = min(range->to, last_fd(fdt)) + 1;

	/* Highest fd first, see close_files(). */
	while ((fd = last_fd_to_close(fdt, n, range)) < n) {
		n = fd;
		(void)file_close_fd_locked(fdt, fd);
	}
}

/* __range_cloexec() without the lock, and bitmap_set() for W-bit words */
static void bitmap_set(unsigned long *map, unsigned int start, unsigned int len)
{
	for (unsigned int b = start; b < start + len; b++)
		map[b / W] |= 1UL << (b % W);
}

static void __range_cloexec(struct fdtable *fdt, struct fd_range *range)
{
	unsigned int last = last_fd(fdt);

	if (!(range->flags & FD_RANGE_EXCEPT)) {
		if (range->from <= last)
			bitmap_set(fdt->close_on_exec, range->from,
				   min(range->to, last) - range->from + 1);
	} else {
		if (range->from > 0)
			bitmap_set(fdt->close_on_exec, 0,
				   min(range->from - 1, last) + 1);
		if (range->to < last)
			bitmap_set(fdt->close_on_exec, range->to + 1,
				   last - range->to);
	}
}

/* dup_fd() with nothing running next to it: the size, copy_fd_bitmaps() and the
   copy loop, get_file() and __clear_open_fd() emulated */
static void dup_fd(struct fdtable *old, struct fd_range *range, struct fdtable *new,
		   unsigned int *open_files_out, int *refs)
{
	unsigned int open_files, fd;
	unsigned long dropped = 0;

	open_files = sane_fdtable_size(old, range);
	*open_files_out = open_files;
	memset(new, 0, sizeof(*new));
	new->max_fds = open_files;	/* alloc_fdtable() rounds up; the rest is free */
	for (unsigned int i = 0; i < open_files / W; i++) {	/* copy_fd_bitmaps() */
		new->open_fds[i] = old->open_fds[i];
		new->close_on_exec[i] = old->close_on_exec[i];
	}
	for (fd = 0; fd < open_files; fd++) {
		int f = old->fd[fd];

		if (!(fd % BITS_PER_LONG))
			dropped = dup_fd_dropped_word(old, fd / BITS_PER_LONG, range);
		if (f && !(dropped & BIT_MASK(fd))) {
			refs[fd] = 1;			/* get_file() */
		} else {
			f = 0;
			new->open_fds[fd / W] &= ~(1UL << (fd % W));	/* __clear_open_fd() */
		}
		new->fd[fd] = f;
	}
}

#define CR_UNSHARE	1
#define CR_CLOEXEC	2
#define CR_EXCEPT	4
#define CR_CLOEXEC_ONLY	8

static bool isopen(struct fdtable *t, unsigned int d)
{
	return d < t->max_fds && (t->open_fds[d / W] & (1UL << (d % W)));
}

static bool iscloexec(struct fdtable *t, unsigned int d)
{
	return d < t->max_fds && (t->close_on_exec[d / W] & (1UL << (d % W)));
}

static bool inrange(struct fd_range *r, unsigned int d) { return r->from <= d && d <= r->to; }

static bool selected(struct fdtable *t, struct fd_range *r, unsigned int flags, unsigned int d)
{
	return isopen(t, d) &&
	       ((flags & CR_EXCEPT) ? !inrange(r, d) : inrange(r, d)) &&
	       (!(flags & CR_CLOEXEC_ONLY) || iscloexec(t, d));
}

static long failures, checks;

static void fail(const char *what, struct fdtable *t, struct fd_range *r, unsigned int flags,
		 bool shared)
{
	if (failures++ < 20) {
		printf("FAIL %s: max_fds %u range [%u, %u] flags%s%s%s%s shared %d slots:",
		       what, t->max_fds, r->from, r->to,
		       flags & CR_UNSHARE ? " UNSHARE" : "", flags & CR_CLOEXEC ? " CLOEXEC" : "",
		       flags & CR_EXCEPT ? " EXCEPT" : "", flags & CR_CLOEXEC_ONLY ? " CLOEXEC_ONLY" : "",
		       shared);
		for (unsigned int d = 0; d < t->max_fds; d++)
			printf(" %u:%s%s", d, !isopen(t, d) ? "-" : t->fd[d] ? "F" : "c",
			       iscloexec(t, d) ? "x" : "");
		printf("\n");
	}
}

/* sys_close_range() against the meaning of its flags */
static void check(struct fdtable *t, unsigned int from, unsigned int to, unsigned int flags,
		  bool shared)
{
	struct fd_range range = { from, to, 0 };
	struct fdtable cur = *t, clone;
	unsigned int open_files = 0;
	int refs[NW * W] = { 0 };
	bool unshared = false;

	checks++;
	if (flags & CR_EXCEPT)
		range.flags |= FD_RANGE_EXCEPT;
	if (flags & CR_CLOEXEC_ONLY)
		range.flags |= FD_RANGE_CLOEXEC_ONLY;

	if ((flags & CR_UNSHARE) && shared) {
		struct fd_range *drop = &range;

		if (flags & CR_CLOEXEC)
			drop = NULL;
		dup_fd(t, drop, &clone, &open_files, refs);
		cur = clone;
		unshared = true;

		/* the clone: no file without an open bit */
		for (unsigned int d = 0; d < cur.max_fds; d++)
			if (cur.fd[d] && !isopen(&cur, d))
				fail("CloneOK", t, &range, flags, shared);
		/* no reference on what is left behind */
		if (drop)
			for (unsigned int d = 0; d < t->max_fds; d++)
				if (refs[d] && selected(t, drop, flags, d))
					fail("NoRefOnDropped", t, &range, flags, shared);
		/* sized to the last descriptor carried over */
		{
			int lastc = -1;

			for (unsigned int d = 0; d < t->max_fds; d++)
				if (isopen(t, d) && !(drop && selected(t, drop, flags, d)))
					lastc = d;
			if (open_files != (lastc < 0 ? NR_OPEN_DEFAULT : ALIGN(lastc + 1, W)))
				fail("Sized", t, &range, flags, shared);
		}
	}

	if (flags & CR_CLOEXEC)
		__range_cloexec(&cur, &range);
	else if (!unshared)
		__range_close(&cur, &range);

	/* the meaning: the base table, then the selected descriptors closed or marked */
	for (unsigned int d = 0; d < NW * W; d++) {
		bool b_open = isopen(t, d), b_file = d < t->max_fds && t->fd[d], b_cx = iscloexec(t, d);
		bool want_open, want_file, want_cx;

		if (unshared && b_open && !b_file)	/* a private copy holds what is installed */
			b_open = false;
		want_open = b_open; want_file = b_file && b_open; want_cx = b_cx;
		if (b_open && ((flags & CR_EXCEPT) ? !inrange(&range, d) : inrange(&range, d)) &&
		    (!(flags & CR_CLOEXEC_ONLY) || b_cx)) {
			if (flags & CR_CLOEXEC)
				want_cx = true;
			else if (b_file) {
				want_open = false;
				want_file = false;
			}
		}
		bool got_open = isopen(&cur, d), got_file = d < cur.max_fds && cur.fd[d] && got_open;
		bool got_cx = iscloexec(&cur, d);
		if (got_open != want_open || got_file != want_file || (want_open && got_cx != want_cx))
			fail("Refines", t, &range, flags, shared);
	}
}

int main(void)
{
	unsigned int nr[NW * W + 2], nrc = 0;

	for (unsigned int v = 0; v <= NW * W; v++)
		nr[nrc++] = v;
	nr[nrc++] = UINT_MAX;

	for (unsigned int words = 1; words <= NW; words++) {
		unsigned int slots = words * W;
		long tables = 1;

		for (unsigned int s = 0; s < slots; s++)
			tables *= 6;
		for (long code = 0; code < tables; code++) {
			struct fdtable t;
			long c = code;

			memset(&t, 0, sizeof(t));
			t.max_fds = slots;
			for (unsigned int d = 0; d < slots; d++, c /= 6) {
				int v = c % 6;	/* free, claimed, installed, each with or without close-on-exec */

				if (v / 2 >= 1)
					t.open_fds[d / W] |= 1UL << (d % W);
				if (v / 2 == 2)
					t.fd[d] = 1;
				if (v % 2)
					t.close_on_exec[d / W] |= 1UL << (d % W);
			}
			for (unsigned int a = 0; a < nrc; a++)
				for (unsigned int b = 0; b < nrc; b++) {
					if (nr[a] > nr[b])
						continue;
					for (unsigned int flags = 0; flags < 16; flags++) {
						if ((flags & CR_CLOEXEC) && (flags & CR_CLOEXEC_ONLY))
							continue;
						check(&t, nr[a], nr[b], flags, false);
						if (flags & CR_UNSHARE)
							check(&t, nr[a], nr[b], flags, true);
					}
				}
		}
	}
	printf("W=%d NW=%d: %ld checks, %ld failures\n", W, NW, checks, failures);
	return failures != 0;
}

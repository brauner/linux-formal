# The queued C code, checked exhaustively

Tree: vfs-7.4.sync_close at 02de8d0c3512, fs/file.c.

The TLA+ models check a transcription of the code. This checks the code
itself. `crcheck.c` copies `fd_range_word()`, `dup_fd_dropped_word()`,
`sane_fdtable_size()` and `last_fd_to_close()` from fs/file.c as they
are, and `__range_cloexec()` and the loops of `dup_fd()` and
`__range_close()` without the locking. It runs them on words of W bits
with the bitmap helpers emulated for that width, and compares what they
do with the meaning of the flags, written down in C on its own: every
table of up to NW words, every slot free, claimed or installed and with
or without close-on-exec, every range over 0..W*NW and ~0U, every flag
combination `sys_close_range()` accepts, shared or not. It checks what
the refinement in `../tla/` checks: the table the caller ends up with,
no file without an open bit in the clone, no reference on a descriptor
that is left behind, and the size of the clone. Nothing runs
concurrently here, the races are `../tla/`'s.

    ./check.sh                               # W=2 NW=3, W=3 NW=2, W=4 NW=2
    EXTRA=-DMUT_HOP_OFF_BY_ONE ./check.sh    # a mutation, has to fail

| W | NW | checks | failures | time |
|---|---|---|---|---|
| 2 | 3 | 31,096,224 | 0 | a second |
| 3 | 2 | 30,373,056 | 0 | a second |
| 4 | 2 | 1,664,102,880 | 0 | 75 seconds |

The emulation is the part that could hide something: GENMASK(),
BIT_MASK(), BITMAP_LAST_WORD_MASK(), `find_last_bit()`, `__fls()` and
`bitmap_set()` are written out for W-bit words, and `~` on a word sets
bits above W, which every caller masks with open_fds or a single bit
before it looks. Three mutations show that the check is not vacuous; at
W=3, NW=2 each one fails:

| Flag | What it takes out | failures |
|---|---|---|
| `-DMUT_NO_LAST_WORD_MASK` | `BITMAP_LAST_WORD_MASK(n)` in `last_fd_to_close()` | 2,837,610 |
| `-DMUT_HOP_OFF_BY_ONE` | the hop below the kept window resumes one word too low | 808,704 |
| `-DMUT_SIZE_NO_EXCEPT_CLAMP` | the clamp of `sane_fdtable_size()` to a CLOSE_RANGE_EXCEPT range | 349,056 |

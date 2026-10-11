# close_range() and the clone dup_fd() makes for it

Status: queued for v7.4 in vfs-7.4.close_range and vfs-7.4.sync_close,
as modelled.

"files,close_range: add CLOSE_RANGE_{CLOEXEC_ONLY,EXCEPT}" does two
things. It makes dup_fd() leave the descriptors close_range() is about
to close behind instead of copying them into the clone and closing them
again from there. And it adds CLOSE_RANGE_EXCEPT, which acts on
everything outside the range, and CLOSE_RANGE_CLOEXEC_ONLY, which acts
only on close-on-exec descriptors. What the series adds is bitmap
arithmetic: which bits of a word a range covers, the inversion and the
close_on_exec mask on top of that, and the size of the clone. "fs:
close files from the highest descriptor down", which sits on top of it
in vfs-7.4.sync_close, turned the walk of __range_close() around. It
starts at the top now, skips empty stretches with find_last_bit() and
hops below the window it keeps.

`FdTable.tla` writes that code down operator by operator, next to what
the flags are supposed to mean. Three models use it. `CloseRange`
checks that the code does what the flags mean for every table of one or
two small words, every range and all twelve flag combinations, shared
and private. `RangeCloseRace` runs __range_close() over a shared table
while other threads open, install, close and re-flag descriptors and
grow the table. `DupFdRace` runs dup_fd() against the lockless
fd_install(). Next to the models, `exhaustive/` runs the queued C
functions themselves against the same meaning of the flags.

Tree: vfs-7.4.sync_close at 02de8d0c3512, which holds
vfs-7.4.close_range (c73c0e243836). The models were first written
against e0bfe9dbba49, the series before it was applied, and brought up
to the queued code since.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `FdTable` and the three models above |
| C, exhaustive | [`exhaustive/`](exhaustive/README.md) | the queued functions on emulated small words, every table, range and flag combination, nothing concurrent |

## Results

No defect in the queued code. The refinement holds over every table
with three-bit, four-bit and two-bit words (`refine_new`,
`refine_new_w4`, `refine_new_3w`). The walk keeps its bound, closes
only what the range and the flags select while the table changes under
it, and ends (`race_fixed`, `race_fixed_w2`). The clone carries over
exactly what it should against concurrent installs (`dupfd_new`). The C
functions agree with the meaning of the flags in about 1.7 billion
cases.

Each piece of the new walk and of the new sizing is needed. Taking any
one of them out makes a configuration fail: `BITMAP_LAST_WORD_MASK()`,
the resume points of the skip and of the hop, the hop taking only words
that lie entirely inside the window, `dup_fd_dropped_word()` in the
walk, and the clamp of the size to a CLOSE_RANGE_EXCEPT range.

The models say a few things beyond the series:

- The code before it was correct for its flags but took references it
  dropped again right away: with only descriptor 2 open,
  `close_range(0, 2, CLOSE_RANGE_UNSHARE)` still gave the clone its
  first word, copied descriptor 2 into it and closed it from there
  (`refine_old_refs`, `dupfd_old_refs`). That's what "file: let dup_fd()
  leave the punched hole behind" removes.
- A claimed slot, open bit set and no file installed yet, counts for the
  size of the clone, so a clone can be one word larger than its files
  need. `Sized` pins that down. The walk leaves a claimed slot open too,
  and `BITMAP_LAST_WORD_MASK()` is what keeps it from ending the walk
  when the bound comes down to it.

Everything but `race_fixed` and `refine_new_w4` finishes in minutes on a
laptop.

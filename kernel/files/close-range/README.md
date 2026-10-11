# close_range() and the clone dup_fd() makes for it

Status: queued for v7.4 in vfs-7.4.close_range, revised since. The
queued sane_fdtable_size() sizes the clone differently, and "fs: close
files from the highest descriptor down" on vfs-7.4.sync_close replaces
the ascending walk of __range_close() and its hop over the kept window
with a descending one. The models describe e0bfe9dbba49, not the queued
code.

"files,close_range: add CLOSE_RANGE_{CLOEXEC_ONLY,EXCEPT}" does two
things. It makes dup_fd() leave the descriptors close_range() is about
to close behind instead of copying them into the clone and closing them
again from there. And it adds CLOSE_RANGE_EXCEPT, which acts on
everything outside the range, and CLOSE_RANGE_CLOEXEC_ONLY, which acts
only on close-on-exec descriptors. What the series adds is bitmap
arithmetic: which bits of a word a range covers, the inversion and the
close_on_exec mask on top of that, the size of the clone, and a walk
over the table that hops over the window it keeps.

`FdTable.tla` writes that code down operator by operator, next to what
the flags are supposed to mean. Three models use it. `CloseRange`
checks that the code does what the flags mean for every table of one or
two small words, every range and all twelve flag combinations, shared
and private. `RangeCloseRace` runs __range_close() over a shared table
while other threads open, install, close and re-flag descriptors and
grow the table. `DupFdRace` runs dup_fd() against the lockless
fd_install().

Tree: work.file.close_range_except at e0bfe9dbba49 on 5dd1818b15d9.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `FdTable` and the three models above |

## Results

No defect in the series. The refinement holds over every table with
three-bit, four-bit and two-bit words (`refine_new`, `refine_new_w4`,
`refine_new_3w`), the walk keeps its bounds and closes only what the
range selects while the table changes under it (`race_fixed_w2`), and
the clone carries over exactly what it should against concurrent
installs (`dupfd_new`).

The models say a few things beyond the series:

- The code before it was correct for its flags but took references it
  dropped again right away: with descriptors 1 and 2 open,
  `close_range(0, 1, CLOSE_RANGE_UNSHARE)` copied descriptor 1 into the
  clone and closed it from there (`refine_old_refs`, `dupfd_old_refs`).
  That's what "file: let dup_fd() leave the punched hole behind"
  removes.
- The hop over the kept window in next_fd_to_close() is load-bearing:
  without it CLOSE_RANGE_EXCEPT closes the first descriptor of the
  window it is supposed to keep (`race_no_hop`).
- A claimed slot, open bit set and no file installed yet, counts for the
  size of the clone, so a clone can be one word larger than its files
  need. `Sized` pins that down.

Everything but `race_fixed` and `refine_new_w4` finishes in minutes on a
laptop.

# Synchronous file closing

Status: queued for v7.4 in vfs-7.4.sync_close, as modelled. "fs: close
files from the highest descriptor down" was redone on top of the
close_range() series, the order it closes in is the one modelled here.

"files: make closing files synchronous for close_range(), exec, exit"
runs the final __fput() of a dying descriptor table inside the walk
instead of deferring it to task work. Nothing in it is a rendezvous.
What changes is the order in which ->flush() and ->release() run,
relative to each other and to the rest of exit, exec and fork. These
models cover the four places where that order is visible: the order of
the walk itself, a vfork child that execs, a fork that fails, and a
session leader that exits holding its tty.

Tree: c7b1fa3db4a1 (the series as merged into vfs-7.4.coredump at the
time) plus the fixes in 938c2dd45269.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | four small models, every configuration finishes in about a second |

## Findings

| Finding | Shown by | Outcome |
|---|---|---|
| The merged walk closes in ascending order. A lower descriptor whose release waits for a higher one (a pipe before a socket) now hangs where the deferred puts did not. | `CloseOrder_AscendingNoWorseThanDeferred` | "fs: close files from the highest descriptor down": the descending walk hangs exactly where the deferred puts hung for release dependencies, and never where they didn't |
| A fork that fails while its child's table holds the last reference to a sched_ext link deadlocks: exit_files() waits for the disable work and the disable work waits for the fork's read side of scx_fork_rwsem. | `ForkCleanup_files_first` | "fork: release the files of a failed fork after sched_cancel_fork()" |
| A session leader that exits holding the last open of its tty closes it before the hangup, so the foreground job never gets SIGHUP. | `TtyHangup_files_first_tty` | "exit: hang up the tty before closing the files" |
| A vfork child that execs while holding the last reference to a file whose ->release() needs the parent hangs until the parent is killed. | `VforkExec_sync_release` | known and left as is: the same program hangs on every kernel if it uses close(2) instead of close-on-exec |

The three fixes were written as part of the coredump series modelled in
[`kernel/coredump/rendezvous/`](../../coredump/rendezvous/) and are
queued as "files: fixes for synchronous close_range(), exec, exit".

The descending walk also fixes a hang the old order had: a ->flush()
that waits for the release of a higher descriptor, a FUSE file served by
the same process with its /dev/fuse above it, now completes
(`CloseOrder_DescendingMatchesDeferred` fails in that direction).

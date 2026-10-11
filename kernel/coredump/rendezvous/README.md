# The coredump rendezvous and the signal code around it

Status: queued for v7.4 in kernel-7.4.signal, revised since. Seven of
the patches the model checks are queued unchanged, and "coredump: parse
a snapshot of core_pattern" is queued unchanged in vfs-7.4.coredump.
"signal: only SIGKILL and the freezers interrupt a coredumping task"
now relies on nothing but SIGKILL and the freezers setting
TIF_SIGPENDING after zap_threads() instead of filtering in
signal_pending(). "signal: fix coredump deadlock with PF_USER_WORKER"
was dropped in favour of enforcing the signal mask of user workers,
which `sqpoll_mask_only` shows is enough on its own.

"coredump & signals: an impossible affair" reworks how a dumping thread
group gets along with signals, exit, fork, exec, the freezers and
io_uring's worker threads. The model is one thread group whose threads
receive signals, dequeue them in get_signal(), dump core, exit, exec and
create io-wq workers from task work, one siglock critical section per
step. Every patch of the series that changes a concurrent protocol is a
`FIX_*` constant. With one of them off TLC finds the trace the patch
fixes, and with all of them on it proves the properties over every
interleaving of the thread layout. Among them: the dump always ends,
nobody counted by the rendezvous goes missing, no task is woken after it
was freed, a user worker never dumps, and exec leaves a single thread
behind.

Tree: work.coredump.close_files.fixes at 938c2dd45269 on c7b1fa3db4a1
(vfs-7.4.coredump), the series v3.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `Coredump` with four thread layouts, plus two small modules for the io-wq exit bit and core_pattern |

## What each patch prevents

| Patch | Without it |
|---|---|
| coredump: hold RCU while releasing parked threads | coredump_finish() wakes a task_struct that was already freed (`signals_no_rcu`) |
| signal: only SIGKILL and the freezers interrupt a coredumping task | a cgroup v2 freeze lets a dump to a file complete (`signals_no_freezer`); with the next patch off as well a dump is cut short for no reason (`signals_no_retarget`) |
| signal: don't retarget shared signals in a dying thread group | see above; each of the two covers the other |
| signal: fix coredump deadlock with PF_USER_WORKER | the io-wq worker of an SQPOLL ring dumps and the SQPOLL thread waits for it forever, together with the next patch (`sqpoll_deadlock`) |
| ptrace: refuse to change the signal mask of a user worker | see above |
| exec: cancel io_uring requests before de_thread() | a create_worker_cont() survives de_thread() and the exec'ing thread isn't alone (`plain_no_exec_cancel`) |
| fork: move the coredump and exec checks into create_io_thread() | the SQPOLL thread creates a worker the dump doesn't count (`sqpoll_no_gate_signaled`) |
| fork: don't create io threads once PF_POSTCOREDUMP is set | a thread in exit(2) creates a worker the dump doesn't count (`cdhole_no_gate`) |
| io-wq: order the exit bit against worker creation task work | a worker creation is stranded when the store of the exit bit is still buffered (`IoWqExitBit_nobarrier`) |
| coredump: parse a snapshot of core_pattern | a torn read mixes the file mode of the new pattern with the helper path of the old one (`CorePattern_torn`) |

The other patches of the series change no concurrent protocol. Three
of them change the order in which files are closed and are modelled in
[`kernel/files/sync-close/`](../../files/sync-close/).

## Beyond the series

With every fix on, a dump can still be cut short by io_uring
(`plain_strict`). A zapped io-wq worker of the dumper's own ring that
blocks with more work queued makes io_wq_dec_running() queue
create_worker_cb() on the dumper with TWA_SIGNAL. signal_pending() then
reports TIF_NOTIFY_SIGNAL before it ever looks at PF_DUMPCORE, and the
next write that has to wait for room fails. "signal: only SIGKILL and
the freezers interrupt a coredumping task" doesn't cover that.

The green configurations with liveness take a quarter of an hour to an
hour each with 32 workers, the ones with a fix switched off stop at
their counterexample in seconds to minutes.

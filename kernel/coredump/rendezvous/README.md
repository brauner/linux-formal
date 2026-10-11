# The coredump rendezvous and the signal code around it

Status: queued for v7.4 in kernel-7.4.signal, as modelled. That includes
vfs-7.4.signal, which kernel-7.4.signal is built on and which keeps
TIF_NOTIFY_SIGNAL from cutting a dump short. "coredump: parse a snapshot
of core_pattern" is queued in vfs-7.4.coredump.

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

Tree: vfs.all at 548491e998e1. The series was first modelled as v3, at
938c2dd45269 on c7b1fa3db4a1 (vfs-7.4.coredump). What v3 did
differently is still a switch away.

| Method | Directory | What it covers |
|---|---|---|
| TLA+ (TLC) | [`tla/`](tla/README.md) | `Coredump` with four thread layouts, plus two small modules for the io-wq exit bit and core_pattern |

## What each patch prevents

| Patch | Without it |
|---|---|
| coredump: hold RCU while releasing parked threads | coredump_finish() wakes a task_struct that was already freed (`signals_no_rcu`) |
| io-wq: order the exit bit against worker creation task work | a worker creation is stranded when the store of the exit bit is still buffered (`IoWqExitBit_nobarrier`) |
| signal: don't retarget shared signals in a dying thread group | a sigtimedwait() sleeper woken by the zap restores its mask, retargets a shared signal onto the dumper and the dump is cut short for no reason (`signals_retarget_only`, `signals_no_retarget`) |
| signal: only SIGKILL and the freezers interrupt a coredumping task | a cgroup v2 freeze lets a dump to a file complete (`signals_no_freezer`), and without its check in zap_threads() a freeze that came just before the dump is lost (`signals_no_freeze_check`) |
| ptrace: refuse to change the signal mask of a user worker | the io-wq worker of an SQPOLL ring dumps and the SQPOLL thread waits for it forever (`sqpoll_deadlock`) |
| exec: cancel io_uring requests before de_thread() | a create_worker_cont() survives de_thread() and the exec'ing thread isn't alone (`plain_no_exec_cancel`) |
| fork: move the coredump and exec checks into create_io_thread() | the SQPOLL thread creates a worker the dump doesn't count (`sqpoll_no_gate_signaled`) |
| fork: don't create io threads once PF_POSTCOREDUMP is set | a thread in exit(2) creates a worker the dump doesn't count (`cdhole_no_gate`) |
| coredump: prevent TIF_NOTIFY_SIGNAL from interrupting coredumps (vfs-7.4.signal) | task work io_uring queues on the dumper cuts the dump short (`plain_strict_no_guard`) |
| coredump: parse a snapshot of core_pattern (vfs-7.4.coredump) | a torn read mixes the file mode of the new pattern with the helper path of the old one (`CorePattern_torn`) |

"signal: fix coredump deadlock with PF_USER_WORKER" from v3 was dropped.
Against the tracer the worker's mask is enough on its own
(`sqpoll_fixed`), and so was the dropped patch (`sqpoll_nodump_only`).
"fork: use SIG_KERNEL_ONLY_MASK for the user worker signal mask" and
"signal: enforce the user worker signal mask in __set_task_blocked()"
change nothing the model can reach. The three patches of v3 that change
the order in which files are closed went to vfs-7.4.sync_close and are
modelled in [`kernel/files/sync-close/`](../../files/sync-close/).

## Beyond the series

In v3 io_uring could still cut a dump short (`plain_strict`). A zapped
io-wq worker of the dumper's own ring that blocks with more work queued
makes io_wq_dec_running() queue create_worker_cb() on the dumper with
TWA_SIGNAL, and signal_pending() reported TIF_NOTIFY_SIGNAL before it
ever looked at PF_DUMPCORE. The guard from vfs-7.4.signal closes that
and `plain_strict` holds now.

The queued "signal: only SIGKILL and the freezers interrupt a
coredumping task" needs the retarget fix. In v3 each of the two covered
the other (`signals_retarget_only_v3`), now dump_interrupted() is
task_sigpending() and nothing filters a retargeted signal anymore. The
retarget fix comes first in the series, so that's fine.

With the PF_USER_WORKER patch gone a user worker's signal mask is all
that keeps it from dumping. force_sig_info_to_task() unblocks the signal
it forces, and a SIGSEGV or SIGBUS forced onto the io-wq worker of an
SQPOLL ring brings the deadlock back (`sqpoll_forced`). The dropped
patch prevents it (`sqpoll_forced_nodump`). The kernel has a path for
that with CAP_SYS_ADMIN and CONFIG_MEMORY_FAILURE: IORING_OP_MADVISE
with MADV_HWPOISON runs in an io-wq worker, and memory_failure() forces
SIGBUS onto it. We followed that path through the code but haven't run
it, the details are in [`tla/`](tla/README.md).

The green configurations take from six minutes to an hour and a
quarter each with 8 to 40 workers, the ones with a fix switched off
stop at their counterexample in seconds to minutes.

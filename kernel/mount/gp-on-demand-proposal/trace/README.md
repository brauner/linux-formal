# Trace validation of the mount reference count protocol

Tree: work.mount.gp_on_demand.trace at 7d6884cae537 "fs: debug-only
tracepoints for the mount reference-count protocol", one commit on
work.mount.gp_on_demand.proposal at 4379d47fd314.

The model in `../tla/` says what the protocol is allowed to do. Trace
validation asks the opposite question: is what a running kernel did
something the model allows? We record the reference count events of
real mounts, turn each mount's events into a trace and let TLC drive
the model through it, step by step. If the model can reproduce every
event in the order the kernel logged it, the trace is accepted. If it
gets stuck, either the kernel did something the model forbids or the
model is too coarse to express it, and the log says at which event.

The tracepoint patch adds eleven events to include/trace/events/mount.h:
mntget(), the fast path and the slow path of mntput_no_expire(),
__legitimize_mnt(), umount_tree(), the caller's drop in do_umount(), the
peek, the grace period, the final put, cleanup_mnt() and the free. Every
event carries mnt_id_unique and the mount_lock sequence count, which
gives the events under mount_lock a total order across CPUs.

## Files

| File | What it is |
|---|---|
| `trace2ndjson.py` | splits an ftrace dump of the mount events into one NDJSON file per mount; line 1 is the configuration (tasks, mode, budgets) derived from the trace, the rest are the events with the model task that performs each; its docstring is the mapping |
| `MntPutTrace.tla`, `MntPutTrace.cfg` | the trace spec: extends `../tla/MntPut.tla`, consumes each task's events in program order and the locked events in mount_lock order, lockless events of different tasks interleave freely, model steps no event logs are free |
| `validate.sh` | runs TLC on one or more NDJSON files, appends a verdict per file to `results.tsv` |
| `traces/selftest.txt`, `ndjson/selftest/` | the ftrace dump of the unheld_umount_test selftest and its 58 per-mount traces |
| `results.tsv`, `selftest-summary.txt`, `selftest-validate.out` | the verdicts for the selftest traces |
| `results-fix.tsv` | a rerun of two of the selftest traces |
| `results/` | the verdicts for the stress runs: `results-walk.tsv`, `results-held.tsv`, `results-expire.tsv` |
| `jens/` | the collection pipeline as it ran on the build machine: kernel build with `trace.config`, an initramfs whose `trace-init.sh` enables the events and runs the workloads, the qemu run, `extract.py` to split the trace disk, `tlc-batch.sh` to validate a sample |

## Results

| Traces | Mounts | Verdict |
|---|---|---|
| unheld_umount_test selftest | 58 | 57 accepted, 1 rejected |
| gpbreak walk run | 700 sampled | all accepted |
| gpbreak held run | 500 sampled | all accepted |
| gpbreak expire run | 500 sampled | all accepted |

The one rejection, mount 2147483720, is the root copy of a namespace
that dies, whose holder references change owner across fork() and
unshare(): copy_fs_struct() takes a reference in the parent and the
child drops it. The converter keeps a ledger per pid and the model has
references per task, so neither can express a reference that moves from
one task to another. That's a limit of the granularity, not a
discrepancy in the kernel.

The model has two more gaps of that kind. Write sections of mount_lock
that have nothing to do with the traced mount aren't in it, so they
can't explain a walker's failed read_seqretry() before umount_tree().
And the model's namespace death never sets MNT_SYNC_UMOUNT, which the
children of a synchronously unmounted tree carry.

The first converter assigned the ranks of locked events over all events,
including the ones it pruned or folded into the model's initial state.
That left gaps in the order and every trace with such an event was
rejected, six of the walk run and eighteen of the expire run in the
first batch. The ranks are now assigned over the emitted events only,
and the stress run verdicts above are from the fixed converter.

Mount ids above 2^31 print negative in TLC, which has 32-bit integers.
The file name carries the real id.

## Running

The trace spec needs a newer TLC than the models: `tla2tools-1.8.0.jar`
and the TLA+ community modules (`CommunityModules-deps.jar`, for the
JSON reader), both in `../../../../tools/` by default (see
`tools/README.md`). From this directory:

    python3 -I trace2ndjson.py traces/selftest.txt ndjson/selftest
    ./validate.sh ndjson/selftest/*.ndjson

`MODEL=` names the directory `MntPut.tla` is taken from (`../tla` by
default), `TLA2TOOLS=` and `COMMUNITY_MODULES=` the jars, `TLC_TIMEOUT=`
and `TLC_HEAP=` bound a run. The scripts in `jens/` assume the layout of
the machine they ran on (`~/tmp/gp-trace/`, a kernel tree under
`~/src/git/linux`, the umount-bench workloads) and are there as a record
of how the traces were made.

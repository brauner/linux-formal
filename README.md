# Formal models of Linux kernel code

These are the formal models I write when I work on or review changes to
the VFS. Most of them are TLA+ specifications checked with TLC. Where
memory ordering matters there are litmus tests for the Linux kernel
memory model as well, run with herd7 under the kernel's model and the
AArch64 and POWER architectural models, and with klitmus7 on hardware.
The C functions of fs/super.c and of one mount series went through
CBMC, that series also through Dartagnan, and its TLA+ model was
validated against real kernel traces.

The code covered here is concurrent and mostly lockless: reference
counts dropped on several CPUs at once, RCU path walks racing mount and
umount, the coredump rendezvous racing signals, exit and exec. A
reproducer only finds the interleavings it happens to hit. A model
checker goes through all of them for a small configuration. So every
protection the code has becomes a switch in the model. With a switch
off TLC finds the trace the protection is there for. With all of them on
it proves the properties for every interleaving of that configuration.

Many of the models were written to check a series before it was sent
or merged, others to review code that is already in. Along the way they
found bugs in mainline and in the series themselves, listed below.

## Layout

`kernel/` has one directory per subsystem and in it one directory per
model, named for what it models. `kernel/mount/core/` models the mount
code itself, `kernel/mount/gp-on-demand-proposal/` a series that changes
it. A model of a series may carry its own copy of a module of another
model with the series applied, and says so. Inside a model every method
has a directory of its own:

    tla/       TLA+ models, their TLC configurations, traces and results
    litmus/    litmus tests for the Linux kernel memory model
    cbmc/      CBMC harnesses of the C functions
    dat3m/     Dartagnan harnesses of the C functions
    trace/     validation of kernel traces against a TLA+ model

The README.md of a subsystem lists its models. The README.md of a model
is where to start: it says where the code stands, what the code does
and what the models check, pins the tree, and lists the findings with
what became of each. The README.md of a method directory is the
reference: which model action stands for which function, what the model
leaves out, every switch and property, and every configuration with its
result.

`tools/` is where the jars go, see [`tools/README.md`](tools/README.md).

## Where the code stands

The line under the title of every model's README says where the code
it describes stands:

    mainline            the code is in Linus' tree
    queued for vX.Y     applied to a tree for the next merge window
    proposed            not applied anywhere
    not merged          dropped or replaced, kept as the record

followed by what that means for the model: "as modelled", or what
changed in the code after the model ran. A model of a series that has
landed is a model of mainline as of that series. When a series lands
nothing moves, only that line changes. `git grep '^Status:' kernel`
lists them all.

## The models

File descriptor tables, [`kernel/files/`](kernel/files/):

| Model | What it models | Methods | Status |
|---|---|---|---|
| [`sync-close/`](kernel/files/sync-close/) | the order in which a dying descriptor table closes its files, against exit, exec and fork | TLA+ | queued for v7.4 |
| [`close-range/`](kernel/files/close-range/) | close_range() with CLOSE_RANGE_EXCEPT and CLOSE_RANGE_CLOEXEC_ONLY, and the clone dup_fd() makes for it | TLA+ | queued for v7.4, revised since |

Coredumps, [`kernel/coredump/`](kernel/coredump/):

| Model | What it models | Methods | Status |
|---|---|---|---|
| [`rendezvous/`](kernel/coredump/rendezvous/) | the coredump rendezvous and the signal, exit, fork, exec and io-wq code around it | TLA+ | queued for v7.4, revised since |

Mounts, [`kernel/mount/`](kernel/mount/):

| Model | What it models | Methods | Status |
|---|---|---|---|
| [`core/`](kernel/mount/core/) | the mount code: the propagation algebra against the documentation, a mount's reference count, the RCU path walk, do_lock_mount(), WRITE_HOLD and the lifetime of a mount namespace | TLA+ | mainline, at v7.3-rc3 |
| [`ownership/`](kernel/mount/ownership/) | who owns an unmounted mount: the reference count cycle a loop device can close, and four answers to it compared | TLA+ | mainline, at v7.3-rc3; three of the answers not merged |
| [`covers/`](kernel/mount/covers/) | mainline's answer: the cover an unmounted mount leaves on its unmounted parent instead of staying attached, and the lookups that find it | TLA+ | mainline |
| [`shrink-submounts/`](kernel/mount/shrink-submounts/) | shrink_submounts() taking the automounts below a mount down during a synchronous umount | TLA+ | mainline |
| [`vacant/`](kernel/mount/vacant/) | the vacant-mount series: unmounted mounts keep their own reference and are vacated in place | TLA+ | not merged |
| [`vacant-root-by-root/`](kernel/mount/vacant-root-by-root/) | the vacant-mount series with propagate_umount() handing the unmounted set back root by root | TLA+ | not merged |
| [`gp-on-demand-proposal/`](kernel/mount/gp-on-demand-proposal/) | unmounting without a grace period when nothing else holds the mounts | TLA+, LKMM litmus, Dartagnan, CBMC, trace validation | proposed |
| [`gp-on-demand/`](kernel/mount/gp-on-demand/) | the same series in its first shapes | TLA+ | not merged |

Superblocks, [`kernel/super/`](kernel/super/):

| Model | What it models | Methods | Status |
|---|---|---|---|
| [`core/`](kernel/super/core/) | fs/super.c: the superblock lifecycle, the device-to-superblock table and the block layer's holder operations, and freezing | TLA+, CBMC, LKMM litmus | mainline, at fc1c25014ff8 |
| [`unborn-wait/`](kernel/super/unborn-wait/) | a version of a device table fix that wasn't taken, kept as the record of the alternative | TLA+, CBMC | not merged |

## What the models found

The model READMEs have the details, the traces and what became of each
finding. In short:

- **Mounts**: clone_mnt() drops T_UNBINDABLE, so a cloned namespace can
  bind what the original could not. A holder migrating between CPUs
  makes mnt_get_count() come out one short, and a synchronous umount
  succeeds with a file still open on the mount. do_set_group() accepts
  an unbindable target. And since v4.13 propagate_mount_busy() misses
  copies that propagate_umount() then takes, so again a synchronous
  umount succeeds with a mount in use. The documentation of shared
  subtrees disagrees with the code in five places. All four bugs and
  the worst of the documentation are fixed in mainline.
  [`kernel/mount/core/`](kernel/mount/core/)
- **Mount ownership**: the reference count cycle Michael Vogt reported,
  and two more ways to close it that the revert of 0342482a4d15 doesn't
  cover, one of them reproduced on a running kernel. With mainline's
  covers only cycles of pins survive, and a lookup on a dead parent
  still never shows what a locked mount covered.
  [`kernel/mount/ownership/`](kernel/mount/ownership/),
  [`kernel/mount/covers/`](kernel/mount/covers/)
- **shrink_submounts()**: checking every shrinkable submount before
  unmounting any lets propagation pull out a mount that is in use, and
  the walk that replaced it needs its restart or it follows a stale
  cursor. Fixed in mainline, with the restart.
  [`kernel/mount/shrink-submounts/`](kernel/mount/shrink-submounts/)
- **Superblocks**: the block layer's holder operations act on a
  superblock through a device claim it already dropped, which with btrfs
  leaves a filesystem frozen or a device that can't be mounted again. A
  freeze that fails at the last step leaves the superblocks frozen with
  a hold nobody owns, and a thaw behind the block layer's back leaves
  the device unmountable. A filesystem error that sets SB_RDONLY on a
  frozen superblock leaves its write locks held after the thaw.
  fserror_unmount() can miss its wakeup on weakly ordered CPUs, and
  concurrent writers lose s_flags updates.
  [`kernel/super/core/`](kernel/super/core/)
- **Coredumps**: the trace each patch of "coredump & signals: an
  impossible affair" fixes, among them a deadlock between an SQPOLL
  thread and its io-wq worker and a use-after-free in coredump_finish(),
  and one way io_uring still cuts a core dump short that the series
  doesn't cover.
  [`kernel/coredump/rendezvous/`](kernel/coredump/rendezvous/)
- **Closing files**: closing a dying descriptor table synchronously in
  ascending order hangs where the old order didn't, a failed fork can
  deadlock against sched_ext, and the foreground job of an exiting
  session leader can miss its SIGHUP.
  [`kernel/files/sync-close/`](kernel/files/sync-close/)
- **The vacant-mount series**: an RCU path walk that climbs out of a
  vacated bind mount, a double free and a lost release in drafts of the
  handoff, a lost release when a vacant mount rides the wrong list, and
  fsnotify accounting that never drops back to zero.
  [`kernel/mount/vacant/`](kernel/mount/vacant/)
- **The grace period on demand**: the protocol holds, the inner smp_mb()
  of mnt_get_count() is load-bearing in a way the TLA+ model can't show,
  and the three outer ones are redundant.
  [`kernel/mount/gp-on-demand-proposal/`](kernel/mount/gp-on-demand-proposal/)

## Reading a TLA+ directory

The `tla/` directories share their conventions.

- `<Name>.tla` is a model. Where a directory has `MC_<layout>.tla`
  files, each fixes the constants of one layout: which tasks, mounts or
  devices exist and what each one may do.
- `<layout>_<what>.cfg` is a TLC configuration, mostly generated by
  `gen-cfgs.py`. Its first line says what to expect: a pass, or the
  invariant or property that has to fail and why.
- The `FIX_*` constants are the switches. Each stands for a fix the
  code has or a series adds, and off means the code without it.
  Configurations with every fix on (`*_fixed` and the like) have to
  pass. Configurations with one fix off have to fail with the trace that
  fix prevents.
- Witnesses (`*_witness_*`) check an invariant that says some case
  never happens, and are expected to fail. That's the proof that the
  case is actually reached and the passing configurations aren't
  vacuous.
- `traces/` has the counterexamples of the configurations that are
  expected to fail, some with the interleaving in words. `RESULTS.txt`
  or the results section of the README has the verdict, the distinct
  states and the time of every configuration.
- Result headers name where a run was made. "jens" is a 512-core build
  machine shared with others, where the long runs went. "local" is a
  laptop.

## Running

The TLA+ models need Java 17 or newer and `tla2tools.jar` from
https://github.com/tlaplus/tlaplus/releases. The models were checked
with TLC 2.19, the tla2tools.jar of 08 August 2024, the trace validation
needs a newer one. Point `TLA2TOOLS` at the jar, or put it into `tools/`
and symlink it into the `tla/` directory:

    export TLA2TOOLS=/path/to/tla2tools.jar
    cd kernel/files/sync-close/tla
    ./check-all.sh                     # all 17 configurations, seconds
    cd ../../../coredump/rendezvous/tla
    ./check.sh cdhole_no_gate 4        # one bug configuration, 4 workers

`check.sh <configuration> [workers]` runs one configuration and logs it
to `logs/<configuration>.log`. Most directories also have `check-all.sh`
or `run-parallel.sh` with `summarize.sh` for the whole set, and a
`show-trace` or `extract-trace` script that prints a counterexample
compactly. Environment variables like `TLC_HEAP` and `TLC_METADIR`
tune a run, and the method README says which ones its scripts take.

The litmus tests need herd7 (herdtools7 7.58 was used) and the
`tools/memory-model` directory of a kernel tree:

    cd linux/tools/memory-model
    herd7 -conf linux-kernel.cfg <path>/litmus/MNT-A1-holder-get-before-put.litmus

CBMC, Dartagnan and the trace validation have their run notes in their
own directories.

How long a run takes varies a lot. Configurations that switch a fix off
stop at their counterexample in seconds to minutes. The green proofs
explore tens of millions of states and want a big machine and up to an
hour each, a few of the mount layouts much longer. Every README says
what to expect.

## Caveats

- A model describes the tree it names. It isn't updated when the code
  changes afterwards, its status line says how far the code has moved.
  When a series changes enough, it gets a new model next to the old
  one, the way `kernel/mount/vacant/` was followed by
  `kernel/mount/vacant-root-by-root/`.
- TLC checks every interleaving of a small configuration: a few tasks, a
  handful of mounts, two CPUs. A pass is a proof for that
  configuration. Where it matters, the method README argues why the
  bound is enough or says that it isn't.
- Every model leaves things out, listed under "Abstractions" or "Not
  modelled" in its README. A pass says nothing about what isn't in the
  model.
- Branch names in the outcome columns are the branches the fixes were
  written on.

## License

MPL-2.0, see [`LICENSE`](LICENSE). Code copied in from elsewhere keeps
its own license: the CBMC harnesses contain functions copied from the
kernel, which are GPL-2.0, and the cat files under `dat3m/` are
GPL-2.0+, as their SPDX lines say.

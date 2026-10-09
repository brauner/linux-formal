# gp-trace: TLA+ trace validation of the mount refcount protocol -- RESUME

Working dir (local): this directory (scratchpad/trace). Copy to
~/src/git/linux-tla/kernel/work.mount.gp_on_demand.proposal/trace/ at the end
(never git add/commit there).

## State
- Patch: worktree /home/brauner/src/git/linux/vfs/work.mount.gp_on_demand.trace,
  branch work.mount.gp_on_demand.trace, commit 7d6884cae537 on 4379d47fd314
  ("fs: debug-only tracepoints for the mount reference-count protocol").
  11 events in include/trace/events/mount.h; compile-affected.py gcc+clang W=1 clean.
  Pushed: build-jens refs/heads/review/gp-trace (push via ssh://jens/... alias;
  the build-jens remote URL fails from here).  On jens: cat-file -t 7d6884cae537 = commit.
- jens: ~/tmp/gp-trace/{SHA,build.sh,run-vm.sh,trace-init.sh,extract.py,pipeline.sh,trace.config}
  tmux session `gptrace` runs pipeline.sh: build (unshare -rm tmpfs, CPUs 256-511, -j64, -t)
  -> /tmp/brauner-tomb-holders/umb-trace/{arch/x86/boot/bzImage,.config,System.map,selftests/,SHA}
  -> mkinitrd (gpbreak from runs/gp1007b/initrd-churn.cpio, selftests as /t/*)
  -> qemu on CPUs 256-263, 8 vcpu, 8G, virtio disk ~/tmp/gp-trace/trace.img
  -> extract.py -> ~/tmp/gp-trace/traces/{selftest,walk,held,expire}.txt
  Logs: ~/tmp/gp-trace/progress.log, build.out, vm.log, pipeline.out
- Local tooling: downloads/cm/CommunityModules-deps.jar (fetched), tla2tools at
  ~/src/git/linux-tla/kernel/mount/tla2tools.jar, Java 25 local and on jens.

## Next steps
1. `ssh jens cat ~/tmp/gp-trace/progress.log` -- wait for "pipeline: done".
   If the VM hung: `ssh jens tail -50 ~/tmp/gp-trace/vm.log`.
2. Convert on jens or locally: `python3 -I trace2ndjson.py <trace.txt> <outdir>` (per-mount NDJSON).
3. Validate: `./validate.sh <outdir>` runs TLC on MntPutTrace.tla per mount file.

## Update (after the first validation runs)
- Model used: ~/src/git/linux-tla/kernel/work.mount.gp_on_demand.proposal/MntPut.tla (its README existed), the
  two-mount batch model; the traced mount is "A", "B" a phantom nobody touches; MODE from the trace
  ("umount" with mnt_caller_drop, else "nsdeath"), LAZY = ~sync.  Spec: MntPutTrace.tla + MntPutTrace.cfg,
  runner validate.sh (env TLA2TOOLS=./tla2tools-1.8.0.jar, the kernel/mount jar is too old for the
  CommunityModules jar: NoClassDefFoundError KSubsetValue).  Converter: trace2ndjson.py (docstring = mapping).
- Selftest traces (ndjson/selftest, results.tsv + results-fix.tsv): 57/58 ACCEPTED, mnt-2147483720 REJECTED:
  nsdeath root copy whose holder refs cross pids (fork's copy_fs_struct: parent gets, child puts) -- the
  per-pid ledger of the converter and the model's per-task references cannot express a reference changing
  owner.  Granularity, not a kernel discrepancy (see report).
- jens: ~/tmp/gp-trace/tla/ (spec, jars, model/MntPut.tla, tlc-batch.sh); tmux `gptlc` runs
  tlc-batch.sh walk 600 100; held 400 100; expire 400 100 -> results-{walk,held,expire}.tsv, logs/.
  NOTE: the first batch ran with a spec bug (inner CASE not parenthesized: every trace with mnt_get/
  mnt_put_fast errored); old results in tla/old/. If `tmux ls` shows no gptlc, restart with:
    ssh jens 'cd ~/tmp/gp-trace/tla && mkdir -p old && mv results-*.tsv old/ 2>/dev/null; tmux new -d -s gptlc "bash -c \"bash ./tlc-batch.sh walk 600 100; bash ./tlc-batch.sh held 400 100; bash ./tlc-batch.sh expire 400 100\""'
- Next: for each REJECTED in results-*.tsv: scp jens:~/tmp/gp-trace/ndjson/<run>/<file> and logs/<file>.log,
  read the "next events per task" line, classify (granularity vs discrepancy).  Known granularity gaps:
  cross-task reference transfer; unrelated mount_lock write sections (not in the model) explaining a
  walker's seqretry failure before umount_tree; MNT_SYNC_UMOUNT children of a sync tree (model nsdeath has sync=FALSE).
- Cosmetic: mnt ids > 2^31 print negative in TLC (32-bit IntValue); the file name carries the real id.
- FIX 2 (converter): locked ranks (lk) are now assigned over the emitted events only; before, a pruned or
  Init-mapped locked legitimize left a gap and every such trace was REJECTED (the 6 walk / 18 expire
  rejections of the first jens batch were this).  jens tmux `gptlc` re-converts walk/held/expire and
  re-runs the batch (results in ~/tmp/gp-trace/tla/results-{walk,held,expire}.tsv; old runs in tla/old*/).
- jens batch 3 failed (all ERROR rc=10): the inline tmux command mangled the loop variable and converted
  into the wrong directory.  Batch 4 runs ~/tmp/gp-trace/tla/reconvert-and-batch.sh (tmux `gptlc`):
  reconvert walk/held/expire, then tlc-batch.sh for each -> tla/results-{walk,held,expire}.tsv.
  To read: ssh jens 'cd ~/tmp/gp-trace/tla; for r in walk held expire; do echo $r; cut -f2 results-$r.tsv | sort | uniq -c; done'
  Then for each REJECTED: grep -o '"REJECTED".*' logs/<file>.log  and  cut -c1-170 ../ndjson/<run>/<file>.ndjson

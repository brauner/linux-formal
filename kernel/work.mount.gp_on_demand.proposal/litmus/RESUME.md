# RESUME: weak-memory follow-up (hardware models + klitmus on jens)

Written 2026-10-09 ~08:45 UTC. Laptop session may be suspended; everything long-running is on jens.

## jens pipeline -- FINISHED 08:5x UTC (STATE=vm-done); results in ~/tmp/klitmus/vm.log, copied to litmus/x86-klitmus.txt
## (history below; the build tree was removed by step5, ~/tmp/klitmus is 29 MB: bzImage, config, kmod/*.ko + sources, logs)
- Orchestrator: `~/tmp/klitmus/run-all.sh` -> log `~/tmp/klitmus/run-all.log`, state file `~/tmp/klitmus/STATE`
  (pipeline-start | building-kernel | building-modules | building-initrd | running-vm | cleaning | done | *-failed).
- Steps (separate scripts, fixable while an earlier one runs): step1-build.sh (build-kernel.sh of 4379d47fd314,
  perf config, -C 256-511 -j 64, then modules_prepare; log build.log), step2-modules.sh (klitmus7 modules for the
  12 barrier tests from ~/tmp/lkmm/litmus, one dir each under ~/tmp/klitmus/kmod/<test>/, .ko copied to
  kmod/<test>.ko; log modules.log), step3-initrd.sh (mkinitrd.py with init.sh + the .ko files; log initrd.log),
  step4-vm.sh (qemu KVM, 8 vcpus pinned 256-263, 4G, 90 min timeout; log vm.log), step5-cleanup.sh (removes the
  build tree + worktree, keeps bzImage/config/.ko/logs; log cleanup.log).
- Waits on `~/tmp/jens-bigvm.lock` (poll 120 s) before the build and before the VM.
- Collect: `ssh jens 'cat ~/tmp/klitmus/STATE; grep -E "^===== MODULE|^Observation|insmod failed" ~/tmp/klitmus/vm.log'`
  Each module prints a herd-style result block to /proc/litmus: `Observation <name> Never|Sometimes|Always <pos> <neg>`.
- If STATE is build-failed: see build.log. If modules failed: kmod/<test>/make.log. If the VM hung: vm.log, then
  `tmux attach -t klitmus`. Never kill other users' processes; other tmux sessions on jens (dat3m, gpscale, tlagp,
  gpl3c) belong to other agents.
- Disk: /home had 17 GB free; the build tree is removed by step5 only if modules were built. If STATE != done,
  check `du -sh ~/tmp/klitmus/build` and remove it by hand once the .ko files exist
  (`git -C ~/src/git/linux worktree remove --force ~/tmp/klitmus/build/src; rm -rf ~/tmp/klitmus/build`).
- Rerun the VM with different parameters: `KLITMUS_NRUNS=50 KLITMUS_SIZE=200000 bash ~/tmp/klitmus/step4-vm.sh > vm2.log`.

## Local (scratchpad litmus/)
- gen-asm.py generates aarch64/*.litmus and ppc/*.litmus from the abstract programs; run-asm.sh runs herd7 on all
  with the Arm official model (aarch64.cat) and ppc.cat, writing <arch>/<test>.out and <arch>/summary.txt.
- Memo: ../research-weak-memory-2.md (this follow-up), ../research-weak-memory.md (first memo).

## Status at hand-off (09:00 UTC)
- x86 KVM klitmus run: complete, 14 modules, see x86-klitmus.txt and research-weak-memory-2.md.
- herd7 hardware-model runs: aarch64/ and ppc/ *.out; B-family tests were still running at hand-off (one herd7 per
  test, started 08:52; AArch64 B tests take ~5-10 min each). Regenerate the table with ./collect-results.sh.
  If the laptop was suspended mid-run the processes resume after wake; a missing Observation line in a .out means
  the run did not finish: rerun with `herd7 -model aarch64.cat -speedcheck true aarch64/<test>.litmus`.
- First run of qemu on jens hung silently: `timeout` without --foreground + qemu -nographic reading the tty ->
  SIGTTIN stop. step4-vm.sh now uses `timeout --foreground` and `< /dev/null`.

## Worktree note (09:00 UTC)
- The worktree HEAD moved during this work: tip is now 1f89fe6a27e1 (rewritten series) and it contains
  e0d99540489b "fs: drop the smp_mb()s that mnt_get_count() made redundant". The jens kernel/klitmus run was
  built from 4379d47fd314 (the tip when the task started); the klitmus modules carry the barriers of the litmus
  tests themselves, not of the kernel, so the results are unaffected by that commit.
- jens: nothing of mine is running any more (tmux `klitmus` ended with STATE=vm-done).

## POWER lock-emulation fix (09:58 UTC)
- The first POWER translation emulated spin_lock as `lwarx; stwcx.; beq ok; li r,1; ok: isync`. Under ppc.cat the
  branch on stwcx.'s CR0 carries no dependency from the lwarx load, so the isync is not a ctrl+isync acquire and
  the critical section's loads were unordered against the lock: MNT-B2 on POWER produced a spurious witness
  (walker read flags=0 under the "lock" after the unmounter had finished the mount). Probe files:
  ppc/probe-lock-acq-emul.litmus (Sometimes) vs ppc/probe-lock-acq-kernel.litmus (Never).
- gen-asm.py now emits the arch_spin_lock shape (lwarx; cmpwi; bne fail; stwcx.; bne fail; isync). Old outputs
  are in ppc/old-emul/. All 14 POWER tests were relaunched (one herd7 each); results land in ppc/*.out and
  ppc/summary-par.txt; `collect-results.sh` prints the table. "Never" results from the old emulation stay valid
  (a weaker lock only adds behaviours); the witnessed ones needed the rerun.

## Hand-off 2 (10:57 UTC)
- Final table sent to the coordinator. Still running when sent: aarch64 MNT-B2 (>2 h CPU), POWER reruns of B1,
  B1m-walker-nomb, B1m-peek, B2 (~55 min CPU each). They keep writing <arch>/<test>.out when done;
  ./collect-results.sh prints the table. The reduced variant MNT-B2r (LKMM C file in litmus/, asm in aarch64/ and
  ppc/) is Never under LKMM, the Arm model and ppc.cat with the corrected lock, and settles the B2 question.

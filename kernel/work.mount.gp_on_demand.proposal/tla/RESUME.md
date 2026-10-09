# RESUME (working notes, delete when done)

Task: TLA+ model of work.mount.gp_on_demand.proposal @ 4379d47fd314 (two-mount
batch, mntput_unmounted()), run on jens, results into README.md/RESULTS.txt.

## State at the report (2026-10-09 10:55 local = 08:55 UTC)

- Model, scripts, 62 cfgs, README.md, RESULTS.txt and traces/ (15 expected
  violations) are in place; nothing is committed (another session has uncommitted
  work in this repo: do not `git add -A`).
- jens batch started 08:32 UTC in tmux session `tlagp`, directory
  `~/tmp/tla-gp-proposal`: `MAXJOBS=16 taskset -c 256-511 ./run-parallel.sh 16 8g`
  (CPUs 256-511 only).  58/62 finished, all `ok` (logs/ here has them).
- Still RUNNING at report time (distinct states so far): full_lazy (8.1M),
  full_lazy_g0 (12.6M), hh_lazy_weak (7.2M), hh_recheck_weak (14.9M).  All expected
  to pass; RESULTS.txt and README.md (results section) say RUNNING / expected pass.
- `logs/summary.txt` on jens ends with ALL-DONE when run-parallel.sh is through.

## To collect (any time after the laptop wakes up)

    ssh jens 'tail -3 ~/tmp/tla-gp-proposal/logs/summary.txt'        # ALL-DONE?
    ssh jens 'cd ~/tmp/tla-gp-proposal && ./summarize.sh'            # partial table any time
    cd ~/src/git/linux-formal/kernel/work.mount.gp_on_demand.proposal
    rsync -a jens:tmp/tla-gp-proposal/logs/ logs/
    ./summarize.sh && { echo '# TLC on jens (16 workers x 8g per run, CPUs 256-511), 2026-10-09'; cat logs/summary.txt; } > RESULTS.txt
    # any MISMATCH: ./show-put-trace.py logs/<cfg>.log > traces/<cfg>.txt, read it,
    # and fix the results section of README.md (the four RUNNING rows claim pass).
    # If all four pass: drop the RUNNING paragraph from README.md's Results section.
    # Then delete this file.

If a run is still going: the tmux session keeps it alive (`tmux attach -t tlagp`
on jens).  To stop one run: `pgrep -f -a "<cfg>.cfg"` on jens for its exact PID,
then `kill <pid>` (never pkill -f with a pattern).  The metadir with checkpoints
is /tmp/brauner-tlc-gp-proposal/<cfg>/ on jens; rerunning ./check.sh <cfg>
resumes from the newest checkpoint.

#!/usr/bin/env python3
"""Replace the RESULTS_TABLE marker in README.md with logs/summary.txt and copy
the summary to RESULTS.txt."""
import pathlib
here = pathlib.Path(__file__).resolve().parent
summary = here / "logs" / "summary.txt"
desc = {
 "refine_new": "the series, all twelve flag combinations, every table of one or two words of three bits: Refines, CloneOK, NoRefOnDropped, Sized",
 "refine_new_3w": "the same over three words of two bits",
 "refine_new_w4": "the same over two words of four bits (1.7M tables, needs -maxSetSize)",
 "refine_old": "the code before the series with its two flags: Refines, CloneOK",
 "refine_old_refs": "the code before the series: NoRefOnDropped (the clone references what it then closes again)",
 "refine_no_last_word_mask": "last_fd_to_close() without BITMAP_LAST_WORD_MASK(n): Refines (a claimed slot at the bound ends the walk)",
 "refine_skip_off_by_one": "the skip of an empty stretch resumes a word too low: Refines (the word holding the last open descriptor is skipped)",
 "refine_hop_off_by_one": "the hop resumes a word too low: Refines (the word below the window is skipped)",
 "refine_hop_partial": "the hop also takes a word that sticks out above the window: Refines (what sits above the window in that word stays open)",
 "refine_no_range_mask": "last_fd_to_close() without dup_fd_dropped_word(): Refines (the walk closes what the range and the flags keep)",
 "refine_size_no_except_clamp": "sane_fdtable_size() keeps the last descriptor above a FD_RANGE_EXCEPT range: Sized",
 "race_fixed": "__range_close() against open, fd_install, close, F_SETFD and table growth: ClosedOnlySelected, Bounded, Terminates",
 "race_fixed_w2": "the same walk with two-bit words",
 "race_no_range_mask": "last_fd_to_close() without dup_fd_dropped_word(): ClosedOnlySelected (the walk closes a descriptor the flags keep)",
 "dupfd_new": "dup_fd() against the lockless fd_install() and the unlocked resize: CloneOK, NoRefOnDropped, KeptCopied, DroppedNotInClone, CopiedAreFiles, Finishes",
 "dupfd_old": "the code before the series: the same without NoRefOnDropped",
 "dupfd_old_refs": "the code before the series: NoRefOnDropped",
}
rows = []
for line in summary.read_text().splitlines()[1:]:
    parts = line.split()
    if len(parts) < 6 or parts[0] == "ALL-DONE":
        continue
    cfg, expect, result, states, took, mark = parts[:6]
    rows.append(f"| `{cfg}` | {desc.get(cfg, '')} | {expect} | {result} | {states} | {took} |")
table = "| Configuration | What it checks | Expected | Result | States | Time |\n|---|---|---|---|---|---|\n" + "\n".join(rows) + "\n"
readme = here / "README.md"
text = readme.read_text()
assert "RESULTS_TABLE" in text or "| Configuration |" in text
if "RESULTS_TABLE" in text:
    text = text.replace("RESULTS_TABLE\n", table)
else:
    start = text.index("| Configuration |"); end = text.index("\n\n", start)
    text = text[:start] + table.rstrip("\n") + text[end:]
readme.write_text(text)
(here / "RESULTS.txt").write_text(summary.read_text())
print(table)

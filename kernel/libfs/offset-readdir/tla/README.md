# TLA+ model of readdir on directories with stable offsets

Tree: work.libfs.offset_readdir.v2 at 9ad16ae61045 on b44341e39d85.
Line numbers below are fs/libfs.c and mm/shmem.c at 9ad16ae61045, and
fs/libfs.c at b44341e39d85 for the code before.

`OffsetReaddir.tla` models a tmpfs directory as libfs keeps it for
readdir: the offset tree with its cyclic allocator, d_children, and the
dentries in both, changed by create, unlink, rename, rename over a name,
RENAME_EXCHANGE and RENAME_WHITEOUT as shmem does them. A lister opens
the directory and calls getdents64() until a call finds the end, with
the buffer filling up after any entry. Between calls it may telldir()
and later seekdir() back to that cookie, or lseek() past the end. Two
listers can run at once. The walk is a switch: the
d_children walk of b44341e39d85, that walk ending the listing where it
would restart, the descending walk of the offset tree of the fix, and
the ascending walk of the offsets the code started out with in
6faddda69f62 (v6.6).

## The code

Before the fix offset_iterate_dir() walked d_children from the head and
used the offset tree only to map ctx->pos back to a dentry when a call
resumed: offset_dir_lookup() (b44341e39d85 L475) found the entry with the
highest offset at or below ctx->pos and find_positive_dentry() (L449)
continued in d_children from there. List order and offset order only
agree as long as nobody renames over a name, exchanges two names or
wraps the offset allocator. When they disagree and the entry at ctx->pos
is gone, the resume lands anywhere in the list: the walk skips entries,
or with no lower entry restarts at the head and returns everything
again.

The fix walks the offset tree in descending offset order: one ma_state
for the whole call (L476), mas_find_rev() under rcu_read_lock() (L479),
a VFS_WARN_ON_ONCE() that the dentry is persistent (L483), ctx->pos =
dentry2offset() (L484), dir_emit() straight from the dentry,
DIR_OFFSET_EOD when the tree has nothing below (L488). It takes no
reference on the dentries it emits and doesn't pause the ma_state across
dir_emit(). That rests on the locking: every change to the offset tree,
and every unlink and rename of a dentry in it, happens with the parent's
i_rwsem held exclusive, readdir holds it shared, and every dentry in the
tree is a d_make_persistent() one.

## Abstractions

* Each directory operation is one step: shmem runs all of it under the
  parent's i_rwsem. Each find and each dir_emit() of the lister is one
  step. With `WRITERS_EXCL` directory operations can't run while the
  lister is inside a call, which is the kernel. Without it they can run
  between any two steps of a call.
* Offsets are DIR_OFFSET_MIN..DIR_OFFSET_MAX = 3..2+NOff. Fewer offsets
  only make the allocator wrap sooner.
* d_children holds the positive dentries of the directory, plus a dead
  one while the lister holds it. Negative dentries are left out: tmpfs
  dentries are DCACHE_DONTCACHE, a negative one never outlives the lookup
  or create it was made for, and every walk skips it.
* A call returns at least one entry, "." and ".." count for the first
  call (a smaller buffer is -EINVAL). The buffer may fill after any
  entry.
* A lister keeps nothing between calls but ctx->pos. So a telldir(),
  closedir(), opendir(), seekdir() round trip to the current position and
  an NFS READDIR resuming at a cookie are the same as the next
  getdents64() call. A telldir() cookie is the file position between two
  calls; a call can stop after any entry, so that covers every position
  glibc's buffered telldir() can hand out.
* Without `RCU_TREE` a writer changes nodes in place, so a find on a
  ma_state whose tree changed since its last find reads a changed tree
  (`NoStale`). The first find of a call starts from a fresh MA_STATE.
  Otherwise the offset tree is a map: mas_find_rev() on a ma_state kept
  across rcu_read_unlock() is taken to be fine as long as no writer ran,
  which lib/maple_tree.c bears out but its documented contract doesn't
  cover (see the landing page).

| Action | Kernel |
|--------|--------|
| `Create` | shmem_mknod() L3824 (create, mkdir, mknod): d_alloc() at the head of d_children (fs/dcache.c L2018), simple_offset_add() L294 with mtree_alloc_cyclic(), d_make_persistent() L3854 |
| `Unlink` | shmem_unlink() L3943 (unlink, rmdir): simple_offset_remove() L330, simple_unlink() drops the persistent reference |
| `Rename` | shmem_rename2() L3997 to a new name: simple_offset_add() of the negative target L4017 while the source still holds its offset, simple_offset_rename() L4033 moves the source there, d_move() puts it at the head (fs/dcache.c L3284) |
| `RenameOver` | shmem_rename2() over an existing name: simple_offset_add() of the target is -EBUSY, simple_offset_rename() gives the source the target's offset, shmem_unlink() of the target, d_move() |
| `Exchange` | RENAME_EXCHANGE: simple_offset_rename_exchange() L385 swaps the dentries in the tree so each name keeps its offset, __d_move() puts the target and then the source at the head (fs/dcache.c L3278, L3284) |
| `Whiteout` | RENAME_WHITEOUT: the target's offset first, shmem_whiteout() L3976 d_alloc()s the whiteout at the head (L3982) and gives it the next offset, then the rename |
| `RenameRead` | generic/736 in user space: rename each entry readdir() returned to a new name before the next readdir() |
| `Open` | opendir(): ctx->pos 0, so the first call runs dir_emit_dots() and the walk starts at DIR_OFFSET_FIRST |
| `CallStart` | getdents64() -> iterate_dir() takes i_rwsem shared -> offset_readdir() L514, which walks for every position but DIR_OFFSET_EOD (L522) |
| `FindOffset` | `WALK = "offset"`: mas_find_rev() L479 at or below ctx->pos (DIR_OFFSET_MAX for DIR_OFFSET_FIRST) on the first find, below the last entry after that; ctx->pos = dentry2offset() L484; DIR_OFFSET_EOD L488. With `REFS` a dget() of the entry (bed62856dba3). `WALK = "ascend"`: the same upwards from ctx->pos, offset_find_next() of 6faddda69f62 |
| `FindList` | `WALK = "list"`/`"list_eod"`: offset_dir_lookup() L475 and find_positive_dentry() L449 of b44341e39d85, then the next positive sibling, dget() before the dput() of the previous one |
| `Emit` | dir_emit() of the entry: d_name, d_inode->i_ino and ->i_mode |
| `Stop` | dir_emit() fails, the buffer is full: the call returns with ctx->pos at the entry it found |
| `Tell`, `SeekBack` | telldir() between two calls and a later seekdir() to that cookie, also after the listing ended: offset_dir_llseek() L438 |
| `SeekFar` | lseek() to a position past DIR_OFFSET_EOD: offset_dir_llseek() takes anything up to LONG_MAX |

## Files

| File | What it is |
|------|------------|
| `OffsetReaddir.tla` | the model |
| `MC_*.tla`, `*.cfg` | the layouts and TLC configurations, generated; `<layout>_<what>.cfg` runs `MC_<layout>.tla`, the header line says what to expect |
| `gen-cfgs.py` | writes the two above |
| `check.sh` | run one configuration (deadlock checking on) |
| `run-all.sh`, `run-parallel.sh`, `summarize.sh` | run them all one after the other or in parallel on a big machine, summarize `logs/` into `logs/summary.txt` |
| `RESULTS.txt` | that summary for the run below |
| `show-trace.py` | print a counterexample compactly |
| `traces/*.txt` | every counterexample of the table below, printed by `show-trace.py` |

## Running

    export TLA2TOOLS=/path/to/tla2tools.jar          # or the tla2tools.jar symlink here
    ./check.sh churn_v2 4
    ./run-all.sh 4                                   # everything, one after the other
    MAXJOBS=12 ./run-parallel.sh 16 16g              # everything, on a big machine
    ./show-trace.py logs/churn_base_skip.log

## Switches

| Constant | Meaning |
|----------|---------|
| `WALK` | `"offset"`: the descending walk of the offset tree (bed62856dba3, 9ad16ae61045). `"list"`: the d_children walk of b44341e39d85. `"list_eod"`: that walk ending the listing where it would restart at the head. `"ascend"`: the ascending walk of 6faddda69f62, with references |
| `REFS` | the offset walk takes a reference on the entry around dir_emit(), as v1 and its batched follow-up do; off is v2 |
| `WRITERS_EXCL` | directory operations hold the parent's i_rwsem exclusive, so none runs while a call is inside offset_readdir(); off lets them run between any two steps of a call, which no kernel does today |
| `RCU_TREE` | the offset tree is MT_FLAGS_USE_RCU, so a ma_state survives a writer by walking again; simple_offset_init() doesn't set it |
| `PAST_EOD` | `"relist"`: offset_readdir() walks for every position but DIR_OFFSET_EOD, which is the code. `"eod"`: it walks only below DIR_OFFSET_EOD, a one-line change |

The layout constants: `Names`, `NOff` offsets, `ND` dentries, `SetupOps`
directory operations before opendir() and `ChurnOps` while the listing
runs, `OpKinds` the operations allowed, `RenameOnRead` for generic/736,
`Track` to remember the dentries returned for `NoReReturn`, `Listers`
the listers, `Seeks` whether each may telldir() once and seekdir() back
once, `FarSeeks` whether each may lseek() past DIR_OFFSET_EOD once.

## Invariants and properties

* `TypeOK`.
* `DirOK`: the offset tree, d_fsdata, d_children and the dentries agree.
  Every entry in the tree is a positive dentry with that offset, names
  are unique, d_children holds the positive dentries and the dead ones
  the lister holds, a dead dentry is held by the lister.
* `NoDup`: no entry nobody touched since opendir() is returned twice.
  Touching a name means creating, unlinking or renaming it, either side
  of a rename or exchange.
* `Complete`: at the end of the listing every entry nobody touched has
  been returned exactly once. After a seekdir() back to a telldir()
  cookie: every untouched entry that hadn't been returned when the cookie
  was taken.
* `NoRepeat`: after a seekdir() back to a cookie, no untouched entry
  that had been returned when the cookie was taken comes back.
* `PastEODEmpty`: after an lseek() past DIR_OFFSET_EOD a listing returns
  nothing, as the ascending walk did before b9b588f22a0c and as
  dcache_readdir() does.
* `Bounded`: a listing returns at most one entry per offset, so no
  listing gets longer than the offset range.
* `ReReturnNeedsWrap`: a listing returns a dentry twice only after the
  allocator wrapped. Until then an entry created or renamed after
  opendir() gets an offset above everything the descending walk can
  still reach. With 2^31 offsets and `Bounded` that's what makes the
  descending walk end however often entries are renamed.
* `NoUAF`: dir_emit() never reads a freed dentry.
* `NoStale`: the walk never continues on a ma_state whose tree a writer
  changed (without `RCU_TREE`).
* `Terminates` (liveness, with weak fairness for the lister and the
  renamer): the listing reaches its end.

Witnesses, expected to be violated, show that the passing configurations
reach the cases that matter: `OrdersAgree` (d_children and offset order
disagree at opendir()), `NoCookieGone` (a call resumes at an offset
whose entry was unlinked or moved), `NoWrap` (the allocator wraps),
`NoReReturn` (a dentry is returned twice in one listing, a renamed one
that wrapped below ctx->pos), `NoSeekBack` (a seekdir() back to a
cookie taken after entries were returned, and the listing after it
reaches its end), `NoOverlap` (two listers inside getdents64() at the
same time).

## Layouts

| Layout | What |
|--------|------|
| `churn` | names a-d, 5 offsets; up to 4 creates, unlinks, renames, renames over a name and exchanges before opendir() and 2 while the listing runs |
| `wo` | names a-c, 5 offsets; creates, unlinks and RENAME_WHITEOUT, 3 before opendir() and 2 while the listing runs |
| `wrap` | names a-c, 3 offsets so the allocator wraps; 5 operations of every kind before opendir() and 2 while the listing runs |
| `rr` | generic/736: up to 5 creates and unlinks, then every entry readdir() returns is renamed to a new name; 4 offsets, so the renames wrap into the holes the unlinks left |
| `conc` | names a-c, 4 offsets; 3 operations of every kind before opendir() and 2 while the listing runs, inside a call where `WRITERS_EXCL` is off |
| `seek` | names a-c, 4 offsets; 3 operations of every kind before opendir() and 2 while the listing runs; telldir() once, seekdir() back once |
| `far` | names a-c, 4 offsets; 3 operations of every kind before opendir() and 1 while the listing runs; lseek() past DIR_OFFSET_EOD once |
| `two` | two listers; names a-c, 4 offsets; 3 operations of every kind before the first opendir() and 2 after it |
| `twoseek` | two listers, each with a telldir() and a seekdir() back; names a-c, 4 offsets; 2 operations of every kind before the first opendir() and 2 after it |
| `big` | names a-d, 5 offsets; 4 operations of every kind including RENAME_WHITEOUT before opendir() and 2 while the listing runs |

## Results (jens, 2026-11-01)

TLC 2.19, 12 workers per configuration.

    config                     expected   result     states     time     check
    big_v2                     pass       pass       66445731   08min17s ok
    churn_ascend               pass       pass       2404497    18s      ok
    churn_base_dup             violation  violation  1109199    08s      ok
    churn_base_skip            violation  violation  1240506    09s      ok
    churn_eod_skip             violation  violation  374961     04s      ok
    churn_v1                   pass       pass       2579253    19s      ok
    churn_v2                   pass       pass       2579253    19s      ok
    churn_witness_cookie       violation  violation  123108     02s      ok
    churn_witness_order        violation  violation  599        00s      ok
    conc_noexcl_rcu            violation  violation  5062       01s      ok
    conc_noexcl_rcu_refs       pass       pass       170794     02s      ok
    conc_noexcl_refs           pass       pass       215704     03s      ok
    conc_noexcl_refs_stale     violation  violation  10302      01s      ok
    conc_noexcl_stale          violation  violation  11005      01s      ok
    conc_noexcl_uaf            violation  violation  5483       01s      ok
    conc_v2                    pass       pass       66391      02s      ok
    far_ascend                 pass       pass       12178      01s      ok
    far_base                   violation  violation  2434       01s      ok
    far_v2                     violation  violation  2570       00s      ok
    far_v2_eod                 pass       pass       12175      01s      ok
    rr_ascend                  violation  violation  7335       01s      ok
    rr_base                    pass       pass       11696      02s      ok
    rr_v2                      pass       pass       14840      01s      ok
    rr_witness_rereturn        violation  violation  8970       02s      ok
    seek_base                  violation  violation  177458     03s      ok
    seek_v2                    pass       pass       447334     05s      ok
    seek_witness_seekback      violation  violation  195215     02s      ok
    two_base                   violation  violation  804371     06s      ok
    two_noexcl_rcu_refs        pass       pass       30263878   02min39s ok
    two_v1                     pass       pass       6264079    35s      ok
    two_v2                     pass       pass       6264079    34s      ok
    two_witness_overlap        violation  violation  1810       01s      ok
    twoseek_v2                 pass       pass       40910591   03min31s ok
    wo_base                    violation  violation  77598      02s      ok
    wo_v2                      pass       pass       178543     03s      ok
    wrap_base                  violation  violation  227680     03s      ok
    wrap_v2                    pass       pass       492085     05s      ok
    wrap_witness_wrap          violation  violation  234        00s      ok

* With the descending walk every layout passes, with and without the
  reference around dir_emit(): every untouched entry is returned exactly
  once, a listing returns at most one entry per offset, and the
  generic/736 loop ends. That holds through renames over names,
  exchanges, whiteouts and wraps of the allocator.
* The d_children walk returns an untouched entry twice
  (`churn_base_dup`, Nickolai's report): the listing stops at the oldest
  entry, that entry is unlinked, nothing has a lower offset, the walk
  restarts at the head. It skips untouched entries (`churn_base_skip`):
  after an exchange d_children reads d@4 b@5 a@3, the listing stops at
  d, d is unlinked, the resume lands on a@3 further down the list and b
  is never returned. Ending the walk instead of restarting
  (`churn_eod_skip`) turns the restart into a skip, as the commit message
  says.
* generic/736 terminates with the d_children walk as well (`rr_base`):
  renamed entries go to the head of d_children, behind the walk. That's
  why it passes before the fix too.
* The ascending walk of 6faddda69f62 returns every untouched entry
  exactly once (`churn_ascend`), but every rename gets the next offset,
  ahead of the walk, and comes back before the allocator ever wrapped
  (`rr_ascend`). With 2^31 offsets to go through that's how generic/736
  broke it.
* Once the allocator wraps, a renamed entry can land below ctx->pos and
  is returned again under its new name (`rr_witness_rereturn`), and the
  listing still ends (`rr_v2`).
* seekdir() back to a telldir() cookie works with the descending walk
  (`seek_v2`, `twoseek_v2`): exactly the untouched entries not returned
  when the cookie was taken come back, also when the cookie's own entry
  was unlinked or the listing had already ended. The d_children walk
  gets that wrong as it gets resuming wrong (`seek_base`).
* An lseek() past DIR_OFFSET_EOD makes v2 return the whole directory
  again (`far_v2`), and so does the d_children walk (`far_base`):
  offset_readdir() walks for every position but DIR_OFFSET_EOD itself
  and mas_find_rev() from past the end starts at the highest offset. The
  ascending walk before b9b588f22a0c returned nothing there
  (`far_ascend`). Walking only below DIR_OFFSET_EOD fixes it
  (`far_v2_eod`). The same reproduces on base and v2 kernels: three
  entries come back after lseek(S32_MAX + 1).
* Two listers don't disturb each other (`two_v2`, `two_v1`), also with
  both inside getdents64() at once (`two_witness_overlap`).
* v2's walk without references is safe because writers are excluded
  (`conc_v2`). Let them in and v2 emits a freed dentry
  (`conc_noexcl_uaf`) and walks a tree changed under its ma_state
  (`conc_noexcl_stale`). A reference alone keeps the dentry alive
  (`conc_noexcl_refs`) but not the tree (`conc_noexcl_refs_stale`), an
  RCU tree alone doesn't keep the dentry (`conc_noexcl_rcu`). Writers
  inside a call would need both (`conc_noexcl_rcu_refs`).

## Not modelled

A telldir() cookie used twice or several cookies at once: one cookie
and one seekdir() per lister. Positions between DIR_OFFSET_FIRST and
DIR_OFFSET_MAX that were never handed out behave like a cookie whose
entry is gone, which the model covers. The negative dentries in
d_children (see above). Directories
with millions of entries: the walk doesn't depend on the number of
offsets, only how soon the allocator wraps does. The memory model is
sequentially consistent; the i_rwsem acquire and release order the
tree's changes before the next call's walk.

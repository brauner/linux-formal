# readdir on directories with stable offsets

Status: proposed, as modelled. v1 was posted as "libfs: walk offset
directories in offset order"
(https://patch.msgid.link/20261030-work-libfs-offset_readdir-v1-1-ed733c14229e@kernel.org),
the model follows v2 on work.libfs.offset_readdir.v2, which isn't sent
yet.

| method | directory |
|---|---|
| TLA+ model of offset_readdir() and the tmpfs directory operations, its TLC configurations, traces and results | [`tla/`](tla/README.md) |

Tree: work.libfs.offset_readdir.v2 at 9ad16ae61045 on b44341e39d85.

tmpfs hands out a stable offset per directory entry from a cyclic
allocator and keeps the entries in a maple tree. Since b9b588f22a0c
(v6.14) readdir walked d_children and used the tree only to map the file
position back to a dentry when a getdents64() call resumed. d_children
and offset order disagree as soon as a rename goes over a name, two
names are exchanged or the allocator wraps. If the entry at the file
position is unlinked between two calls the walk then resumes anywhere in
the list: it skips entries nobody touched, or with no lower offset left
restarts at the head and returns the whole directory again, which is
what Nickolai Zeldovich reported. The fix walks the tree itself in
descending offset order. v2 keeps one ma_state for the whole call and
emits without taking references, because all writers hold the
directory's i_rwsem exclusive and readdir holds it shared. The model
checks the walk against every interleaving of creates, unlinks, renames,
renames over a name, exchanges and whiteouts with the calls of a
listing, with seekdir() back to a telldir() cookie, lseek() past the end
and two listers at once, and shows what the walk without references
relies on.

## Results

- With the descending walk every entry nobody touches while the listing
  runs is returned exactly once, a listing returns at most one entry per
  offset and the generic/736 loop that renames every entry it reads
  ends, through wraps of the allocator. With or without the reference
  around dir_emit().
- The d_children walk of b44341e39d85 returns untouched entries twice
  and skips them. Ending the walk instead of restarting it at the head
  loses entries as well. generic/736 passes with the d_children walk
  too: it checks that the listing ends, not what it returns.
- Once the allocator wraps a renamed entry can land below the file
  position and come back under its new name. The listing still ends.
- seekdir() back to a telldir() cookie brings back exactly the untouched
  entries that hadn't been returned when the cookie was taken, also once
  the listing had ended. Two listers don't disturb each other.
- An lseek() past DIR_OFFSET_EOD makes v2 return the whole directory
  again, as the d_children walk has done since b9b588f22a0c (v6.14).
  The ascending walk before it returned nothing there, as
  dcache_readdir() does. offset_readdir() only skips the walk for
  DIR_OFFSET_EOD itself, and the walk then starts at the highest offset.
  Skipping it for every position at or past DIR_OFFSET_EOD fixes that.
  Reproduced on base and v2 kernels: lseek(S32_MAX + 1) brings back
  every entry.
- The walk without references depends on the writers being excluded.
  With create or unlink running while a call is inside the walk, v2
  emits a freed dentry and walks a tree a writer changed under its
  ma_state. A reference only fixes the first, MT_FLAGS_USE_RCU only
  helps the second, both together would be needed.
- Open: the model takes the offset tree as a map. Keeping the ma_state
  across rcu_read_unlock() and dir_emit() is safe while no writer can
  run, but it is outside what the maple tree documents. Its contract
  wants mas_pause() before RCU is dropped, unless the lock that keeps
  writers out is the tree's own lock (MT_FLAGS_LOCK_EXTERN, as the VMA
  tree has with mmap_lock). Making i_rwsem the offset tree's lock would
  bring v2 within it, and lockdep would then check the writers too.

On jens with 12 workers each `big_v2` (66 million states) takes eight
minutes, `twoseek_v2` and `two_noexcl_rcu_refs` three, everything else
seconds. See [`tla/README.md`](tla/README.md#results-jens-2026-11-01).

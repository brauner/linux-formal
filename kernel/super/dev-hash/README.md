# The device table as a hashtable

Status: proposed, as modelled. work.super.dev_hash.fixups only changes a
comment in fs/super.c and the selftest.

| method | directory |
|---|---|
| TLA+ model of the device table as a hashtable and its TLC configurations, traces and results | [`tla/`](tla/README.md) |

Tree: work.super.dev_hash at de417b144a46, on 587d78169911
(work.super.fixes.core.claims) on fc1c25014ff8 (v7.3-rc6-301).

The branch replaces the rhltable of the device-to-superblock table with
a plain hashtable under a spinlock that every lookup takes. The walks of
the fs_holder_ops callbacks and user_get_super() keep their place with a
cursor on the walker's stack instead of pinning entries, so an entry is
unhashed and freed as soon as its last claim is dropped and no walk can
act on a claim that is gone. fs_bdev_register() checks the device's
freeze count and hashes a new claim under the same lock, so a refused
claim is never visible to a walk. The entry for s_dev is embedded in the
superblock and hashed from sget_fc(). The model checks the walks, the
claims and the freeze balance on the layouts of the earlier models and
on two with an erofs blob shared by two superblocks, and shows what each
of the cursor, the second look after an unborn superblock, the locked
frozen check and the locked lookup-and-insert is needed for.

## Results

- Every layout passes with the branch's code, among them the btrfs
  layouts that drop a claim during the mount or roll it back, and two
  with an erofs blob shared by two superblocks.
- Two concurrent registrations of one device and superblock no longer
  hash two entries. The lookup and the insert happen under one hold of
  the lock, and dropping the lock in between brings the duplicate back
  (`dtdup_no_atomic_claim`).
- The cursor, the second look after the wait for an unborn superblock,
  the frozen check under the lock and the atomic lookup-and-insert are
  each needed, without one of them TLC finds the trace. The second look
  only matters for claims dropped during the mount. A refused claim is
  never hashed.
- A claim dropped from a live superblock without bdev_deny_freeze()
  still breaks the freeze balance, and the cursor doesn't change that
  (`dtlive_no_deny`).

Every configuration finishes in under half a minute.

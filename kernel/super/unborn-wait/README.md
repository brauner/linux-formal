# Models of work.super.fixes.core.claims

| method | directory |
|---|---|
| TLA+ model of the device table and its TLC configurations, traces and results | [`tla/`](tla/README.md) |
| CBMC harness of the device table | [`cbmc/`](cbmc/README.md) |

Tree: work.super.fixes.core.claims at 587d78169911, on fc1c25014ff8
(v7.3-rc6-301).

The branch is a second take on "super: don't act on superblocks that
dropped their device claim". The fs_holder_ops walks pin an entry of the
device table and wait for SB_BORN with the pin held, so a claim dropped
while the superblock is still being set up (btrfs_free_extra_devids(), the
-EBUSY rollback of fs_bdev_register()) leaves the entry linked and the walk
acts on a superblock that no longer uses the device. Instead of counting
the claims of an entry separately and checking them under s_umount, the
branch never lets the cursor pin the entry of a superblock that is neither
SB_BORN nor SB_DYING: super_dev_get() waits for such a superblock with a
passive reference and looks again, from the head of the list or from the
previous entry it still pins. The branch was not taken; the version that
counts the claims was kept. These models are the record of the
alternative: with the switch on they pass every layout, with it off they
find the defect, and a claim dropped from a live superblock still needs
bdev_deny_freeze().

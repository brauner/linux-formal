# Superblocks

Models of fs/super.c and of the block layer's holder operations that
act on superblocks.

| Model | What it models | Status |
|---|---|---|
| [`core/`](core/) | the superblock lifecycle, the device-to-superblock table and its walks, freezing and the holder operations | mainline, at fc1c25014ff8 |
| [`unborn-wait/`](unborn-wait/) | the device table with a cursor that waits for an unborn superblock, a version of a fix that wasn't taken | not merged |
| [`dev-hash/`](dev-hash/) | the device table as a plain hashtable under a spinlock, with walks that keep their place with a cursor on the stack | proposed |

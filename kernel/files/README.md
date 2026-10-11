# File descriptor tables

Models of fs/file.c and of the code in exit, exec and fork that tears a
descriptor table down.

| Model | What it models | Status |
|---|---|---|
| [`sync-close/`](sync-close/) | the order in which a dying descriptor table closes its files, against exit, exec and fork | queued for v7.4 |
| [`close-range/`](close-range/) | close_range() with CLOSE_RANGE_EXCEPT and CLOSE_RANGE_CLOEXEC_ONLY, and the clone dup_fd() makes for it | queued for v7.4, revised since |

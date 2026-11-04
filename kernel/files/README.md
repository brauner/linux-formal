# File descriptor tables

Models of fs/file.c, of the code in exit, exec and fork that tears a
descriptor table down, and of the reference count of struct file.

| Model | What it models | Status |
|---|---|---|
| [`sync-close/`](sync-close/) | the order in which a dying descriptor table closes its files, against exit, exec and fork | queued for v7.4 |
| [`close-range/`](close-range/) | close_range() with CLOSE_RANGE_EXCEPT and CLOSE_RANGE_CLOEXEC_ONLY, and the clone dup_fd() makes for it | queued for v7.4 |
| [`file-ref/`](file-ref/) | file_ref_t, the reference count of struct file, with SLAB_TYPESAFE_BY_RCU recycling, against the fget-rcu lookup, close(), open(), epoll; and the ordering its lockless users need (LKMM litmus) | mainline, at v7.4-rc1 |

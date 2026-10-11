# Coredumps

Models of fs/coredump.c and of the signal, exit, fork, exec and io-wq
code a dumping thread group runs into.

| Model | What it models | Status |
|---|---|---|
| [`rendezvous/`](rendezvous/) | the coredump rendezvous and the signal code around it | queued for v7.4 |

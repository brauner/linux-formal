# libfs

Models of the helpers in fs/libfs.c that in-memory filesystems build on.

| Model | What it models | Status |
|---|---|---|
| [`offset-readdir/`](offset-readdir/) | readdir on tmpfs directories with stable offsets: the d_children walk and the descending walk of the offset tree that replaces it, against creates, unlinks, renames, exchanges and whiteouts | proposed |

#!/usr/bin/env python3
"""Split the raw virtio image the VM wrote into one ftrace text file per run."""
import os, re, sys
img, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
begin = re.compile(rb"^===== TRACE BEGIN (\S+)$")
name, f, n = None, None, 0
with open(img, "rb") as fh:
    for line in fh:
        if line.startswith(b"===== ALL DONE"):
            break
        if line.startswith(b"\0"):
            print("hit zeros before ALL DONE: incomplete image")
            break
        m = begin.match(line.rstrip(b"\n"))
        if m:
            name = m.group(1).decode(); f = open(os.path.join(out, name + ".txt"), "wb"); n = 0
            continue
        if line.startswith(b"===== TRACE END"):
            f.close(); print(f"{name}: {n} lines"); f = None
            continue
        if f:
            f.write(line); n += 1

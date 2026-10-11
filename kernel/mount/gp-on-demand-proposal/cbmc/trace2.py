import re, sys
log = open(sys.argv[1], errors="replace").read()
want = sys.argv[2]
props = dict(re.findall(r"^\[([^\]]+)\] (.*): FAILURE\s*$", log, re.M))
pid = [i for i, d in props.items() if want in d][0]
m = re.search(r"^Trace for " + re.escape(pid) + r":\n(.*?)(?=^Trace for |\Z)", log, re.M | re.S)
lines = m.group(1).splitlines()
keep = re.compile(r"^\s*(ghost_(refs|transient|hashed|cleaned|cleaner|freed|sb_torn|fast_final|umounted|gps|caller_put)|mounts\[0l\]\.(mnt_ns|mnt\.mnt_flags|mnt_pcp\[\d\]\.\w+)|in_rcu|mount_lock\.(sequence|locked)|thread_done|retval|count=|res=|found=|seq=|cpu=|c=|idx=|i=|k=)")
hdr = re.compile(r"^State \d+ file \S+ function (\S+) line (\d+) thread (\d+)")
i = 0
print("property:", props[pid])
while i < len(lines):
    h = hdr.match(lines[i])
    if h and i + 2 < len(lines) and keep.match(lines[i+2]) and "__CPROVER" not in lines[i+2]:
        a = lines[i+2].strip()
        a = re.sub(r" \(\d[\d ]*\)$", "", a)
        print(f"T{h.group(3)} {h.group(1)}:{h.group(2):<5} {a}")
    i += 1

#!/usr/bin/env python3
"""Rewrite the results table in research-weak-memory-2.md from collect-results.sh output."""
import subprocess, re, os, datetime
here = os.path.dirname(os.path.abspath(__file__))
memo = os.path.join(here, '..', 'research-weak-memory-2.md')
out = subprocess.run(['bash', os.path.join(here, 'collect-results.sh')], capture_output=True, text=True).stdout.splitlines()[1:]
rows = []
for line in out:
    parts = re.split(r'\s{2,}', line.strip())
    if len(parts) < 5:
        continue
    test, lk, a64, ppc, x86 = parts[0], parts[1], parts[2], parts[3], ' '.join(parts[4:])
    def cell(c, lk):
        c = c.replace('witnessed (speedcheck)', 'witnessed').replace(' (full)', '')
        if c == 'running': return 'still running at hand-off'
        return c
    x86n = x86.replace('Sometimes ', 'Sometimes ').replace('Never ', 'Never ')
    if test in ('MNT-A1m-nomb-in-sum', 'MNT-A1m-nowmb'):
        x86n += ' (unobservable on TSO)'
    rows.append('| %s | %s | %s | %s | %s |' % (test, lk, cell(a64, lk), cell(ppc, lk), x86n))
order = ['MNT-A1-holder-get-before-put','MNT-A1m-gets-first','MNT-A1m-nomb-in-sum','MNT-A1m-nowmb',
         'MNT-B1-walker-inc-vs-peek','MNT-B1m-walker-nomb','MNT-B1m-peek-no-outer-mb',
         'MNT-B2-walker-bail-sees-doomed-lazy','MNT-B2m-walker-flags-unlocked','MNT-C1-kern-unmount-get-before-put',
         'MNT-D1-dekker-fastpath-recheck','MNT-D1m-holder-wmb-only','MNT-E1-slowpath-no-outer-mb','MNT-E2-busycheck-no-outer-mb']
rows.sort(key=lambda r: order.index(r.split('|')[1].strip()) if r.split('|')[1].strip() in order else 99)
s = open(memo).read()
start = s.index('| test | LKMM | AArch64 (Arm official model)')
end = s.index('\n\n', start)
header = s[start:s.index('\n', s.index('\n', start) + 1) + 1]
s = s[:start] + header + '\n'.join(rows) + s[end:]
s = re.sub(r'Table at hand-off \([0-9:]+ UTC;', 'Table at hand-off (%s UTC;' % datetime.datetime.utcnow().strftime('%H:%M'), s)
open(memo, 'w').write(s)
print('\n'.join(rows))

#!/usr/bin/env python3
"""Print a TLC counterexample of the MntVacant model compactly, one line per
state: the action, every mount's flags and count, U, the holders, the
walkers, D, the pending task work and the history.
    ./show-vacant-trace.py logs/<cfg>.log
"""
import re
import sys

log = open(sys.argv[1]).read()
marks = ['Error: The behavior up to this point is:', 'Error: The following behavior constitutes a counter-example:']
mark = next((mk for mk in marks if mk in log), None)
if mark is None:
    print(log[log.find('Error'):][:1500] if 'Error' in log else 'no error in log')
    sys.exit(0)
print(log[log.index('Error:'):log.index(mark)].strip())
trace = log[log.index(mark):]
tail = re.search(r'\n\d+ states generated', trace)
if tail:
    trace = trace[:tail.start()]
states = re.split(r'\nState (\d+): ', trace)


def var(body, name):
    m = re.search(r'/\\ ' + name + r' = (.*?)(?=\n/\\ |\Z)', body, re.S)
    return re.sub(r'\s+', ' ', m.group(1)).strip() if m else '?'


def mounts(body):
    mt = var(body, 'mt')
    out = []
    # TLC prints a function on 1..n as a tuple of records
    for i, mm in enumerate(re.finditer(r'\[(.*?)\](?=, \[| ?>>|$)', mt), 1):
        rec = mm.group(1)
        f = dict(re.findall(r'(\w+) \|-> ([^,\]]+(?:\{[^}]*\})?)', rec))
        flags = ''.join(k[0].upper() for k in ('hashed', 'doomed', 'vacant', 'oldroot', 'freed', 'rcufree', 'mpgone') if f.get(k) == 'TRUE')
        flags += 'K' if f.get('mark') == 'TRUE' else ''
        out.append(f"{i}:{f.get('count', '?')}{flags}/{f.get('inst', '?').strip('\"')}p{f.get('parent', '?')}"
                   + (f"s{f['stuck']}" if f.get('stuck', '{}') != '{}' else ''))
    return ' '.join(out)


for i in range(1, len(states), 2):
    num, body = states[i], states[i + 1]
    head = body.split('\n', 1)[0].strip()
    act = re.sub(r' line \d+, col \d+ to line \d+, col \d+ of module \w+', '', head).strip('<>')
    hist = var(body, 'hist')
    h = dict(re.findall(r'(\w+) \|-> ([^,\]]+)', hist))
    warn = re.search(r'warn \|-> (\{[^}]*\})', hist)
    print(f"{num:>3} {act:<11} {mounts(body)} | U={var(body, 'upc')}{var(body, 'uhead')} ext={var(body, 'ext')} "
          f"W={var(body, 'wpc')}/{var(body, 'wres')} D={var(body, 'dpc')}{var(body, 'dhead')} tw={var(body, 'tw')} "
          f"pins={var(body, 'pins')} owed={var(body, 'vq')} sb={var(body, 'sbact')} watched={var(body, 'watched')} "
          f"vac={h.get('vacates')} warn={warn.group(1) if warn else '?'}")

#!/usr/bin/env python3
"""Print a TLC counterexample of the two-mount MntPut model compactly, one
line per state: the action, every task's label, the visible seq/lock, each
mount's counters and flags, U's lists, RCU and the ledger; the store buffers
when they are not empty.
    ./show-put-trace.py logs/<cfg>.log
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
states = re.split(r'\nState (\d+): ', trace)


def var(body, name):
    m = re.search(r'/\\ ' + name + r' = (.*?)(?=\n/\\ |\Z)', body, re.S)
    return re.sub(r'\s+', ' ', m.group(1)).strip() if m else '?'


def per_mount(txt):
    """split a TLC function over {"A","B"} (printed like a record,
    [A |-> <value>, B |-> <value>]) into {mount: rendering}; a value is a flat
    record [...] or a tuple <<...>>"""
    out = {}
    for mm in re.finditer(r'\b([AB]) \|-> (\[[^\[\]]*\]|<<[^>]*>>)', txt):
        out[mm.group(1)] = mm.group(2).strip()
    return out


def flags(rec):
    return ''.join(k[0].upper() for k in ('hashed', 'ns', 'umount', 'sync', 'doomed', 'freed')
                   if re.search(k + r' \|-> TRUE', rec))


def counters(rec):
    return re.sub(r'\s', '', rec).strip('<>')


def store(rec):
    f = dict(re.findall(r'(\w+) \|-> ("?-?\w+"?)', rec))
    k = f.get('f', '?').strip('"')
    if k == 'cnt':
        return f"cnt{f['x'].strip(chr(34))}[{f['c']}]{'+' if not f['d'].startswith('-') else ''}{f['d']}"
    if k in ('hashed', 'ns'):
        return f"{k}{f['x'].strip(chr(34))}={f['v']}"
    if k in ('seq', 'lock'):
        return f"{k}={f['v'].strip(chr(34))}"
    return k


def short_buf(txt):
    txt = re.sub(r'\[[^\[\]]*\]', lambda mm: store(mm.group(0)), txt)
    return re.sub(r'\s+', ' ', txt)


for i in range(1, len(states), 2):
    num, body = states[i], states[i + 1]
    head = body.split('\n', 1)[0].strip()
    act = re.sub(r' line \d+, col \d+ to line \d+, col \d+ of module \w+', '', head)
    ms = per_mount(var(body, 'm'))
    cn = per_mount(var(body, 'cntv'))
    pu = per_mount(var(body, 'putv'))
    mounts = ' '.join(f"{x}[{flags(ms.get(x, ''))}] cnt={counters(cn.get(x, '?'))} puts={counters(pu.get(x, '?'))}"
                      for x in ('A', 'B'))
    print(f"{num:>3} {act:<16} pc={var(body, 'pc')} seq={var(body, 'seqv')} lock={var(body, 'lockv')}")
    print(f"      {mounts} own={var(body, 'own')}")
    print(f"      um={var(body, 'um')} ownput={var(body, 'ownput')} bi={var(body, 'bi')} head={var(body, 'head')} "
          f"held={var(body, 'held')} fin={var(body, 'fin')} synced={var(body, 'synced')} res={var(body, 'uresult')}")
    print(f"      refs={var(body, 'refs')} rcu={var(body, 'rcu')} gp={var(body, 'gp')} gpfree={var(body, 'gpfree')} "
          f"acc={var(body, 'acc')} ci={var(body, 'ci')} cleaner={var(body, 'cleaner')}")
    b = short_buf(var(body, 'buf'))
    if re.search(r'<<[^>]', b):
        print(f"      buf={b}")
m = re.search(r'Back to state (\d+)', trace)
if m:
    print(f"... back to state {m.group(1)} (stuttering/lasso)")

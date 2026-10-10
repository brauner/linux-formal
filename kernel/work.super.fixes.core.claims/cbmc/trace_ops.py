#!/usr/bin/env python3
"""Condense CBMC --trace output of devtable.c into operation sequences.

Usage: trace_ops.py devtable <cbmc-log>

For every "Trace for <property>" section, print the property and one line
per harness step: the operation (from log_op[]/log_arg[]/log_ret[]) and the
interesting state after the step (last assignment seen in the trace).

arg: sb * 10 + dev; PUT_FINISH 100 + row; CUR_WAKE 200 + sb.
ret of a cursor step: pinned row, 10 + sb it sleeps on, -1 walk done.
flags: B = SB_BORN, Y = SB_DYING, D = SB_DEAD.
"""
import re
import sys

OPS = {
    'devtable': ['SGET_SET', 'KILL_NOTIFY', 'PUT_SUPER', 'REGISTER', 'REGISTER_STEP',
                 'UNREGISTER', 'UNREG_LOOKUP', 'UNREG_PUT', 'CUR_FIRST', 'CUR_NEXT',
                 'CUR_TAKE', 'DROP_SUPER', 'PUT_FINISH', 'BORN', 'CUR_WAKE'],
}

WATCH = {
    'devtable': [
        ('E0', r'E0\.sd_ref'), ('E0l', r'E0\.m_linked'), ('E0d', r'E0\.m_dying'),
        ('E1', r'E1\.sd_ref'), ('E1l', r'E1\.m_linked'), ('E1d', r'E1\.m_dying'),
        ('E2', r'E2\.sd_ref'), ('E2l', r'E2\.m_linked'), ('E2d', r'E2\.m_dying'),
        ('E3', r'E3\.sd_ref'), ('E3l', r'E3\.m_linked'), ('E3d', r'E3\.m_dying'),
        ('E4', r'E4\.sd_ref'), ('E4l', r'E4\.m_linked'), ('E4d', r'E4\.m_dying'),
        ('pas0', r'S0\.s_passive'), ('pas1', r'S1\.s_passive'),
        ('fl0', r'S0\.s_flags'), ('fl1', r'S1\.s_flags'),
        ('pin', r'cursor\[0l?\]'), ('prev', r'cursor_prev\[0l?\]'),
        ('wait', r'cursor_wait\[0l?\]'),
        ('ud0.1', r'unborn_drop\[0l?\]\[1l?\]'), ('ud0.2', r'unborn_drop\[0l?\]\[2l?\]'),
        ('ud1.1', r'unborn_drop\[1l?\]\[1l?\]'), ('ud1.2', r'unborn_drop\[1l?\]\[2l?\]'),
    ],
}

ASSIGN = re.compile(r'^\s+([A-Za-z_][\w\.\[\]\$#!@-]*)=(\S+)')
FLAGS = ((29, 'B'), (24, 'Y'), (21, 'D'))


def pretty(name, val):
    if name.startswith('fl'):
        try:
            v = int(re.sub(r'[ul]+$', '', val))
        except ValueError:
            return val
        return ''.join(c for bit, c in FLAGS if v >> bit & 1) or '0'
    if 'NULL' in val:
        return '-'
    return re.sub(r'!\d+@\d+', '', val).lstrip('&')


def main():
    harness, path = sys.argv[1], sys.argv[2]
    ops = OPS[harness]
    watch = [(n, re.compile('^' + rx + '$')) for n, rx in WATCH[harness]]
    lines = open(path, errors='replace').read().splitlines()

    i = 0
    while i < len(lines):
        m = re.match(r'^Trace for (.*):$', lines[i])
        if not m:
            i += 1
            continue
        prop = m.group(1)
        state = {}
        steps = {}
        out = []
        in_main = False
        i += 1
        while i < len(lines) and not lines[i].startswith('Trace for ') \
                and not lines[i].startswith('** '):
            line = lines[i]
            if re.match(r'^State \d+ file \S+ function main ', line):
                in_main = True
            if line.startswith('Violated property:'):
                desc = lines[i + 2].strip() if i + 2 < len(lines) else ''
                pend = [k for k, v in sorted(steps.items()) if 'ret' not in v]
                for k in pend:
                    v = steps[k]
                    try:
                        opn = ops[int(v.get('op', '-1'))]
                    except (ValueError, IndexError):
                        opn = v.get('op', '?')
                    st = ' '.join('%s=%s' % (n, state[n]) for n, _ in watch if n in state)
                    out.append('  %2d %-13s arg=%-3s (in progress) | %s' %
                               (k, opn, v.get('arg', '-'), st))
                out.append('  VIOLATED: ' + lines[i + 1].strip() + ' -- ' + desc)
            a = ASSIGN.match(line) if in_main else None
            if a:
                var, val = a.group(1), a.group(2)
                for n, rx in watch:
                    if rx.match(var):
                        state[n] = pretty(n, val)
                mm = re.match(r'^log_(op|arg|ret)\[(\d+)l?\]$', var)
                if mm:
                    kind, idx = mm.group(1), int(mm.group(2))
                    steps.setdefault(idx, {})[kind] = val
                    if kind == 'ret':
                        s = steps[idx]
                        try:
                            opn = ops[int(s.get('op', '-1'))]
                        except (ValueError, IndexError):
                            opn = s.get('op', '?')
                        st = ' '.join('%s=%s' % (n, state[n]) for n, _ in watch if n in state)
                        out.append('  %2d %-13s arg=%-3s ret=%-5s | %s' %
                                   (idx, opn, s.get('arg', '-'), val, st))
            i += 1
        print('=== ' + prop)
        print('\n'.join(out))
        print()


if __name__ == '__main__':
    main()

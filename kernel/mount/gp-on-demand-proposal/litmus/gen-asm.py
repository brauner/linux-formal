#!/usr/bin/env python3
"""Translate the MNT-* LKMM litmus tests into AArch64 and PPC herd7 litmus tests.

Mapping (what the kernel emits):
  READ_ONCE/WRITE_ONCE  -> LDR/STR            | lwz/stw
  smp_wmb()             -> DMB ISHST          | lwsync
  smp_rmb()             -> DMB ISHLD          | lwsync
  smp_mb()              -> DMB ISH            | sync
  spin_lock()           -> SWPA (acquire swap; the qspinlock fast path is an
                           acquire RMW) with the herd7 'filter' clause keeping
                           only executions in which every acquisition found the
                           lock free (the lock-emulation trick of
                           tools/memory-model/Documentation/litmus-tests.txt)
                                              | lwarx; cmpwi; bne; stwcx.; bne; isync
                                                (arch_spin_lock shape); a held lock
                                                or failed stwcx. marks the register
                                                and is filtered out
  spin_unlock()         -> STLR WZR           | lwsync; stw (PPC_RELEASE_BARRIER)

The RISC-V, MIPS and ARM backends further down carry their own mapping in a
comment.  They are generated for the E family only, into riscv/, riscv-lrsc/,
mips/, mips-weak/ and arm/ (arm/ is run under both arm.cat and aarch32.cat).
"""
import sys, os

# ---------------------------------------------------------------- abstract programs
# ops: ('st',var,imm) ('ld',reg,var) ('wmb',) ('rmb',) ('mb',) ('lock',var,reg) ('unlock',var)
#      ('brz',reg,label) ('brnz',reg,label) ('brne',reg,imm,label) ('label',name)

def unmounter_sections(first_locked=True, flags_sync=False, outer_mb=True, gets_first=False,
                       inner_mb=True, decide=False, gets='gets_h', puts='puts_h'):
    ops = []
    if first_locked:
        ops += [('lock','mlock','q1'), ('st','seq',1), ('wmb',), ('st','mnt_ns',0)]
        if flags_sync:
            ops += [('st','flags',1)]
        ops += [('wmb',), ('st','seq',2), ('unlock','mlock')]
        ops += [('lock','mlock','q2'), ('st','seq',3), ('wmb',)]
    else:
        ops += [('st','mnt_ns',0)]
        ops += [('lock','mlock','q2'), ('st','seq',1), ('wmb',)]
    if outer_mb:
        ops += [('mb',)]
    puts_pass = [('ld','r1',puts), ('ld','r2','puts_u')]
    gets_pass = [('ld','r3',gets), ('ld','r4','gets_u')]
    mid = [('mb',)] if inner_mb else []
    ops += (gets_pass + mid + puts_pass) if gets_first else (puts_pass + mid + gets_pass)
    if decide:
        ops += [('brnz','r3','L1'), ('st','flags',3), ('st','freed',1), ('label','L1'),
                ('brne','r3',1,'L2'), ('brne','r1',1,'L2'), ('st','flags',3), ('st','freed',1), ('label','L2')]
    ops += [('wmb',), ('st','seq',4 if first_locked else 2), ('unlock','mlock')]
    return ops

def holder_a1(wmb=True, getfirst=True):
    ops = []
    if getfirst:
        ops += [('st','gets_h',2)]
    ops += [('ld','r0','mnt_ns'), ('brz','r0','L0')]
    if wmb:
        ops += [('wmb',)]
    ops += [('st','puts_h',1), ('label','L0')]
    return ops

def holder_d1(full=True):
    return [('ld','r0','mnt_ns'), ('brz','r0','L0'), ('wmb',), ('st','puts_h',1),
            ('mb',) if full else ('wmb',), ('ld','r1','mnt_ns'), ('label','L0')]

def walker(mb=True, locked=True):
    ops = [('ld','r0','seq'), ('rmb',), ('rmb',), ('ld','r1','seq'), ('brnz','r1','Lend'),
           ('st','gets_w',1)]
    if mb:
        ops += [('mb',)]
    ops += [('rmb',), ('ld','r2','seq'), ('brz','r2','Lend')]
    if locked:
        ops += [('lock','mlock','q0')]
    ops += [('ld','r3','flags'), ('brz','r3','Lskip'), ('st','puts_w',1), ('label','Lskip')]
    if locked:
        ops += [('unlock','mlock')]
    ops += [('label','Lend')]
    return ops

def e1_slowpath():
    # mntput_no_expire_slowpath() without its explicit smp_mb(): lock, seqcount write, own put,
    # puts pass, mnt_get_count()'s inner smp_mb(), gets pass; count == 1 + own put -> finish off
    return [('lock','mlock','q1'), ('st','seq',1), ('wmb',), ('st','mnt_ns',0), ('st','flags',1), ('wmb',),
            ('st','seq',2), ('unlock','mlock'),
            ('lock','mlock','q2'), ('st','seq',3), ('wmb',), ('st','puts_u',1),
            ('ld','r1','puts_w'), ('ld','r2','puts_u'), ('mb',), ('ld','r3','gets_w'), ('ld','r4','gets_u'),
            ('brne_reg','r3','r1','L1'), ('st','flags',3), ('st','freed',1), ('label','L1'),
            ('wmb',), ('st','seq',4), ('unlock','mlock')]

def e1u_slowpath_after_umount_tree():
    # the in-tree mnt-slowpath-sum-no-outer-mb.litmus after the fixup: the initial state is the mount
    # after umount_tree() (flags=1, seqcount 0), P1() is only the slow path's critical section
    return [('lock','mlock','q1'), ('st','seq',1), ('wmb',), ('st','puts_u',1),
            ('ld','r1','puts_w'), ('ld','r2','puts_u'), ('mb',), ('ld','r3','gets_w'), ('ld','r4','gets_u'),
            ('brne_reg','r3','r1','L1'), ('st','flags',3), ('st','freed',1), ('label','L1'),
            ('wmb',), ('st','seq',2), ('unlock','mlock')]

def e2_busycheck():
    # do_umount() without its explicit smp_mb(): lock_mount_hash() (seqcount write), the busy check's
    # sum (puts pass, inner smp_mb(), gets pass); count == 1 -> the unmount proceeds
    return [('lock','mlock','q1'), ('st','seq',1), ('wmb',),
            ('ld','r1','puts_w'), ('ld','r2','puts_u'), ('mb',), ('ld','r3','gets_w'), ('ld','r4','gets_u'),
            ('brne_reg','r3','r1','L1'), ('st','mnt_ns',0), ('st','flags',1), ('st','freed',1), ('label','L1'),
            ('wmb',), ('st','seq',2), ('unlock','mlock')]

def unmounter_b2_reduced():
    # reduced B2 (lazy): only the peek's critical section, the two own-counter loads and mnt_ns dropped,
    # flags=3 as the finish indicator; finish iff gets_w == puts_w (count == 1)
    return [('lock','mlock','q2'), ('st','seq',1), ('wmb',),
            ('ld','r1','puts_w'), ('mb',), ('ld','r3','gets_w'),
            ('brne_reg','r3','r1','L1'), ('st','flags',3), ('label','L1'),
            ('wmb',), ('st','seq',2), ('unlock','mlock')]

A1_INIT = {'mnt_ns':1, 'gets_h':1, 'gets_u':1}
B_INIT = {'mnt_ns':1, 'gets_u':1}

TESTS = {
 'MNT-A1-holder-get-before-put': (A1_INIT, [holder_a1(), unmounter_sections()], '0:r0=1 /\\ 1:r1=1 /\\ 1:r3=1', 'Never'),
 'MNT-A1m-nowmb':        (A1_INIT, [holder_a1(wmb=False), unmounter_sections()], '0:r0=1 /\\ 1:r1=1 /\\ 1:r3=1', 'Sometimes'),
 'MNT-A1m-nomb-in-sum':  (A1_INIT, [holder_a1(), unmounter_sections(inner_mb=False)], '0:r0=1 /\\ 1:r1=1 /\\ 1:r3=1', 'Sometimes'),
 'MNT-A1m-gets-first':   (A1_INIT, [holder_a1(), unmounter_sections(gets_first=True)], '0:r0=1 /\\ 1:r1=1 /\\ 1:r3=1', 'Sometimes'),
 'MNT-C1-kern-unmount-get-before-put': (A1_INIT, [holder_a1(), unmounter_sections(first_locked=False)], '0:r0=1 /\\ 1:r1=1 /\\ 1:r3=1', 'Never'),
 'MNT-D1-dekker-fastpath-recheck': (A1_INIT, [holder_d1(), unmounter_sections()], '0:r0=1 /\\ 0:r1=1 /\\ 1:r1=0', 'Never'),
 'MNT-D1m-holder-wmb-only': (A1_INIT, [holder_d1(full=False), unmounter_sections()], '0:r0=1 /\\ 0:r1=1 /\\ 1:r1=0', 'Sometimes'),
 'MNT-B1-walker-inc-vs-peek': (B_INIT, [walker(), unmounter_sections(flags_sync=True, decide=True, gets='gets_w', puts='puts_w')], '0:r1=0 /\\ 0:r2=0 /\\ freed=1', 'Never'),
 'MNT-B1m-walker-nomb': (B_INIT, [walker(mb=False), unmounter_sections(flags_sync=True, decide=True, gets='gets_w', puts='puts_w')], '0:r1=0 /\\ 0:r2=0 /\\ freed=1', 'Sometimes'),
 'MNT-B1m-peek-no-outer-mb': (B_INIT, [walker(), unmounter_sections(flags_sync=True, decide=True, outer_mb=False, gets='gets_w', puts='puts_w')], '0:r1=0 /\\ 0:r2=0 /\\ freed=1', 'Never'),
 'MNT-B2-walker-bail-sees-doomed-lazy': (B_INIT, [walker(), unmounter_sections(decide=True, gets='gets_w', puts='puts_w')], '0:r1=0 /\\ ~(0:r2=0) /\\ 0:r3=0 /\\ freed=1', 'Never'),
 'MNT-E1-slowpath-no-outer-mb': (B_INIT, [walker(), e1_slowpath()], '0:r1=0 /\\ 0:r2=0 /\\ freed=1', 'Never'),
 'MNT-E1u-slowpath-after-umount-tree': ({'gets_u':1, 'flags':1}, [walker(), e1u_slowpath_after_umount_tree()], '0:r1=0 /\\ 0:r2=0 /\\ freed=1', 'Never'),
 'MNT-E2-busycheck-no-outer-mb': (B_INIT, [walker(), e2_busycheck()], '0:r1=0 /\\ 0:r2=0 /\\ freed=1', 'Never'),
 'MNT-B2r-walker-bail-reduced': ({}, [walker(), unmounter_b2_reduced()], '0:r1=0 /\\ ~(0:r2=0) /\\ 0:r3=0 /\\ flags=3', 'Never'),
 'MNT-B2m-walker-flags-unlocked': (B_INIT, [walker(locked=False), unmounter_sections(decide=True, gets='gets_w', puts='puts_w')], '0:r1=0 /\\ ~(0:r2=0) /\\ 0:r3=0 /\\ freed=1', 'Sometimes'),
}
WALKER_TESTS = {k for k in TESTS if '-B' in k or '-E' in k}

def vars_of(ops):
    vs = []
    for op in ops:
        if op[0] in ('st','lock','unlock'):
            v = op[1]
        elif op[0] == 'ld':
            v = op[2]
        else:
            continue
        if v not in vs:
            vs.append(v)
    return vs

def regs_of(ops):
    rs = []
    for op in ops:
        if op[0] in ('ld','lock'):
            r = op[2] if op[0]=='ld' else op[2]
            r = op[1] if op[0]=='ld' else op[2]
            if r not in rs:
                rs.append(r)
    return rs

# ---------------------------------------------------------------- backends
class AArch64:
    name = 'AArch64'; model = 'aarch64.cat'
    def __init__(self, ops, tid):
        self.ops, self.tid = ops, tid
        self.addr = {v: i for i, v in enumerate(vars_of(ops))}          # X0..
        self.reg = {r: 10 + i for i, r in enumerate(regs_of(ops))}       # X10..
    def init(self):
        return ['%d:X%d=%s;' % (self.tid, i, v) for v, i in self.addr.items()]
    def regname(self, r): return 'X%d' % self.reg[r]
    def lines(self):
        out = []
        for op in self.ops:
            k = op[0]
            if k == 'st':   out += ['MOV W9,#%d' % op[2], 'STR W9,[X%d]' % self.addr[op[1]]]
            elif k == 'ld': out += ['LDR W%d,[X%d]' % (self.reg[op[1]], self.addr[op[2]])]
            elif k == 'wmb': out += ['DMB ISHST']
            elif k == 'rmb': out += ['DMB ISHLD']
            elif k == 'mb':  out += ['DMB ISH']
            elif k == 'lock': out += ['MOV W9,#1', 'SWPA W9,W%d,[X%d]' % (self.reg[op[2]], self.addr[op[1]])]
            elif k == 'unlock': out += ['STLR WZR,[X%d]' % self.addr[op[1]]]
            elif k == 'brz':  out += ['CBZ W%d,%s%d' % (self.reg[op[1]], op[2], self.tid)]
            elif k == 'brnz': out += ['CBNZ W%d,%s%d' % (self.reg[op[1]], op[2], self.tid)]
            elif k == 'brne': out += ['CMP W%d,#%d' % (self.reg[op[1]], op[2]), 'B.NE %s%d' % (op[3], self.tid)]
            elif k == 'brne_reg': out += ['CMP W%d,W%d' % (self.reg[op[1]], self.reg[op[2]]), 'B.NE %s%d' % (op[3], self.tid)]
            elif k == 'label': out += ['%s%d:' % (op[1], self.tid)]
        return out

class PPC:
    name = 'PPC'; model = 'ppc.cat'
    def __init__(self, ops, tid):
        self.ops, self.tid = ops, tid
        self.addr = {v: 20 + i for i, v in enumerate(vars_of(ops))}     # r20..
        self.reg = {r: 1 + i for i, r in enumerate(regs_of(ops))}        # r1..
        self.nlock = 0
    def init(self):
        return ['%d:r%d=%s;' % (self.tid, i, v) for v, i in self.addr.items()]
    def regname(self, r): return 'r%d' % self.reg[r]
    def lines(self):
        out = []
        for op in self.ops:
            k = op[0]
            if k == 'st':   out += ['li r10,%d' % op[2], 'stw r10,0(r%d)' % self.addr[op[1]]]
            elif k == 'ld': out += ['lwz r%d,0(r%d)' % (self.reg[op[1]], self.addr[op[2]])]
            elif k in ('wmb','rmb'): out += ['lwsync']
            elif k == 'mb':  out += ['sync']
            elif k == 'lock':
                # kernel arch_spin_lock shape: lwarx; cmpwi; bne-; stwcx.; bne-; isync.  The branch on the
                # LOADED value is what gives ctrl+isync acquire ordering in ppc.cat; a branch only on
                # stwcx.'s CR0 (the first version of this emulation) carries no dependency from the lwarx
                # and left the critical section's loads unordered (spurious witness in MNT-B2 on POWER).
                self.nlock += 1; ok = 'Lok%d%d' % (self.tid, self.nlock); fail = 'Lfail%d%d' % (self.tid, self.nlock)
                a, r = self.addr[op[1]], self.reg[op[2]]
                out += ['li r10,1', 'lwarx r%d,r0,r%d' % (r, a), 'cmpwi r%d,0' % r, 'bne %s' % fail,
                        'stwcx. r10,r0,r%d' % a, 'bne %s' % fail, 'isync', 'b %s' % ok,
                        '%s:' % fail, 'li r%d,1' % r, '%s:' % ok]
            elif k == 'unlock': out += ['lwsync', 'li r10,0', 'stw r10,0(r%d)' % self.addr[op[1]]]
            elif k == 'brz':  out += ['cmpwi r%d,0' % self.reg[op[1]], 'beq %s%d' % (op[2], self.tid)]
            elif k == 'brnz': out += ['cmpwi r%d,0' % self.reg[op[1]], 'bne %s%d' % (op[2], self.tid)]
            elif k == 'brne': out += ['cmpwi r%d,%d' % (self.reg[op[1]], op[2]), 'bne %s%d' % (op[3], self.tid)]
            elif k == 'brne_reg': out += ['cmpw r%d,r%d' % (self.reg[op[1]], self.reg[op[2]]), 'bne %s%d' % (op[3], self.tid)]
            elif k == 'label': out += ['%s%d:' % (op[1], self.tid)]
        return out

def emit(backend, name, init, threads, exists, expect):
    bs = [backend(ops, i) for i, ops in enumerate(threads)]
    cols = [b.lines() for b in bs]
    n = max(len(c) for c in cols)
    w = [max(len(l) for l in c) + 1 for c in cols]
    text = ['%s %s' % (backend.name, name),
            '(* LKMM result: %s; translation of litmus/%s.litmus, see gen-asm.py for the barrier mapping *)' % (expect, name),
            '{']
    text += ['%s=%d;' % (v, x) for v, x in init.items()]
    for b in bs:
        text += b.init()
    text += ['}']
    hdr = ' ' + ' | '.join(('P%d' % i).ljust(w[i]) for i in range(len(bs))) + ' ;'
    text += [hdr]
    for j in range(n):
        row = [ (cols[i][j] if j < len(cols[i]) else '').ljust(w[i]) for i in range(len(bs)) ]
        text += [' ' + ' | '.join(row) + ' ;']
    # exists/filter: translate logical registers "P:rN" -> physical
    def xl(cond):
        import re
        def sub(m):
            tid, r = int(m.group(1)), m.group(2)
            return '%d:%s' % (tid, bs[tid].regname(r))
        return re.sub(r'(\d):(r\d|q\d)', sub, cond)
    filt = []
    for i, ops in enumerate(threads):
        for op in ops:
            if op[0] == 'lock':
                filt.append('%d:%s=0' % (i, op[2]))
    if name in WALKER_TESTS:
        filt.append('0:r0=0')
    conds = []
    if filt:
        conds += ['filter (' + ' /\\ '.join(filt) + ')']
    conds += ['exists (' + exists + ')']
    return '\n'.join(text) + '\n' + xl('\n'.join(conds)) + '\n'


# ---------------------------------------------------------------- mutations of the E tests
def nomb(ops):
    # drop the sum's inner smp_mb(); the walker's smp_mb() lives in walker()
    assert ops.count(('mb',)) == 1
    return [op for op in ops if op != ('mb',)]

E_COND = '0:r1=0 /\\ 0:r2=0 /\\ freed=1'
E1U_INIT = {'gets_u':1, 'flags':1}
TESTS.update({
 'MNT-E1m-nomb-in-sum':   (B_INIT,   [walker(),         nomb(e1_slowpath())], E_COND, 'Sometimes'),
 'MNT-E1m-walker-nomb':   (B_INIT,   [walker(mb=False), e1_slowpath()],       E_COND, 'Sometimes'),
 'MNT-E1um-nomb-in-sum':  (E1U_INIT, [walker(),         nomb(e1u_slowpath_after_umount_tree())], E_COND, 'Sometimes'),
 'MNT-E1um-walker-nomb':  (E1U_INIT, [walker(mb=False), e1u_slowpath_after_umount_tree()],       E_COND, 'Sometimes'),
 'MNT-E2m-nomb-in-sum':   (B_INIT,   [walker(),         nomb(e2_busycheck())], E_COND, 'Sometimes'),
 'MNT-E2m-walker-nomb':   (B_INIT,   [walker(mb=False), e2_busycheck()],       E_COND, 'Sometimes'),
})
WALKER_TESTS = {k for k in TESTS if '-B' in k or '-E' in k}

# ---------------------------------------------------------------- more backends
# Mapping (what the kernel emits), same conventions as above:
#   RISC-V: READ_ONCE/WRITE_ONCE -> lw/sw; smp_mb -> fence rw,rw; smp_wmb -> fence w,w; smp_rmb -> fence r,r;
#           spin_lock -> amoswap.w.aq (acquire RMW: qspinlock's cmpxchg_acquire ends in fence r,rw, the ticket
#           lock's fetch_add is .aqrl; the acquire AMO is the weaker stand-in); spin_unlock -> fence rw,w; sw
#           (smp_store_release()).  Registers x10.. hold addresses, x20.. the values, x9 is scratch.
#   MIPS:   lw/sw; smp_mb/smp_wmb/smp_rmb -> sync (the herd7 model knows only the full sync; that is exact for
#           pre-R6 kernels, where __SYNC_rmb/__SYNC_wmb are full, and stronger than R6's sync 0x4 wmb);
#           spin_lock -> qspinlock's arch_cmpxchg(): smp_mb__before_llsc() (sync), ll/sc with a branch on the
#           loaded value, smp_llsc_mb() (sync); a failed sc marks the register and is filtered out;
#           spin_unlock -> smp_store_release() = sync; sw.  Registers $10.. addresses, $20.. values, $9 scratch.
#   ARM:    ldr/str; smp_mb -> dmb ish; smp_rmb -> dmb ish (arm has no load-only variant); smp_wmb -> dmb ishst;
#           spin_lock -> ldrex/strex (ticket lock shape) then dmb ish (arch_spin_lock() ends in smp_mb());
#           spin_unlock -> dmb ish; str (arch_spin_unlock() starts with smp_mb()).  Only R0-R12, LR and SP
#           exist, so when a thread needs more the two own-counter loads r2 and r4, whose values nothing
#           reads, share one register.

class RISCV:
    name = 'RISCV'; model = 'riscv.cat'
    def __init__(self, ops, tid):
        self.ops, self.tid = ops, tid
        self.addr = {v: 10 + i for i, v in enumerate(vars_of(ops))}
        self.reg = {r: 20 + i for i, r in enumerate(regs_of(ops))}
        assert len(self.addr) <= 9 and len(self.reg) <= 12
    def init(self):
        return ['%d:x%d=%s;' % (self.tid, i, v) for v, i in self.addr.items()]
    def regname(self, r): return 'x%d' % self.reg[r]
    def lines(self):
        out = []
        for op in self.ops:
            k = op[0]
            if k == 'st':
                if op[2] == 0: out += ['sw x0,0(x%d)' % self.addr[op[1]]]
                else: out += ['ori x9,x0,%d' % op[2], 'sw x9,0(x%d)' % self.addr[op[1]]]
            elif k == 'ld': out += ['lw x%d,0(x%d)' % (self.reg[op[1]], self.addr[op[2]])]
            elif k == 'wmb': out += ['fence w,w']
            elif k == 'rmb': out += ['fence r,r']
            elif k == 'mb':  out += ['fence rw,rw']
            elif k == 'lock': out += ['ori x9,x0,1', 'amoswap.w.aq x%d,x9,(x%d)' % (self.reg[op[2]], self.addr[op[1]])]
            elif k == 'unlock': out += ['fence rw,w', 'sw x0,0(x%d)' % self.addr[op[1]]]
            elif k == 'brz':  out += ['beq x%d,x0,%s%d' % (self.reg[op[1]], op[2], self.tid)]
            elif k == 'brnz': out += ['bne x%d,x0,%s%d' % (self.reg[op[1]], op[2], self.tid)]
            elif k == 'brne': out += ['ori x9,x0,%d' % op[2], 'bne x%d,x9,%s%d' % (self.reg[op[1]], op[3], self.tid)]
            elif k == 'brne_reg': out += ['bne x%d,x%d,%s%d' % (self.reg[op[1]], self.reg[op[2]], op[3], self.tid)]
            elif k == 'label': out += ['%s%d:' % (op[1], self.tid)]
        return out

class MIPS:
    name = 'MIPS'; model = 'mips.cat'
    def __init__(self, ops, tid):
        self.ops, self.tid = ops, tid
        self.addr = {v: 10 + i for i, v in enumerate(vars_of(ops))}
        self.reg = {r: 20 + i for i, r in enumerate(regs_of(ops))}
        self.nlock = 0
        assert len(self.addr) <= 9 and len(self.reg) <= 12
    def init(self):
        return ['%d:$%d=%s;' % (self.tid, i, v) for v, i in self.addr.items()]
    def regname(self, r): return '$%d' % self.reg[r]
    def lines(self):
        out = []
        for op in self.ops:
            k = op[0]
            if k == 'st':
                if op[2] == 0: out += ['sw $0,0($%d)' % self.addr[op[1]]]
                else: out += ['ori $9,$0,%d' % op[2], 'sw $9,0($%d)' % self.addr[op[1]]]
            elif k == 'ld': out += ['lw $%d,0($%d)' % (self.reg[op[1]], self.addr[op[2]])]
            elif k in ('wmb', 'rmb', 'mb'): out += ['sync']
            elif k == 'lock':
                self.nlock += 1; ok = 'Lok%d%d' % (self.tid, self.nlock); fail = 'Lfail%d%d' % (self.tid, self.nlock)
                a, r = self.addr[op[1]], self.reg[op[2]]
                out += ['sync', 'ori $9,$0,1', 'll $%d,0($%d)' % (r, a), 'bne $%d,$0,%s' % (r, fail),
                        'sc $9,0($%d)' % a, 'beq $9,$0,%s' % fail, 'sync', 'b %s' % ok,
                        '%s:' % fail, 'ori $%d,$0,1' % r, '%s:' % ok]
            elif k == 'unlock': out += ['sync', 'sw $0,0($%d)' % self.addr[op[1]]]
            elif k == 'brz':  out += ['beq $%d,$0,%s%d' % (self.reg[op[1]], op[2], self.tid)]
            elif k == 'brnz': out += ['bne $%d,$0,%s%d' % (self.reg[op[1]], op[2], self.tid)]
            elif k == 'brne': out += ['ori $9,$0,%d' % op[2], 'bne $%d,$9,%s%d' % (self.reg[op[1]], op[3], self.tid)]
            elif k == 'brne_reg': out += ['bne $%d,$%d,%s%d' % (self.reg[op[1]], self.reg[op[2]], op[3], self.tid)]
            elif k == 'label': out += ['%s%d:' % (op[1], self.tid)]
        return out

ARM_PHYS = ['R%d' % i for i in range(13)] + ['LR', 'SP']

class ARM:
    name = 'ARM'; model = 'arm.cat'
    def __init__(self, ops, tid):
        self.ops, self.tid = ops, tid
        vs, rs = vars_of(ops), regs_of(ops)
        # addresses first, then the registers that conditions may name (q*, r0, r1, r3), then r2/r4, scratch last
        order = [r for r in rs if r.startswith('q')] + [r for r in rs if r in ('r0', 'r1', 'r3')] + \
                [r for r in rs if r in ('r2', 'r4')]
        assert sorted(order) == sorted(rs)
        alias = len(vs) + len(rs) + 1 > len(ARM_PHYS) and 'r2' in rs and 'r4' in rs
        if alias:
            order.remove('r4')
        assert len(vs) + len(order) + 1 <= len(ARM_PHYS), (vs, rs)
        self.addr = {v: ARM_PHYS[i] for i, v in enumerate(vs)}
        self.reg = {r: ARM_PHYS[len(vs) + i] for i, r in enumerate(order)}
        if alias:
            self.reg['r4'] = self.reg['r2']
        self.scratch = ARM_PHYS[len(vs) + len(order)]
        self.nlock = 0
    def init(self):
        return ['%d:%s=%s;' % (self.tid, p, v) for v, p in self.addr.items()]
    def regname(self, r): return self.reg[r]
    def lines(self):
        out = []; s = self.scratch
        for op in self.ops:
            k = op[0]
            if k == 'st':   out += ['MOV %s,#%d' % (s, op[2]), 'STR %s,[%s]' % (s, self.addr[op[1]])]
            elif k == 'ld': out += ['LDR %s,[%s]' % (self.reg[op[1]], self.addr[op[2]])]
            elif k == 'wmb': out += ['DMB ISHST']
            elif k in ('rmb', 'mb'): out += ['DMB ISH']
            elif k == 'lock':
                self.nlock += 1; ok = 'Lok%d%d' % (self.tid, self.nlock); fail = 'Lfail%d%d' % (self.tid, self.nlock)
                a, r = self.addr[op[1]], self.reg[op[2]]
                # r holds the loaded value, then strex's status: 0 at ok means found free and stored
                out += ['MOV %s,#1' % s, 'LDREX %s,[%s]' % (r, a), 'CMP %s,#0' % r, 'BNE %s' % fail,
                        'STREX %s,%s,[%s]' % (r, s, a), 'CMP %s,#0' % r, 'BNE %s' % fail, 'DMB ISH', 'B %s' % ok,
                        '%s:' % fail, 'MOV %s,#1' % r, '%s:' % ok]
            elif k == 'unlock': out += ['DMB ISH', 'MOV %s,#0' % s, 'STR %s,[%s]' % (s, self.addr[op[1]])]
            elif k == 'brz':  out += ['CMP %s,#0' % self.reg[op[1]], 'BEQ %s%d' % (op[2], self.tid)]
            elif k == 'brnz': out += ['CMP %s,#0' % self.reg[op[1]], 'BNE %s%d' % (op[2], self.tid)]
            elif k == 'brne': out += ['CMP %s,#%d' % (self.reg[op[1]], op[2]), 'BNE %s%d' % (op[3], self.tid)]
            elif k == 'brne_reg': out += ['CMP %s,%s' % (self.reg[op[1]], self.reg[op[2]]), 'BNE %s%d' % (op[3], self.tid)]
            elif k == 'label': out += ['%s%d:' % (op[1], self.tid)]
        return out


class MIPSW(MIPS):
    # sound lower bound for Cavium Octeon, where smp_wmb() is the lighter syncw and smp_rmb() is nothing:
    # smp_wmb()/smp_rmb() emit no instruction at all (weaker than the kernel's syncw, so a Never here holds),
    # smp_mb() stays sync, smp_mb__before_llsc() (smp_wmb() on Octeon) is dropped, smp_llsc_mb() stays sync
    name = 'MIPS'; model = 'mips.cat'
    def lines(self):
        saved = self.ops
        self.ops = [op for op in saved if op[0] not in ('wmb', 'rmb')]
        out = MIPS.lines(self)
        self.ops = saved
        # drop the leading sync of each lock sequence (smp_mb__before_llsc() is smp_wmb() on Octeon)
        res = []
        i = 0
        while i < len(out):
            if out[i] == 'sync' and i + 2 < len(out) and out[i+1] == 'ori $9,$0,1' and out[i+2].startswith('ll '):
                i += 1
                continue
            res.append(out[i]); i += 1
        return res

class RISCVLRSC(RISCV):
    # RISC-V qspinlock shape: arch_cmpxchg_acquire() is lr.w; bne; sc.w; bnez; fence r,rw (RISCV_ACQUIRE_BARRIER);
    # the branch is on the loaded value, a failed sc marks the register and is filtered out
    name = 'RISCV'; model = 'riscv.cat'
    def lines(self):
        out = []; self.nlock = 0
        for op in self.ops:
            if op[0] != 'lock':
                out += RISCV.lines(RISCV.__new__(RISCV)) if False else RISCV.lines(type('T', (), {'ops': [op], 'tid': self.tid, 'addr': self.addr, 'reg': self.reg})())
                continue
            self.nlock += 1; ok = 'Lok%d%d' % (self.tid, self.nlock); fail = 'Lfail%d%d' % (self.tid, self.nlock)
            a, r = self.addr[op[1]], self.reg[op[2]]
            out += ['ori x9,x0,1', 'lr.w x%d,(x%d)' % (r, a), 'bne x%d,x0,%s' % (r, fail),
                    'sc.w x9,x9,(x%d)' % a, 'bne x9,x0,%s' % fail, 'fence r,rw', 'j %s' % ok,
                    '%s:' % fail, 'ori x%d,x0,1' % r, '%s:' % ok]
        return out
if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    for backend, sub in ((AArch64, 'aarch64'), (PPC, 'ppc')):
        os.makedirs(os.path.join(here, sub), exist_ok=True)
        for name, (init, threads, exists, expect) in TESTS.items():
            with open(os.path.join(here, sub, name + '.litmus'), 'w') as f:
                f.write(emit(backend, name, init, threads, exists, expect))
    efam = [n for n in TESTS if n.startswith('MNT-E')]
    for backend, sub in ((RISCV, 'riscv'), (RISCVLRSC, 'riscv-lrsc'), (MIPS, 'mips'), (MIPSW, 'mips-weak'), (ARM, 'arm')):
        os.makedirs(os.path.join(here, sub), exist_ok=True)
        for name in efam:
            init, threads, exists, expect = TESTS[name]
            with open(os.path.join(here, sub, name + '.litmus'), 'w') as f:
                f.write(emit(backend, name, init, threads, exists, expect))
    print('generated %d tests x 2 archs, %d E tests x 5 more backends' % (len(TESTS), len(efam)))

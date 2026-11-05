# The stale field read on AArch64

The LKMM tests say that the lookup before the dependency fix can return
a recycled file whose fields the caller reads stale (`FREF-G2`, the
Documentation test `file-ref-reload-nodep-field`).  The Arm architecture
says the same for the code GCC emits for that lookup.  These are the
AArch64 litmus tests of it, run against the model of the architecture
that herd7 ships (`herd7 <test>.litmus`, herd7 7.58).

## The compiled code

`fget-v7.4-rc1-aarch64.dis` is fget() from fs/file.o of v7.4-rc1
(6628e7d4c6b2), built with `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
defconfig fs/file.o`, aarch64-linux-gnu-gcc 16.2.0 (Debian 16.2.0-3).
The lookup, with __fget_files_rcu() inlined:

    1148: ldr     x0, [x0, x4, lsl #3]   file = fdt->fd[fd & mask]
    1158: add     x4, x0, #0xa8          &file->f_ref: an address dependency on the first load
    1160: ldaddal x1, x1, [x4]           file_ref_get(), the LSE alternative
    116c: ldr     x1, [x5]               the reload of the slot
    1170: cmp     x0, x1 ; b.ne          the recheck
    1178: ldr     x1, [x19, #32]         the fdt recheck
    1184: ldr     w1, [x0, #4]           file->f_mode through x0, the register of the FIRST load
    11b0: ldxr/add/stlxr/cbnz ; dmb ish  the LL/SC alternative of the increment, then back to 116c

The f_mode load at 1184 takes its address from x0, the first load, not
from x1, the reload.  Arm orders two loads from different addresses
only through a dependency or a barrier between them, and the
conditional branches in between order later stores, not later loads.
So the f_mode load can be satisfied before the reload, and the reload
can then observe the fd_install() of the recycled file while the field
load observed the previous incarnation.

## The tests

| test | the Arm model says | what it is |
|---|---|---|
| `file-ref-reload-nodep-field-lse` | Sometimes (2 of 25) | the code above: ldaddal, the field read through the first pointer |
| `file-ref-reload-dep-field-lse` | Never | the fix: the field read through the reloaded pointer |
| `file-ref-reload-nodep-field-dmb` | Sometimes (2 of 25) | the LL/SC path's ordering, a relaxed RMW and dmb ish, the field read through the first pointer |
| `file-ref-reload-dep-field-dmb` | Never | the same with the field read through the reloaded pointer |

Encoding, as in the LKMM tests: the counter holds references - 1
(ONEREF 0, NOREF -1, DEAD -4); the slot holds a pointer to `fop`, the
file's f_op field, 1 in the old incarnation and 2 in the new one, or to
`q`, NULL.  The RMW address depends on the first pointer through the
`EOR X10,X4,X4; ADD X11,X2,X10` idiom, which stands in for the
`add x4, x0, #0xa8` of the compiled code.  P0 is the owner: the plain
store of NULL of file_close_fd_locked(), the ldaddal of file_ref_put(),
the `CASL` to DEAD of __file_ref_put() with the `DMB ISHLD` of
smp_acquire__after_ctrl_dep() after it, the plain stores of init_file()
and do_dentry_open(), the `STLR` of fd_install().  The final state
selects the executions in which P0's decrement read ONEREF (0:X6=0) and
its cmpxchg succeeded (0:X7=-1), so that P1's increment reading 0
(1:X6=0) read the recycled counter, the reload saw the file in the slot
again (1:X8=fop), and the field read returned the old value (1:X9=1).

herd7 does not finish the version with an actual `ldxr/stlxr` loop in
P1 (not within minutes, with `-unroll 1` either).  The dmb variant has
the same ordering for the question asked: the `dmb ish` after the loop
orders the increment before both later loads and neither of them
against the other, which is what the ldaddal's acquire does on the LSE
path.

## Hardware

Not run, there is no arm64 machine here.  `litmus7` runs the `-lse`
tests on one.  Whether a given core shows the outcome depends on the
microarchitecture; the architecture permits it, which is what the fix
is for.

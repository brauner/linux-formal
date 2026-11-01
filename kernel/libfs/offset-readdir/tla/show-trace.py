#!/usr/bin/env python3
"""Print a TLC counterexample of OffsetReaddir compactly.

Usage: ./show-trace.py logs/<cfg>.log
For each step it prints the action, the directory in d_children order as
name@offset (a dead dentry the lister still holds as name@-!), and what the
lister did: where ctx->pos is, which entry it found or returned. The names
the listing must return exactly once are those present at opendir() and not
touched since.
"""
import re
import sys


class P:
    def __init__(self, s):
        self.s, self.i = s, 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1

    def peek(self, t):
        self.ws()
        return self.s.startswith(t, self.i)

    def eat(self, t):
        self.ws()
        if not self.s.startswith(t, self.i):
            raise ValueError("expected %r at %r" % (t, self.s[self.i:self.i + 40]))
        self.i += len(t)

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == '"':
            j = self.s.index('"', self.i + 1)
            v = self.s[self.i + 1:j]
            self.i = j + 1
            return v
        if self.s.startswith("<<", self.i):
            self.i += 2
            out = []
            while not self.peek(">>"):
                out.append(self.value())
                if self.peek(","):
                    self.eat(",")
            self.eat(">>")
            return tuple(out)
        if c == "{":
            self.i += 1
            out = []
            while not self.peek("}"):
                out.append(self.value())
                if self.peek(","):
                    self.eat(",")
            self.eat("}")
            return frozenset(out) if all(not isinstance(x, (dict, list)) for x in out) else tuple(out)
        if c == "[":
            self.i += 1
            out = {}
            while not self.peek("]"):
                self.ws()
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", self.s[self.i:])
                k = m.group(0)
                self.i += len(k)
                self.eat("|->")
                out[k] = self.value()
                if self.peek(","):
                    self.eat(",")
            self.eat("]")
            return out
        if c == "(":
            self.i += 1
            out = {}
            while not self.peek(")"):
                k = self.value()
                self.eat(":>")
                out[k] = self.value()
                if self.peek("@@"):
                    self.eat("@@")
            self.eat(")")
            return out
        m = re.match(r"-?[0-9]+", self.s[self.i:])
        if m:
            self.i += len(m.group(0))
            return int(m.group(0))
        for w, v in (("TRUE", True), ("FALSE", False)):
            if self.s.startswith(w, self.i):
                self.i += len(w)
                return v
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", self.s[self.i:])
        if m:
            self.i += len(m.group(0))
            return m.group(0)
        raise ValueError("cannot parse at %r" % self.s[self.i:self.i + 40])


def parse_state(lines):
    txt = "\n".join(lines)
    out = {}
    for m in re.finditer(r"/\\ (\w+) = ", txt):
        pass
    parts = re.split(r"(?m)^/\\ (\w+) = ", txt)
    for k, v in zip(parts[1::2], parts[2::2]):
        out[k] = P(v.strip()).value()
    return out



def dirview(st):
    out = []
    for d in st["dlist"]:
        n, o, s = st["dname"][d - 1], st["doff"][d - 1], st["dstate"][d - 1]
        out.append("%s@%s%s" % (n, o if o else "-", "!" if s == "dead" else ""))
    return " ".join(out) if out else "(empty)"


def name(st, d):
    return st["dname"][d - 1] if d else "-"


def posname(p, eod):
    return {2: "FIRST", eod: "EOD", eod + 1: "PAST_EOD"}.get(p, str(p))


def main():
    log = open(sys.argv[1]).read().splitlines()
    states, cur, act = [], None, None
    for ln in log:
        m = re.match(r"^State (\d+): (?:<(\w+)[^>]*>|(.*))", ln)
        if m:
            if cur is not None:
                states.append((act, parse_state(cur)))
            act = m.group(2) or (m.group(3) or "").strip()
            cur = []
            continue
        if cur is not None:
            if ln.startswith("/\\") or ln.startswith("  ") or ln.startswith("\t"):
                cur.append(ln)
            elif ln.strip() == "":
                states.append((act, parse_state(cur)))
                cur = None
    if cur:
        states.append((act, parse_state(cur)))
    for m in re.finditer(r"(Invariant \w+ is violated|Temporal properties were violated|Deadlock reached)",
                         "\n".join(log)):
        print("**", m.group(1))
    if not states:
        return
    eod = max(states[0][1]["tree"].keys()) + 1
    nl = len(states[0][1]["lphase"])
    prev = None
    for n, (act, st) in enumerate(states, 1):
        notes = []
        if prev is not None:
            for i in range(nl):
                tag = "L%d " % (i + 1) if nl > 1 else ""
                ph, pph = st["lphase"][i], prev["lphase"][i]
                if ph != pph:
                    notes.append("%s%s -> %s" % (tag, pph, ph))
                if st["pos"][i] != prev["pos"][i]:
                    notes.append("%spos=%s" % (tag, posname(st["pos"][i], eod)))
                if ph == "emit" and (pph != "emit" or st["cur"][i] != prev["cur"][i]):
                    notes.append("%sfound %s" % (tag, name(st, st["cur"][i])))
                for k, v in st["count"][i].items():
                    if v > prev["count"][i].get(k, 0):
                        notes.append("%sRETURNED %s (x%d)" % (tag, k, v))
                if st["saved"][i] != prev["saved"][i]:
                    notes.append("%stelldir() = %s, returned so far %s" % (
                        tag, posname(st["saved"][i], eod), ",".join(sorted(st["before"][i])) or "-"))
                if st["seekleft"][i] < prev["seekleft"][i]:
                    notes.append("%sseekdir(%s)" % (tag, posname(st["saved"][i], eod)))
                if st["far"][i] and not prev["far"][i]:
                    notes.append("%slseek() past DIR_OFFSET_EOD" % tag)
                new = sorted(set(st["touched"][i]) - set(prev["touched"][i]))
                if new and ph != "closed" and pph != "closed" and i == 0:
                    notes.append("touched %s" % ",".join(new))
                if ph == "idle" and pph == "closed":
                    notes.append("%sopendir: entries %s" % (tag, ",".join(sorted(st["startset"][i]))))
            for f in ("err", "wrapped", "mismatch", "cookiegone", "rereturn"):
                if st[f] != prev[f]:
                    notes.append("%s=%s" % (f, st[f]))
        print("%3d %-11s %-34s %s" % (n, act, dirview(st), "; ".join(notes)))
        prev = st
    last = states[-1][1]
    for i in range(nl):
        tag = "L%d " % (i + 1) if nl > 1 else ""
        stable = sorted(set(last["startset"][i]) - set(last["touched"][i]))
        print("%suntouched since opendir(): %s; returned since opendir() or the last seek: %s" % (
            tag, ",".join(stable) or "-",
            " ".join("%s=%d" % (k, v) for k, v in sorted(last["count"][i].items()) if v) or "-"))


if __name__ == "__main__":
    main()

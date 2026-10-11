#!/usr/bin/env python3
"""Print a TLC counterexample of SuperDevTable compactly.

Usage: ./show-trace.py logs/<cfg>.log
For each step it prints the action, the tasks whose program counter moved
(task: old -> new) with the locals that changed, and every other variable
(or field of a function-valued variable) that changed.
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


def fmt(v):
    if isinstance(v, dict):
        return "{" + ", ".join("%s: %s" % (k, fmt(x)) for k, x in v.items()) + "}"
    if isinstance(v, (tuple, list)):
        return "<" + ",".join(fmt(x) for x in v) + ">"
    if isinstance(v, frozenset):
        return "{" + ",".join(sorted(fmt(x) for x in v)) + "}"
    return str(v)


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
    for m in re.finditer(r"(Invariant \w+ is violated|Deadlock reached)", "\n".join(log)):
        print("**", m.group(1))
    prev = None
    for n, (act, st) in enumerate(states, 1):
        if prev is None:
            print("%3d %s" % (n, act))
            prev = st
            continue
        moves = []
        ch = []
        if "L" in st:
            for p, v in st["L"].items():
                pv = prev["L"].get(p, {})
                if pv.get("pc") != v.get("pc"):
                    moves.append("%s: %s -> %s" % (p, pv.get("pc"), v.get("pc")))
                d = ["%s=%s" % (k, fmt(x)) for k, x in v.items()
                     if k != "pc" and pv.get(k) != x]
                if d:
                    ch.append("L[%s] %s" % (p, " ".join(d)))
        for k, v in st.items():
            if k in ("L",):
                continue
            if prev.get(k) != v:
                if isinstance(v, dict) and isinstance(prev.get(k), dict):
                    for kk, vv in v.items():
                        if prev[k].get(kk) != vv:
                            ch.append("%s[%s]=%s" % (k, kk, fmt(vv)))
                elif isinstance(v, tuple) and isinstance(prev.get(k), tuple) and len(v) == len(prev[k]):
                    for kk, vv in enumerate(v, 1):
                        if prev[k][kk - 1] != vv:
                            ch.append("%s[%s]=%s" % (k, kk, fmt(vv)))
                else:
                    ch.append("%s=%s" % (k, fmt(v)))
        print("%3d %-10s %s" % (n, act, "; ".join(moves)))
        for c in ch:
            print("      %s" % c)
        prev = st


if __name__ == "__main__":
    main()

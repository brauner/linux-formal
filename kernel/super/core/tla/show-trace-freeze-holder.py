#!/usr/bin/env python3
# Print a TLC counterexample of SuperFreeze or SuperHolder compactly: for
# every state the action and the fields that changed.
#   ./show-trace-freeze-holder.py logs/freeze_steal.log
# With several runs appended to one log the last counterexample is shown.
import re
import sys


class P:
    """A parser for the TLC value syntax."""

    def __init__(self, s):
        self.s = s
        self.i = 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1

    def peek(self, t):
        self.ws()
        return self.s.startswith(t, self.i)

    def eat(self, t):
        self.ws()
        if not self.s.startswith(t, self.i):
            raise ValueError(f"expected {t!r} at {self.s[self.i:self.i + 40]!r}")
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
            return frozenset(out)
        if c == "[":
            self.i += 1
            out = {}
            while not self.peek("]"):
                self.ws()
                m = re.compile(r'"?([A-Za-z0-9_]+)"?\s*\|->').match(self.s, self.i)
                if not m:
                    raise ValueError(f"bad record at {self.s[self.i:self.i + 40]!r}")
                self.i = m.end()
                out[m.group(1)] = self.value()
                if self.peek(","):
                    self.eat(",")
            self.eat("]")
            return out
        if c == "(":
            # (a :> b @@ c :> d) function notation
            self.i += 1
            out = {}
            while not self.peek(")"):
                k = self.value()
                self.eat(":>")
                out[str(k)] = self.value()
                if self.peek("@@"):
                    self.eat("@@")
            self.eat(")")
            return out
        m = re.compile(r"-?[0-9]+|TRUE|FALSE|[A-Za-z_][A-Za-z0-9_]*").match(self.s, self.i)
        if not m:
            raise ValueError(f"bad value at {self.s[self.i:self.i + 40]!r}")
        self.i = m.end()
        t = m.group(0)
        if t == "TRUE":
            return True
        if t == "FALSE":
            return False
        if re.fullmatch(r"-?[0-9]+", t):
            return int(t)
        return t


def fmt(v):
    if isinstance(v, bool):
        return "T" if v else "F"
    if isinstance(v, frozenset):
        return "{" + ",".join(sorted(fmt(x) for x in v)) + "}"
    if isinstance(v, tuple):
        return "<" + ",".join(fmt(x) for x in v) + ">"
    if isinstance(v, dict):
        return "[" + ", ".join(f"{k}={fmt(x)}" for k, x in v.items()) + "]"
    return str(v)


def diff(path, a, b, out):
    if isinstance(a, dict) and isinstance(b, dict) and a.keys() == b.keys():
        for k in a:
            diff(path + [k], a[k], b[k], out)
    elif isinstance(a, tuple) and isinstance(b, tuple) and len(a) == len(b) and len(a) <= 4:
        for k in range(len(a)):
            diff(path + [str(k + 1)], a[k], b[k], out)
    elif a != b:
        out.append(".".join(path) + "=" + fmt(b))


def states(text):
    blocks = re.split(r"\nState (\d+): ", text)
    # blocks[0] is the preamble; then (num, body) pairs
    out = []
    for n in range(1, len(blocks), 2):
        body = blocks[n + 1]
        first, _, rest = body.partition("\n")
        act = re.sub(r" line .*", "", first.strip("<> "))
        rest = rest.split("\n\n")[0]
        vals = {}
        for m in re.finditer(r"^/\\ (\w+) = ", rest, re.M):
            pass
        parts = re.split(r"^/\\ (\w+) = ", rest, flags=re.M)
        for k in range(1, len(parts), 2):
            vals[parts[k]] = P(parts[k + 1]).value()
        out.append((int(blocks[n]), act, vals))
    return out


def main():
    text = open(sys.argv[1]).read()
    idx = text.rfind("The behavior up to this point is:")
    if idx < 0:
        idx = text.rfind("Error:")
    seg = text[idx:]
    end = re.search(r"\n\d+ states generated|\nThe number of states generated", seg)
    if end:
        seg = seg[:end.start()]
    err = re.findall(r"^Error: (Invariant .*|Deadlock.*|Action property.*|Temporal.*|The behavior.*violat.*)$", text[:idx + 1], re.M)
    if err:
        print("#", err[-1])
    prev = None
    for n, act, vals in states("\n" + seg):
        if prev is None:
            print(f"{n:3} {act}")
            for k, v in vals.items():
                print(f"      {k} = {fmt(v)}")
        else:
            ch = []
            for k in vals:
                diff([k], prev.get(k), vals[k], ch)
            print(f"{n:3} {act}: " + "; ".join(ch))
        prev = vals


if __name__ == "__main__":
    main()

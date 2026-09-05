"""Check that every string.format() in a Lua file has as many arguments as
conversion specifiers.

Lua raises this only when the call actually runs, so a mismatch in a rarely
hit branch (an error page, say) would sit undetected until the day it matters.
There is no Lua toolchain on this machine, so we check it statically.

Usage:  python tools/check_format.py firmware/*.lua
"""
import io
import re
import sys


def spec_count(fmt):
    """Conversion specifiers, ignoring the %% escape."""
    return len(re.findall(r'%[-+ #0-9.]*[diouxXeEfgGqscaA]', fmt.replace('%%', '')))


def arg_count(text):
    """Count top-level commas in an argument list, +1. Stops at the closing paren."""
    depth, n, instr, quote = 0, 1, False, None
    i = 0
    while i < len(text):
        ch = text[i]
        if instr:
            if ch == '\\':
                i += 2
                continue
            if ch == quote:
                instr = False
        elif ch in '"\'':
            instr, quote = True, ch
        elif ch in '([{':
            depth += 1
        elif ch in ')]}':
            if depth == 0:
                break
            depth -= 1
        elif ch == ',' and depth == 0:
            n += 1
        i += 1
    return n


def literals(src):
    """Map a long-bracket constant name -> its text, so string.format(TPL, ...) resolves."""
    out = {}
    for m in re.finditer(r'local\s+(\w+)\s*=\s*\[\[(.*?)\]\]', src, re.S):
        out[m.group(1)] = m.group(2)
    return out


def check(path):
    src = io.open(path, encoding='utf-8').read()
    consts = literals(src)
    errs = []
    n = 0

    for m in re.finditer(r'string\.format\s*\(', src):
        rest = src[m.end():]
        line = src[:m.start()].count('\n') + 1

        # first argument: an inline "..." literal, or the name of a [[...]] constant
        lit = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*(,?)', rest, re.S)
        if lit:
            fmt, tail = lit.group(1), rest[lit.end():]
            if not lit.group(2):
                continue  # single-argument format, nothing to check
        else:
            name = re.match(r'\s*(\w+)\s*,', rest)
            if not name or name.group(1) not in consts:
                continue  # can't resolve statically; skip rather than guess
            fmt, tail = consts[name.group(1)], rest[name.end():]

        n += 1
        want, got = spec_count(fmt), arg_count(tail)
        if want != got:
            errs.append("  line %d: %d specifiers but %d arguments" % (line, want, got))

    return n, errs


bad = 0
for p in sys.argv[1:]:
    n, errs = check(p)
    if errs:
        bad = 1
        print("FAIL %s" % p)
        for e in errs:
            print(e)
    else:
        print("ok   %s  (%d formats checked)" % (p, n))
sys.exit(bad)

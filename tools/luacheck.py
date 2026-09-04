import re, sys, pathlib

BACKSLASH = chr(92)


def strip(src):
    """Remove comments and string literals, keeping newlines for line numbers."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '\n':
            out.append('\n')
            i += 1
            continue
        m = re.match(r'(--)?\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(2) + ']'
            j = src.find(close, i + m.end())
            j = n if j < 0 else j + len(close)
            out.append(re.sub(r'[^\n]', ' ', src[i:j]))
            i = j
            continue
        if src.startswith('--', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
            continue
        if c in '"\'':
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == BACKSLASH:
                    j += 1
                j += 1
            j = min(j + 1, n)
            out.append(re.sub(r'[^\n]', ' ', src[i:j]))
            i = j
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def check(path):
    src = pathlib.Path(path).read_text(encoding='utf-8')
    lines = strip(src).split('\n')
    errs = []

    # --- block depth: function / if / do / repeat  vs  end / until ---
    stack = []
    for ln, text in enumerate(lines, 1):
        t = re.sub(r'\belseif\b', 'ELSEIF', text)
        for m in re.finditer(r'\b(function|if|do|repeat|end|until)\b', t):
            w = m.group(1)
            if w in ('function', 'if', 'do', 'repeat'):
                stack.append((w, ln))
            else:
                if not stack:
                    errs.append("  line %d: 多出來的 '%s'" % (ln, w))
                    continue
                opener, oln = stack.pop()
                if w == 'until' and opener != 'repeat':
                    errs.append("  line %d: 'until' 對到的是第 %d 行的 '%s'" % (ln, oln, opener))
                if w == 'end' and opener == 'repeat':
                    errs.append("  line %d: 'end' 對到第 %d 行的 'repeat'（應為 until）" % (ln, oln))
    for opener, oln in stack:
        errs.append("  line %d: '%s' 沒有對應的 end" % (oln, opener))

    # --- bracket balance ---
    pairs = {')': '(', ']': '[', '}': '{'}
    bstack = []
    for ln, text in enumerate(lines, 1):
        for ch in text:
            if ch in '([{':
                bstack.append((ch, ln))
            elif ch in ')]}':
                if not bstack:
                    errs.append("  line %d: 多出來的 '%s'" % (ln, ch))
                    continue
                o, oln = bstack.pop()
                if o != pairs[ch]:
                    errs.append("  line %d: '%s' 對到第 %d 行的 '%s'" % (ln, ch, oln, o))
    for o, oln in bstack:
        errs.append("  line %d: '%s' 沒有關閉" % (oln, o))

    # --- every if / elseif needs a then on the same line ---
    for ln, text in enumerate(lines, 1):
        t = re.sub(r'\belseif\b', 'ELSEIF ', text)
        if re.search(r'\bif\b', t) and not re.search(r'\bthen\b', t):
            errs.append("  line %d: 'if' 這行沒有 'then'" % ln)
        if re.search(r'\bELSEIF\b', t) and not re.search(r'\bthen\b', t):
            errs.append("  line %d: 'elseif' 這行沒有 'then'" % ln)

    return errs


bad = 0
for p in sys.argv[1:]:
    e = check(p)
    if e:
        bad = 1
        print("FAIL %s" % pathlib.Path(p).name)
        for x in e:
            print(x)
    else:
        print("ok   %s" % pathlib.Path(p).name)
sys.exit(bad)

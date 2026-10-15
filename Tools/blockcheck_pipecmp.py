"""Run on the Pi: python pipecmp.py ORIGDIR RTDIR  -> compares what the real md.py/inbox.py make of each file pair."""
import sys, re, os
sys.path.insert(0, os.path.expanduser('~/devrobotics-site/_tools/frames'))
from framespipe import md as M, inbox as I


def body_lines(path):
    text = open(path, encoding='utf-8').read().lstrip('﻿')
    lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    first = next((i for i, l in enumerate(lines) if l.strip()), None)
    start = 0
    if first is not None and lines[first].strip() == '---':
        end = next((i for i in range(first + 1, len(lines)) if lines[i].strip() == '---'), None)
        if end is not None:
            start = end + 1
    return [(i + 1, lines[i]) for i in range(start, len(lines))]


def digest(path):
    out, para, words = [], [], 0
    def flush():
        nonlocal para, words
        if para:
            try:
                h, w, warn = M.render(para)
                out.append(('md', h))
                words += len(w)
            except M.MdError as e:
                out.append(('mderr', str(e)))
            para = []
    for ln, t in body_lines(path):
        if I.MARKER_START.match(t):
            flush()
            mk, err = I.parse_marker(ln, t)
            if err:
                out.append(('err', err))
            else:
                out.append(('mk', mk.kind, tuple(mk.files), mk.note, getattr(mk, 'alt', None), getattr(mk, 'place', None),
                            getattr(mk, 'full', None), tuple(map(tuple, mk.items)) if getattr(mk, 'items', None) else None,
                            getattr(mk, 'url', None)))
        elif re.search(r'<\s*insert\b', t, re.I):
            out.append(('err', 'inline marker'))
        else:
            para.append((ln, t))
    flush()
    return out, words


bad = 0
for name in sorted(os.listdir(sys.argv[1])):
    a, wa = digest(os.path.join(sys.argv[1], name))
    b, wb = digest(os.path.join(sys.argv[2], name))
    # empty md chunks produce no html; compare ignoring them
    a = [x for x in a if not (x[0] == 'md' and not x[1])]
    b = [x for x in b if not (x[0] == 'md' and not x[1])]
    ok = a == b and wa == wb
    bad += not ok
    print(('SAME ' if ok else 'DIFF ') + name, f'items={len(a)} words={wa}/{wb}')
    if not ok:
        for x, y in zip(a, b):
            if x != y:
                print('   orig:', x, '\n   rt:  ', y)
        if len(a) != len(b):
            print('   len', len(a), len(b))
sys.exit(1 if bad else 0)

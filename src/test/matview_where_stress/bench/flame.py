#!/usr/bin/env python3
"""Fold pmp.sh stacks and render a flame graph SVG.

    ./flame.py <stacks> <out.svg> [title]

Why this is here rather than flamegraph.pl: the FlameGraph scripts are not
installed and fetching them puts a network dependency in the middle of a
measurement.  This is the same idea in fewer lines -- fold identical stacks,
lay each out as a box whose width is its sample count, stack callers below
callees -- and it produces a self-contained SVG with no external assets.

Read it as a census, not a timeline.  Width is "fraction of samples in which
this function was somewhere on the stack", and the x axis is alphabetical, not
chronological.  Frames are dropped below MIN_FRAC of total width because a box
narrower than a couple of pixels cannot be read or clicked.
"""
import sys
import re
import html
from collections import defaultdict

MIN_FRAC = 0.002
ROW_H = 17
FONT = 11
WIDTH = 1480
PAD = 12


def parse(path):
    """pmp.sh writes gdb '#N frame' lines, each sample ended by //SAMPLE."""
    stacks, cur = [], []
    frame_re = re.compile(r"^#\d+\s+(?:0x[0-9a-f]+\s+in\s+)?([^\s(]+)")
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("//SAMPLE"):
                if cur:
                    # gdb prints innermost first; a flame graph wants callers
                    # at the bottom, so reverse into root-to-leaf order.
                    stacks.append(tuple(reversed(cur)))
                cur = []
                continue
            m = frame_re.match(line)
            if m:
                cur.append(m.group(1))
    if cur:
        stacks.append(tuple(reversed(cur)))
    return stacks


def fold(stacks):
    counts = defaultdict(int)
    for s in stacks:
        counts[s] += 1
    return counts


def layout(counts):
    """Assign every (depth, function) run a start offset and width."""
    total = sum(counts.values())
    boxes = []

    def walk(prefix, subset, depth, x0):
        groups = defaultdict(list)
        for stack, n in subset:
            if len(stack) <= depth:
                continue
            groups[stack[depth]].append((stack, n))
        x = x0
        for name in sorted(groups):
            members = groups[name]
            w = sum(n for _, n in members)
            if w / total >= MIN_FRAC:
                boxes.append((depth, x, w, name, w / total))
                walk(prefix + (name,), members, depth + 1, x)
            x += w

    walk((), list(counts.items()), 0, 0)
    return boxes, total


PALETTE = ["#d94", "#c85", "#e a6", "#db7", "#c96", "#eb8", "#da6", "#cb7"]


def colour(name):
    """Warm hues, deterministic per name so the same function keeps its colour
    across two graphs being compared."""
    h = 0
    for ch in name:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    r = 205 + (h % 50)
    g = 60 + ((h >> 8) % 130)
    b = 40 + ((h >> 16) % 45)
    return "#%02x%02x%02x" % (r, g, b)


def render(boxes, total, title, out):
    depth_max = max((d for d, *_ in boxes), default=0)
    height = (depth_max + 1) * ROW_H + PAD * 2 + 46
    scale = (WIDTH - PAD * 2) / float(total)

    p = []
    p.append(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" font-family="Verdana,Helvetica,sans-serif" '
        'font-size="%d">' % (WIDTH, height, WIDTH, height, FONT)
    )
    p.append('<style>rect{stroke:#fff;stroke-width:.6}'
             'rect:hover{stroke:#000;stroke-width:1.2}'
             'text{pointer-events:none}</style>')
    p.append('<rect width="100%%" height="100%%" fill="#f8f6f2"/>')
    p.append('<text x="%d" y="24" font-size="15" font-weight="bold" '
             'fill="#222">%s</text>' % (PAD, html.escape(title)))
    p.append('<text x="%d" y="40" font-size="11" fill="#555">%d samples; '
             'width = share of samples with the frame on the stack; '
             'x axis alphabetical, NOT time</text>' % (PAD, total))

    for depth, x0, w, name, frac in boxes:
        x = PAD + x0 * scale
        bw = w * scale
        y = height - PAD - (depth + 1) * ROW_H
        tip = "%s  %.1f%%  (%d samples)" % (name, frac * 100, w)
        p.append('<g><title>%s</title>'
                 '<rect x="%.2f" y="%d" width="%.2f" height="%d" fill="%s"/>'
                 % (html.escape(tip), x, y, max(bw - 0.6, 0.4),
                    ROW_H - 1, colour(name)))
        # ~6.2px per char at this font; only label boxes that can hold text.
        if bw > 26:
            room = int((bw - 6) / 6.2)
            label = name if len(name) <= room else name[: max(room - 1, 1)] + "…"
            p.append('<text x="%.2f" y="%d" fill="#1a1a1a">%s</text>'
                     % (x + 3, y + ROW_H - 5, html.escape(label)))
        p.append('</g>')

    p.append('</svg>')
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(p))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else src
    stacks = parse(src)
    if not stacks:
        print("no stacks parsed from %s" % src, file=sys.stderr)
        return 1
    counts = fold(stacks)
    boxes, total = layout(counts)
    render(boxes, total, title, out)
    print("%d samples, %d distinct stacks, %d boxes -> %s"
          % (total, len(counts), len(boxes), out))

    # A flame graph is for looking at; this is for reading in a terminal.
    leaves = defaultdict(int)
    for stack, n in counts.items():
        if stack:
            leaves[stack[-1]] += n
    print("\ntop leaf frames (where the CPU actually was):")
    for name, n in sorted(leaves.items(), key=lambda kv: -kv[1])[:15]:
        print("  %5.1f%%  %4d  %s" % (100.0 * n / total, n, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())

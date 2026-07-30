#!/usr/bin/env python3
"""Render a bench_result run as a standalone HTML page.

    ./chart.py <run_label> <out.html> [--port 5610] [--db postgres]

Reads the run straight out of bench_result rather than from a pasted table, so
the page cannot drift from the measurement.  Everything is inline: no scripts,
styles, or fonts are fetched, which is what the artifact sandbox requires and is
also what makes the file worth keeping next to the numbers.

Colours come from the data-viz reference palette and were run through its
validator (2 slots, light and dark, all checks pass).  Do not substitute a hue
here without re-running it.
"""
import json
import math
import shlex
import subprocess
import sys

BINDIR = '/home/user/pgsql-opt/bin'

QUERY = """
SELECT json_agg(row_to_json(t) ORDER BY t.workload, t.predshape, t.span) FROM (
  SELECT a.workload, a.predshape, a.span, a.scope_rows, a.mv_rows,
         a.isolates, a.assertions, a.pg_version, a.sync, a.clients,
         round(a.latency_ms,3) AS spi_ms,  round(b.latency_ms,3) AS qt_ms,
         round(a.tps,1)        AS spi_tps, round(b.tps,1)        AS qt_tps,
         round(a.full_ms,1)    AS full_ms,
         round(100*(a.latency_ms-b.latency_ms)/a.latency_ms,2) AS pct
    FROM bench_result a
    JOIN bench_result b USING (run_label, workload, predshape, span,
                               clients, overlap)
   WHERE a.run_label = %s AND a.form = 'spi' AND b.form = 'querytree') t
"""


def fetch(label, port, db):
    # One line: this goes through `su -c`, so the shell sees the whole psql
    # invocation as a single word and will not turn embedded newlines back
    # into newlines -- it passes them through as a literal backslash-n.
    sql = ' '.join(QUERY.replace('%s', "'" + label.replace("'", "''") + "'")
                   .split())
    cmd = f'{BINDIR}/psql -p {port} -d {db} -X -Atc {shlex.quote(sql)}'
    out = subprocess.run(['su', 'pgtest', '-c', cmd],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout.strip()) if out.stdout.strip() else []


# ---------------------------------------------------------------- geometry --

def logscale(v, lo, hi, px0, px1):
    v = max(v, lo)
    t = (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo))
    return px0 + t * (px1 - px0)


def nice_log_ticks(lo, hi):
    ticks, e = [], math.floor(math.log10(lo))
    while 10 ** e <= hi * 1.001:
        for m in (1, 2, 5):
            v = m * 10 ** e
            if lo * 0.999 <= v <= hi * 1.001:
                ticks.append(v)
        e += 1
    return ticks


def spaced(ticks, lo, hi, px0, px1, minpx=46):
    """Drop ticks that would render on top of their neighbour.

    A 1/2/5 ladder over four decades puts 5,000 / 10,000 / 20,000 within a few
    pixels of each other at this width, and the labels overprint.
    """
    kept, last = [], None
    for t in ticks:
        x = logscale(t, lo, hi, px0, px1)
        if last is None or abs(x - last) >= minpx:
            kept.append(t)
            last = x
    return kept


def fmt_ms(v):
    if v >= 100:
        return f'{v:,.0f}'
    if v >= 10:
        return f'{v:.0f}'
    if v >= 1:
        return f'{v:.1f}'
    return f'{v:.2f}'


def esc(s):
    return (str(s).replace('&', '&amp;').replace('<', '&lt;')
            .replace('>', '&gt;').replace('"', '&quot;'))


# ------------------------------------------------------------------ charts --

def chart_by_workload(rows):
    """Mean percent faster per workload.  One nominal axis, one hue."""
    agg = {}
    for r in rows:
        agg.setdefault(r['workload'], []).append(r['pct'])
    items = sorted(((w, sum(v) / len(v), len(v), min(v), max(v))
                    for w, v in agg.items()), key=lambda x: -x[1])

    W, rowh, top, left, right = 720, 38, 16, 116, 64
    H = top + rowh * len(items) + 34
    xmax = max(8.0, max(i[1] for i in items) * 1.18)
    x0, x1 = left, W - right

    p = [f'<svg viewBox="0 0 {W} {H}" role="img" class="chart" '
         f'aria-label="Mean percent faster by workload">']
    for gv in range(0, int(xmax) + 1, 5):
        gx = x0 + gv / xmax * (x1 - x0)
        p.append(f'<line class="grid" x1="{gx:.1f}" y1="{top - 6}" '
                 f'x2="{gx:.1f}" y2="{top + rowh * len(items) - 8}"/>')
        p.append(f'<text class="tick" x="{gx:.1f}" '
                 f'y="{top + rowh * len(items) + 12}" '
                 f'text-anchor="middle">{gv}%</text>')
    for i, (w, mean, n, lo, hi) in enumerate(items):
        y = top + i * rowh
        bw = max(2.0, mean / xmax * (x1 - x0))
        p.append(f'<text class="cat" x="{left - 12}" y="{y + 15}" '
                 f'text-anchor="end">{esc(w)}</text>')
        p.append(f'<rect class="bar" x="{x0}" y="{y + 3}" width="{bw:.1f}" '
                 f'height="16" rx="4"/>')
        p.append(f'<rect class="bar-sq" x="{x0}" y="{y + 3}" '
                 f'width="{min(4.0, bw):.1f}" height="16"/>')
        p.append(f'<text class="val" x="{x0 + bw + 8:.1f}" y="{y + 15}">'
                 f'{mean:.1f}%</text>')
        p.append(f'<rect class="hit" x="{x0}" y="{y}" width="{x1 - x0}" '
                 f'height="{rowh - 4}" data-tip="{esc(w)} · mean {mean:.1f}% '
                 f'· range {lo:.1f}% to {hi:.1f}% · {n} combinations"/>')
    p.append(f'<line class="axis" x1="{x0}" y1="{top - 6}" x2="{x0}" '
             f'y2="{top + rowh * len(items) - 8}"/>')
    p.append('</svg>')
    return '\n'.join(p)


def chart_scatter(rows):
    """Query-tree latency against SPI latency, log-log, with a y=x diagonal."""
    vals = [v for r in rows for v in (r['spi_ms'], r['qt_ms'])]
    # Pad the observed range rather than snapping out to whole decades.  One
    # workload refreshes in ~1.1 s and the rest in under 100 ms; snapping put
    # the data in a fifth of the plot and crowded the tick labels.
    lo, hi = min(vals) / 1.6, max(vals) * 1.6

    W, H, pad_l, pad_b, pad_t, pad_r = 640, 560, 62, 52, 18, 18
    x0, x1 = pad_l, W - pad_r
    y0, y1 = H - pad_b, pad_t

    p = [f'<svg viewBox="0 0 {W} {H}" role="img" class="chart" '
         f'aria-label="Query-tree latency against SPI latency">']
    for t in spaced(nice_log_ticks(lo, hi), lo, hi, x0, x1, 42):
        gx = logscale(t, lo, hi, x0, x1)
        gy = logscale(t, lo, hi, y0, y1)
        p.append(f'<line class="grid" x1="{gx:.1f}" y1="{y1}" '
                 f'x2="{gx:.1f}" y2="{y0}"/>')
        p.append(f'<line class="grid" x1="{x0}" y1="{gy:.1f}" '
                 f'x2="{x1}" y2="{gy:.1f}"/>')
        p.append(f'<text class="tick" x="{gx:.1f}" y="{y0 + 18}" '
                 f'text-anchor="middle">{fmt_ms(t)}</text>')
        p.append(f'<text class="tick" x="{x0 - 8}" y="{gy + 4:.1f}" '
                 f'text-anchor="end">{fmt_ms(t)}</text>')

    p.append(f'<line class="diag" x1="{logscale(lo, lo, hi, x0, x1):.1f}" '
             f'y1="{logscale(lo, lo, hi, y0, y1):.1f}" '
             f'x2="{logscale(hi, lo, hi, x0, x1):.1f}" '
             f'y2="{logscale(hi, lo, hi, y0, y1):.1f}"/>')
    t = 0.88
    p.append(f'<text class="note" x="{x0 + t * (x1 - x0) - 10:.1f}" '
             f'y="{y0 - t * (y0 - y1) - 9:.1f}" '
             f'text-anchor="end">no change</text>')

    for r in rows:
        cx = logscale(r['spi_ms'], lo, hi, x0, x1)
        cy = logscale(r['qt_ms'], lo, hi, y0, y1)
        slower = r['pct'] < 0
        cls = 'dot slower' if slower else 'dot'
        tip = (f"{r['workload']} · {r['predshape']} span {r['span']} · "
               f"spi {r['spi_ms']:.2f} ms → querytree {r['qt_ms']:.2f} ms · "
               f"{r['pct']:+.1f}%")
        p.append(f'<circle class="{cls}" cx="{cx:.1f}" cy="{cy:.1f}" r="5"/>')
        p.append(f'<circle class="hit" cx="{cx:.1f}" cy="{cy:.1f}" r="13" '
                 f'data-tip="{esc(tip)}"/>')

    p.append(f'<line class="axis" x1="{x0}" y1="{y0}" x2="{x1}" y2="{y0}"/>')
    p.append(f'<line class="axis" x1="{x0}" y1="{y0}" x2="{x0}" y2="{y1}"/>')
    p.append(f'<text class="axlabel" x="{(x0 + x1) / 2:.0f}" y="{H - 6}" '
             f'text-anchor="middle">spi latency (ms, log)</text>')
    p.append(f'<text class="axlabel" transform="translate(14,'
             f'{(y0 + y1) / 2:.0f}) rotate(-90)" text-anchor="middle">'
             f'querytree latency (ms, log)</text>')
    p.append('</svg>')
    return '\n'.join(p)


def chart_vs_scope(rows):
    """Percent faster against scope.  The point is that there is no trend."""
    pts = [r for r in rows if (r['scope_rows'] or 0) > 0]
    lo, hi = 0.8, max(r['scope_rows'] for r in pts) * 1.7
    pcts = sorted(r['pct'] for r in rows)
    med = pcts[len(pcts) // 2] if len(pcts) % 2 else \
        (pcts[len(pcts) // 2 - 1] + pcts[len(pcts) // 2]) / 2

    W, H, pad_l, pad_b, pad_t, pad_r = 720, 320, 52, 52, 18, 18
    x0, x1 = pad_l, W - pad_r
    y0, y1 = H - pad_b, pad_t
    ymin = min(-10.0, min(r['pct'] for r in pts) - 2)
    ymax = max(30.0, max(r['pct'] for r in pts) + 2)

    def ypx(v):
        return y0 - (v - ymin) / (ymax - ymin) * (y0 - y1)

    p = [f'<svg viewBox="0 0 {W} {H}" role="img" class="chart" '
         f'aria-label="Percent faster against scope">']
    for gv in range(int(ymin // 10 * 10), int(ymax) + 1, 10):
        gy = ypx(gv)
        if not (y1 <= gy <= y0):
            continue
        p.append(f'<line class="grid" x1="{x0}" y1="{gy:.1f}" x2="{x1}" '
                 f'y2="{gy:.1f}"/>')
        p.append(f'<text class="tick" x="{x0 - 8}" y="{gy + 4:.1f}" '
                 f'text-anchor="end">{gv}%</text>')
    for t in spaced(nice_log_ticks(lo, hi), lo, hi, x0, x1):
        gx = logscale(t, lo, hi, x0, x1)
        p.append(f'<line class="grid" x1="{gx:.1f}" y1="{y1}" '
                 f'x2="{gx:.1f}" y2="{y0}"/>')
        p.append(f'<text class="tick" x="{gx:.1f}" y="{y0 + 18}" '
                 f'text-anchor="middle">{t:,.0f}</text>')

    p.append(f'<line class="zero" x1="{x0}" y1="{ypx(0):.1f}" x2="{x1}" '
             f'y2="{ypx(0):.1f}"/>')
    p.append(f'<line class="median" x1="{x0}" y1="{ypx(med):.1f}" x2="{x1}" '
             f'y2="{ypx(med):.1f}"/>')
    for r in pts:
        cx = logscale(r['scope_rows'], lo, hi, x0, x1)
        cy = ypx(r['pct'])
        cls = 'dot slower' if r['pct'] < 0 else 'dot'
        tip = (f"{r['workload']} · {r['predshape']} span {r['span']} · "
               f"{r['scope_rows']:,} rows in scope · {r['pct']:+.1f}%")
        p.append(f'<circle class="{cls}" cx="{cx:.1f}" cy="{cy:.1f}" r="5"/>')
        p.append(f'<circle class="hit" cx="{cx:.1f}" cy="{cy:.1f}" r="13" '
                 f'data-tip="{esc(tip)}"/>')

    p.append(f'<text class="note" x="{x1 - 6}" y="{ypx(med) - 10:.1f}" '
             f'text-anchor="end">median {med:.1f}%</text>')
    p.append(f'<line class="axis" x1="{x0}" y1="{y0}" x2="{x1}" y2="{y0}"/>')
    p.append(f'<text class="axlabel" x="{(x0 + x1) / 2:.0f}" y="{H - 6}" '
             f'text-anchor="middle">matview rows the predicate selects '
             f'(log)</text>')
    p.append('</svg>')
    return '\n'.join(p), len(rows) - len(pts)


# -------------------------------------------------------------------- page --

def corr(a, b):
    n = len(a)
    ma, mb = sum(a) / n, sum(b) / n
    num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    den = (sum((x - ma) ** 2 for x in a) * sum((y - mb) ** 2 for y in b)) ** .5
    return num / den if den else 0.0


def build(rows, label):
    pcts = sorted(r['pct'] for r in rows)
    n = len(rows)
    mean = sum(pcts) / n
    med = pcts[n // 2] if n % 2 else (pcts[n // 2 - 1] + pcts[n // 2]) / 2
    wins = sum(1 for p in pcts if p > 0)
    r_scope = corr([math.log10(max(r['scope_rows'] or 1, 1)) for r in rows],
                   [r['pct'] for r in rows])
    r_total = corr([r['spi_ms'] for r in rows],
                   [r['spi_ms'] - r['qt_ms'] for r in rows])
    meta = rows[0]
    scope_chart, dropped = chart_vs_scope(rows)

    table = ['<table><thead><tr>'
             '<th>workload</th><th>shape</th><th class="n">span</th>'
             '<th class="n">scope rows</th><th class="n">spi ms</th>'
             '<th class="n">querytree ms</th><th class="n">faster</th>'
             '</tr></thead><tbody>']
    for r in sorted(rows, key=lambda r: -r['pct']):
        cls = ' class="neg"' if r['pct'] < 0 else ''
        # scope_rows is NULL when the scope probe found no rows -- see the
        # note under the scope chart.  Say so rather than printing a 0 that
        # would read as a measured value.
        scope = ('&mdash;' if r['scope_rows'] is None
                 else f"{r['scope_rows']:,}")
        table.append(
            f"<tr><td class=\"mono\">{esc(r['workload'])}</td>"
            f"<td class=\"mono\">{esc(r['predshape'])}</td>"
            f"<td class=\"n\">{r['span']}</td>"
            f"<td class=\"n\">{scope}</td>"
            f"<td class=\"n\">{r['spi_ms']:.2f}</td>"
            f"<td class=\"n\">{r['qt_ms']:.2f}</td>"
            f"<td class=\"n\"{cls}>{r['pct']:+.1f}%</td></tr>")
    table.append('</tbody></table>')

    return TEMPLATE.format(
        label=esc(label), n=n, wins=wins, losses=n - wins,
        mean=f'{mean:.1f}', med=f'{med:.1f}',
        best=f'{max(pcts):.1f}',
        worst=f'{min(pcts):.1f}'.replace('-', '\u2212'),
        workloads=len({r['workload'] for r in rows}),
        version=esc(meta['pg_version'].split(' on ')[0]),
        assertions=esc(meta['assertions']),
        sync=esc(meta['sync']), clients=meta['clients'],
        r_scope=f'{r_scope:+.2f}', r_total=f'{r_total:+.2f}',
        dropped_note=('' if not dropped else
                      f' {dropped} combination{"s" if dropped > 1 else ""} '
                      f'omitted here: the scope probe evaluates the predicate '
                      f'at key 1, which that workload&#8217;s key space does '
                      f'not contain, so its scope reads 0 and cannot sit on a '
                      f'log axis. The measurements themselves are unaffected '
                      f'and are in the table.'),
        chart1=chart_by_workload(rows),
        chart2=chart_scatter(rows),
        chart3=scope_chart,
        table=''.join(table))


TEMPLATE = """<title>Partial refresh: Query tree vs generated SQL</title>
<style>
  :root {{
    color-scheme: light;
    --plane:      #f9f9f7;
    --surface:    #fcfcfb;
    --ink:        #0b0b0b;
    --ink-2:      #52514e;
    --muted:      #898781;
    --rule:       #e1e0d9;
    --axis:       #c3c2b7;
    --series:     #2a78d6;
    --neg:        #d03b3b;
    --hair:       rgba(11,11,11,0.10);
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) {{
      color-scheme: dark;
      --plane: #0d0d0d; --surface: #1a1a19; --ink: #ffffff;
      --ink-2: #c3c2b7; --muted: #898781; --rule: #2c2c2a;
      --axis: #383835; --series: #3987e5; --neg: #d03b3b;
      --hair: rgba(255,255,255,0.10);
    }}
  }}
  :root[data-theme="dark"] {{
    color-scheme: dark;
    --plane: #0d0d0d; --surface: #1a1a19; --ink: #ffffff;
    --ink-2: #c3c2b7; --muted: #898781; --rule: #2c2c2a;
    --axis: #383835; --series: #3987e5; --neg: #d03b3b;
    --hair: rgba(255,255,255,0.10);
  }}

  body {{
    background: var(--plane); color: var(--ink);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    line-height: 1.55; margin: 0; padding: 40px 20px 72px;
    -webkit-font-smoothing: antialiased;
  }}
  .wrap {{ max-width: 1000px; margin: 0 auto; display: flex;
           flex-direction: column; gap: 28px; }}
  .mono, code {{ font-family: ui-monospace, SFMono-Regular, "SF Mono",
                 Menlo, Consolas, monospace; }}

  header {{ display: flex; flex-direction: column; gap: 10px; }}
  .eyebrow {{ font-size: 11px; letter-spacing: .13em; text-transform: uppercase;
              color: var(--muted); font-family: ui-monospace, SFMono-Regular,
              Menlo, monospace; }}
  h1 {{ font-size: clamp(24px, 4vw, 33px); line-height: 1.2; margin: 0;
        font-weight: 620; letter-spacing: -.015em; text-wrap: balance; }}
  .lede {{ color: var(--ink-2); max-width: 62ch; margin: 0; }}
  .provenance {{ display: flex; flex-wrap: wrap; gap: 6px 18px; font-size: 12px;
                 color: var(--muted); padding-top: 6px;
                 border-top: 1px solid var(--rule);
                 font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}

  .kpis {{ display: grid; gap: 12px;
           grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }}
  .kpi {{ background: var(--surface); border: 1px solid var(--hair);
          border-radius: 3px; padding: 14px 16px 13px; }}
  .kpi .v {{ font-size: 31px; font-weight: 600; letter-spacing: -.02em;
             line-height: 1.05; }}
  .kpi .v.accent {{ color: var(--series); }}
  .kpi .v.range {{ font-size: 21px; white-space: nowrap; }}
  .kpi .k {{ font-size: 11px; color: var(--muted); margin-top: 5px;
             letter-spacing: .04em; }}

  .panel {{ background: var(--surface); border: 1px solid var(--hair);
            border-radius: 3px; padding: 20px 22px 18px; }}
  .panel h2 {{ font-size: 15px; margin: 0 0 2px; font-weight: 600;
               letter-spacing: -.005em; }}
  .panel p.read {{ font-size: 13px; color: var(--ink-2); margin: 0 0 16px;
                   max-width: 68ch; }}
  .chart {{ width: 100%; height: auto; display: block; overflow: visible; }}

  .grid {{ stroke: var(--rule); stroke-width: 1; }}
  .axis {{ stroke: var(--axis); stroke-width: 1; }}
  .diag {{ stroke: var(--axis); stroke-width: 1; }}
  .zero {{ stroke: var(--axis); stroke-width: 1; }}
  .median {{ stroke: var(--series); stroke-width: 2; }}
  .bar {{ fill: var(--series); }}
  .bar-sq {{ fill: var(--series); }}
  .dot {{ fill: var(--series); stroke: var(--surface); stroke-width: 2; }}
  .dot.slower {{ fill: var(--neg); stroke: var(--surface); stroke-width: 2; }}
  .hit {{ fill: transparent; cursor: crosshair; }}
  text {{ font-family: system-ui, -apple-system, sans-serif; }}
  .tick {{ font-size: 11px; fill: var(--muted);
           font-variant-numeric: tabular-nums; }}
  .cat {{ font-size: 12.5px; fill: var(--ink-2);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
  .val {{ font-size: 12px; fill: var(--ink); font-weight: 600;
          font-variant-numeric: tabular-nums; dominant-baseline: middle; }}
  .axlabel {{ font-size: 12px; fill: var(--ink-2); }}
  .note {{ font-size: 11px; fill: var(--muted); stroke: var(--surface);
           stroke-width: 3px; paint-order: stroke; }}

  .legend {{ display: flex; gap: 18px; font-size: 12px; color: var(--ink-2);
             margin-top: 12px; flex-wrap: wrap; }}
  .legend span {{ display: inline-flex; align-items: center; gap: 7px; }}
  .sw {{ width: 10px; height: 10px; border-radius: 50%;
         background: var(--series); }}
  .sw.neg {{ background: var(--neg); }}
  .sw.line {{ width: 16px; height: 2px; border-radius: 0;
              background: var(--axis); }}

  .tablewrap {{ overflow-x: auto; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 12.5px;
           font-variant-numeric: tabular-nums; }}
  th, td {{ text-align: left; padding: 5px 12px 5px 0;
            border-bottom: 1px solid var(--rule); white-space: nowrap; }}
  th {{ font-size: 11px; letter-spacing: .05em; color: var(--muted);
        font-weight: 500; text-transform: uppercase; }}
  td.n, th.n {{ text-align: right; }}
  td.neg {{ color: var(--neg); }}
  td.mono {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}

  .caveats {{ font-size: 13px; color: var(--ink-2); }}
  .caveats h2 {{ font-size: 13px; text-transform: uppercase;
                 letter-spacing: .09em; color: var(--muted); margin: 0 0 10px;
                 font-weight: 600; }}
  .caveats ul {{ margin: 0; padding-left: 18px; display: flex;
                 flex-direction: column; gap: 8px; max-width: 76ch; }}

  #tip {{ position: fixed; pointer-events: none; opacity: 0;
          transition: opacity .09s; background: var(--ink); color: var(--plane);
          font-size: 12px; padding: 6px 9px; border-radius: 3px;
          max-width: 300px; z-index: 9; line-height: 1.4; }}
  @media (prefers-reduced-motion: reduce) {{
    #tip {{ transition: none; }}
  }}
  :focus-visible {{ outline: 2px solid var(--series); outline-offset: 2px; }}
</style>

<div class="wrap">
  <header>
    <div class="eyebrow">REFRESH MATERIALIZED VIEW &hellip; WHERE &hellip;
      &nbsp;/&nbsp; run {label}</div>
    <h1>Evaluating the view from its Query tree, measured against building
      its SQL as text</h1>
    <p class="lede">Both implementations live in the same binary and are
      selected at run time, so this compares two code paths and nothing
      else &mdash; not two builds, not two machines. Each pair was measured
      back to back, best of three.</p>
    <div class="provenance">
      <span>{version}</span><span>assertions {assertions}</span>
      <span>synchronous_commit {sync}</span><span>{clients} client</span>
      <span>{workloads} workloads &middot; {n} combinations</span>
    </div>
  </header>

  <div class="kpis">
    <div class="kpi"><div class="v accent">+{med}%</div>
      <div class="k">median, all combinations</div></div>
    <div class="kpi"><div class="v">+{mean}%</div>
      <div class="k">mean</div></div>
    <div class="kpi"><div class="v">{wins}<span
      style="color:var(--muted);font-size:19px"> / {n}</span></div>
      <div class="k">combinations faster</div></div>
    <div class="kpi"><div class="v range">{worst}% to +{best}%</div>
      <div class="k">full range</div></div>
  </div>

  <section class="panel">
    <h2>Every combination, plotted against no change</h2>
    <p class="read">One point per combination. The diagonal is
      &ldquo;identical&rdquo;; everything below it is faster on the Query-tree
      path. Both axes are log, so a constant <em>percentage</em> gain shows up
      as points lying parallel to the diagonal &mdash; which is what they
      do, across three orders of magnitude of refresh cost.</p>
    {chart2}
    <div class="legend">
      <span><i class="sw"></i>faster on the Query-tree path</span>
      <span><i class="sw neg"></i>slower ({losses})</span>
      <span><i class="sw line"></i>no change</span>
    </div>
  </section>

  <section class="panel">
    <h2>By workload</h2>
    <p class="read">Mean across each workload&rsquo;s predicate shapes and
      scopes. The eight workloads were chosen to isolate different cost
      drivers rather than different domains, so the spread between them is the
      interesting part &mdash; not any single bar.</p>
    {chart1}
  </section>

  <section class="panel">
    <h2>The gain does not shrink as the refresh gets bigger</h2>
    <p class="read">Worth stating because the obvious explanation predicts the
      opposite. If the saving were the deparse-and-replan of the view
      definition &mdash; a fixed cost paid once per refresh &mdash; it would
      dominate a one-row refresh and vanish by ten thousand. It does not:
      percent gain against scope correlates <code>r&nbsp;=&nbsp;{r_scope}</code>,
      effectively flat, while absolute milliseconds saved tracks total refresh
      cost at <code>r&nbsp;=&nbsp;{r_total}</code>. The saving is proportional
      to the work, not constant.{dropped_note}</p>
    {chart3}
  </section>

  <section class="panel">
    <h2>All measurements</h2>
    <p class="read">Sorted by gain. Every value in the charts is here, so
      nothing is reachable only by hovering.</p>
    <div class="tablewrap">{table}</div>
  </section>

  <section class="caveats">
    <h2>What this does not say</h2>
    <ul>
      <li>Why the saving is proportional is not established here. The
        measurement rules out the fixed-cost explanation; it does not identify
        the replacement. Candidates worth an <code>EXPLAIN</code> before
        anyone claims one: the source rows arrive through a registered
        tuplestore rather than a materialised CTE, and the two are costed and
        scanned differently.</li>
      <li>Single client, disjoint scopes, no base-table mutation. Concurrency
        and contention are a separate sweep and are not in these numbers.</li>
      <li>pgbench commits once per refresh. A refresh inside a larger
        transaction is a different workload and measures differently by an
        order of magnitude.</li>
      <li>This is half of the rewrite. The write side still builds SQL text on
        both paths, so a later run against the same labels is the comparison
        that matters.</li>
      <li>Whether a partial refresh beats a full rebuild at all is a different
        question with a different normalisation, and is not what any chart
        here shows.</li>
    </ul>
  </section>
</div>

<div id="tip" role="status"></div>
<script>
  const tip = document.getElementById('tip');
  for (const el of document.querySelectorAll('[data-tip]')) {{
    el.addEventListener('pointerenter', e => {{
      tip.textContent = el.dataset.tip;
      tip.style.opacity = '1';
    }});
    el.addEventListener('pointermove', e => {{
      const r = tip.getBoundingClientRect();
      let x = e.clientX + 14, y = e.clientY + 16;
      if (x + r.width > innerWidth - 8) x = e.clientX - r.width - 14;
      if (y + r.height > innerHeight - 8) y = e.clientY - r.height - 14;
      tip.style.left = x + 'px';
      tip.style.top = y + 'px';
    }});
    el.addEventListener('pointerleave', () => {{ tip.style.opacity = '0'; }});
  }}
</script>
"""


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    label, out = sys.argv[1], sys.argv[2]
    argv = sys.argv[3:]
    port = argv[argv.index('--port') + 1] if '--port' in argv else '5610'
    db = argv[argv.index('--db') + 1] if '--db' in argv else 'postgres'

    rows = fetch(label, port, db)
    if not rows:
        sys.exit(f'no spi/querytree pairs in bench_result for {label!r}')
    with open(out, 'w') as f:
        f.write(build(rows, label))
    print(f'{out}: {len(rows)} combinations, '
          f'{len({r["workload"] for r in rows})} workloads')


if __name__ == '__main__':
    main()

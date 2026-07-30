#!/usr/bin/env python3
"""Render a bench_result run as a standalone HTML page.

    ./chart.py <run_label> <out.html> [--port 5610] [--db postgres]

Reads the run straight out of bench_result rather than from a pasted table, so
the page cannot drift from the measurement.  Run verify.sql against the same
label first -- this refuses a run with unnormalisable rows, but it checks far
less than verify.sql does.

Everything is inline: no scripts, styles or fonts are fetched.

The metric throughout is vs_full_per_row: the refresh's cost per row it
selected, over a full rebuild's cost per row of the whole matview.  Raw
milliseconds are not comparable between a one-row refresh and a twenty-thousand
row one; this is.  1.0 means the two cost the same per row.

Colours are the data-viz reference palette, validated in both modes.  The
dumbbell uses the emphasis pairing -- neutral for the implementation that
exists, accent for the one being proposed -- so do not swap in a second
categorical hue without re-running the validator.
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
         round(a.latency_ms,3) AS spi_ms, round(b.latency_ms,3) AS qt_ms,
         a.txns AS spi_txns, b.txns AS qt_txns,
         round(a.full_ms,1) AS full_ms,
         round(a.vs_full_per_row,3) AS spi_norm,
         round(b.vs_full_per_row,3) AS qt_norm,
         round(100*(a.latency_ms-b.latency_ms)/a.latency_ms,2) AS pct
    FROM bench_result a
    JOIN bench_result b USING (run_label, workload, predshape, span,
                               clients, overlap)
   WHERE a.run_label = %s AND a.form = 'spi' AND b.form = 'querytree') t
"""


def fetch(label, port, db):
    # One line: this goes through `su -c`, so the shell sees the whole psql
    # invocation as a single word and would pass embedded newlines through as
    # a literal backslash-n.
    sql = ' '.join(QUERY.replace('%s', "'" + label.replace("'", "''") + "'")
                   .split())
    cmd = f'{BINDIR}/psql -p {port} -d {db} -X -Atc {shlex.quote(sql)}'
    out = subprocess.run(['su', 'pgtest', '-c', cmd],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout.strip()) if out.stdout.strip() else []


# ---------------------------------------------------------------- geometry --

def logscale(v, lo, hi, px0, px1):
    v = min(max(v, lo), hi)
    t = (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo))
    return px0 + t * (px1 - px0)


def log_ticks(lo, hi, px0, px1, minpx=44):
    """A 1/2/5 ladder, thinned so labels cannot overprint each other."""
    out, last, e = [], None, math.floor(math.log10(lo))
    while 10 ** e <= hi * 1.001:
        for m in (1, 2, 5):
            v = m * 10 ** e
            if not lo * 0.999 <= v <= hi * 1.001:
                continue
            x = logscale(v, lo, hi, px0, px1)
            if last is None or abs(x - last) >= minpx:
                out.append(v)
                last = x
        e += 1
    return out


def fmt(v):
    return f'{v:,.0f}' if v >= 1000 else f'{v:g}'


def esc(s):
    return (str(s).replace('&', '&amp;').replace('<', '&lt;')
            .replace('>', '&gt;').replace('"', '&quot;'))


def label_of(r):
    return f"{r['workload']} · {r['predshape']} span {r['span']}"


# A normalised cost this far above 1 cannot share a log axis with values near
# 1 without compressing them into a few pixels.  Splitting is stated on the
# page, with the separated values printed in full -- an outlier that is quietly
# dropped and an outlier that is quietly rescaled are both lies about the data.
OUTLIER = 1000


def split_outliers(rows):
    by_wl = {}
    for r in rows:
        by_wl.setdefault(r['workload'], []).append(r)
    main, aside = [], []
    for rs in by_wl.values():
        lo = min(min(r['spi_norm'], r['qt_norm']) for r in rs)
        (aside if lo > OUTLIER else main).extend(rs)
    return main, aside


# ------------------------------------------------------------------ charts --

def chart_dumbbell(rows):
    """One row per combination: where it sits, and which way the change moved.

    Before-and-after per item on a log scale, which is what a dumbbell is for.
    A bar cannot do this job -- bar length has to be proportional from zero,
    and these values cover four decades.
    """
    items = sorted(rows, key=lambda r: (r['workload'], -r['spi_norm']))
    vals = [v for r in rows for v in (r['spi_norm'], r['qt_norm'])]
    lo, hi = min(vals) / 1.5, max(vals) * 1.5

    W, rowh, top, left, right = 760, 22, 24, 190, 24
    H = top + rowh * len(items) + 48
    x0, x1 = left, W - right

    p = [f'<svg viewBox="0 0 {W} {H}" role="img" class="chart" '
         f'aria-label="Normalised cost per combination, before and after">']
    for t in log_ticks(lo, hi, x0, x1):
        gx = logscale(t, lo, hi, x0, x1)
        p.append(f'<line class="grid" x1="{gx:.1f}" y1="{top - 10}" '
                 f'x2="{gx:.1f}" y2="{top + rowh * len(items) - 4}"/>')
        p.append(f'<text class="tick" x="{gx:.1f}" '
                 f'y="{top + rowh * len(items) + 14}" '
                 f'text-anchor="middle">{fmt(t)}&times;</text>')

    seen = set()
    for i, r in enumerate(items):
        y = top + i * rowh + rowh / 2 - 3
        if r['workload'] not in seen:
            seen.add(r['workload'])
            p.append(f'<text class="cat strong" x="8" y="{y + 4:.1f}">'
                     f'{esc(r["workload"])}</text>')
        p.append(f'<text class="shape" x="{left - 10}" y="{y + 4:.1f}" '
                 f'text-anchor="end">{esc(r["predshape"])} '
                 f'{r["span"]}</text>')
        sx = logscale(r['spi_norm'], lo, hi, x0, x1)
        qx = logscale(r['qt_norm'], lo, hi, x0, x1)
        p.append(f'<line class="link" x1="{sx:.1f}" y1="{y:.1f}" '
                 f'x2="{qx:.1f}" y2="{y:.1f}"/>')
        p.append(f'<circle class="dot-before" cx="{sx:.1f}" cy="{y:.1f}" '
                 f'r="4.5"/>')
        p.append(f'<circle class="dot-after" cx="{qx:.1f}" cy="{y:.1f}" '
                 f'r="4.5"/>')
        tip = (f"{label_of(r)} · {r['scope_rows']:,} rows in scope · "
               f"spi {r['spi_norm']:,.1f}× → querytree {r['qt_norm']:,.1f}× "
               f"a full rebuild's per-row cost · {r['pct']:+.1f}%")
        p.append(f'<rect class="hit" x="{x0 - 40}" y="{y - rowh / 2:.1f}" '
                 f'width="{x1 - x0 + 40}" height="{rowh}" '
                 f'data-tip="{esc(tip)}"/>')

    p.append(f'<text class="axlabel" x="{(x0 + x1) / 2:.0f}" y="{H - 8}" '
             f'text-anchor="middle">cost per row selected, as a multiple of a '
             f'full rebuild&#8217;s cost per row (log)</text>')
    p.append('</svg>')
    return '\n'.join(p)


def chart_cost_curve(rows):
    """Normalised cost against scope: the shape of the cost model."""
    xs = [r['scope_rows'] for r in rows]
    ys = [v for r in rows for v in (r['spi_norm'], r['qt_norm'])]
    xlo, xhi = min(xs) / 1.7, max(xs) * 1.7
    ylo, yhi = min(ys) / 1.7, max(ys) * 1.7

    W, H, pad_l, pad_b, pad_t, pad_r = 760, 400, 68, 54, 20, 20
    x0, x1 = pad_l, W - pad_r
    y0, y1 = H - pad_b, pad_t

    p = [f'<svg viewBox="0 0 {W} {H}" role="img" class="chart" '
         f'aria-label="Normalised cost against scope">']
    for t in log_ticks(xlo, xhi, x0, x1):
        gx = logscale(t, xlo, xhi, x0, x1)
        p.append(f'<line class="grid" x1="{gx:.1f}" y1="{y1}" x2="{gx:.1f}" '
                 f'y2="{y0}"/>')
        p.append(f'<text class="tick" x="{gx:.1f}" y="{y0 + 18}" '
                 f'text-anchor="middle">{fmt(t)}</text>')
    for t in log_ticks(ylo, yhi, y0, y1, 34):
        gy = logscale(t, ylo, yhi, y0, y1)
        p.append(f'<line class="grid" x1="{x0}" y1="{gy:.1f}" x2="{x1}" '
                 f'y2="{gy:.1f}"/>')
        p.append(f'<text class="tick" x="{x0 - 8}" y="{gy + 4:.1f}" '
                 f'text-anchor="end">{fmt(t)}&times;</text>')

    for r in rows:
        cx = logscale(r['scope_rows'], xlo, xhi, x0, x1)
        for key, cls, name in (('spi_norm', 'dot-before', 'spi'),
                               ('qt_norm', 'dot-after', 'querytree')):
            cy = logscale(r[key], ylo, yhi, y0, y1)
            tip = (f"{label_of(r)} · {r['scope_rows']:,} rows · "
                   f"{name} {r[key]:,.1f}×")
            p.append(f'<circle class="{cls}" cx="{cx:.1f}" cy="{cy:.1f}" '
                     f'r="4"/>')
            p.append(f'<circle class="hit" cx="{cx:.1f}" cy="{cy:.1f}" '
                     f'r="12" data-tip="{esc(tip)}"/>')

    p.append(f'<line class="axis" x1="{x0}" y1="{y0}" x2="{x1}" y2="{y0}"/>')
    p.append(f'<line class="axis" x1="{x0}" y1="{y0}" x2="{x0}" y2="{y1}"/>')
    p.append(f'<text class="axlabel" x="{(x0 + x1) / 2:.0f}" y="{H - 8}" '
             f'text-anchor="middle">matview rows the predicate selects '
             f'(log)</text>')
    p.append(f'<text class="axlabel" transform="translate(15,'
             f'{(y0 + y1) / 2:.0f}) rotate(-90)" text-anchor="middle">'
             f'cost per row vs a full rebuild (log)</text>')
    p.append('</svg>')
    return '\n'.join(p)


def chart_by_workload(rows):
    """Mean percent the Query-tree path saves, per workload.  One hue."""
    agg = {}
    for r in rows:
        agg.setdefault(r['workload'], []).append(r['pct'])
    items = sorted(((w, sum(v) / len(v), len(v), min(v), max(v))
                    for w, v in agg.items()), key=lambda x: -x[1])

    W, rowh, top, left, right = 760, 34, 14, 116, 64
    H = top + rowh * len(items) + 32
    xmax = max(6.0, max(i[1] for i in items) * 1.2)
    x0, x1 = left, W - right

    p = [f'<svg viewBox="0 0 {W} {H}" role="img" class="chart" '
         f'aria-label="Mean percent saved by workload">']
    for gv in range(0, int(xmax) + 1, 5):
        gx = x0 + gv / xmax * (x1 - x0)
        p.append(f'<line class="grid" x1="{gx:.1f}" y1="{top - 6}" '
                 f'x2="{gx:.1f}" y2="{top + rowh * len(items) - 8}"/>')
        p.append(f'<text class="tick" x="{gx:.1f}" '
                 f'y="{top + rowh * len(items) + 12}" '
                 f'text-anchor="middle">{gv}%</text>')
    for i, (w, mean, cnt, lo, hi) in enumerate(items):
        y = top + i * rowh
        bw = max(2.0, mean / xmax * (x1 - x0))
        p.append(f'<text class="cat" x="{left - 12}" y="{y + 15}" '
                 f'text-anchor="end">{esc(w)}</text>')
        p.append(f'<rect class="bar" x="{x0}" y="{y + 3}" width="{bw:.1f}" '
                 f'height="15" rx="4"/>')
        p.append(f'<rect class="bar" x="{x0}" y="{y + 3}" '
                 f'width="{min(4.0, bw):.1f}" height="15"/>')
        p.append(f'<text class="val" x="{x0 + bw + 8:.1f}" y="{y + 11}">'
                 f'{mean:.1f}%</text>')
        p.append(f'<rect class="hit" x="{x0}" y="{y}" width="{x1 - x0}" '
                 f'height="{rowh - 4}" data-tip="{esc(w)} · mean {mean:.1f}% '
                 f'· range {lo:.1f}% to {hi:.1f}% · {cnt} combinations"/>')
    p.append(f'<line class="axis" x1="{x0}" y1="{top - 6}" x2="{x0}" '
             f'y2="{top + rowh * len(items) - 8}"/>')
    p.append('</svg>')
    return '\n'.join(p)


# -------------------------------------------------------------------- page --

def corr(a, b):
    n = len(a)
    ma, mb = sum(a) / n, sum(b) / n
    num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    den = (sum((x - ma) ** 2 for x in a) * sum((y - mb) ** 2 for y in b)) ** .5
    return num / den if den else 0.0


def render_aside(aside):
    """Whatever could not share the axis, printed rather than hidden."""
    if not aside:
        return ''
    wl = sorted({r['workload'] for r in aside})
    lo = min(min(r['spi_norm'], r['qt_norm']) for r in aside)
    hi = max(max(r['spi_norm'], r['qt_norm']) for r in aside)
    ms = sorted(r['spi_ms'] for r in aside)
    rows_html = ''.join(
        f"<tr><td class=\"mono\">{esc(r['workload'])}</td>"
        f"<td class=\"mono\">{esc(r['predshape'])} {r['span']}</td>"
        f"<td class=\"n\">{r['scope_rows']:,}</td>"
        f"<td class=\"n\">{r['spi_norm']:,.0f}&times;</td>"
        f"<td class=\"n\">{r['qt_norm']:,.0f}&times;</td>"
        f"<td class=\"n\">{r['spi_ms']:,.0f}</td>"
        f"<td class=\"n\">{r['qt_ms']:,.0f}</td></tr>"
        for r in sorted(aside, key=lambda r: (r['predshape'], r['span'])))
    return f"""
  <section class="panel">
    <h2>{esc(', '.join(wl))}, which is off the scale above and stays off it</h2>
    <p class="read">Between {lo:,.0f}&times; and {hi:,.0f}&times; a full
      rebuild&rsquo;s per-row cost &mdash; more than three decades above
      everything else, which is why it is printed here instead of compressing
      the chart above into a few pixels. The predicate cannot push into the
      recursive term, so every partial refresh evaluates the whole closure and
      then filters it. That makes the latency a constant: {min(ms):,.0f} to
      {max(ms):,.0f} ms whether the predicate selects one row or twenty-nine.
      Swept at three combinations rather than seven for that reason &mdash;
      the other four would re-measure the same number. It becomes worth
      sweeping properly if push-down into the recursive term is ever
      implemented.</p>
    <div class="tablewrap"><table><thead><tr>
      <th>workload</th><th>shape / span</th><th class="n">scope rows</th>
      <th class="n">spi &times;full</th><th class="n">querytree &times;full</th>
      <th class="n">spi ms</th><th class="n">querytree ms</th>
    </tr></thead><tbody>{rows_html}</tbody></table></div>
  </section>"""


def build(rows, label):
    pcts = sorted(r['pct'] for r in rows)
    n = len(rows)
    med = pcts[n // 2] if n % 2 else (pcts[n // 2 - 1] + pcts[n // 2]) / 2
    wins = sum(1 for p in pcts if p > 0)
    r_scope = corr([math.log10(max(r['scope_rows'], 1)) for r in rows],
                   [r['pct'] for r in rows])
    r_total = corr([r['spi_ms'] for r in rows],
                   [r['spi_ms'] - r['qt_ms'] for r in rows])
    main, aside = split_outliers(rows)
    aside_html = render_aside(aside)
    norms = [r['spi_norm'] for r in main]
    pays = sum(1 for r in rows if r['spi_ms'] < r['full_ms'])
    meta = rows[0]
    min_txns = min(min(r['spi_txns'] or 0, r['qt_txns'] or 0) for r in rows)

    table = ['<table><thead><tr>'
             '<th>workload</th><th>shape</th><th class="n">span</th>'
             '<th class="n">scope rows</th><th class="n">spi &times;full</th>'
             '<th class="n">querytree &times;full</th>'
             '<th class="n">spi ms</th><th class="n">querytree ms</th>'
             '<th class="n">saved</th><th class="n">refreshes</th>'
             '</tr></thead><tbody>']
    for r in sorted(rows, key=lambda r: -r['pct']):
        cls = ' class="neg"' if r['pct'] < 0 else ''
        table.append(
            f"<tr><td class=\"mono\">{esc(r['workload'])}</td>"
            f"<td class=\"mono\">{esc(r['predshape'])}</td>"
            f"<td class=\"n\">{r['span']}</td>"
            f"<td class=\"n\">{r['scope_rows']:,}</td>"
            f"<td class=\"n\">{r['spi_norm']:,.1f}</td>"
            f"<td class=\"n\">{r['qt_norm']:,.1f}</td>"
            f"<td class=\"n\">{r['spi_ms']:.2f}</td>"
            f"<td class=\"n\">{r['qt_ms']:.2f}</td>"
            f"<td class=\"n\"{cls}>{r['pct']:+.1f}%</td>"
            f"<td class=\"n\">{min(r['spi_txns'] or 0, r['qt_txns'] or 0):,}"
            f"</td></tr>")
    table.append('</tbody></table>')

    return TEMPLATE.format(
        label=esc(label), n=n, wins=wins, med=f'{med:.1f}',
        norm_lo=f'{min(norms):,.1f}', norm_hi=f'{max(norms):,.0f}',
        pays=pays, min_txns=f'{min_txns:,}',
        workloads=len({r['workload'] for r in rows}),
        version=esc(meta['pg_version'].split(' on ')[0]),
        assertions=esc(meta['assertions']),
        sync=esc(meta['sync']), clients=meta['clients'],
        r_scope=f'{r_scope:+.2f}', r_total=f'{r_total:+.2f}',
        chart_db=chart_dumbbell(main),
        chart_curve=chart_cost_curve(main),
        chart_wl=chart_by_workload(rows),
        aside=aside_html,
        norm_hi_main=f'{max(r["spi_norm"] for r in main):,.0f}',
        table=''.join(table))


TEMPLATE = """<title>Partial refresh: Query tree vs generated SQL</title>
<style>
  :root {{
    color-scheme: light;
    --plane: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e;
    --muted: #898781; --rule: #e1e0d9; --axis: #c3c2b7;
    --series: #2a78d6; --before: #898781; --neg: #d03b3b;
    --hair: rgba(11,11,11,0.10);
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) {{
      color-scheme: dark;
      --plane: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7;
      --muted: #898781; --rule: #2c2c2a; --axis: #383835;
      --series: #3987e5; --before: #898781; --neg: #d03b3b;
      --hair: rgba(255,255,255,0.10);
    }}
  }}
  :root[data-theme="dark"] {{
    color-scheme: dark;
    --plane: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7;
    --muted: #898781; --rule: #2c2c2a; --axis: #383835;
    --series: #3987e5; --before: #898781; --neg: #d03b3b;
    --hair: rgba(255,255,255,0.10);
  }}

  body {{
    background: var(--plane); color: var(--ink);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    line-height: 1.55; margin: 0; padding: 40px 20px 72px;
    -webkit-font-smoothing: antialiased;
  }}
  .wrap {{ max-width: 1020px; margin: 0 auto; display: flex;
           flex-direction: column; gap: 26px; }}
  .mono, code {{ font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo,
                 Consolas, monospace; }}

  header {{ display: flex; flex-direction: column; gap: 10px; }}
  .eyebrow {{ font-size: 11px; letter-spacing: .13em; text-transform: uppercase;
              color: var(--muted); font-family: ui-monospace, SFMono-Regular,
              Menlo, monospace; }}
  h1 {{ font-size: clamp(24px, 4vw, 32px); line-height: 1.2; margin: 0;
        font-weight: 620; letter-spacing: -.015em; text-wrap: balance; }}
  .lede {{ color: var(--ink-2); max-width: 64ch; margin: 0; }}
  .provenance {{ display: flex; flex-wrap: wrap; gap: 6px 18px; font-size: 12px;
                 color: var(--muted); padding-top: 6px;
                 border-top: 1px solid var(--rule);
                 font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}

  .kpis {{ display: grid; gap: 12px;
           grid-template-columns: repeat(auto-fit, minmax(165px, 1fr)); }}
  .kpi {{ background: var(--surface); border: 1px solid var(--hair);
          border-radius: 3px; padding: 14px 16px 13px; }}
  .kpi .v {{ font-size: 30px; font-weight: 600; letter-spacing: -.02em;
             line-height: 1.05; }}
  .kpi .v.accent {{ color: var(--series); }}
  .kpi .v.sm {{ font-size: 21px; white-space: nowrap; }}
  .kpi .k {{ font-size: 11px; color: var(--muted); margin-top: 5px;
             letter-spacing: .04em; }}

  .panel {{ background: var(--surface); border: 1px solid var(--hair);
            border-radius: 3px; padding: 20px 22px 18px; }}
  .panel h2 {{ font-size: 15px; margin: 0 0 2px; font-weight: 600; }}
  .panel p.read {{ font-size: 13px; color: var(--ink-2); margin: 0 0 16px;
                   max-width: 70ch; }}
  .chart {{ width: 100%; height: auto; display: block; overflow: visible; }}

  .grid {{ stroke: var(--rule); stroke-width: 1; }}
  .axis {{ stroke: var(--axis); stroke-width: 1; }}
  .link {{ stroke: var(--axis); stroke-width: 2; }}
  .bar {{ fill: var(--series); }}
  .dot-before {{ fill: var(--before); stroke: var(--surface); stroke-width: 2; }}
  .dot-after {{ fill: var(--series); stroke: var(--surface); stroke-width: 2; }}
  .hit {{ fill: transparent; cursor: crosshair; }}
  text {{ font-family: system-ui, -apple-system, sans-serif; }}
  .tick {{ font-size: 10.5px; fill: var(--muted);
           font-variant-numeric: tabular-nums; }}
  .cat {{ font-size: 12px; fill: var(--ink-2);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
  .cat.strong {{ fill: var(--ink); font-weight: 600; }}
  .shape {{ font-size: 10.5px; fill: var(--muted);
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
  .val {{ font-size: 12px; fill: var(--ink); font-weight: 600;
          font-variant-numeric: tabular-nums; dominant-baseline: middle; }}
  .axlabel {{ font-size: 12px; fill: var(--ink-2); }}

  .legend {{ display: flex; gap: 20px; font-size: 12px; color: var(--ink-2);
             margin-top: 14px; flex-wrap: wrap; }}
  .legend span {{ display: inline-flex; align-items: center; gap: 7px; }}
  .sw {{ width: 10px; height: 10px; border-radius: 50%;
         background: var(--series); flex: none; }}
  .sw.before {{ background: var(--before); }}

  .tablewrap {{ overflow-x: auto; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 12.5px;
           font-variant-numeric: tabular-nums; }}
  th, td {{ text-align: left; padding: 5px 12px 5px 0;
            border-bottom: 1px solid var(--rule); white-space: nowrap; }}
  th {{ font-size: 10.5px; letter-spacing: .05em; color: var(--muted);
        font-weight: 500; text-transform: uppercase; }}
  td.n, th.n {{ text-align: right; }}
  td.neg {{ color: var(--neg); }}
  td.mono {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}

  .caveats {{ font-size: 13px; color: var(--ink-2); }}
  .caveats h2 {{ font-size: 13px; text-transform: uppercase;
                 letter-spacing: .09em; color: var(--muted); margin: 0 0 10px;
                 font-weight: 600; }}
  .caveats ul {{ margin: 0; padding-left: 18px; display: flex;
                 flex-direction: column; gap: 8px; max-width: 78ch; }}

  #tip {{ position: fixed; pointer-events: none; opacity: 0;
          transition: opacity .09s; background: var(--ink); color: var(--plane);
          font-size: 12px; padding: 6px 9px; border-radius: 3px;
          max-width: 320px; z-index: 9; line-height: 1.4; }}
  @media (prefers-reduced-motion: reduce) {{ #tip {{ transition: none; }} }}
  :focus-visible {{ outline: 2px solid var(--series); outline-offset: 2px; }}
</style>

<div class="wrap">
  <header>
    <div class="eyebrow">REFRESH MATERIALIZED VIEW &hellip; WHERE &hellip;
      &nbsp;/&nbsp; run {label}</div>
    <h1>What a partial refresh costs, and what evaluating the view from its
      Query tree changes about it</h1>
    <p class="lede">Every value is a refresh&rsquo;s cost per row it selected,
      over a full rebuild&rsquo;s cost per row of the whole matview.
      Milliseconds are not comparable between a one-row refresh and a
      ten-thousand-row one; this is. <strong>1&times; means the two cost the
      same per row.</strong> Both implementations are compiled into one binary
      and chosen at run time, so nothing here is a difference between builds.</p>
    <div class="provenance">
      <span>{version}</span><span>assertions {assertions}</span>
      <span>synchronous_commit {sync}</span><span>{clients} client</span>
      <span>{workloads} workloads &middot; {n} combinations</span>
      <span>&ge;{min_txns} refreshes per measurement</span>
    </div>
  </header>

  <div class="kpis">
    <div class="kpi"><div class="v sm">{norm_lo}&times; &ndash;
      {norm_hi}&times;</div>
      <div class="k">per-row cost, excluding recursive</div></div>
    <div class="kpi"><div class="v">{pays}<span
      style="color:var(--muted);font-size:19px"> / {n}</span></div>
      <div class="k">faster than a full rebuild outright</div></div>
    <div class="kpi"><div class="v accent">+{med}%</div>
      <div class="k">median saved by the Query tree</div></div>
    <div class="kpi"><div class="v">{wins}<span
      style="color:var(--muted);font-size:19px"> / {n}</span></div>
      <div class="k">combinations improved</div></div>
  </div>

  <section class="panel">
    <h2>Every combination, and which way the change moved it</h2>
    <p class="read">Each row is one combination; the two ends are the two
      implementations. Everything sits above 1&times;, so a partial refresh
      never costs less <em>per row</em> than a rebuild does &mdash; what it
      saves is the rows it never touches. Whether it pays is this cost times
      the rows selected, against the size of the matview.</p>
    {chart_db}
    <div class="legend">
      <span><i class="sw before"></i>spi &mdash; the view deparsed to SQL
        text</span>
      <span><i class="sw"></i>querytree &mdash; the view evaluated from its
        Query tree</span>
    </div>
  </section>

  <section class="panel">
    <h2>The cost model</h2>
    <p class="read">The same values against how many rows the predicate
      selected. Per-row cost falls steeply as the scope widens: a refresh has a
      fixed part, and a wider scope spreads it over more rows. The two
      implementations track each other throughout &mdash; the change moves the
      curve down, it does not change its shape.</p>
    {chart_curve}
    <div class="legend">
      <span><i class="sw before"></i>spi</span>
      <span><i class="sw"></i>querytree</span>
    </div>
  </section>

  {aside}

  <section class="panel">
    <h2>What the Query tree saves, by workload</h2>
    <p class="read">Mean across each workload&rsquo;s predicate shapes and
      scopes. This is the one quantity that is already a ratio between the two
      implementations, so it needs no normalising.</p>
    {chart_wl}
  </section>

  <section class="panel">
    <h2>All measurements</h2>
    <p class="read">Sorted by what the Query tree saved. Every value in every
      chart is here, including how many refreshes each measurement averaged
      over.</p>
    <div class="tablewrap">{table}</div>
  </section>

  <section class="caveats">
    <h2>What this does not say</h2>
    <ul>
      <li>The saving is not a fixed cost being amortised away, which is the
        obvious explanation and the first one to reach for. That predicts a
        gain dominating a one-row refresh and vanishing by ten thousand.
        Percent saved against scope correlates
        <code>r&nbsp;=&nbsp;{r_scope}</code> while milliseconds saved tracks
        total refresh cost at <code>r&nbsp;=&nbsp;{r_total}</code>: the saving
        is proportional to the work. What produces it is not established
        here.</li>
      <li>Single client, disjoint scopes, base data not mutated between
        refreshes. Contention is a separate sweep.</li>
      <li>pgbench commits once per refresh. The same refresh inside a larger
        transaction measures differently by an order of magnitude.</li>
      <li>Both implementations still build the write side as SQL text. This is
        half the rewrite; the run worth comparing against is the one after the
        other half.</li>
      <li>Baselines are re-measured per run, so normalised values are
        comparable within a run and only roughly between runs. The ratio
        between the two implementations is unaffected either way.</li>
    </ul>
  </section>
</div>

<div id="tip" role="status"></div>
<script>
  const tip = document.getElementById('tip');
  for (const el of document.querySelectorAll('[data-tip]')) {{
    el.addEventListener('pointerenter', () => {{
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
    bad = [r for r in rows if r['spi_norm'] is None or r['qt_norm'] is None
           or r['scope_rows'] is None]
    if bad:
        sys.exit(f'{len(bad)} of {len(rows)} combinations have no normalised '
                 f'cost.  Run verify.sql and fix the run before charting it:\n'
                 + '\n'.join('  ' + label_of(r) for r in bad[:8]))
    with open(out, 'w') as f:
        f.write(build(rows, label))
    print(f'{out}: {len(rows)} combinations, '
          f'{len({r["workload"] for r in rows})} workloads')


if __name__ == '__main__':
    main()

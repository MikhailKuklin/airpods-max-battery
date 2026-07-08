#!/usr/bin/env python3
"""AirPods Max battery report — reads battery_log.csv and shows the discharge
curve plus the measured 'how long does a full charge last' figure.

Pure stdlib, no dependencies. Run:  python3 report.py
"""
import csv, os, sys
from datetime import datetime, timezone

LOG = os.path.expanduser("~/airpods-max-battery/battery_log.csv")


def load():
    if not os.path.exists(LOG):
        sys.exit("No log yet at %s — let the app run while you use the headphones." % LOG)
    rows = []
    with open(LOG) as f:
        for r in csv.DictReader(f):
            rows.append((int(r["epoch"]), int(r["percent"])))
    rows.sort()
    return rows


def segments(rows):
    """Split into discharge runs, breaking whenever % jumps up (a charge)."""
    segs, cur = [], []
    for epoch, pct in rows:
        if cur and pct > cur[-1][1] + 2:      # charged since last sample
            if len(cur) >= 2:
                segs.append(cur)
            cur = []
        cur.append((epoch, pct))
    if len(cur) >= 2:
        segs.append(cur)
    return segs


def slope_pct_per_hr(seg):
    """Least-squares %/hour drain over a discharge run (positive = draining)."""
    t0 = seg[0][0]
    xs = [(e - t0) / 3600 for e, _ in seg]
    ys = [p for _, p in seg]
    n = len(xs)
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys))
    denom = n * sxx - sx * sx
    if denom == 0:
        return None
    slope = (n * sxy - sx * sy) / denom
    return -slope if slope < 0 else None


def sparkline(seg, width=60):
    """ASCII discharge curve: % (y) over the run's elapsed time (x)."""
    blocks = "▁▂▃▄▅▆▇█"
    t0, t1 = seg[0][0], seg[-1][0]
    span = max(t1 - t0, 1)
    # bucket into `width` columns, take last pct in each
    cols = [None] * width
    for e, p in seg:
        i = min(width - 1, int((e - t0) / span * (width - 1)))
        cols[i] = p
    # forward-fill
    last = seg[0][1]
    for i in range(width):
        if cols[i] is None:
            cols[i] = last
        else:
            last = cols[i]
    line = "".join(blocks[min(7, max(0, p * 8 // 101))] for p in cols)
    return line


def fmt_h(h):
    hh = int(h); mm = int((h - hh) * 60)
    return f"{hh}h {mm:02d}m"


def main():
    rows = load()
    segs = segments(rows)
    print(f"\n  AirPods Max battery report  ({len(rows)} samples, "
          f"{len(segs)} discharge run(s))\n")

    if not segs:
        print("  Not enough discharge history yet — keep using the headphones.\n")
        return

    rates = []
    for i, seg in enumerate(segs, 1):
        r = slope_pct_per_hr(seg)
        dur = (seg[-1][0] - seg[0][0]) / 3600
        drop = seg[0][1] - seg[-1][1]
        t = lambda e: datetime.fromtimestamp(e, tz=timezone.utc).astimezone().strftime("%b %d %H:%M")
        print(f"  Run {i}: {seg[0][1]:>3d}% → {seg[-1][1]:>3d}%   "
              f"{t(seg[0][0])} … {t(seg[-1][0])}  ({fmt_h(dur)})")
        print(f"         {sparkline(seg)}")
        if r:
            rates.append(r)
            print(f"         drain {r:5.1f}%/hr  →  full charge lasts ~{fmt_h(100/r)}\n")
        else:
            print()

    if rates:
        avg = sum(rates) / len(rates)
        best = min(rates)   # slowest drain = longest life
        print("  ── Summary ──────────────────────────────────────────")
        print(f"  Avg drain across runs : {avg:5.1f}%/hr")
        print(f"  Est. full-charge life : ~{fmt_h(100/avg)}  "
              f"(best run: {fmt_h(100/best)})")
        cur = rows[-1][1]
        print(f"  Latest reading        : {cur}%  "
              f"(~{fmt_h(cur/avg)} left at avg drain)\n")


if __name__ == "__main__":
    main()

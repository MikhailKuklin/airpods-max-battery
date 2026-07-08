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


GAP_MINUTES = 15.0  # a gap bigger than this = headset put away → excluded


def active_drain(seg):
    """(%/hour of ACTUAL use, active_hours) over a discharge run, excluding idle
    gaps. Intervals longer than GAP_MINUTES (headset asleep / not broadcasting)
    contribute neither time nor drop, so the rate reflects real listening."""
    active_h, drop = 0.0, 0.0
    for (e0, p0), (e1, p1) in zip(seg, seg[1:]):
        if p1 > p0 + 2:            # charge blip inside the run
            continue
        dt = (e1 - e0) / 3600
        if dt <= 0 or dt > GAP_MINUTES / 60:   # idle gap → skip
            continue
        active_h += dt
        drop += (p0 - p1)
    if active_h <= 0 or drop <= 0:
        return None
    return drop / active_h, active_h


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
        res = active_drain(seg)
        elapsed = (seg[-1][0] - seg[0][0]) / 3600      # calendar span
        t = lambda e: datetime.fromtimestamp(e, tz=timezone.utc).astimezone().strftime("%b %d %H:%M")
        print(f"  Run {i}: {seg[0][1]:>3d}% → {seg[-1][1]:>3d}%   "
              f"{t(seg[0][0])} … {t(seg[-1][0])}  (elapsed {fmt_h(elapsed)})")
        print(f"         {sparkline(seg)}")
        if res:
            r, active_h = res
            rates.append(r)
            print(f"         {fmt_h(active_h)} of actual use, drain {r:5.1f}%/hr"
                  f"  →  full charge lasts ~{fmt_h(100/r)} of listening\n")
        else:
            print("         (not enough contiguous in-use data)\n")

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

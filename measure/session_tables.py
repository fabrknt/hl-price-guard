"""Re-print the docs/safe-limits.md tables for a measured session: normal gaps (max and p99, whole
session and one sub-window) and caps from depth10 p10 (whole session and the sub-window).

usage: python3 -I measure/session_tables.py NORMAL_GAPS.json SAFE_CAPS.json FROM TO
  FROM, TO: unix seconds of the sub-window, e.g. the opening hour of 2026-10-19:
  python3 -I measure/session_tables.py measure/normal-gaps-20261019.json \\
      measure/safe-caps-20261019.json 1792416600 1792420200
"""
import json, sys

K, CALIB = 3, 0.27  # docs/safe-limits.md section 4


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def money(x):
    return "under $0.01M" if x < 0.005e6 else f"${x / 1e6:.2f}M"


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    g, c = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
    lo, hi = float(sys.argv[3]), float(sys.argv[4])
    inside = lambda t: lo <= t < hi
    print(f"normal gaps: {len(g)} samples. In bp, max (p99)")
    print("| asset | mark–oracle | mid–oracle | spread | mid–oracle, sub-window |\n|---|---|---|---|---|")
    for a in [k for k in g[0] if k != "t"]:
        cells = []
        for m in ["markOracleBps", "midOracleBps", "spreadBps"]:
            v = [s[a][m] for s in g if a in s]
            cells.append(f"{max(v):.1f} ({pct(v, .99):.1f})")
        v = [s[a]["midOracleBps"] for s in g if a in s and inside(s["t"])]
        cells.append(f"{max(v):.1f} ({pct(v, .99):.1f})" if v else "-")
        print(f"| {a} | " + " | ".join(cells) + " |")
    print("\n| asset | depth10 p10 | cap per minute (k = 3) | in the sub-window |\n|---|---|---|---|")
    rows = []
    for a, xs in c.items():
        d = [min(x["bid"], x["ask"]) for x in xs]
        w = [min(x["bid"], x["ask"]) for x in xs if inside(x["t"])]
        rows.append((pct(d, .10), a, pct(w, .10) if w else None))
    for p10, a, w in sorted(rows, reverse=True):
        f = CALIB / K
        print(f"| {a} | {money(p10)} | {money(f * p10)} | {money(f * w) if w is not None else '-'} |")


if __name__ == "__main__":
    main()

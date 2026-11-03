"""Summarise round_trips.py output across many collector runs.

usage: python3 measure/round_trips_summary.py [--covered FILE.json] [--runs FILE.txt] FILE.jsonl [...]

The collector's raw feeds are kept for 4 days, its round trips for 30, so a summary over weeks has to
start from the round-trips.jsonl files. Candidates seen by two runs are counted once (coin, wallet, t0).
For each strict candidate it prints the predicted cost, the cash cost and their ratio (cost without
fees). When |cost| is many times the prediction, the price drift while the wallet held its position
moved more cash than the push did, and the round trip says little about impact.
"""
import collections, json, sys


def main():
    args, covered, runs = sys.argv[1:], None, None
    while args and args[0] in ("--covered", "--runs"):
        flag, path, args = args[0], args[1], args[2:]
        if flag == "--covered":
            covered = json.load(open(path))
        else:
            runs = [l for l in open(path).read().split() if l]
    if runs is not None:
        print(f"{len(runs)} runs")
    if covered is not None:
        print(f"{sum(b - a for a, b in covered) / 3600:.0f} hours collected")
    rows = {}
    for path in args:
        for line in open(path):
            r = json.loads(line)
            rows[(r["coin"], r["wallet"], round(r["t0"], 1))] = r
    rows = list(rows.values())
    strict = sorted((r for r in rows if not r["flags"]), key=lambda r: r["t0"])
    flags = collections.Counter(f for r in rows for f in r["flags"])
    print(f"{len(rows)} candidates, {len({r['wallet'] for r in rows})} wallets, {len(strict)} strict")
    print("flags:", ", ".join(f"{f} {n}" for f, n in flags.most_common()))
    print("coin         d_bps  push_usd   hold_s  predicted      cost    ratio")
    for r in strict:
        print(f"{r['coin']:12} {r['d_bps']:5.2f} {r['push_notional']:9,.0f} {r['hold_secs']:7.1f} "
              f"{r['predicted']:10.2f} {r['cost']:9.2f} {r['ratio']:8.2f}")
    for coin in sorted({r["coin"] for r in strict}):
        ratios = sorted(r["ratio"] for r in strict if r["coin"] == coin)
        print(f"{coin}: n={len(ratios)} ratios {', '.join(f'{x:.2f}' for x in ratios)}")
    big = [r for r in rows if r["push_notional"] >= 1_000_000 and r["d_bps"] >= 10]
    flags = collections.Counter(f for r in big for f in r["flags"])
    print(f"pushes of $1M+ and 10 bp+: {len(big)}, flags: " + ", ".join(f"{f} {n}" for f, n in flags.most_common()))


if __name__ == "__main__":
    main()

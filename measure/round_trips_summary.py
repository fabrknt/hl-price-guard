"""Summarise round_trips.py output across many collector runs.

usage: python3 measure/round_trips_summary.py FILE.jsonl [FILE.jsonl ...]

The collector's raw feeds are kept for 4 days, its round trips for 30, so a summary over weeks has to
start from the round-trips.jsonl files. Candidates seen by two runs are counted once (coin, wallet, t0).
For each strict candidate it prints the predicted cost, the cash cost and their ratio (cost without
fees). When |cost| is many times the prediction, the price drift while the wallet held its position
moved more cash than the push did, and the round trip says little about impact.
"""
import collections, json, sys


def main():
    rows = {}
    for path in sys.argv[1:]:
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


if __name__ == "__main__":
    main()

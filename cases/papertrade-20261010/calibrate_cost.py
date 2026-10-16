"""What each Papertrade round actually cost the attacker on HL, against what static book depth predicts.

    python3 -I calibrate_cost.py positions.json hl-fills.json ETH-L2.jsonl

ETH-L2.jsonl: HL's archived ETH book for 21:00-22:59 UTC, the decompressed concatenation of
s3://hyperliquid-archive/market_data/20261010/{21,22}/l2Book/ETH.lz4 (requester pays; a snapshot
about every 5 s, 20 levels a side, which reaches about 7.8 bp from the mid).

Predicted cost of a d bp round: depth per bp on the side being pushed (from the last snapshot
before the round opens, extrapolated linearly past 7.8 bp) * d * d / 10000.
Measured: fees minus closedPnl of the attacker's ETH fills from 60 s before the round opens to
60 s before the next one.
"""
import bisect, collections, datetime, json, sys

positions = [p for p in json.load(open(sys.argv[1])) if p["close"] and p["open"]["instrument"] == 1]
fills = [f for f in json.load(open(sys.argv[2])) if f["coin"] == "ETH"]
books = [json.loads(l)["raw"]["data"] for l in open(sys.argv[3])]
book_t = [b["time"] / 1000 for b in books]


def side_depth_per_bp(book, buying):
    bids, asks = book["levels"]
    mid = (float(bids[0]["px"]) + float(asks[0]["px"])) / 2
    levels = asks if buying else bids
    reach = abs(float(levels[-1]["px"]) / mid - 1) * 1e4
    return sum(float(l["px"]) * float(l["sz"]) for l in levels) / reach


rounds = collections.defaultdict(list)
for p in positions:
    rounds[p["close"]["t"] // 60].append(p)
keys = sorted(rounds)
pred_sum = meas_sum = 0
print("close  move(bp)  predicted  measured")
for i, m in enumerate(keys):
    ps = rounds[m]
    o0 = min(p["open"]["t"] for p in ps)
    nxt = min(p["open"]["t"] for p in rounds[keys[i + 1]]) if i + 1 < len(keys) else o0 + 600
    fs = [f for f in fills if o0 - 60 <= f["time"] / 1000 < nxt - 60]
    measured = sum(float(f["fee"]) - float(f["closedPnl"]) for f in fs)
    p0 = ps[0]
    d = abs(p0["close"]["exit"] / p0["open"]["entry"] - 1) * 1e4
    book = books[bisect.bisect_right(book_t, o0) - 1]
    predicted = side_depth_per_bp(book, p0["open"]["side"] == "long") * d * d / 1e4
    if d >= 5:
        pred_sum += predicted
        meas_sum += measured
    print(f"{datetime.datetime.fromtimestamp(m * 60, datetime.timezone.utc):%H:%M} {d:8.1f} {predicted:10,.0f} {measured:9,.0f}")
print(f"rounds moving 5 bp or more: predicted ${pred_sum:,.0f}, measured ${meas_sum:,.0f}, ratio {meas_sum / pred_sum:.2f}")

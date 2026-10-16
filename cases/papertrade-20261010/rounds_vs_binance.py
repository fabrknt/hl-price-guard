"""Per round: how far HL's BBO mid, HL's oracle and Binance moved between open and close.

    python3 -I rounds_vs_binance.py positions.json eth-oracle.json

Binance ETHUSDT 1 s closes come from the public klines API at run time.
All moves are signed so that positive is in the position's favour.
"""
import bisect, collections, datetime, json, sys, urllib.request

positions = [p for p in json.load(open(sys.argv[1])) if p["close"] and p["open"]["instrument"] == 1]
rows = json.load(open(sys.argv[2]))["rows"]
ts = [datetime.datetime.fromisoformat(r[0][:26]).replace(tzinfo=datetime.timezone.utc).timestamp() for r in rows]
px = [float(r[2]) for r in rows]


def oracle(t):
    return px[bisect.bisect_right(ts, t) - 1]


def binance(t0, t1):
    url = (f"https://api.binance.com/api/v3/klines?symbol=ETHUSDT&interval=1s"
           f"&startTime={t0 * 1000}&endTime={t1 * 1000}&limit=1000")
    return {int(k[0]) // 1000: float(k[4]) for k in json.load(urllib.request.urlopen(url, timeout=20))}


rounds = collections.defaultdict(list)
for p in positions:
    rounds[p["close"]["t"] // 60].append(p)
print("close  positions side   mid   oracle  binance  (bp)")
for minute, ps in sorted(rounds.items()):
    p = ps[0]
    o, c = p["open"], p["close"]
    s = 1 if o["side"] == "long" else -1
    b = binance(o["t"] - 2, c["t"] + 2)
    move = lambda a, z: s * (z / a - 1) * 1e4
    print(f"{datetime.datetime.fromtimestamp(minute * 60, datetime.timezone.utc):%H:%M} {len(ps):6}    {o['side']:5}"
          f" {move(o['entry'], c['exit']):6.1f} {move(oracle(o['t'] + 1), oracle(c['t'] + 1)):6.1f}"
          f" {move(b[o['t']], b[c['t']]):7.1f}")

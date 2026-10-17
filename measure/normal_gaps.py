"""Sample the normal gaps HLPriceGuard checks, straight from HyperEVM precompiles.

usage: python3 measure/normal_gaps.py MINUTES OUT.json

OUT.json is rewritten every minute, so a run cut short (network, Ctrl-C) keeps what it has.
All 15 precompile reads go in one JSON-RPC batch; after a failed sweep the wait doubles, up to 2 minutes.
"""
import json, os, sys, time, urllib.request

RPC = "https://rpc.hyperliquid.xyz/evm"
# name: (dex, index, szDecimals)
ASSETS = {"BTC": (0, 0, 5), "ETH": (0, 1, 4), "SOL": (0, 5, 2), "HYPE": (0, 159, 2), "xyz:TSLA": (1, 1, 3)}


PRECOMPILES = (("oracle", "0x0000000000000000000000000000000000000807"),
               ("mark", "0x0000000000000000000000000000000000000806"),
               ("bbo", "0x000000000000000000000000000000000000080e"))


def sample():
    """One JSON-RPC batch for all assets; an asset whose calls fail is left out of the row."""
    calls = []
    for name, (dex, i, _) in ASSETS.items():
        perp = dex * 10000 + i
        bbo = i if dex == 0 else 100000 + dex * 10000 + i
        for kind, addr in PRECOMPILES:
            calls.append((name, kind, addr, bbo if kind == "bbo" else perp))
    body = json.dumps([{"jsonrpc": "2.0", "id": n, "method": "eth_call",
                        "params": [{"to": addr, "data": "0x" + format(idx, "064x")}, "latest"]}
                       for n, (_, _, addr, idx) in enumerate(calls)]).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json"})
    res = {r["id"]: r.get("result") for r in json.load(urllib.request.urlopen(req, timeout=10))}
    got = {}
    for n, (name, kind, _, _) in enumerate(calls):
        out = (res.get(n) or "0x")[2:]
        got.setdefault(name, {})[kind] = [int(out[j:j + 64], 16) for j in range(0, len(out), 64)]
    row = {"t": time.time()}
    for name, g in got.items():
        try:
            (o,), (m,), (b, a) = g["oracle"], g["mark"], g["bbo"]
        except ValueError:
            continue
        mid = (a + b) / 2
        row[name] = {"oracle": o, "mark": m, "bid": b, "ask": a,
                     "markOracleBps": abs(m - o) / o * 1e4, "midOracleBps": abs(mid - o) / o * 1e4,
                     "spreadBps": (a - b) / b * 1e4}
    if len(row) == 1:
        raise RuntimeError("no asset returned a full set of prices")
    return row


def save(rows, out):
    json.dump(rows, open(out + ".tmp", "w"))
    os.replace(out + ".tmp", out)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    minutes, out = float(sys.argv[1]), sys.argv[2]
    rows, end = [], time.time() + minutes * 60
    next_save, fails = time.monotonic() + 60, 0
    try:
        while time.time() < end:
            try:
                rows.append(sample())
                fails = 0
            except Exception as e:  # keep going through RPC hiccups, backing off up to 2 min
                fails += 1
                print("skip:", e, file=sys.stderr)
            if time.monotonic() >= next_save:
                save(rows, out)
                next_save = time.monotonic() + 60
            time.sleep(min(5 * 2 ** fails, 120))
    except KeyboardInterrupt:
        print("stopped early", file=sys.stderr)
    save(rows, out)
    if not rows:
        sys.exit("no samples")
    for name in ASSETS:
        for k in ("markOracleBps", "midOracleBps", "spreadBps"):
            v = sorted(r[name][k] for r in rows if name in r)
            if not v:
                print(f"{name:9} {k:14} n=0")
                continue
            print(f"{name:9} {k:14} n={len(v)} p50={v[len(v)//2]:.1f} p99={v[int(len(v)*.99)]:.1f} max={v[-1]:.1f}")


main()

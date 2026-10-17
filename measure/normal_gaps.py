"""Sample the normal gaps HLPriceGuard checks, straight from HyperEVM precompiles.

usage: python3 measure/normal_gaps.py MINUTES OUT.json

OUT.json is rewritten every minute, so a run cut short (network, Ctrl-C) keeps what it has.
"""
import json, os, sys, time, urllib.request

RPC = "https://rpc.hyperliquid.xyz/evm"
# name: (dex, index, szDecimals)
ASSETS = {"BTC": (0, 0, 5), "ETH": (0, 1, 4), "SOL": (0, 5, 2), "HYPE": (0, 159, 2), "xyz:TSLA": (1, 1, 3)}


def call(addr, idx):
    data = "0x" + format(idx, "064x")
    body = json.dumps([{"jsonrpc": "2.0", "id": 0, "method": "eth_call",
                        "params": [{"to": addr, "data": data}, "latest"]}]).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req, timeout=10))[0]["result"][2:]
    return [int(out[i:i + 64], 16) for i in range(0, len(out), 64)]


def sample():
    row = {"t": time.time()}
    for name, (dex, i, _) in ASSETS.items():
        perp = dex * 10000 + i
        bbo = i if dex == 0 else 100000 + dex * 10000 + i
        o, = call("0x0000000000000000000000000000000000000807", perp)
        m, = call("0x0000000000000000000000000000000000000806", perp)
        b, a = call("0x000000000000000000000000000000000000080e", bbo)
        mid = (a + b) / 2
        row[name] = {"oracle": o, "mark": m, "bid": b, "ask": a,
                     "markOracleBps": abs(m - o) / o * 1e4, "midOracleBps": abs(mid - o) / o * 1e4,
                     "spreadBps": (a - b) / b * 1e4}
    return row


def save(rows, out):
    json.dump(rows, open(out + ".tmp", "w"))
    os.replace(out + ".tmp", out)


def main():
    minutes, out = float(sys.argv[1]), sys.argv[2]
    rows, end = [], time.time() + minutes * 60
    try:
        while time.time() < end:
            try:
                rows.append(sample())
            except Exception as e:  # keep going through RPC hiccups
                print("skip:", e, file=sys.stderr)
            if len(rows) % 12 == 0:
                save(rows, out)
            time.sleep(5)
    except KeyboardInterrupt:
        print("stopped early", file=sys.stderr)
    save(rows, out)
    for name in ASSETS:
        for k in ("markOracleBps", "midOracleBps", "spreadBps"):
            v = sorted(r[name][k] for r in rows)
            print(f"{name:9} {k:14} n={len(v)} p50={v[len(v)//2]:.1f} p99={v[int(len(v)*.99)]:.1f} max={v[-1]:.1f}")


main()

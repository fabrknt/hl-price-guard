"""Fetch and decode one wallet's Papertrade positions from HyperEVM logs.

The Exchange contract (0x6cd56616…) is not verified anywhere we could find, so the
event layout is inferred from the data and checked against prices and the press:
- 0x88451ea1… PositionOpened(id indexed, user indexed): instrument (0 BTC, 1 ETH),
  side (0 short, 1 long), ?, entry price (HL raw units, ETH = 1/100 USD),
  margin (USDC, 1e18), leverage
- 0x87902ed2… PositionClosed(id indexed, user indexed): exit price, raw PnL,
  PnL after the asymmetric impact haircut (both int256, 1e18), ?, staker share

    python3 -I papertrade_events.py WALLET FROM_BLOCK TO_BLOCK OUT.json
"""
import json, sys, time, urllib.request

RPC = "https://rpc.hyperliquid.xyz/evm"
EXCHANGE = "0x6cd5661646289FB6E65EA5C032310fDEd797D0a2"
OPEN, CLOSE = "0x88451ea1", "0x87902ed2"
wallet, lo, hi, out = sys.argv[1].lower(), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
topic = "0x" + "0" * 24 + wallet[2:]


def rpc(method, params):
    for attempt in range(8):
        req = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), {"content-type": "application/json"})
        o = json.load(urllib.request.urlopen(req, timeout=60))
        if "error" not in o:
            return o["result"]
        time.sleep(2 + 3 * attempt)  # the public RPC rate-limits
    raise SystemExit(o["error"])


def words(data, signed=False):
    out = []
    for i in range((len(data) - 2) // 64):
        v = int(data[2 + 64 * i: 66 + 64 * i], 16)
        out.append(v - (1 << 256) if signed and v >= 1 << 255 else v)
    return out


logs = []
for start in range(lo, hi + 1, 50):
    logs += rpc("eth_getLogs", [{"address": EXCHANGE, "fromBlock": hex(start), "toBlock": hex(min(hi, start + 49)), "topics": [None, None, topic]}])
    time.sleep(0.25)
opens, closes = {}, {}
for l in logs:
    k, pid, t = l["topics"][0][:10], int(l["topics"][1], 16), int(l["blockTimestamp"], 16)
    if k == OPEN:
        w = words(l["data"])
        opens[pid] = {"t": t, "instrument": w[0], "side": "long" if w[1] else "short", "entry": w[3] / 100, "margin": w[4] / 1e18, "leverage": w[5]}
    elif k == CLOSE:
        w = words(l["data"], signed=True)
        closes[pid] = {"t": t, "exit": w[0] / 100, "raw_pnl": w[1] / 1e18, "pnl": w[2] / 1e18, "staker_share": w[4] / 1e18}
positions = [{"id": p, "open": o, "close": closes.get(p)} for p, o in sorted(opens.items())]
json.dump(positions, open(out, "w"), indent=1)
closed = [p for p in positions if p["close"]]
print(f"{len(positions)} opened, {len(closed)} closed, PnL ${sum(p['close']['pnl'] for p in closed):,.0f}")

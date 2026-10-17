"""Record HL trades (with wallet addresses), best bid/offer and books, for round_trips.py.

usage: python3 measure/round_trips_collect.py MINUTES OUT_DIR [COIN ...]

One WebSocket, three feeds per coin:
  trades  every trade, with users [buyer, seller]
  bbo     every change of the best bid/offer (about once a block): the mid, at the resolution a push needs
  l2Book  20 levels a side, about every 5 s: the depth a push has to eat
Messages go to OUT_DIR/feed-YYYYMMDD-HH.jsonl.gz (UTC hour) as received, one per line, prefixed with the local receive time.
OUT_DIR/covered.json lists the stretches with an unbroken connection ([first, last] receive time), so
analysis can keep only what lies wholly inside one. SIGTERM or Ctrl-C closes the files cleanly.
Needs `websockets` (pip install websockets).
"""
import asyncio, gzip, json, os, signal, sys, time

import websockets

WS = "wss://api.hyperliquid.xyz/ws"
DEFAULT = ["ETH", "SOL", "HYPE", "xyz:XYZ100", "xyz:TSLA"]


class Out:
    def __init__(self, d):
        self.d, self.hour, self.f = d, None, None

    def write(self, t, msg):
        hour = time.strftime("%Y%m%d-%H", time.gmtime(t))
        if hour != self.hour:
            self.close()
            self.hour, self.f = hour, gzip.open(os.path.join(self.d, f"feed-{hour}.jsonl.gz"), "at")
        self.f.write(f"{t:.3f} {msg}\n")

    def close(self):
        if self.f:
            self.f.close()
            self.f = None


async def run(minutes, d, coins):
    end = time.time() + minutes * 60
    out, covered, fails = Out(d), [], 0
    stop = asyncio.Event()
    for s in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(s, stop.set)
    while time.time() < end and not stop.is_set():
        try:
            async with websockets.connect(WS, max_size=None, ping_interval=None) as ws:
                for c in coins:
                    for feed in ("trades", "bbo", "l2Book"):
                        await ws.send(json.dumps({"method": "subscribe", "subscription": {"type": feed, "coin": c}}))
                last_sent, first, t = time.time(), None, None
                try:
                    while time.time() < end and not stop.is_set():
                        if time.time() - last_sent > 50:  # HL closes a connection idle for 60 s
                            await ws.send('{"method":"ping"}')
                            last_sent = time.time()
                        try:
                            msg = await asyncio.wait_for(ws.recv(), 5)
                        except asyncio.TimeoutError:
                            continue
                        t = time.time()
                        first = first or t
                        out.write(t, msg)
                        fails = 0
                finally:
                    if first:
                        covered.append([first, t])
        except Exception as e:  # reconnect with backoff; the gap is recorded
            print("reconnect:", repr(e), file=sys.stderr)
            fails += 1
        if time.time() < end and not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), min(2 ** fails, 60))
            except asyncio.TimeoutError:
                pass
    out.close()
    json.dump(covered, open(os.path.join(d, "covered.json"), "w"))
    print(f"connected stretches: {len(covered)}, {sum(b - a for a, b in covered) / 60:.1f} min")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    minutes, d = float(sys.argv[1]), sys.argv[2]
    os.makedirs(d, exist_ok=True)
    asyncio.run(run(minutes, d, sys.argv[3:] or DEFAULT))


main()

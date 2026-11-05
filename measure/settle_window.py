"""Record HIP-3 oracles and books around a fixed-time settlement (e.g. a TWAP ending 20:00 ET).

usage: python3 measure/settle_window.py MINUTES OUT_DIR

Every 10 s: metaAndAssetCtxs for the core dex and each dex in DEXES (oracle, mark, impact prices
for every asset), plus l2Book at full and 3-significant-figure resolution for each coin in BOOKS.
One JSON line per sweep, appended to OUT_DIR/samples.jsonl and flushed, so a run cut short
(network, SIGTERM) keeps what it has. Weight per sweep, by HL's published info weights: 3 x 20 for
metaAndAssetCtxs + 2 x 2 per book = 108, about 650 a minute against 1200 per IP. After a failed
sweep the wait doubles, up to 2 minutes; failed sweeps are counted in OUT_DIR/summary.txt. A request
that fails inside a sweep is named in the row's "err" and the rest of the row is kept. Exits 1 if
no sweep succeeded.
"""
import json, os, signal, sys, time, urllib.request

API = "https://api.hyperliquid.xyz/info"
INTERVAL = 10  # seconds between sweeps
DEXES = ["", "xyz", "io"]  # "" = core perps
BOOKS = ["io:ANTH", "io:OAI", "xyz:XYZ100", "xyz:SP500", "xyz:NVDA", "xyz:TSLA", "xyz:AAPL",
         "xyz:SPCX", "xyz:HOOD", "xyz:CRWV", "xyz:ANT", "BTC"]


def post(body):
    req = urllib.request.Request(API, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=10))


def sweep():
    """One row; a request that fails is left out and named in row["err"], the rest are kept."""
    row = {"t": time.time(), "ctx": {}, "ctxT": {}, "book": {}, "err": []}
    for dex in DEXES:
        key = dex or "core"
        try:
            meta, ctxs = post({"type": "metaAndAssetCtxs", "dex": dex} if dex else {"type": "metaAndAssetCtxs"})
        except Exception as e:
            row["err"].append(f"{key}: {e}")
            continue
        row["ctxT"][key] = time.time()  # local time of the response; metaAndAssetCtxs carries none
        row["ctx"][key] = {u["name"]: [c.get("oraclePx"), c.get("markPx"), c.get("midPx"),
                                       c.get("impactPxs"), c.get("openInterest")]
                           for u, c in zip(meta["universe"], ctxs)}
    for coin in BOOKS:
        for sig in (None, 3):
            key = f"{coin}@{sig or 'full'}"
            body = {"type": "l2Book", "coin": coin}
            if sig:
                body["nSigFigs"] = sig
            try:
                b = post(body)
            except Exception as e:
                row["err"].append(f"{key}: {e}")
                continue
            # server time (ms) and [px, sz, n] per level
            row["book"][key] = {"time": b.get("time"),
                                "levels": [[[l["px"], l["sz"], l.get("n")] for l in side] for side in b["levels"]]}
    if not row["ctx"] and not row["book"]:
        raise RuntimeError("; ".join(row["err"]) or "nothing returned")
    return row


def _stop(*_):
    raise KeyboardInterrupt


def main():
    minutes, out = float(sys.argv[1]), sys.argv[2]
    os.makedirs(out, exist_ok=True)
    signal.signal(signal.SIGTERM, _stop)
    end = time.time() + minutes * 60
    ok = failed = 0
    wait = INTERVAL
    with open(os.path.join(out, "samples.jsonl"), "a") as f:
        try:
            while time.time() < end:
                t0 = time.time()
                try:
                    f.write(json.dumps(sweep(), separators=(",", ":")) + "\n")
                    f.flush()
                    ok += 1
                    wait = INTERVAL
                except Exception as e:  # keep sampling through a bad sweep
                    failed += 1
                    print(f"{time.strftime('%H:%M:%S', time.gmtime())} sweep failed: {e}", file=sys.stderr)
                    wait = min(wait * 2, 120)
                time.sleep(max(0.0, min(wait - (time.time() - t0), end - time.time())))
        except KeyboardInterrupt:
            pass
    with open(os.path.join(out, "summary.txt"), "w") as s:
        s.write(f"sweeps: {ok} ok, {failed} failed\n")
    print(f"sweeps: {ok} ok, {failed} failed")
    if ok == 0:
        sys.exit(1)  # an empty recording must not look like a successful one


if __name__ == "__main__":
    main()

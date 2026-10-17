"""Safe exposure caps per asset: how much notional a pool or venue can settle per minute against
an HL price before a one-minute push stops costing more than it pays.

    python3 -I measure/safe_caps.py MINUTES OUT.json [ASSET ...]
    python3 -I measure/safe_caps.py summary OUT.json        # re-print, overall and per UTC hour

OUT.json is rewritten after every sweep, so a run cut short (network, Ctrl-C) keeps what it has.

For each asset, sample HL's L2 book every 30 s and record the notional within 10 bp of the mid
on the thinner side (`depth10`). Then:

    cost of holding a 10 bp push  ~= CAL * depth10 * 10 / 10000
    cap per minute (ExposureBudget.safeCap, k = 3) = cost * 10000 / (10 * 3) = CAL * depth10 / 3

CAL = 0.27, calibrated on Papertrade (cases/papertrade-20261010, calibrate_cost.py): what the
attacker actually spent per round was 0.27 of what static book depth predicts, because the book
refills and the move spread to other venues. One incident on one asset: treat it as a first
estimate. The low percentile (p10) of depth is used, since a push picks a thin moment.
"""
import datetime, json, os, sys, time, urllib.request

API = "https://api.hyperliquid.xyz/info"
CAL, K, D_BPS = 0.27, 3, 10
DEFAULT = ["BTC", "ETH", "SOL", "HYPE", "xyz:XYZ100", "xyz:SP500", "xyz:SKHX", "xyz:TSLA", "xyz:CL",
           "xyz:SPCX", "xyz:NVDA", "xyz:GOLD", "xyz:SMSN", "xyz:KORU"]


def post(body):
    req = urllib.request.Request(API, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=10))


def depth_within(coin, d_bps):
    """Notional within d_bps of mid, per side, at the finest aggregation that reaches d_bps."""
    for sig in (None, 5, 4, 3):
        body = {"type": "l2Book", "coin": coin}
        if sig:
            body["nSigFigs"] = sig
        bids, asks = post(body)["levels"]
        if not bids or not asks:
            return None
        mid = (float(bids[0]["px"]) + float(asks[0]["px"])) / 2
        reach_b = (1 - float(bids[-1]["px"]) / mid) * 1e4
        reach_a = (float(asks[-1]["px"]) / mid - 1) * 1e4
        if min(reach_b, reach_a) >= d_bps or sig == 3:
            nb = sum(float(l["px"]) * float(l["sz"]) for l in bids if (1 - float(l["px"]) / mid) * 1e4 <= d_bps)
            na = sum(float(l["px"]) * float(l["sz"]) for l in asks if (float(l["px"]) / mid - 1) * 1e4 <= d_bps)
            return {"bid": nb, "ask": na, "sig": sig, "spread_bps": (float(asks[0]["px"]) / float(bids[0]["px"]) - 1) * 1e4}


def save(samples, out):
    tmp = out + ".tmp"
    json.dump(samples, open(tmp, "w"))
    os.replace(tmp, out)


def table(samples, title):
    print(title)
    print(f"{'asset':12} {'n':>3} {'depth10 p10':>12} {'median':>10} {'cap/min':>10}")
    for a, ss in samples.items():
        if not ss:
            print(f"{a:12} no book")
            continue
        d = sorted(min(s["bid"], s["ask"]) for s in ss)
        p10 = d[int(len(d) * 0.1)]
        print(f"{a:12} {len(d):3} {p10/1e6:11.2f}M {d[len(d)//2]/1e6:9.2f}M {CAL*p10/K/1e6:9.2f}M")


def summary(samples):
    ts = [s["t"] for ss in samples.values() for s in ss]
    if not ts:
        print("no samples")
        return
    utc = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
    table(samples, f"all: {utc(min(ts)):%Y-%m-%d %H:%M}-{utc(max(ts)):%H:%M} UTC")
    hours = sorted({utc(t).replace(minute=0, second=0, microsecond=0) for t in ts})
    if len(hours) > 1:
        for h in hours:
            lo, hi = h.timestamp(), h.timestamp() + 3600
            print()
            table({a: [s for s in ss if lo <= s["t"] < hi] for a, ss in samples.items()}, f"{h:%H}:00 UTC")


def main():
    if sys.argv[1] == "summary":
        summary(json.load(open(sys.argv[2])))
        return
    minutes, out = float(sys.argv[1]), sys.argv[2]
    assets = sys.argv[3:] or DEFAULT
    samples = {a: [] for a in assets}
    end = time.time() + minutes * 60
    try:
        while True:
            t = time.time()
            for a in assets:
                try:
                    s = depth_within(a, D_BPS)
                    if s:
                        samples[a].append({"t": t, **s})
                except Exception as e:
                    print("skip", a, e, file=sys.stderr)
                time.sleep(0.2)
            save(samples, out)
            if time.time() > end:
                break
            time.sleep(max(0, 30 - (time.time() - t)))
    except KeyboardInterrupt:
        print("stopped early", file=sys.stderr)
    save(samples, out)
    summary(samples)


main()

"""How far trade.xyz's US-stock perps (HIP-3 dex "xyz") are from the stock's next open, when the
cash market is shut.

    python3 -I measure/offhours_gaps.py --fetch   # fetch HL and Yahoo (raw cache, not committed)
    python3 -I measure/offhours_gaps.py           # rerun from the local cache

The raw inputs (HL hourly candles, Yahoo daily bars, a snapshot of xyz's max leverage) are cached
in offhours-gaps-data.json, which is not committed; offhours-gaps-result.json, one row per gap, is.
Hyperliquid serves only the most recent 5,000 candles per coin, so the fixed window below can be
refetched only for a few days after 2026-11-23; after that the result file is the record.

For every gap between two regular sessions of the stock (weeknight, weekend, holiday) it compares
three prices with the next official open O, each as |price / O - 1| in percent:

    C        the previous official close (what a feed frozen at the close would hold)
    P_pre    the perp's close of the last 1h bar ending at least 30 min before the open
    P_dark   weekends/holidays only: the perp at 20:00 ET the evening before the open, the end of
             xyz's internal session (no US venue has traded since 20:00 ET after the close)

and how far the perp went while the cash market was shut, from 1h bars that lie entirely between
the close and the open (so the half hour before the open is left out):

    exc_C    max |high or low / C - 1|
    exc_O    the same against O
    band     how far beyond both C and O (outside [min(C,O), max(C,O)]), 0 if inside

and the same over xyz's internal session only (20:00 ET after the close .. 20:00 ET the evening
before the open), from highs and lows and from hourly closes. A dark window missing more than 10%
of its hourly bars gets no dark metrics.

The perp is the traded price (HL 1h candles), not the deployer's oracle or the mark: the API keeps
no oracle history. Stock bars: Yahoo 1d (regular session only); a bar must start at 13:30 or 14:30
UTC (09:30 ET) or the script stops; its close is 6.5 h later, 3.5 h on the NYSE early-close days
listed below. A ticker whose perp, at the close, is more than 3% from C in the median is dropped
(a different instrument or a split).
"""
import bisect, datetime as dt, json, os, statistics, sys, time, urllib.parse, urllib.request

UTC = dt.timezone.utc
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "offhours-gaps-data.json")
END = dt.datetime(2026, 11, 22, tzinfo=UTC)
START = END - dt.timedelta(days=200)
H = 3600
EARLY_CLOSES = {"2026-11-27", "2026-12-24"}  # NYSE 13:00 ET closes; none fall inside the window

# xyz perp -> Yahoo symbol. US-listed single stocks and ETFs only (no indices, commodities, FX,
# Korean/Chinese/Japanese listings), the largest by open interest on 2026-11-23.
PAIRS = {
    "xyz:NVDA": "NVDA", "xyz:SOXL": "SOXL", "xyz:MU": "MU", "xyz:SKHY": "SKHY", "xyz:GOOGL": "GOOGL",
    "xyz:SNDK": "SNDK", "xyz:EWY": "EWY", "xyz:AAPL": "AAPL", "xyz:MSFT": "MSFT", "xyz:TSLA": "TSLA",
    "xyz:AMZN": "AMZN", "xyz:AMD": "AMD", "xyz:INTC": "INTC", "xyz:NBIS": "NBIS", "xyz:META": "META",
    "xyz:KORU": "KORU", "xyz:CRCL": "CRCL", "xyz:MSTR": "MSTR", "xyz:IREN": "IREN", "xyz:TSM": "TSM",
    "xyz:MRVL": "MRVL", "xyz:COST": "COST", "xyz:AVGO": "AVGO", "xyz:COIN": "COIN", "xyz:HOOD": "HOOD",
    "xyz:PLTR": "PLTR", "xyz:ORCL": "ORCL", "xyz:CRWV": "CRWV", "xyz:STRC": "STRC", "xyz:SMH": "SMH",
}
# Businesses tied to crypto (holdings, exchanges, stablecoins, mining/hosting, a preferred backed by
# bitcoin holdings), compared as a group in section 4 of docs/stock-offhours.md.
CRYPTO_LINKED = {"xyz:MSTR", "xyz:COIN", "xyz:CRCL", "xyz:HOOD", "xyz:IREN", "xyz:STRC"}


def post(body):
    req = urllib.request.Request("https://api.hyperliquid.xyz/info", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def hl_hourly(coin):
    out, s, e = {}, int(START.timestamp() * 1000), int(END.timestamp() * 1000)
    while s < e:
        rows = post({"type": "candleSnapshot", "req": {"coin": coin, "interval": "1h", "startTime": s, "endTime": e}})
        if not rows:
            break
        for r in rows:
            out[r["t"] // 1000] = [float(r["o"]), float(r["h"]), float(r["l"]), float(r["c"])]
        nxt = rows[-1]["t"] + H * 1000
        if nxt <= s:
            break
        s = nxt
        time.sleep(0.3)
    return out


def yahoo_daily(sym):
    u = (f"https://query1.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(sym)}?interval=1d"
         f"&period1={int(START.timestamp())}&period2={int(END.timestamp())}&includePrePost=false")
    r = json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"}),
                                          timeout=30).read())["chart"]["result"][0]
    q = r["indicators"]["quote"][0]
    out = []
    for t, o, c in zip(r["timestamp"], q["open"], q["close"]):
        if o is None or c is None:
            continue
        hm = dt.datetime.fromtimestamp(t, UTC).strftime("%H:%M")
        if hm not in ("13:30", "14:30"):
            sys.exit(f"{sym}: daily bar at {hm} UTC, not 09:30 ET")
        out.append([t, o, c])
    return out


def max_leverage():
    m = post({"type": "meta", "dex": "xyz"})
    return {"fetched": dt.datetime.now(UTC).strftime("%Y-%m-%d"),
            "max_leverage": {u["name"]: u["maxLeverage"] for u in m["universe"] if u["name"] in PAIRS}}


def fetch():
    data = {"source": "HL candleSnapshot 1h (xyz dex); Yahoo chart API 1d; HL meta (xyz) for max leverage",
            "window": [START.date().isoformat(), END.date().isoformat()], "tickers": {}}
    for coin, sym in PAIRS.items():
        print("fetch", coin, file=sys.stderr)
        data["tickers"][coin] = {"yahoo": sym, "stock_1d": yahoo_daily(sym), "perp_1h": hl_hourly(coin)}
    data["leverage"] = max_leverage()
    with open(DATA, "w") as f:
        json.dump(data, f)
    return data


def session_close(t0):
    d = dt.datetime.fromtimestamp(t0, UTC).strftime("%Y-%m-%d")
    return t0 + int((3.5 if d in EARLY_CLOSES else 6.5) * H)


def pct(x, ref):
    return 100 * abs(x / ref - 1)


def gaps(t):
    bars = t["stock_1d"]
    perp = {int(k): v for k, v in t["perp_1h"].items()}
    hours = sorted(perp)
    if not hours:
        return [], None
    out, basis = [], []
    for (t0, _, c), (t1, o, _) in zip(bars, bars[1:]):
        tc = session_close(t0)
        if tc < hours[0] + H:
            continue
        # perp at the close: close of the 1h bar ending at tc
        if tc - H in perp:
            basis.append(pct(perp[tc - H][3], c))
        # bars lying entirely between the close and the open
        win_h = [h for h in hours[bisect.bisect_left(hours, tc):bisect.bisect_left(hours, t1)] if h + H <= t1]
        if not win_h:
            continue
        # P_pre: the last bar ending at least 30 min before the open
        pre = [h for h in win_h if h + H <= t1 - 1800]
        if not pre:
            continue
        p_pre = perp[pre[-1]][3]
        days = (dt.datetime.fromtimestamp(t1, UTC).date() - dt.datetime.fromtimestamp(t0, UTC).date()).days
        wd0 = dt.datetime.fromtimestamp(t0, UTC).weekday()
        kind = "weeknight" if days == 1 else ("weekend" if days == 3 and wd0 == 4 else "holiday/long")
        win = [perp[h] for h in win_h]
        mx, mn = max(b[1] for b in win), min(b[2] for b in win)
        row = {
            "close_utc": tc, "open_utc": t1, "kind": kind, "C": c, "O": o,
            "err_C": pct(c, o), "err_pre": pct(p_pre, o), "err_dark": None,
            "exc_C": 100 * max(mx / c - 1, 1 - mn / c), "exc_O": 100 * max(mx / o - 1, 1 - mn / o),
            "band": 100 * max(mx / max(c, o) - 1, 1 - mn / min(c, o), 0),
            "exc_dark_C": None, "exc_dark_C_close": None, "band_dark": None, "band_dark_close": None,
            "hours": len(win_h), "hours_expected": (t1 - tc) // H,
        }
        if kind != "weeknight":
            d0, d1 = tc + 4 * H, t1 - int(13.5 * H)  # 20:00 ET after the close .. 20:00 ET before the open
            dk_h = [h for h in win_h if h >= d0 and h + H <= d1]
            row["dark_hours"], row["dark_hours_expected"] = len(dk_h), (d1 - d0) // H
            if dk_h and len(dk_h) >= 0.9 * ((d1 - d0) // H) and (d1 - H) in perp:
                dk = [perp[h] for h in dk_h]
                hi, lo = max(b[1] for b in dk), min(b[2] for b in dk)
                hc, lc = max(b[3] for b in dk), min(b[3] for b in dk)
                row["err_dark"] = pct(perp[d1 - H][3], o)
                row["exc_dark_C"] = 100 * max(hi / c - 1, 1 - lo / c)
                row["exc_dark_C_close"] = 100 * max(hc / c - 1, 1 - lc / c)
                row["band_dark"] = 100 * max(hi / max(c, o) - 1, 1 - lo / min(c, o), 0)
                row["band_dark_close"] = 100 * max(hc / max(c, o) - 1, 1 - lc / min(c, o), 0)
        out.append(row)
    return out, (statistics.median(basis) if basis else None)


def q(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * (len(xs) - 1) + 0.5))] if xs else float("nan")


def s3(rows, key):
    xs = [r[key] for r in rows if r[key] is not None]
    if not xs:
        return "n=0"
    return f"n={len(xs)} median {statistics.median(xs):.2f} p95 {q(xs, 0.95):.2f} max {max(xs):.2f}"


def wins(rows, a, b="err_C"):
    rs = [r for r in rows if r[a] is not None]
    k = sum(1 for r in rs if r[a] < r[b])
    return f"{k}/{len(rs)} ({100 * k / len(rs):.1f}%)" if rs else "0/0"


def day(ts):
    return dt.datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%d")


def main():
    data = fetch() if "--fetch" in sys.argv or not os.path.exists(DATA) else json.load(open(DATA))
    if "leverage" not in data:
        data["leverage"] = max_leverage()
        with open(DATA, "w") as f:
            json.dump(data, f)
    lev = data["leverage"]["max_leverage"]
    allrows, dropped, per = [], [], {}
    for coin, t in data["tickers"].items():
        rows, basis = gaps(t)
        if basis is None or basis > 3:
            dropped.append((coin, None if basis is None else round(basis, 1)))
            continue
        for r in rows:
            r["coin"] = coin
        per[coin] = rows
        allrows += rows
    print(f"window {data['window'][0]}..{data['window'][1]}; tickers kept {len(per)}; "
          f"dropped (median % from C at the close) {dropped}; gaps {len(allrows)}")
    missing = sum(1 for r in allrows if r["hours"] < r["hours_expected"] - 1)
    print(f"gaps missing more than one hourly bar between close and open: {missing}")
    print(f"reopening dates: all gaps {len({day(r['open_utc']) for r in allrows})}, weekends+holidays "
          f"{len({day(r['open_utc']) for r in allrows if r['kind'] != 'weeknight'})}")

    print("\n1. Error vs the next open, |price / O - 1| in %")
    for kind in ("weeknight", "weekend", "holiday/long"):
        rs = [r for r in allrows if r["kind"] == kind]
        print(f"  {kind}: C {s3(rs, 'err_C')}")
        print(f"  {'':{len(kind)}}  P_pre {s3(rs, 'err_pre')}; P_pre closer than C {wins(rs, 'err_pre')}")
        if kind != "weeknight":
            print(f"  {'':{len(kind)}}  P_dark {s3(rs, 'err_dark')}; P_dark closer than C {wins(rs, 'err_dark')}")
    dark = [r for r in allrows if r["kind"] != "weeknight"]
    print(f"  weekends+holidays: P_dark closer than C {wins(dark, 'err_dark')}; dark windows without "
          f"dark metrics (bars missing) {sum(1 for r in dark if r['err_dark'] is None)}")

    print("\n2. Internal session (20:00 ET after the close .. 20:00 ET before the open), %")
    for name, rs in (("weekends", [r for r in dark if r["kind"] == "weekend"]), ("weekends+holidays", dark)):
        print(f"  {name}: excursion from C, closes {s3(rs, 'exc_dark_C_close')}")
        print(f"  {'':{len(name)}}  excursion from C, highs/lows {s3(rs, 'exc_dark_C')}")
        print(f"  {'':{len(name)}}  beyond both C and O, closes {s3(rs, 'band_dark_close')}")
        print(f"  {'':{len(name)}}  beyond both C and O, highs/lows {s3(rs, 'band_dark')}")
        for th in (2, 5, 10):
            k = sum(1 for r in rs if (r["band_dark_close"] or 0) > th)
            print(f"  {'':{len(name)}}  an hourly close more than {th}% beyond both: {k}/{len(rs)}")

    print("\n3. Whole close-to-open gap (bars entirely before the open), %")
    for kind in ("weeknight", "weekend", "holiday/long"):
        rs = [r for r in allrows if r["kind"] == kind]
        print(f"  {kind}: exc_C {s3(rs, 'exc_C')}; beyond both {s3(rs, 'band')}")

    print("\n4. Crypto-linked businesses vs the rest")
    for scope, base in (("weekends", [r for r in dark if r["kind"] == "weekend"]), ("weekends+holidays", dark)):
        for name, sel in (("crypto-linked", lambda c: c in CRYPTO_LINKED), ("other", lambda c: c not in CRYPTO_LINKED)):
            rs = [r for r in base if sel(r["coin"])]
            print(f"  {scope:17s} {name:13s} P_dark closer than C {wins(rs, 'err_dark')}; "
                  f"excursion from C, closes {s3(rs, 'exc_dark_C_close')}")

    print("\n5. A fixed band around C over the internal session (weekends+holidays with dark metrics)")
    dm = [r for r in dark if r["exc_dark_C_close"] is not None]
    for b in (3, 5, 8, 10):
        held_c = sum(1 for r in dm if r["exc_dark_C_close"] <= b)
        held_w = sum(1 for r in dm if r["exc_dark_C"] <= b)
        dc = {day(r["open_utc"]) for r in dm if r["exc_dark_C_close"] > b}
        dw = {day(r["open_utc"]) for r in dm if r["exc_dark_C"] > b}
        print(f"  ±{b}%: closes inside {held_c}/{len(dm)}, highs/lows inside {held_w}/{len(dm)}; reopening "
              f"dates with a breach: closes {len(dc)}, highs/lows {len(dw)} of {len({day(r['open_utc']) for r in dm})}")

    print(f"\n6. Internal-session highs/lows beyond 1/max leverage (leverage snapshot "
          f"{data['leverage']['fetched']}; illustrative, not a test of the mark bound)")
    over = sorted([r for r in dm if r["exc_dark_C"] > 100 / lev[r["coin"]]], key=lambda r: -r["exc_dark_C"])
    for r in over:
        print(f"  {r['coin']:10s} {lev[r['coin']]:2d}x  open {day(r['open_utc'])}  "
              f"{r['exc_dark_C']:.2f}% (closes {r['exc_dark_C_close']:.2f}%)")
    print(f"  {len(over)}/{len(dm)}")

    print("\n7. Largest hourly-close moves beyond both C and O in the internal session")
    for r in sorted(dm, key=lambda r: -r["band_dark_close"])[:10]:
        print(f"  {r['coin']:10s} close {day(r['close_utc'])} -> open {day(r['open_utc'])}  "
              f"{r['band_dark_close']:.2f}% (highs/lows {r['band_dark']:.2f}%), C {r['C']:.2f} O {r['O']:.2f}")

    out = os.path.join(HERE, "offhours-gaps-result.json")
    rnd = [{k: (round(v, 4) if isinstance(v, float) else v) for k, v in r.items()} for r in allrows]
    with open(out, "w") as f:
        json.dump({"window": data["window"], "dropped": dropped, "pairs": PAIRS,
                   "crypto_linked": sorted(CRYPTO_LINKED), "leverage": data["leverage"],
                   "rows": rnd}, f, separators=(",", ":"))
        f.write("\n")


if __name__ == "__main__":
    main()

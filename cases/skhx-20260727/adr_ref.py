"""An out-of-hours reference for xyz:SKHX from SK Hynix's Nasdaq ADS (SKHY), and how well it does.

    python3 -I adr_ref.py           # from adr_ref_data.json
    python3 -I adr_ref.py --fetch   # refetch it from Yahoo's chart API first

The inputs are daily SKHY and 000660.KS and hourly USD/KRW from Yahoo, for a fixed window,
reduced to one row per KRX session in adr_ref_data.json. k is fitted from the listing
(2026-07-10), errors are reported for the sessions from 2026-07-28 (the incident's) to
2026-11-20. For each KRX session d, in USD per share:

    k_d   = (000660 open on d / USDKRW at the open) / SKHY's last close by 08:00 KST
    ref_d = SKHY's last close by 08:00 KST * median(k over the 10 sessions before d)

08:00 KST (23:00 UTC) is when the incident's updates were read. ref_d is what a contract could
hold from the US close (20:00 UTC, 21:00 in US winter time) to the KRX open:
Pyth publishes SKHY/USD (Equity.US.SKHY/USD), so the close itself can reach the chain; k is a
governed parameter updated once a session. The script prints the incident's reference
(2026-07-28 session, read at 2026-07-27 23:00 UTC) and the reference's error against each open.

Session times are checked, not assumed: a KRX bar must start at 00:00 UTC (09:00 KST) or
01:00 UTC (10:00 KST, the CSAT day), and an ADR bar at 13:30 or 14:30 UTC (09:30 ET), whose
close is taken 6.5 h later (an early close only makes it earlier). Any other time stops the
script. USD/KRW at the open is the open of the hourly bar starting then, else the close of the
last bar that ended by then, at most 6 h old.
"""
import bisect, datetime as dt, json, os, statistics, sys, urllib.parse, urllib.request

UTC = dt.timezone.utc


START, END = dt.datetime(2026, 6, 1, tzinfo=UTC), dt.datetime(2026, 11, 21, tzinfo=UTC)


def chart(sym, interval):
    u = (f"https://query1.finance.yahoo.com/v8/finance/chart/{urllib.parse.quote(sym)}?interval={interval}"
         f"&period1={int(START.timestamp())}&period2={int(END.timestamp())}&includePrePost=false")
    r = json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"}),
                                          timeout=30).read())["chart"]["result"][0]
    q = r["indicators"]["quote"][0]
    return [(t, o, c) for t, o, c in zip(r["timestamp"], q["open"], q["close"]) if o and c]


DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "adr_ref_data.json")


def tod(t):
    return t % 86400


def fetch():
    krx = chart("000660.KS", "1d")
    adr = chart("SKHY", "1d")
    fx = chart("KRW=X", "1h")
    fx_t = [t for t, _, _ in fx]

    def usdkrw(t):
        i = bisect.bisect_right(fx_t, t) - 1
        if i >= 0 and fx_t[i] == t:
            return fx[i][1]  # the bar starting at t: its open is the price at t
        i = bisect.bisect_right(fx_t, t - 3600) - 1  # else the last bar that ended by t
        if i < 0 or t - fx_t[i] > 7 * 3600:
            raise SystemExit(f"no USD/KRW within 6 h before {dt.datetime.fromtimestamp(t, UTC)}")
        return fx[i][2]

    for t, _, _ in adr:
        if tod(t) not in (13 * 3600 + 1800, 14 * 3600 + 1800):
            raise SystemExit(f"SKHY bar at {dt.datetime.fromtimestamp(t, UTC)}: not 09:30 ET")
    rows = []
    for t, o, _ in krx:
        if tod(t) not in (0, 3600):
            raise SystemExit(f"000660 bar at {dt.datetime.fromtimestamp(t, UTC)}: not 09:00/10:00 KST")
        cutoff = t - tod(t) - 3600  # 08:00 KST on the session's day
        prior = [(ta + 23400, c) for ta, _, c in adr if ta + 23400 <= cutoff]
        if prior:
            d = dt.datetime.fromtimestamp(t + 9 * 3600, UTC).date().isoformat()
            fxo = usdkrw(t)
            rows.append({"session": d, "krx_open_utc": t, "krx_open_krw": o, "usdkrw": fxo,
                         "open_usd": o / fxo, "skhy_close_utc": prior[-1][0], "skhy_close": prior[-1][1]})
    with open(DATA, "w") as f:
        json.dump({"source": "Yahoo chart API: 000660.KS 1d, SKHY 1d, KRW=X 1h; reduced by adr_ref.py --fetch",
                   "window": [START.date().isoformat(), END.date().isoformat()], "sessions": rows}, f, indent=1)


if "--fetch" in sys.argv:
    fetch()
with open(DATA) as f:
    rows = [(dt.date.fromisoformat(r["session"]), r["open_usd"], r["skhy_close"]) for r in json.load(f)["sessions"]]

ks = [(d, o / c) for d, o, c in rows]
first = [k for d, k in ks if d < dt.date(2026, 7, 24)]
print(f"k over the first {len(first)} sessions of the listing: {min(first):.2f}-{max(first):.2f}")
errors = []
for i in range(10, len(rows)):
    d, open_usd, close = rows[i]
    if d < dt.date(2026, 7, 28):
        continue
    k = statistics.median(k for _, k in ks[i - 10:i])
    ref = close * k
    errors.append((d, ref / open_usd - 1))
    if d == dt.date(2026, 7, 28):
        print(f"2026-07-28 session: SKHY close ${close:.2f} x k {k:.4f} = ${ref:.2f}; "
              f"the open was ${open_usd:.2f} ({ref / open_usd - 1:+.1%})")

e = sorted(abs(x) for _, x in errors)
worst = max(errors, key=lambda x: abs(x[1]))
print(f"{len(errors)} sessions {errors[0][0]}..{errors[-1][0]}: mean |error| {statistics.mean(e):.2%}, "
      f"p95 {e[int(0.95 * (len(e) - 1))]:.2%}, max {e[-1]:.2%} ({worst[0]}); over 10%: "
      + (", ".join(f"{d} ({x:+.1%})" for d, x in errors if abs(x) > 0.10) or "none"))

"""Find single-wallet push-and-unwind round trips in round_trips_collect.py output; compare their cost
with what static book depth predicts (the 0.27 of docs/safe-limits.md, measured on Papertrade).

usage: python3 measure/round_trips.py OUT.jsonl DIR [DIR ...]

A candidate, per wallet and coin:
  quiet   no fills by the wallet in that coin for PRE seconds before
  push    the wallet's taker fills in one direction, gaps <= PUSH_GAP, span <= PUSH_SPAN, notional >= MIN_NOTIONAL;
          >= 80% of the wallet's notional in the push is taker, and the wallet is >= 50% of all aggressive
          notional in that direction meanwhile
  unwind  the wallet's net change returns to within 5% of its peak within HOLD_MAX of the push start
  d       largest move of the mid (bbo) in the push direction, from the last bbo before the push to 1 s after
          its last fill; kept if >= MIN_BPS
Cost is cash: what the round trip's fills paid minus what they got back, the small residual valued at the
mid. Fees are not in the public data, so cost is without fees; fee scenarios are reported separately.
Predicted = depth per bp on the pushed side of the last book before the push (20 levels, extrapolated
linearly past their reach, as cases/papertrade-20261010/calibrate_cost.py) * d * d / 1e4.

Only strict candidates keep their fills in OUT.jsonl, to keep it small.

Strict: none of these flags. stale (book over 10 s old), before (the mid had already moved half of d the
same way in the 10 s before the push), extrapolated (d beyond the book's reach), hold (unwind under 20 s or
over 120 s; Papertrade's rounds were about a minute), small (the push's taker notional is under a quarter
of the static depth it would take to move the mid d bp: the move was mostly someone else's). A candidate is dropped unless its quiet window, push
and unwind (padded by PAD) lie inside one unbroken stretch of collection. Use the strict cohort, not the loose low tail, for a cap.
"""
import bisect, collections, glob, gzip, json, os, sys

PRE, PUSH_GAP, PUSH_SPAN, HOLD_MAX = 600, 2, 60, 180
MIN_NOTIONAL, MIN_BPS, PAD = 10_000, 5, 10
TAKER_FEE, MAKER_FEE = 4.5e-4, 1.5e-4  # base tier; real wallets vary


def load(dirs):
    trades, bbo, books, covered = {}, collections.defaultdict(list), collections.defaultdict(list), []
    for d in dirs:
        covered += json.load(open(os.path.join(d, "covered.json")))
        for path in sorted(glob.glob(os.path.join(d, "feed-*.jsonl.gz"))):
            for line in gzip.open(path, "rt"):
                _, msg = line.split(" ", 1)
                m = json.loads(msg)
                ch, data = m.get("channel"), m.get("data")
                if ch == "trades":
                    for x in data:
                        trades[(x["coin"], x["time"], x["tid"])] = x
                elif ch == "bbo" and all(data["bbo"]):
                    b, a = data["bbo"]
                    bbo[data["coin"]].append((data["time"] / 1000, (float(b["px"]) + float(a["px"])) / 2))
                elif ch == "l2Book":
                    books[data["coin"]].append((data["time"] / 1000, data["levels"]))
    for s in (*bbo.values(), *books.values()):
        s.sort(key=lambda r: r[0])
    return sorted(trades.values(), key=lambda x: (x["time"], x["tid"])), bbo, books, covered


def depth_per_bp(levels, buying, mid):
    side = levels[1] if buying else levels[0]
    reach = abs(float(side[-1]["px"]) / mid - 1) * 1e4
    return sum(float(l["px"]) * float(l["sz"]) for l in side) / reach, reach


def candidates(trades, bbo, books, covered):
    fills = collections.defaultdict(list)  # (wallet, coin) -> (t, qty signed for the wallet, px, taker)
    aggressive = collections.defaultdict(list)  # coin -> (t, +notional buy / -notional sell)
    for x in trades:
        t, px, sz, buy = x["time"] / 1000, float(x["px"]), float(x["sz"]), x["side"] == "B"
        buyer, seller = x["users"]
        if buyer != seller:  # a self-match moves no inventory
            fills[(buyer, x["coin"])].append((t, sz, px, buy))
            fills[(seller, x["coin"])].append((t, -sz, px, not buy))
        aggressive[x["coin"]].append((t, px * sz if buy else -px * sz))
    agg_t = {c: [r[0] for r in v] for c, v in aggressive.items()}
    bbo_t = {c: [r[0] for r in v] for c, v in bbo.items()}
    book_t = {c: [r[0] for r in v] for c, v in books.items()}

    def observed(a, b):  # [a - PRE, b] inside one connected stretch, with PAD to spare (server vs local clock)
        return any(c0 <= a - PRE - PAD and b + PAD <= c1 for c0, c1 in covered)

    for (wallet, coin), fs in fills.items():
        i = 0
        while i < len(fs):
            t0, q0, _, taker0 = fs[i]
            if not taker0 or (i and t0 - fs[i - 1][0] < PRE):
                i += 1
                continue
            sign, j = (1 if q0 > 0 else -1), i
            while j + 1 < len(fs) and fs[j + 1][0] - fs[j][0] <= PUSH_GAP and fs[j + 1][0] - t0 <= PUSH_SPAN \
                    and (fs[j + 1][1] > 0) == (sign > 0):
                j += 1
            push = fs[i:j + 1]
            t1 = push[-1][0]
            notional = sum(abs(q) * px for _, q, px, _ in push)
            taker_notional = sum(abs(q) * px for _, q, px, tk in push if tk)
            lo, hi = bisect.bisect_left(agg_t[coin], t0), bisect.bisect_right(agg_t[coin], t1)
            same_way = sum(abs(n) for _, n in aggressive[coin][lo:hi] if (n > 0) == (sign > 0))
            if notional < MIN_NOTIONAL or taker_notional < 0.8 * notional or taker_notional < 0.5 * same_way:
                i = j + 1
                continue
            # unwind: net change back within 5% of its peak
            net = peak = 0.0
            k, cash, done = i, 0.0, None
            while k < len(fs) and fs[k][0] - t0 <= HOLD_MAX:
                _, q, px, _ = fs[k]
                net += q
                cash -= q * px
                peak = max(peak, abs(net))
                if k > j and abs(net) <= 0.05 * peak:
                    done = k
                    break
                k += 1
            if done is None:
                i = j + 1
                continue
            tau = fs[done][0]
            if coin not in bbo or coin not in books or not observed(t0, tau):
                i = done + 1
                continue
            bt = bbo_t[coin]
            p = bisect.bisect_left(bt, t0) - 1
            if p < 0:
                i = done + 1
                continue
            mid0 = bbo[coin][p][1]
            window = bbo[coin][p + 1:bisect.bisect_right(bt, t1 + 1)]
            d = max([sign * (m / mid0 - 1) * 1e4 for _, m in window] or [0])
            if d < MIN_BPS:
                i = done + 1
                continue
            before = bbo[coin][bisect.bisect_right(bt, t0 - 10) - 1][1] if bisect.bisect_right(bt, t0 - 10) else mid0
            mid_end = bbo[coin][bisect.bisect_right(bt, tau) - 1][1]
            b = bisect.bisect_left(book_t[coin], t0) - 1
            if b < 0:
                i = done + 1
                continue
            bt0, levels = books[coin][b]
            dpb, reach = depth_per_bp(levels, sign > 0, mid0)
            predicted = dpb * d * d / 1e4
            cost = -(cash + net * mid_end)
            flags = [f for f, on in (("stale", t0 - bt0 > 10), ("before", sign * (mid0 / before - 1) * 1e4 >= d / 2),
                                     ("extrapolated", d > reach), ("hold", not 20 <= tau - t0 <= 120),
                                     ("small", taker_notional < 0.25 * dpb * d)) if on]
            rt = fs[i:done + 1]
            yield {"coin": coin, "wallet": wallet, "t0": t0, "push_secs": round(t1 - t0, 3), "hold_secs": round(tau - t0, 3),
                   "dir": "buy" if sign > 0 else "sell", "push_notional": round(notional), "d_bps": round(d, 2),
                   "depth_per_bp": round(dpb), "book_age": round(t0 - bt0, 2), "predicted": round(predicted, 2),
                   "cost": round(cost, 2), "ratio": round(cost / predicted, 4) if predicted else None,
                   "taker_notional": round(sum(abs(q) * px for _, q, px, tk in rt if tk)),
                   "maker_notional": round(sum(abs(q) * px for _, q, px, tk in rt if not tk)),
                   "flags": flags, "fills": [[t, q, px, tk] for t, q, px, tk in rt] if not flags else None}
            i = done + 1


def pct(v, q):
    return v[min(len(v) - 1, int(len(v) * q))]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    found = list(candidates(*load(sys.argv[2:])))
    with open(sys.argv[1], "w") as f:
        for c in found:
            f.write(json.dumps(c) + "\n")
    print(f"{len(found)} candidates; ratio = cost / predicted, cost without fees (with base fees in brackets)")
    print("coin         cohort  n    p10    p25    median")
    for coin in sorted({c["coin"] for c in found}):
        for cohort, keep in (("strict", lambda c: not c["flags"]), ("loose", lambda c: True)):
            cs = [c for c in found if c["coin"] == coin and keep(c) and c["ratio"] is not None]
            if not cs:
                print(f"{coin:12} {cohort:6}  0")
                continue
            r = sorted(c["ratio"] for c in cs)
            rf = sorted((c["cost"] + c["taker_notional"] * TAKER_FEE + c["maker_notional"] * MAKER_FEE) / c["predicted"] for c in cs)
            print(f"{coin:12} {cohort:6} {len(r):3} " + " ".join(f"{pct(r, q):6.2f} [{pct(rf, q):.2f}]" for q in (.1, .25, .5)))


main()

"""Replay Papertrade's 229 closed positions under the launch-pool rules (docs/c-launch-pool-design.md).

    python3 -I replay_c.py positions.json eth-oracle.json

eth-oracle.json: HL's ETH oracle from the validators' SetGlobalAction in the public explorer
blocks, one row per update: [block_time, height, oracle, second px].

Rules, each adding to the one before:
  R0  Papertrade: settle at HL's BBO mid when the tx lands (the recorded entry/exit).
  R1  settle at HL's oracle at the same moment instead.
  R2  two-step: settle at the first oracle update after the request.
  R3  tripwire: refuse the close when the BBO mid is more than 15 bp from the oracle.
  R4  ExposureBudget: notional per minute capped at $3.3M.
PnL is notional * price change for each rule, so the rules compare like with like; Papertrade's
own raw PnL is about 2.5% lower and its haircut takes about a third more (both shown).
"""
import bisect, collections, datetime, json, sys

TRIPWIRE_BPS = 15
CAP_PER_MIN = 3_333_333  # ExposureBudget.safeCap($10K, 10 bp, 3)

positions = [p for p in json.load(open(sys.argv[1])) if p["close"] and p["open"]["instrument"] == 1]
rows = json.load(open(sys.argv[2]))["rows"]
ts = [datetime.datetime.fromisoformat(r[0][:26]).replace(tzinfo=datetime.timezone.utc).timestamp() for r in rows]
px = [float(r[2]) for r in rows]


def at(t):  # oracle in force at t
    return px[bisect.bisect_right(ts, t) - 1]


def after(t):  # first oracle update strictly after t
    i = bisect.bisect_right(ts, t)
    return px[i], ts[i]


def pnl(p, entry, exit):
    o = p["open"]
    n = o["margin"] * o["leverage"]
    return n * (exit / entry - 1) * (1 if o["side"] == "long" else -1)


tot = collections.Counter()
gap_at_close, refused = [], 0
per_min = collections.defaultdict(float)
for p in positions:
    o, c = p["open"], p["close"]
    # EVM block timestamps are whole seconds; take the end of that second as "the moment".
    t_open, t_close = o["t"] + 1, c["t"] + 1
    tot["papertrade_raw"] += c["raw_pnl"]
    tot["papertrade_after_haircut"] += c["pnl"]
    tot["R0"] += pnl(p, o["entry"], c["exit"])
    tot["R1"] += pnl(p, at(t_open), at(t_close))
    e2, _ = after(t_open)
    x2, _ = after(t_close)
    r2 = pnl(p, e2, x2)
    tot["R2"] += r2
    gap = abs(c["exit"] / at(t_close) - 1) * 1e4
    gap_at_close.append(gap)
    if gap > TRIPWIRE_BPS:
        refused += 1  # close refused; the position stays open and settles later at the oracle
    tot["R3"] += r2  # R3 only refuses closes; settlement is already the oracle
    per_min[c["t"] // 60] += o["margin"] * o["leverage"]
    tot["notional"] += o["margin"] * o["leverage"]

edge = tot["R0"] / tot["notional"]  # what Papertrade's rules paid per $ of notional
minutes = len(per_min)
r4_max = edge * CAP_PER_MIN * minutes

print(f"{len(positions)} ETH positions, notional ${tot['notional']:,.0f}, closed across {minutes} distinct minutes")
print(f"Papertrade recorded: raw ${tot['papertrade_raw']:,.0f}, after haircut ${tot['papertrade_after_haircut']:,.0f}")
for k in ("R0", "R1", "R2"):
    print(f"{k}: ${tot[k]:,.0f}")
gap_at_close.sort()
print(f"R3: BBO mid vs oracle at close: median {gap_at_close[len(gap_at_close)//2]:.1f} bp, max {gap_at_close[-1]:.1f} bp; "
      f"{refused}/{len(positions)} closes over {TRIPWIRE_BPS} bp refused")
print(f"R4: at R0's edge ({edge*1e4:.2f} bp of notional), ${CAP_PER_MIN:,}/min over {minutes} minutes caps the take at ${r4_max:,.0f}")

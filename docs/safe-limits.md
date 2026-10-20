# Reading Hyperliquid prices safely on HyperEVM

For contracts that settle, liquidate or mint against HyperCore prices. Every rule below has a
case or a measurement behind it; where a number is a first estimate, it says so.

## 1. Settle on the oracle, and do not expect it to be enough
| Precompile | Who moves it | What it costs to move |
|---|---|---|
| `0x80e` BBO | anyone with market orders | the spread and the book's depth, for as long as you hold it |
| `0x806` mark | partly the HL book | less than the oracle, more than the BBO |
| `0x807` oracle, core perps | validators, from external venues | more than the BBO, but on ETH a push on HL reached it (below) |
| `0x807` oracle, HIP-3 perps | **the market's deployer** | one key |

Papertrade (cases/papertrade-20261010) settled at the BBO mid. About $10K on Hyperliquid
moved ETH's mid about 10 bp for a minute, and each $10M position on Papertrade paid $7–9K for
it: $130,873 spent, $1,407,332 taken, 10.8 to 1.

Replaying the same 228 positions against HL's oracle (validators' `SetGlobalAction`, from the
L1 explorer blocks) changes less than expected:

| settle at | take (notional x price move) |
|---|---|
| BBO mid, as Papertrade did | $2,052,046 |
| oracle at the same moment | $1,738,919 (-15%) |
| oracle, first update after the request (two-step) | $1,664,799 (-19%) |

The oracle moved with the push. In 16 of 18 rounds Binance's ETHUSDT moved the same way by
almost the same amount (21:41: mid 16.3 bp, oracle 12.7 bp, Binance 12.9 bp), and the timing
follows the attacker's HL orders: $1.25M sells from 68 s to 106 s while Binance fell 13 bp, then
a $2.61M buy-back right after the close, with Binance rebounding in the same second. Either the
push on HL spread to other venues through arbitrage, or the attacker also traded elsewhere; the
public HL data cannot tell which. Either way, for ETH on HL, "the oracle comes from outside
venues" did not stop a one-minute push.

`HLPriceGuard.read` still returns the oracle: it removes the part of the move that stays on HL,
and for most assets the outside venues are harder to reach than HL's book. But what stopped
Papertrade on replay is the exposure cap (section 4), not the choice of price.

## 2. Use the cheap prices as tripwires
`HLPriceGuard.Bounds` rejects a read when:
- the book is empty or crossed;
- the spread is wider than `maxSpreadBps`;
- the mark is more than `maxMarkOracleBps` from the oracle;
- the BBO mid is more than `maxMidOracleBps` from the oracle.

A tripwire only sees the gap between the book and the oracle, and it has to sit above normal
noise: over a full US session ETH's mid drifted up to 11.4 bp from the oracle (below), so a bound
at 2x is about 25 bp. On Papertrade even 15 bp would have caught nothing: because the oracle
followed the push, the gap at close was 5.8 bp at the median and 10.2 bp at most. Bounds limit how far the price can be
pushed unnoticed; section 4 limits how much that push can be worth. You need both.

### Normal gaps (one US session)
Sampled every 10 s, `measure/normal_gaps.py`, through the US session of Monday 2026-10-19,
13:25–20:05 UTC (the stock market opened at 13:30 and closed at 20:00 UTC): 2,361 samples per
asset, none failed, run on GitHub Actions (`.github/workflows/measure-us-session.yml`). In bp,
max (p99); the last column is the opening hour, 13:30–14:30 UTC (data:
`measure/normal-gaps-20261019.json`; `measure/session_tables.py` re-prints this table):

| asset | mark–oracle | mid–oracle | spread | mid–oracle, opening hour |
|---|---|---|---|---|
| BTC | 7.2 (4.6) | 8.6 (6.0) | 2.6 (0.6) | 8.6 (7.9) |
| ETH | 10.8 (5.8) | 11.4 (8.5) | 2.9 (1.7) | 11.1 (10.2) |
| SOL | 9.1 (6.7) | 13.5 (9.1) | 5.7 (1.9) | 13.5 (10.1) |
| HYPE | 13.0 (7.9) | 19.0 (11.7) | 6.1 (1.7) | 18.8 (16.0) |
| xyz:TSLA | 7.8 (6.1) | 38.5 (12.6) | 9.2 (2.8) | 38.5 (21.5) |

The opening hour is the noisiest: mid–oracle p99 is higher there for every asset, and xyz:TSLA's
38.5 bp came 15 s after the open (outside that hour its max was 15.6 bp). Every maximum is above
the first, quiet sample (2026-10-16 22:50–23:00 UTC, 99 samples: ETH mid–oracle 7.2 bp, TSLA
7.5 bp). This is one session: weekends and volatile days are still unmeasured.

Set each bound well above its normal maximum (2–3x) so normal trading does not trip it, and
re-measure for every asset you list.

## 3. Check the oracle itself against something outside Hyperliquid
Tripwires compare HL prices with each other. If the oracle itself is wrong, they agree with it.
That is the HIP-3 case: one deployer posts the oracle.

**Independent reference (`Ref`, `maxRefOracleBps`).** Pyth runs on HyperEVM at
`0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc`, but it is pull-based. On 2026-10-17 the stored
ETH/USD was 7.5 hours old and TSLA/USD 3.5 months old. Have the caller push a fresh update in
the same transaction (`PythRef.updateAndRead`) and keep `maxAge` to seconds. A reference that
nobody updates passes every check with a stale price, so the staleness check matters as much as
the deviation check.

The update data comes from Pyth's Hermes service, which needs an API key: on 2026-10-19 Hermes
and every keyless mirror we tried answered 401. Budget for a key before relying on `PythRef`.
On HyperEVM testnet Pyth is at `0x2880aB155794e7179c9eE2e38200202908C17B43` and the update fee
was 0.

For stocks, the reference stops at the close while the HL oracle keeps moving. Our operations
repo (hip3-ops, not yet public, so these numbers cannot be rerun from here) measured this on xyz
markets: in trading hours the gap to RedStone reached 76 bp (p99 9.6 bp); out of
hours it reached 484 bp. A first estimate is 150 bp in trading hours and no deviation check out
of hours. US trading hours are not yet measured.

**Jumps (`JumpLatch`).** Keep the last accepted oracle as an anchor and reject any read more
than `maxJumpBps` from it. On xyz the deployer's oracle moved at most 66 bp within 90 s in the
hip3-ops sample, so 200 bp is a first estimate.

The anchor must not move on a rejected read. SK Hynix (2026-07-27, cases/skhx-20260727) shows
why. The first bad update took the oracle from $1,131.40 to $954.99 in 3.2 s, 2.7 s before the
first liquidation; after that it walked down to $870 in -100 bp steps, each small enough to pass
a check against the previous read. Replaying all 144 updates at 200 bp:

| stored price | accepted | accepted below $1,000 |
|---|---|---|
| previous read | 142 / 144 | 39, down to $870.12 |
| last accepted, forgotten after 90 s | 84 / 144 | 10, down to $872.52 |
| last accepted, kept (the latch) | 100 / 144 | 0 |

With the latch, reads paused from 23:00:03.9 and resumed at 23:02:15.7, once the oracle was back
within 200 bp of $1,131.40. A real gap (a stock opening 5% higher after a weekend) also trips
the latch and keeps it tripped; `rearm` moves the anchor, and should only be called once an
independent reference agrees, or by governance.

**Past precompile values cannot be read back.** The public HyperEVM RPC ignores the block
number for precompile calls: `eth_call` to `0x807` at a block from 10-10 returns today's
price. Audits and replays need the L1 data: validators' `SetGlobalAction` for core perps and
deployers' `setOracle` for HIP-3, in the explorer blocks of `s3://hl-mainnet-node-data`.

## 4. Cap what one push can be worth
If moving the price by `d` bp for one window costs `C`, an exposure `E` settled in that window
pays `E * d / 10000`. Keep it below the cost with a margin `k`:

    E_max = C * 10000 / (d * k)          // ExposureBudget.safeCap

The attacker picks `d`, and the tripwire may not limit it (on Papertrade the oracle moved with
the book), so take the smallest `C(d) / d` over the moves you have measured. Papertrade gives one
point for ETH: `C` about $10K at `d` = 10 bp. With `k` = 3 that is **E_max of about $3.3M per
minute**. Papertrade's per-side open-interest caps were current OI plus about $1B, about 300
times that.

On replay this is the rule that matters. Papertrade's positions earned 9.18 bp of notional on
average; at $3.3M per minute over the 18 minutes in which they closed, that is about $55,101,
against the $130,873 the attacker spent on HL. This is a scenario estimate, not a bound: it
assumes the capped settlements earn the incident's average edge, while an attacker would pick
the best moments, and it assumes pushes cost what Papertrade's did (shorter pushes may cost
less; see below). Under those assumptions the attack would not have paid.

Use `ExposureBudget.Rolling`: no stretch of `windowSecs` ever settles more than the cap (after
a lowering, more than the largest cap in force during that stretch). It
splits the window into 6 slices and counts the current one plus the 6 before it, so it is
conservative by under one slice (after a full-cap burst on a 60 s window, the next full burst
waits up to 70 s). The cap and window are fixed on first use: changing either mid-life would let
more than the cap through, so `reconfigure` lowers the cap at once for new spends (what already
settled stays counted, so a stretch spanning the change is bounded by the old, higher cap) and
otherwise waits until nothing settled under the old settings is inside either window.

The older `ExposureBudget.Window` resets at fixed times, so up to `2 * cap` can settle across a
reset, halving the margin `k`. It stays for existing users.

**What `C` assumes: a push held for about a minute.** Papertrade's attacker opened, pushed and
closed in rounds of about a minute, and `C` is what those rounds cost. A settlement that reads
one instant (a close, a liquidation, a batch) only needs the price moved at that instant. A
shorter push may cost less than `C` (unmeasured: the spread, fees and trading cost of the push
and unwind remain), and if the application offers several independently timed
settlements, each can ride its own short push: the rolling cap limits their total, not how long
each push must last. For such settlements the cap above is too loose by an amount we have not
measured. A single price read after an irrevocable request helps little if the read time is
predictable, since a short push can be timed to it (in the Papertrade replay no oracle update was
more than 8.1 s after the previous one). A price averaged over a window that starts after the
request does make the push last that long; measure `C` for that window before relying on it.

### Measuring `C` per asset
Papertrade's per-round costs (`cases/papertrade-20261010/calibrate_cost.py`, against HL's archived
ETH book at the time) came to 0.27 of what static book depth predicts. The archived book is in HL's
requester-pays S3 bucket (the script's docstring gives the paths) and is not redistributed here, so
rerunning it needs your own AWS account. Why the ratio is below 1 is a hypothesis, not measured:
the book refilling, and the move spreading to other venues. So, as a first estimate,

    C(10 bp) ~= 0.27 * depth10 * 10 / 10000      cap per minute ~= 0.27 * depth10 / k

where `depth10` is the notional within 10 bp of the mid on the thinner side. On 10-10 ETH's
depth10 was about $14M, giving $1.3M per minute at `k` = 3; the $3.3M above, from the whole
episode's cost, is the looser of the two estimates.

0.27 rests on one incident on one asset, and a first attempt at a second point (2026-10-17) did
not produce one: HL's archived book has a snapshot only every ~5 s, too sparse to see a sweep's
impact, and an average price-impact fit over all trades measures something other than what a
push costs. The next step is to collect real push-and-unwind round trips by single wallets and
measure what they cost. `measure/round_trips_collect.py` records HL trades (which name both
wallets), every change of the best bid/offer and the book; `measure/round_trips.py` keeps a narrow
cohort: a wallet quiet for 10 minutes sweeps one way as taker, moves the mid at least 5 bp, and is
back to within 5% of flat 20 to 120 s later. Its cost is cash, without fees (not public), against
the same depth prediction as Papertrade's. Such wallets may be informed, hedged elsewhere or lucky,
which pulls the ratio down for reasons that are not cheap manipulation; read the strict cohort's
spread per asset, not its low tail, before replacing 0.27.

First result: the collector ran 10 times between 2026-10-17 and 10-20 (about 325 minutes each,
on GitHub Actions). It found 27 candidates and no strict one. 24 were `small` (the wallet's own
taker notional was under a quarter of what the move needed: someone else moved the price), 24
`extrapolated` and 20 `hold` (unwound in under 20 s or over 120 s); most carry several flags.
Single wallets pushing and unwinding within a minute may be rare outside an attack; if a few weeks
give no strict round trip, the approach needs rethinking, and 0.27 stays one incident's number.

`measure/safe_caps.py` samples depth10 every 30 s and uses its p10, since a push picks a thin
moment. Measured through the same US session as the normal gaps, 2026-10-19 13:25–20:05 UTC, 802
sweeps for each asset except xyz:GOLD (801, one failed request). The opening hour is 13:30–14:30 UTC; the last
column is the first run, 29 sweeps on Friday 2026-10-16 23:22–23:40 UTC, after the US close
(data: `measure/safe-caps-20261019.json` and `measure/safe-caps-20261017.json`):

| asset | depth10 p10 | cap per minute (k = 3) | in the opening hour | 2026-10-16 evening |
|---|---|---|---|---|
| BTC | $18.75M | $1.69M | $1.60M | $1.86M |
| xyz:SP500 | $4.32M | $0.39M | $0.35M | $0.10M |
| xyz:XYZ100 | $3.86M | $0.35M | $0.28M | $0.12M |
| ETH | $3.30M | $0.30M | $0.21M | $0.33M |
| xyz:CL | $2.34M | $0.21M | $0.20M | $0.04M |
| xyz:SPCX | $1.73M | $0.16M | $0.06M | $0.08M |
| SOL | $1.39M | $0.13M | $0.09M | $0.12M |
| xyz:GOLD | $1.05M | $0.09M | $0.08M | $0.05M |
| xyz:TSLA | $0.60M | $0.05M | $0.04M | $0.03M |
| xyz:NVDA | $0.48M | $0.04M | $0.04M | $0.02M |
| HYPE | $0.38M | $0.03M | $0.04M | $0.04M |
| xyz:SKHX | $0.24M | $0.02M | $0.03M | $0.02M |
| xyz:SMSN | $0.04M | under $0.01M | under $0.01M | under $0.01M |
| xyz:KORU | $0.02M | under $0.01M | under $0.01M | under $0.01M |

In US hours xyz:XYZ100, xyz:SP500 and xyz:CL were about 3 to 5 times deeper than on Friday
evening; the other xyz books were up to about 2 times deeper or unchanged, and crypto about the same. The opening hour is thinner for most assets (ETH $0.21M,
xyz:SPCX $0.06M). Single sweeps go far lower than p10: at 14:46:30 UTC the ask side within 10 bp
was $3.46M for BTC and $0.03M for SOL, in the same sweep. A cap from p10 assumes a push is not
timed to such a moment.

xyz:SKHX carried $376M of open interest on 2026-07-27 (the incident day) against a safe settlement
rate of about $16K a minute from the Friday-evening book (about $22K in US hours). Anything settling against these prices at Papertrade's sizes is
far outside the safe range.

**For xyz markets these caps cover the book, not the oracle.** They bound what a push on the HL
book is worth, which matters for anything that reads the BBO or mark, or whose checks lean on
them. A HIP-3 oracle is posted by the deployer, and whoever holds that key can post any value:
that is not a cost an attacker pays, and no book-derived cap offsets it. Settle on a HIP-3 oracle
only while a fresh independent reference agrees with it (section 3); when none can be fresh, as
for stocks out of hours, pause price-sensitive settlement or fall back to an explicitly governed
rule. The cap then limits only what a book push adds on top.

## 5. Liquidations, prices at a set time, testnet
Learned from apps built on this library (psyto/hyperevm-lend, psyto/hyperevm-perp and others).

**Liquidations: behind the checks or not.** Both choices cost something.
- Behind `read`: a pushed or one-sided book stops liquidations while it lasts. If the position
  keeps losing meanwhile, a late liquidation can leave a debt (a lending market, or a perp that
  pays a liquidation bonus).
- Outside the checks, with `lenientPrice`: of the oracle and the mark, the one that favours the
  position (the higher for a long or for collateral, the lower for a short). A move against the
  position counts only once both feeds show it, so one feed moving alone liquidates no one, and
  a wide or empty book does not block it. But a real move that one feed lags also waits, and the
  mark follows the book: the position's owner (or anyone) can hold a liquidation back by pushing
  the book its way, for as long as they pay to hold the push. Either can leave a debt. And
  whoever can move both feeds can liquidate at their price: a HIP-3 deployer, or a push that
  reaches the oracle (it did for ETH, section 1).
- Day One keeps liquidations behind the checks: its losses stop at the margin, so waiting leaves
  no debt. hyperevm-lend and hyperevm-perp use the lenient price, although there a late
  liquidation can lose more than the collateral and the lenders or the pool pay for it. Neither
  path is free of delay. Section 4's push cost says what moving a price for a minute costs, not
  how long someone will keep paying to hold off a liquidation, so it gives no margin bound; the
  margin has to cover a stress move chosen for the asset plus the liquidation delay, and we have
  not measured either. Neither has a jump latch on that path; on HIP-3 add one, or the
  deployer's key is the liquidation price.

**Prices at a set time.** `read`, `oracleOnly` and `lenientPrice` return the price at the moment
of the call, and the caller picks that moment. When a price at a set time decides who gets paid
(an expiry, a race, a knock-out), anyone who may call can wait for a better block, or not call at
all. Take that price from an observation no one chooses, such as Pyth's
`parsePriceFeedUpdatesUnique` (the first update after the time), which anyone can submit later.

**Raw reads return 0.** `HLPrecompiles.oracle` and `mark` return 0 as a price. `read` rejects a
0 oracle always, and a 0 mark only through the mark–oracle bound (with that bound at 0 it ignores
the mark). `oracleOnly` reverts with `NoPrice` on a 0 oracle, `lenientPrice` on either. Code that
reads the precompiles directly must check for 0 itself.

**Testnet prices are not usable for the checks.** On HyperEVM testnet the HYPE perp's mark sat
far from its oracle: 2,797 bp on 2026-10-18 (oracle 40.48, mark 51.80, book 42.5 to 58.5) and
2,678 bp on 2026-10-19, while BTC (index 3) was within 9 bp. HyperCore's lending reserve
(`0x812`) priced HYPE at the mark, not the oracle. Test the checks on BTC, or with bounds set to 0.

**Spot.** This library reads perps only. `0x80e` also answers for spot, with the order asset ID
`10000 + spot index` (seen on testnet in psyto/hyperevm-amm); `bboIndex` does not produce it.

## 6. Checklist
- [ ] Settlement, liquidation and minting read `0x807`, not `0x80e`.
- [ ] HIP-3 assets use both encodings: `dex * 10000 + i` for `0x806`/`0x807`/`0x80a`,
      `100000 + dex * 10000 + i` for `0x80e`.
- [ ] Spread, mark–oracle and mid–oracle bounds are set at 2–3x their measured normal maximum.
- [ ] HIP-3 assets also have an independent reference updated in the same transaction, and a
      jump check; settlement pauses whenever that reference cannot be fresh (stocks out of hours).
- [ ] Notional settled per window is capped at `C * 10000 / (d * k)`, with `C` measured for the
      asset, using `ExposureBudget.Rolling` (a fixed window lets `2 * cap` through).
- [ ] If settlement reads a single instant, the cap may be too loose: use a smaller cap, or settle
      on a price averaged over a window that starts after an irrevocable request, with `C`
      measured for that window.
- [ ] What happens on a rejection is decided: revert, pause the market, or let only
      position-reducing actions through.
- [ ] Liquidations are either behind the checks or on `lenientPrice`, chosen for whether a late
      liquidation can leave a debt (section 5); on HIP-3, not on the deployer's oracle alone.
- [ ] A price at a set time comes from an observation no caller chooses, not from a read at the
      time of the call.
- [ ] Every direct `HLPrecompiles` read checks for 0, and `szDecimals` is at most 6.
- [ ] A Hermes API key is arranged before `PythRef` is relied on.

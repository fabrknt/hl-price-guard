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
noise: ETH's mid already drifts up to 7.2 bp from the oracle (below), so a bound at 2x is about
15 bp. On Papertrade it would have caught nothing: because the oracle followed the push, the gap
at close was 5.8 bp at the median and 10.2 bp at most. Bounds limit how far the price can be
pushed unnoticed; section 4 limits how much that push can be worth. You need both.

### Normal gaps (first sample)
Sampled every 5 s for 10 minutes, 2026-10-17 (a Saturday, so crypto books are thin-ish and
TSLA is out of US hours), `measure/normal_gaps.py`, 99 samples per asset. Max in bp:

| asset | mark–oracle | mid–oracle | spread |
|---|---|---|---|
| BTC | 3.1 | 3.1 | 0.1 |
| ETH | 5.6 | 7.2 | 0.4 |
| SOL | 6.2 | 6.7 | 1.0 |
| HYPE | 5.2 | 6.6 | 0.4 |
| xyz:TSLA | 2.6 | 7.5 | 1.7 |

Ten minutes on a weekend is a first look, not a basis for production bounds: re-measure across
weekdays, US hours and volatile sessions.

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

For stocks, the reference stops at the close while the HL oracle keeps moving. hip3-ops measured
this on xyz markets: in trading hours the gap to RedStone reached 76 bp (p99 9.6 bp); out of
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
average; at $3.3M per minute over the 18 minutes in which they closed, that is at most $55,101,
against the $130,873 the attacker spent on HL. The attack stops paying.

`ExposureBudget.spend` enforces the cap per fixed window. Because the window resets, up to
`2 * cap` can settle across a boundary; size the cap with that in mind.

### Measuring `C` per asset
Papertrade's per-round costs (`cases/papertrade-20261010/calibrate_cost.py`, against HL's archived
ETH book at the time) came to 0.27 of what static book depth predicts: the book refills, and the
move spread to other venues. So, as a first estimate,

    C(10 bp) ~= 0.27 * depth10 * 10 / 10000      cap per minute ~= 0.27 * depth10 / k

where `depth10` is the notional within 10 bp of the mid on the thinner side. On 10-10 ETH's
depth10 was about $14M, giving $1.3M per minute at `k` = 3; the $3.3M above, from the whole
episode's cost, is the looser of the two estimates.

`measure/safe_caps.py` samples depth10 every 30 s and uses its p10, since a push picks a thin
moment. First run, 15 minutes on Saturday 2026-10-17 (US stocks closed, so the xyz books are at
their weekend depth; re-measure in US hours and on weekdays):

| asset | depth10 p10 | cap per minute (k = 3) |
|---|---|---|
| BTC | $20.7M | $1.86M |
| ETH | $3.7M | $0.33M |
| SOL | $1.3M | $0.12M |
| HYPE | $0.42M | $0.04M |
| xyz:XYZ100 | $1.3M | $0.12M |
| xyz:SP500 | $1.1M | $0.10M |
| xyz:SPCX | $0.88M | $0.08M |
| xyz:GOLD | $0.50M | $0.05M |
| xyz:CL | $0.45M | $0.04M |
| xyz:TSLA | $0.32M | $0.03M |
| xyz:NVDA | $0.24M | $0.02M |
| xyz:SKHX | $0.17M | $0.02M |
| xyz:SMSN | $0.03M | under $0.01M |
| xyz:KORU | $0.01M | under $0.01M |

xyz:SKHX carried $376M of open interest that day against a safe settlement rate of about $20K a
minute. Anything settling against these prices at Papertrade's sizes is far outside the safe
range.

## 5. Checklist
- [ ] Settlement, liquidation and minting read `0x807`, not `0x80e`.
- [ ] HIP-3 assets use both encodings: `dex * 10000 + i` for `0x806`/`0x807`/`0x80a`,
      `100000 + dex * 10000 + i` for `0x80e`.
- [ ] Spread, mark–oracle and mid–oracle bounds are set at 2–3x their measured normal maximum.
- [ ] HIP-3 assets also have an independent reference updated in the same transaction, and a
      jump check.
- [ ] Notional settled per window is capped at `C * 10000 / (d * k)`, with `C` measured for the
      asset.
- [ ] What happens on a rejection is decided: revert, pause the market, or let only
      position-reducing actions through.

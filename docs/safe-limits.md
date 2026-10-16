# Reading Hyperliquid prices safely on HyperEVM

For contracts that settle, liquidate or mint against HyperCore prices. Every rule below has a
case or a measurement behind it; where a number is a first estimate, it says so.

## 1. Settle on the oracle, never on the BBO
| Precompile | Who moves it | What it costs to move |
|---|---|---|
| `0x80e` BBO | anyone with market orders | the spread and the book's depth, for as long as you hold it |
| `0x806` mark | partly the HL book | less than the oracle, more than the BBO |
| `0x807` oracle, core perps | validators, from external venues | moving several outside venues at once |
| `0x807` oracle, HIP-3 perps | **the market's deployer** | one key |

Papertrade (cases/papertrade-20261010) settled at the BBO mid. About $10K on Hyperliquid
moved ETH's mid about 10 bp for a minute, and each $10M position on Papertrade paid $7–9K for
it: $130,873 spent, $1,407,332 taken, 10.8 to 1.

`HLPriceGuard.read` always returns the oracle. The BBO and mark are read only to notice a
pushed book.

## 2. Use the cheap prices as tripwires
`HLPriceGuard.Bounds` rejects a read when:
- the book is empty or crossed;
- the spread is wider than `maxSpreadBps`;
- the mark is more than `maxMarkOracleBps` from the oracle;
- the BBO mid is more than `maxMidOracleBps` from the oracle.

A tripwire only stops a push bigger than its bound, and the bound has to sit above normal
noise. ETH's mid already drifts up to 7.2 bp from the oracle (below), so a bound at 2x is about
15 bp: it would have stopped Papertrade's 16 bp rounds and none of the 5–14 bp ones. Bounds limit how far the price can be
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

**Jumps (`checkJump`).** Store the price at each read and reject a move larger than
`maxJumpBps` since the last one. On xyz the deployer's oracle moved at most 66 bp within 90 s
in the hip3-ops sample. At 200 bp, `checkJump` would have rejected SK Hynix's first bad update
(2026-07-27 23:00:03.946 UTC, $1,131.40 to $954.99 in 3.2 s), 2.7 s before the first
liquidation. It only compares consecutive reads within `window`: an update that arrives after a
long quiet spell is not compared with anything.

## 4. Cap what one push can be worth
If moving the price by `d` bp for one window costs `C`, an exposure `E` settled in that window
pays `E * d / 10000`. Keep it below the cost with a margin `k`:

    E_max = C * 10000 / (d * k)          // ExposureBudget.safeCap

The attacker picks any `d` up to your tripwire bound, so take the smallest `C(d) / d` over that
range. Papertrade gives one measured point for ETH: `C` about $10K at `d` = 10 bp. With `k` = 3
that is **E_max of about $3.3M per minute**. Papertrade's
per-side open-interest caps were current OI plus about $1B, about 300 times that.

`ExposureBudget.spend` enforces the cap per fixed window. Because the window resets, up to
`2 * cap` can settle across a boundary; size the cap with that in mind.

`C` differs by asset and by hour: thin books are cheap to move. It should be measured per asset
(planned under `measure/`) rather than copied from ETH.

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

# Stock perps out of hours: how far trade.xyz's price is from the next open

A contract that settles on a HIP-3 stock perp has to decide what that price is worth while the
stock does not trade. A related question, whether prices are reliable when the underlying cash
market is closed, is in the CFTC's 2026-06-25
[request for comment](https://www.cftc.gov/media/14256/RFC_ExtSFC-24-7TradingPerpetualContractsEnergyMarkets/download)
on 24/7 futures and perpetuals, which concerns energy commodities rather than stocks. This note measures it for trade.xyz (`xyz`),
the largest HIP-3 deployer, over 29 US-listed stocks and ETFs from 2026-05-06 to 2026-11-22:
3,661 ticker gaps between two regular sessions (138 reopening dates), of which 641 ticker-weekend
sessions and 99 holiday or long-weekend sessions (28 reopening dates).

`measure/offhours_gaps.py` prints the numbers below (sections 1–7 of its output, by gap type;
the prose names which type it quotes);
`measure/offhours-gaps-result.json` has one row per gap. Hyperliquid serves only the latest 5,000
hourly candles, so the window can be refetched only for a few days after 2026-11-23; after that
the result file is the record.

## What xyz does out of hours
From trade.xyz's docs (read 2026-11-23):
- When external prices exist, the oracle is the "externally-derived fair price"
  ([oracle price](https://docs.trade.xyz/perpetuals/mechanics/oracle-price)).
- From Friday 20:00 to Sunday 20:05 ET, and on US market holidays, an internal session runs: the
  oracle starts from the last external price and moves by a 30-minute EMA of the impact-price
  difference on xyz's own book
  ([session hours](https://docs.trade.xyz/perpetuals/changelog/equities-internal-session-hours)).
- The mark (median of the oracle, the oracle plus a 150 s EMA of mid minus oracle, and the median
  of bid, ask and last trade) is what liquidates
  ([mark price](https://docs.trade.xyz/perpetuals/mechanics/mark-price)).
- Discovery bounds keep the mark within ±1/max leverage of a reference that starts at the last
  external close and can re-anchor per direction, until it becomes a hard cap
  ([discovery bounds](https://docs.trade.xyz/perpetuals/mechanics/discovery-bounds)).

So during the internal session the price is made on xyz's own book. From 20:00 ET on Sunday to
the open, overnight ATS and pre-market prices exist again.

## Method
For each gap, with `C` the previous official close and `O` the next official open (Yahoo daily
bars, regular session), each price is compared with `O` as `|price / O - 1|`:

| name | what it is |
|---|---|
| `P_pre` | the perp's close of the last hourly bar ending at least 30 min before the open |
| `P_dark` | weekends and holidays: the perp at 20:00 ET the evening before the open, the end of the internal session |
| excursion | how far the perp went from `C` during the internal session (20:00 ET after the close to 20:00 ET before the open) |
| beyond both | how far the perp went past both `C` and `O` (outside the range between them), over the same hours |

Excursions are given from hourly closes and from hourly highs and lows. A single trade sets a high
or low, and sets a close only if it is the hour's last. The perp price is the traded price (HL
hourly candles), not the oracle or the mark: the API keeps no oracle history. One ticker was
dropped: SNDK's perp was 700% from the stock's close in the median, so it is not the same
instrument at the same scale.

## Results
**1. At the end of a weekend, the perp's price is little closer to Monday's open than Friday's
close.** Over the 641 ticker-weekend sessions, the perp at 20:00 ET on Sunday was closer to the open than the
Friday close in 352 (54.9%). Its median distance from the open was 1.14% against 1.35% for the
close, p95 5.8% against 6.7%. With holidays, 410 of 740 (55.4%).

**2. It moves away from both while only its own book trades.** Over the 641 ticker-weekend
internal sessions:

| | median | p95 | max |
|---|---|---|---|
| excursion from `C`, hourly closes | 1.38% | 5.1% | 14.2% |
| beyond both `C` and `O`, hourly closes | 0.82% | 3.3% | 8.7% |
| beyond both `C` and `O`, highs and lows | 1.01% | 4.2% | 10.1% |

In 103 of the 641 an hourly close of the perp's trades went more than 2% past both the Friday
close and the Monday open; in 7, more than 5%. The two endpoints do not say what the stock was
worth in between, and these are traded prices: whether the oracle or the mark, and so any
liquidation, went there too is not measured.

**3. Close to the open, it is close.** Thirty minutes before the open, after the overnight ATS and
pre-market have traded, the perp was within 0.36% of the open in the median over weeknights
(p95 1.5%) and 0.34% over weekends (p95 1.4%), closer than the previous close in 82% of
weeknights and 83% of weekends. That is agreement near the open,
not evidence that the night before was safe: over whole weeknight gaps the perp still went past
both `C` and `O` by 0.92% in the median (p95 3.6%).

**4. Crypto-linked businesses move more, and are not better predicted.** For MSTR, COIN, CRCL,
HOOD, IREN and STRC, the weekend perp was closer to the open than the close in 72 of 127
ticker-weekend sessions (56.7%), against 280 of 514 (54.5%) for the rest; its median excursion from the close was 2.0%,
against 1.2%.

**5. Several moves passed 1/max leverage.** With max leverage as of 2026-11-23, 8 of 740 internal
sessions had a high or low further from the close than 1/max leverage. Four fell on the weekend of
2026-11-14/15, when crypto fell: MSTR 14.7%, CRCL 12.3%, KORU 11.6% and COIN 11.0% (10x, so 10%).
The others are MRVL (June, 13.3%), NBIS (August, 10.1%) and EWY twice (6.8% and 5.1%; 20x, so
5%). These are traded prices against the official close, not the mark against xyz's reference,
which can re-anchor; they illustrate the size of the moves and do not test the bound.

## For a contract that reads these prices
How often the perp's traded price stayed within a fixed band around the previous regular-session
close (the Friday close on weekends) over the internal session, weekends and holidays together:

| band | hourly closes inside | highs and lows inside | reopening dates with a breach (closes / highs and lows, of 28) |
|---|---|---|---|
| ±3% | 587 / 740 | 547 / 740 | 27 / 28 |
| ±5% | 695 / 740 | 666 / 740 | 13 / 18 |
| ±8% | 729 / 740 | 721 / 740 | 6 / 10 |
| ±10% | 735 / 740 | 734 / 740 | 2 / 3 |

Section 4 of [safe-limits](safe-limits.md) already says to pause price-sensitive settlement when
no independent reference can be fresh, or fall back to a governed rule. These are historical
coverage figures for traded prices that can inform the width of that rule; they are not rates at
which a guard on the oracle would have refused, and no width here is shown to be enough. At ±5%,
an hourly close went outside the band in 45 of 740 ticker sessions, on 13 of the 28 reopening
dates.

`HLPriceGuard.read` applies such a band if the caller passes a `Ref` holding the previous close,
with a `maxAge` that runs from that close's timestamp to the end of the actual session (about
52 h for a normal weekend, more over a holiday: 100 h from the Thursday close of 2026-07-02 to
20:00 ET on Monday 07-06) and `maxRefOracleBps = 500` for ±5%. It compares the deployer's oracle, not the traded price measured here. It does not end the
band by itself: the same `Ref` keeps refusing a real move after outside prices return, and once
`maxAge` passes every read fails as `RefStale`. The caller has to switch the reference at the end
of the session (20:05 ET on Sunday, or the holiday's end) to a fresh outside price, or pause
until one exists. The ADR replay in `cases/skhx-20260727` is the same idea for a Korean stock.

## Limits
- Traded prices, not the oracle or the mark. On a thin book these differ, and the mark is what
  liquidates.
- Hourly bars. A spike shorter than an hour shows in the highs and lows, and in the close if the
  hour's last trade falls in it; an excursion of hourly closes does not show that a price held.
  The half hour before the open is left out of the excursions.
- 29 names, 200 days, one deployer. Korean names (SKHY, EWY, KORU) have a cash market in Seoul
  during US nights, so "no outside price" holds for them only on weekends.
- The internal session ends at 20:05 ET; this note uses 20:00 ET. Holidays are taken from the
  stock's own calendar; no NYSE early close fell in the window.
- The leverage figures are a snapshot of today's settings.
- Open interest and liquidations at these levels are not measured here.

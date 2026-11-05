# Anthropic's IPO, November 2026: four HIP-3 oracles change by rule

Written before the event. Anthropic made its S-1 public on 2026-10-26 and has filed S-1/A-1, which
still leaves the price range and share count blank. It plans to list Class A on Nasdaq as `ANT`. No
listing date is announced: press reports name the week of 11-16 or of 11-23, and trade.xyz lists
2026-11-20 "for reference only". This file says what each Hyperliquid market's own rules do to its
oracle on the way to the listing, so a contract reading these prices can tell a scheduled change
from a bad price. After the listing it will be replayed like the other cases.

## The markets (read 2026-11-05)

| market | unit | open interest | oracle before listing | at listing |
|---|---|---|---|---|
| `io:ANTH` (Entropy) | $1 = $1B of market cap | 62,563 (≈ $115M) | private-market aggregate (RedStone) blended with its own book, internal weight up to 95% | share price × fully diluted count ÷ 1,000,000,000, from the first official opening trade |
| `xyz:ANT` (trade.xyz) | 1 Class A share | 504,917 (≈ $59M) | internal: 30-minute EMA, ±50% discovery bound, 3 resets | converts to a standard XYZ equity perp once regular trading and external data are sufficient, "typically the first regular session" |
| `para:ANTH` (Paragon) | per share (≈ 117) | 714 | internal: EMA of impact price, τ 30 min (3 min in the listing window), ±10% bound | Listed status once the external feed passes its quality gate; until then the pre-listing EMA keeps running |
| `vntl:ANTHROPIC` (Ventuals) | — | 0 | delisted in June; oracle frozen at 1,618.9 | — |

Sources: Entropy [Pre-IPO Perpetuals](https://docs.entropy.io/market-types/pre-ipo-perpetuals),
trade.xyz [Pre-IPO specification index](https://docs.trade.xyz/perpetuals/specifications-and-schedules/pre-ipo-specification-index)
and [IPOPs](https://docs.trade.xyz/asset-directory/pre-ipo-perpetuals-ipops), Paragon
[Pre-Listing Pricing](https://docs.paragon.trade/markets/equities/pre-listing-pricing); open
interest and units from `metaAndAssetCtxs` per dex.

## Steps where the oracle moves by rule, not by trading

1. **S-1/A with a price range.** Entropy publishes an estimated fully diluted count. OKX said at
   listing that its contract (quoted on an estimated 1B, rebased to 10B on 2026-06-30) would
   rebase proportionally once an S-1 discloses the share count. Binance and Bitget quote on 1B.
   A rebase is value-neutral for the venue but is a step of up to ≈17× in its price.
2. **Three calendar days before the announced listing.** `io:ANTH`'s oracle becomes a 1-hour EMA
   of its own mark ("hyperp mode"). For those three days nothing outside its own book prices about
   $115M of open interest.
3. **The final IPO price.** Paragon "reserves the right to set the oracle price directly" to the
   offering price, as a reset that is "not constrained by the Bounds in effect"; its docs warn of
   immediate liquidations. On Binance, from the Final IPO Price until listing the mark is
   `(1 − w) × mean traded price + w × Final IPO Price`, with `w` rising to 0.95 over 24 h
   ([Clearing Procedure 51A.2](https://www.binance.com/en/about-legal/clearing-procedures)).
   OKX's rebase rule is in its [listing notice](https://www.okx.com/en-us/help/okx-to-list-pre-ipo-pre-market-perpetual-futures-for-spacex-usdt-openai-usdt-and-anthropic-usdt).
4. **The first opening trade on Nasdaq.** `io:ANTH` jumps from its hyperp EMA to
   `open price × count ÷ 1e9`. The count is fixed once, from the 424(b) prospectus if filed before
   the open (else the latest S-1/A): "Total Class A and Class N Common Stock (As-Converted, Fully
   Diluted)", without the underwriters' option. Analysts' readings of S-1/A-1 give about 16.9B
   and 17.3B; the 2.4% between them is the size of the step a wrong count would add.
5. **The first regular session with a good feed.** `xyz:ANT` and `para:ANTH` move to external
   equity oracles. Paragon says this may come after trading starts (opening auctions, volatility
   halts, provider onboarding).

## Where the prices stand

1-minute samples, 2026-11-04 07:25–22:17 UTC (122 with all three exchange quotes; the recorder
paused while the machine slept). Exchange median = median of Binance `ANTHROPICUSDT` mark, Bitget
`ANTHROPICUSDT` last, OKX `ANTHROPIC-USDT-SWAP` last × 10, each as $1 = $1B of market cap.

| | value |
|---|---|
| exchange median, last sample | 1,607.6 ($1.61T) |
| `io:ANTH` oracle above the exchange median | +10.1% to +17.3%, median +12.4% |
| `xyz:ANT` oracle | 116.81 per share: $1.97T at 16.9B shares; the exchange median implies 13.8B |

Before the count is known, the per-share markets and the market-cap markets cannot be compared
without choosing a count, and the choice moves the answer by more than the spread between venues.

## What this means for a contract that reads these oracles

- `HLPriceGuard.JumpLatch` trips at steps 3 and 4 by design and stays tripped: the oracle does not
  come back to the old anchor. Call `rearm` only once an independent price agrees with the new
  oracle: for `io:ANTH`, the Nasdaq `ANT` price × the published count ÷ 1e9; for `xyz:ANT` and
  `para:ANTH`, the Nasdaq price.
- During step 2 there is no independent price for `io:ANTH` at all. A reference check
  (`maxRefOracleBps`) has nothing to compare with; treat the market as unpriced rather than as
  priced by its own book.
- A step-1 rebase on an exchange quote used as a reference looks like a 90%+ crash. Read the
  venue's basis with the quote.

## Recording

prebell's `listing-watch` Worker reads the Hyperliquid markets, OKX and Bitget every minute from
2026-11-05 and logs oracle jumps, exchange rebases and markets that appear or disappear; its
status says where each step above stands (`https://prebell-listing-watch.meowna-server.workers.dev/`,
the record at `/samples.csv`). Binance answers 403 to Cloudflare, so Binance comes only from a
second recorder that started on 2026-11-04 and pauses while its machine sleeps. The replay after
the event will check each step above against what the oracles actually did.

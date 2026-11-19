# Anthropic's IPO, November 2026: four HIP-3 oracles change by rule

Written before the event. Anthropic made its S-1 public on 2026-10-26 and has filed S-1/A-1, which
still leaves the price range and share count blank. It plans to list Class A on Nasdaq as `ANT`. No
listing date is announced: press reports name the week of 11-16 or of 11-23, and trade.xyz lists
2026-11-20 "for reference only". This file says what each Hyperliquid market's own rules do to its
oracle on the way to the listing, so a contract reading these prices can tell a scheduled change
from a bad price. The listing came on 2026-11-19; "What happened" replays it.

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

## So far (read 2026-11-15 03:00 UTC)

**Step 1 happened.** S-1/A-2 was filed on 2026-11-10 ([EDGAR, accession 0001628280-26-072484](https://www.sec.gov/Archives/edgar/data/2130357/000162828026072484/)).
Its fee table registers 948,750,000 Class A shares at a $78.00 maximum, including the underwriters'
option of 123,750,000; press reports give the range as $70–78.

- **OKX rebased.** From an estimated 10,000,000,000 shares to 13,116,075,288 at 2026-11-12 17:30
  UTC+8 ([OKX notice](https://www.okx.com/en-us/help/okx-to-execute-a-rebase-on-anthropic-perpetuals-and-x-perp)).
  OKX says this count is shares outstanding after the offering and the concurrent placement, and
  "not a fully diluted share count": options, RSUs and reserves are left out. `listing-watch`
  logged the step at 10:10:03 UTC as `136.73 -> 104.24 (-23.76%) in 60s`, a ratio of 1.3117
  against OKX's 1.3116. A reference check comparing OKX before and after would have read a 24% crash.
- **Binance has not rebased yet.** It still quotes `ANTHROPICUSDT` on 1B and has announced a move
  to about 13.1B under a new symbol, `ANTUSDT`
  ([PANews](https://panews.io/articles/01a1d4bf-447f-7150-8ff3-635e29a53de3)).
- **Two counts, not one.** At listing `io:ANTH` uses the fully diluted, as-converted count from the
  424(b); OKX, and Binance once it moves, use shares outstanding. Before the 424(b) the difference
  is unknown, but at today's prices `io:ANTH` (1,771.7, i.e. $1.77T) and OKX × 13.116B ($1.34T)
  are 32% apart. Part of that gap is the count, not a disagreement about price.
- **Listing date.** Pricing on 11-18 and first trade on 11-19 are reported (citing CNBC), not
  announced by Anthropic in anything read here. If Entropy treats 11-19 as the announced date,
  `io:ANTH` enters step 2 on 11-16.

## What happened (replayed 2026-11-20)

Anthropic priced at $83 on 11-18. `ANT`'s first trade, out of Nasdaq's opening auction, was $111.50
at about 11:48 ET (16:48 UTC) on 11-19, more than two hours after the 9:30 open; it closed at $97.17
([CBS News](https://www.cbsnews.com/news/anthropic-ipo-nasdaq-debut-claude-ai/),
[TechRepublic](https://www.techrepublic.com/article/news-anthropic-ipo-nasdaq-trading-debut/)).
Record: `listing-watch` for the three Hyperliquid markets, and the second recorder for Binance
`ANTUSDT`, Bitget and OKX, every minute from 11-18 22:00 UTC (Binance from 23:30) to 11-20, with no
gap in Binance from 13:30 to 21:00 UTC on 11-19.

| step | expected | what the oracles did |
|---|---|---|
| 3. IPO price ($83) | Paragon may reset to it; Binance blends its mark toward it | nothing moved toward $83. Every venue stayed near $98 that night, 18% above. Binance's mark equalled its index (its own trades) all day, so no blend showed; Paragon did not reset |
| 4. first opening trade | `io:ANTH` jumps from its own EMA to open × count ÷ 1e9 | no step: `io:ANTH` was 1,955.8 at 16:47 and 1,961.9 at 16:48. The exchange perps were already at about 111.2, 0.3% under the open |
| 5. external feed | `xyz:ANT` and `para:ANTH` switch | `xyz:ANT` at 16:50 (2 min after the open): 108.11 → 110.8, +2.5%. `para:ANTH` at 17:03 (15 min): 108.58 → 102.72, −5.4%, the largest by-rule step of the day |
| (exchanges) | — | Binance's index left its own trades at 17:06 (mark ≠ index from then). OKX changed the contract from `pre_market` to `normal` at 18:00 |

- **The count.** After the open, `io:ANTH` ÷ `xyz:ANT` holds at 17.6 (17.627 at 16:51, 17.616 at
  21:00), so Entropy is using about 17.6B shares. The analysts' 16.9B and 17.3B read from S-1/A-1
  were 4% and 2% low; OKX and Binance quote on 13.1B. A reference check that converts one into the
  other with the wrong count is off by that much before any price moves.
- **The steps that hurt were the internal oracles catching up.** Both per-share markets ran their
  own EMA during the opening auction, below a perp market that had already priced the open.
  `xyz:ANT` caught up fast; `para:ANTH` held its EMA through the post-open drop and stepped down
  5.4% a quarter of an hour later. A 5% latch fires on Paragon's step and on none of the others.
- **The exchanges agreed.** From 13:30 to 21:00 UTC (451 minutes with all three quotes) the spread
  between Binance's mark, Bitget's last and OKX's last was a median 11 bp of their median, 33 bp at
  the 95th percentile, and 247 bp at worst (16:51, OKX's last 108.0 against 110.7 and 110.1, in the
  minute the price fell from the open). At 21:00 UTC they were 97.13, 97.00 and 97.09 against the
  $97.17 close.
- **The perps priced the first trade, not the offering.** The night before, every venue was at $98
  against the $83 price; through the auction they climbed from about 104 to 111.2. Using the
  offering price as the reference, as step 3 assumes Paragon and Binance would, would have been 25%
  off.

The quotes themselves are third-party API data and are not published; the scripts and the dated
record that produced the numbers above are in
[fabrknt/research, 2026-11-18-anthropic-listing-quotes](https://github.com/fabrknt/research/tree/main/2026-11-18-anthropic-listing-quotes).

## What this means for a contract that reads these oracles

- The steps a latch has to expect on a listing day are the switches from internal to external
  pricing (here +2.5% and −5.4%, minutes after the first trade), not the offering price or the
  first trade itself. Size the threshold to the gap between an internal EMA and the live market,
  and expect the slow converter to step last.
- `HLPriceGuard.JumpLatch` stays tripped after such a step: the oracle does not come back to the
  old anchor. Call `rearm` only once an independent price agrees with the new oracle: for
  `io:ANTH`, the Nasdaq `ANT` price × the count Entropy uses (about 17.6B here) ÷ 1e9; for
  `xyz:ANT` and `para:ANTH`, the Nasdaq price.
- During step 2 there is no independent price for `io:ANTH` at all. A reference check
  (`maxRefOracleBps`) has nothing to compare with; treat the market as unpriced rather than as
  priced by its own book.
- A step-1 rebase on an exchange quote used as a reference looks like a 90%+ crash. Read the
  venue's basis with the quote.

## Recording

A Cloudflare Worker, `listing-watch`, reads the Hyperliquid markets, OKX and Bitget every minute
from 2026-11-05 and logs oracle jumps, exchange rebases and markets that appear or disappear; its
status says where each step above stands (`https://listing-watch.meowna-server.workers.dev/`, the
record at `/samples.csv`). Binance answers 403 to Cloudflare, and by 2026-11-15 Bitget did too,
so both come only from a second recorder, which pauses while its machine sleeps. It ran
2026-11-04 to 11-11 and again from 11-15 to 11-21; from 11-15 it stores each venue's price as
quoted, with no basis applied, so a rebase cannot be written into the record. "What happened"
above is the replay of the steps against what the oracles did.

Replayed with an AI (Claude), which wrote the scripts, lined up the records and drafted this
section; the numbers were checked minute by minute against both records. Not financial advice.

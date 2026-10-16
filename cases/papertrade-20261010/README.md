# Papertrade, 2026-10-10: moving Hyperliquid's ETH mid to settle 500x positions

Rebuilt from public data only:
- Hyperliquid fills: `s3://hl-mainnet-node-data/node_fills_by_block/hourly/20261010/{21,22,23}.lz4`
- Papertrade Exchange logs on HyperEVM: `0x6cd5661646289FB6E65EA5C032310fDEd797D0a2`, blocks 48,201,342–48,210,642

Wallet: `0x2025137a136bea7446deba681cbfc7cf1970840e` (the same address on HyperCore and HyperEVM).

## The result, and how it matches the press
| | This rebuild | Reported ([The Block](https://www.theblock.co/news/defi/2026-10-11-trader-nets-1-28-million-on-new-1000x-exchange-papertrade-by-moving-hyperliquids-eth-prices-418239)) |
|---|---|---|
| Papertrade PnL, 229 closed positions (21:35–23:11 UTC) | **+$1,407,332** (223 wins, 5 small losses) | |
| Hyperliquid: volume / fees / trading PnL | $309.8M / $70,853 / −$60,021 | ~$231M ETH, ~$52K fees |
| Net | **+$1,276,458** | "$1.28 million" |
| Left open at the end: 30 ETH shorts, 660x, $15,000 margin each | $450,000 at risk | "$450,000 on 30 ETH shorts (660x)" |

Papertrade notional opened: $2.24B, almost all on ETH, at 500–660x, with $15,000–20,000 margin per position.

## How it worked, round by round
Each round: open ten to twenty $10M positions on Papertrade at the BBO mid, push Hyperliquid's
ETH book the same way with market orders, close on Papertrade at the moved mid.

| close minute (UTC) | positions | notional | mid moved | Papertrade PnL |
|---|---|---|---|---|
| 21:39 | 14 | $140M | 7.7 bp | $68,952 |
| 21:41 | 16 | $160M | 16.0 bp | $194,548 |
| 21:47 | 13 | $130M | 16.0 bp | $158,181 |
| 21:49 | 13 | $130M | 13.5 bp | $129,588 |
| 21:53 | 20 | $200M | 8.9 bp | $119,760 |
| 21:54 | 22 | $220M | 7.0 bp | $95,289 |
| 21:58 | 15 | $150M | 5.3 bp | $45,136 |
| 22:01 | 11 | $110M | 9.3 bp | $69,071 |
| 22:03 | 20 | $200M | 12.0 bp | $171,931 |
| 22:04 | 16 | $160M | 9.2 bp | $99,027 |
| 22:05 | 21 | $210M | 6.7 bp | $87,623 |
| 22:11 | 20 | $192M | 10.4 bp | $138,451 |

(Smaller rounds omitted; `positions.json` has every position.)

**The economics: $130,873 spent on Hyperliquid (fees plus trading loss) returned $1,407,332 on
Papertrade, 10.8 to 1.** Moving ETH's mid by about 10 bp for a minute cost roughly $10K; each $10M
position paid about $7–9K for it after Papertrade's haircut.

## Why it worked
- Papertrade settles at Hyperliquid's BBO mid (`0x…80e`) with no independent reference price;
  its own docs list BBO manipulation as an unresolved risk.
- Its per-side open-interest caps were set at launch to current OI plus about $1B, far above what
  a ~10 bp push costs to defend.
- The asymmetric impact haircut keeps about 2/3 of the gain at these move sizes, so it cuts the
  payoff but does not remove it.

## Replay under the launch-pool rules (docs/c-launch-pool-design.md)
HL's ETH oracle for 21:33–23:14 UTC comes from the validators' `SetGlobalAction` in the explorer
blocks (`s3://hl-mainnet-node-data/explorer_blocks/1100000000/`, heights 1179121000–1179206099,
1,968 updates, never more than 8.1 s apart): `eth-oracle.json`. The public HyperEVM RPC cannot
give this: it ignores the block number for precompile calls.

| rule | take on the 228 ETH positions |
|---|---|
| settle at the BBO mid (Papertrade) | $2,052,046 |
| settle at the oracle, same moment | $1,738,919 |
| settle at the next oracle update (two-step) | $1,664,799 |
| refuse closes with mid–oracle gap over 15 bp | refuses 0 of 228 (gap at close: median 5.8 bp, max 10.2 bp) |
| cap notional at $3.3M per minute | at most $55,101, against $130,873 spent |

(Take = notional x price move, the same formula for every rule. Papertrade's recorded raw PnL is
about 2.5% lower, and its haircut then keeps about 70%.)

Moving the settlement price to the oracle barely helps, because the oracle moved too. Binance's
ETHUSDT moved the same way in 16 of 18 rounds, by almost the same amount, timed with the
attacker's HL orders (`rounds_vs_binance.py`). Whether the push spread through arbitrage or the
attacker also traded elsewhere, the public HL data cannot say.

## Files
- `hl_fills.py`, `papertrade_events.py`: regenerate `hl-fills.json` and `positions.json`.
- `replay_c.py`: the replay above. `rounds_vs_binance.py`: mid, oracle and Binance per round.
- Event layouts are inferred (the contract is not verified on any explorer we tried); every number
  above follows from them and matches the reported totals.

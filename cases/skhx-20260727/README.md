# xyz:SKHX, 2026-07-27: a deployer's oracle falls 15.6% in one update

trade.xyz's SK Hynix perp. At 23:00:03.946 UTC the deployer's oracle went from $1,131.40 to
$954.99 in one update, 2.7 s before the first liquidation. It then stepped down 1% per update to
$870.12, sat near $870–874 for about 80 s, jumped back to $1,078.70 at 23:02:03.598 and stepped
up to about $1,198. The liquidations were rebuilt in our operations repo,
[fabrknt/hip3-ops](https://github.com/fabrknt/hip3-ops) (`web/incident_data.py`); the oracle series
below is all this replay needs.

`skhx-oracle.json`: all 144 `setOracle` updates for SKHX, 22:57:36–23:04:45 UTC, from the public
explorer blocks, s3://hl-mainnet-node-data explorer_blocks (extracted with
[hip3-ops `web/incident_oracle.py`](https://github.com/fabrknt/hip3-ops/blob/main/web/incident_oracle.py);
the JSON is the complete input).

## Replay under the jump check (200 bp)
| stored price to compare with | accepted | accepted below $1,000 |
|---|---|---|
| previous read | 142 / 144 | 39, down to $870.12 |
| last accepted, forgotten after 90 s | 84 / 144 | 10, down to $872.52 |
| last accepted, kept (`HLPriceGuard.JumpLatch`) | 100 / 144 | 0 |

The steps after the first bad update are 100 bp each, so a check against the previous read lets
them through. The latch pauses from 23:00:03.9 and resumes at 23:02:15.7, when the oracle is back
within 200 bp of $1,131.40. `replay_c.py` runs this table; `test_jumpLatchOnSkhx` replays the same
file through the Solidity library and gets the same 100.

23:00 UTC is 08:00 in Seoul, an hour before KRX opens, so no fresh stock price was available to
compare with. The launch-pool rules stop new positions out of hours for this reason.

## Replay under an ADR reference
A stale one was. SK Hynix's ADS has traded on Nasdaq as SKHY since 2026-07-10 and closed at
$143.02 at 20:00 UTC, three hours before the incident; Pyth publishes it (Equity.US.SKHY/USD).
Times a ratio `k` fitted on the 10 sessions before (SKHX's open in USD per SKHY's prior close,
7.7967), that is $1,115.09 per share. The session opened at $1,134.30, 1.7% above.

| reference, as `Ref` with `maxRefOracleBps` | accepted | accepted below $1,000 |
|---|---|---|
| SKHY close x k, 10% band | 104 / 144 | 0 |
| SKHY close x k, 5% band | 61 / 144 | 0 |

`test_adrReferenceOnSkhx` runs both rows through `HLPriceGuard.read`, checking each update's
result. Against the latch it needs no price stored from before the incident (a contract whose
first read was 23:00:03.946 would have anchored the latch at $954.99) and no `rearm` after a real
overnight gap. The 5% band also refuses the $1,179.30–1,198.50 updates after 23:02, which were
above where the session opened.

The band has to be wide because the reference is rough. Over the 79 sessions from 2026-07-28 to
2026-11-20 it missed the open by 3.2% on average, 7.4% at the 95th percentile and 9.8% at most
(2026-08-27); `k` itself ranged 7.25–8.39 over the first 8 sessions of the listing (`adr_ref.py`,
which reads its inputs from `adr_ref_data.json`, one row per KRX session, and checks each
session's open and the ADR's close time). The ADR is a sanity bound for the deployer's oracle;
how it compares with xyz:SKHX's own pre-open price is not measured here. The bound holds only while the reference is admissible
(within `maxAge`) and `k` is right; `k` is a parameter someone updates, so set it from closes
nobody chooses. One incident does not show it covers every real overnight gap.

# xyz:SKHX, 2026-07-27: a deployer's oracle falls 15.6% in one update

trade.xyz's SK Hynix perp. At 23:00:03.946 UTC the deployer's oracle went from $1,131.40 to
$954.99 in one update, 2.7 s before the first liquidation. It then stepped down 1% per update to
$870.12, sat near $870–874 for about 80 s, jumped back to $1,078.70 at 23:02:03.598 and stepped
up to about $1,198. The liquidations were rebuilt in our operations repo, hip3-ops, which is not
yet public; the oracle series below is all this replay needs.

`skhx-oracle.json`: all 144 `setOracle` updates for SKHX, 22:57:36–23:04:45 UTC, from the public
explorer blocks, s3://hl-mainnet-node-data explorer_blocks (extracted with a hip3-ops script, not
yet public; the JSON is the complete input).

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

23:00 UTC is 08:00 in Seoul, an hour before KRX opens, so no independent stock price was
available to compare with. The launch-pool rules stop new positions out of hours for this reason.

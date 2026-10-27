# HL Price Guard (hl-price-guard)

A neutral Solidity library for any HyperEVM app that reads Hyperliquid's own prices.
Part of **[Fabrknt for HIP-3](https://fabrknt.com/hip3/index.html)** ([product page](https://fabrknt.com/hip3/price-guard/index.html)); built for Hyperliquid, not affiliated with it.

Scope: reading prices, detecting deviation (BBO, mark), an independent reference, a jump latch, and
exposure caps. Nothing else: pools, settlement queues, liquidation and UI belong to the apps that use
it (for example Day One, below), and nothing in this repo depends on any of them.

HyperEVM contracts can read HyperCore prices through precompiles:

| Precompile | Price | Set by | How hard to move |
|---|---|---|---|
| `0x…807` | oracle | validators, from external venues (HIP-3: the deployer) | harder, but a push on HL reached it for ETH (cases/papertrade-20261010) |
| `0x…806` | mark | oracle combined with the HL book | medium |
| `0x…80e` | best bid / ask (BBO) | the HL book itself | easy |

Index encodings differ between precompiles (checked on mainnet, 2026-10-17):
- `0x807` oracle takes `dex * 10000 + index` (xyz:TSLA = `10001`); the API's asset ID `110001` errors.
- `0x80e` BBO takes the API asset ID `100000 + dex * 10000 + index` (xyz:TSLA = `110001`).

## Contents
- `src/`: a Solidity library to read HL prices safely.
  - `HLPriceGuard`: returns the oracle and rejects it when the BBO, mark, an independent
    reference or the last stored price disagree beyond set bounds.
    `lenientPrice` gives liquidations the oracle or the mark, whichever favours the position, and
    `oracleOnly` the oracle with no tripwires; both revert on a 0 price (docs/safe-limits.md §5).
  - `PythRef`: Pyth on HyperEVM as the independent reference (it must be updated in the same tx,
    with update data from Pyth's Hermes, which needs an API key).
  - `ExposureBudget`: caps notional settled against one price per time window. `Rolling` (use this):
    no stretch of the window settles more than the cap; cap and window change only through
    `reconfigure`. `Window`: the older fixed window, which lets up to `2 * cap` through across a reset.
  - `HLPrecompiles`: raw reads and the two index encodings.
  - Apps built on it live in their own repos. One is Day One — Fabrknt Labs (`fabrknt/dayone`,
    private for now), a research launch pool. It uses this library as a git submodule (see Versions).
- `docs/safe-limits.md`: which price to use, how to set the bounds, how to size the cap, and what
  the cap does not cover (settlements at a single instant; a HIP-3 deployer's oracle key); then
  liquidations, prices at a set time and testnet, learned from apps built on the library.
- `docs/c-launch-pool-design.md`: points to Day One, where the launch-pool design now lives.
- `cases/`: incidents rebuilt from public data. Each is replayed under rules built from this library
  (oracle instead of BBO, deviation tripwire, exposure cap), plus the two-step settlement Day One adds.
  - Papertrade, 2026-10-10: one wallet moved HL's ETH mid and settled 500x positions against it.
    The Binance comparison fetches Binance's public klines; save them once to rerun offline.
  - xyz:SKHX, 2026-07-27: the deployer's oracle fell 15.6% in one update, then stepped down.
- `measure/`: `normal_gaps.py` samples the gaps the guard checks; `safe_caps.py` turns book
  depth into a per-minute exposure cap per asset (calibrated on Papertrade, one incident: a first
  estimate). Both save as they go; `safe_caps.py summary OUT.json` re-prints per UTC hour.
  `session.sh START END OUT` runs both over a UTC window; `.github/workflows/measure-us-session.yml`
  ran it on GitHub through the US session of 2026-10-19, started on time by `dispatch-at.yml`
  because this repository's scheduled runs start hours late. The data are
  `normal-gaps-20261019.json` and `safe-caps-20261019.json`; `session_tables.py` re-prints the
  tables in `docs/safe-limits.md` from them.
  `round_trips_collect.py` records trades (with wallets), best bid/offer and books;
  `round_trips.py` picks out single-wallet push-and-unwind round trips and compares their cost
  with the book-depth prediction, to test the Papertrade calibration on more than one incident.
  `.github/workflows/collect-round-trips.yml` runs both every 6 hours (it skips itself if the
  repository is private) and keeps the round trips found as artifacts for 30 days.
  Data files are named by the JST date they were taken; their timestamps are UTC.

## Status
**Not for production funds.** The library is unaudited and its caps are first estimates from
little data; use it for research, test deployments and review.
- Measured so far: normal gaps and book depth through one full US session (2026-10-19), plus a
  quiet Friday-evening sample of each (2026-10-16). The caps in `docs/safe-limits.md` still rest
  on the 0.27 calibration from one incident, so they remain first estimates.
- Running: round trips are collected every 6 hours to test that calibration. In the first 10 runs
  (2026-10-17 to 10-20) 27 candidates were found and none passed the strict filters, mostly
  because the wallet's own trades were too small to explain the move, so 0.27 is not yet tested.
- Not measured: weekends and volatile sessions.
- Not done: a cost for pushes shorter than a minute; an audit.

## Versions
Tagged `vX.Y.Z`. Apps should pin a tag (as a git submodule at that tag) and move to a new tag on
purpose, never to the latest commit. Day One pins `v0.2.1`.
- `v0.1.0` (b596268): `HLPriceGuard`, `PythRef`, `JumpLatch`, `ExposureBudget` (fixed window).
- `v0.2.0` (d996453): adds `ExposureBudget.Rolling`, a cap that no stretch of the window can exceed,
  and `reconfigure` that waits on the last spend. Do not pin: a spend at timestamp 0 was treated as
  "never spent", so `reconfigure` skipped the wait.
- `v0.2.1` (f18cdd4): the same, with that fix. The version to pin for `Rolling`.
- Untagged on `main` since `v0.2.1`: `szDecimals` over 6 reverts (`BadSzDecimals`; it used to
  mis-scale, and overflow from 46); `lenientPrice`, `oracleOnly` and `NoPrice`. Not tagged yet.

## Tests
`forge test`. Precompiles are mocked at their real addresses with mainnet values: forge's fork
mode cannot run HyperEVM's custom precompiles. `test/Live.t.sol` checks what the mocks assume
against mainnet: it fetches real precompile output over the public RPC and decodes it with
`HLPrecompiles` for BTC, ETH, xyz:TSLA and the L1 block number, and reads HyperEVM's Pyth
through `PythRef` (`HL_LIVE=true forge test --match-contract Live`). Its bounds are loose: it
catches a wrong encoding or scale, not a market anomaly. CI (`.github/workflows/test.yml`) runs
the suite on pushes to `main` and pull requests, and the live check then and daily.
- `test/HLPriceGuard.t.sol`: each check against mainnet values and the two incidents;
  `lenientPrice` and `oracleOnly` (including a 0 price), and `szDecimals` over 6 reverting.
  `ExposureBudget.Rolling` has two fuzz tests (with and without `reconfigure`) that check every
  admitted spend against the cap and window it was admitted under.
- `test/Properties.t.sol`: fuzz tests that `check` never passes a price outside an enabled bound
  and never reports a breach within one, that `diffBps` rounds up, and that the jump latch moves
  its anchor only on an accepted read, that `lenientPrice` returns one of the two feeds and the one
  on the position's side; `PythRef.updateAndRead` paying the fee and reading the update.
- `test/Integration.t.sol`: an example settlement contract wiring Pyth, the tripwires, the latch
  and a rolling cap the way docs/safe-limits.md recommends, run through Papertrade- and
  SKHX-like moves. A starting point for apps, not part of the library.
- Each fuzz test was shown to fail when the check it covers is removed or weakened.
- Not covered: the library running on HyperEVM itself (it runs locally; only what the precompiles
  and Pyth return is fetched from HyperEVM), and pushes shorter than a minute.

## License
Apache-2.0 (see `LICENSE`). Not audited.

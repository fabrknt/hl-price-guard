# HL Price Guard (hl-price-guard)

Private. A neutral Solidity library for any HyperEVM app that reads Hyperliquid's own prices.
Part of **Fabrknt for HIP-3** (fabrknt.com/hip3/price-guard); built for Hyperliquid, not affiliated with it.

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
  - `PythRef`: Pyth on HyperEVM as the independent reference (it must be updated in the same tx).
  - `ExposureBudget`: caps notional settled per time window.
  - `HLPrecompiles`: raw reads and the two index encodings.
  - Apps built on it live in their own repos. One is Day One — Fabrknt Labs (`fabrknt/dayone`), a
    research launch pool; it pins a tagged version of this library.
- `docs/safe-limits.md`: which price to use, how to set the bounds, and how to size the cap.
- `docs/c-launch-pool-design.md`: points to Day One, where the launch-pool design now lives.
- `cases/`: incidents rebuilt from public data. Each is replayed under rules built from this library
  (oracle instead of BBO, deviation tripwire, exposure cap), plus the two-step settlement Day One adds.
  - Papertrade, 2026-10-10: one wallet moved HL's ETH mid and settled 500x positions against it.
  - xyz:SKHX, 2026-07-27: the deployer's oracle fell 15.6% in one update, then stepped down.
- `measure/`: `normal_gaps.py` samples the gaps the guard checks; `safe_caps.py` turns book
  depth into a per-minute exposure cap per asset (calibrated on Papertrade).

## Versions
Tagged `vX.Y.Z`; apps pin a tag (as a git submodule at that tag) and move to a new tag on purpose,
never to the latest commit.
- `v0.1.0` (90c3455): `HLPriceGuard`, `PythRef`, `JumpLatch`, `ExposureBudget` (fixed window).
- `v0.2.0` (e4eac11): adds `ExposureBudget.Rolling`, a cap that no stretch of the window can exceed,
  and `reconfigure` that waits on the last spend. Do not pin: a spend at timestamp 0 was treated as
  "never spent", so `reconfigure` skipped the wait.
- `v0.2.1` (b03e605): the same, with that fix. The version to pin for `Rolling`.

## Tests
`forge test`. Precompiles are mocked at their real addresses with mainnet values: forge's fork
mode cannot run HyperEVM's custom precompiles, so encodings were checked with `cast call`.

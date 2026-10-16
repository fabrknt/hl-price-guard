# hl-price-guard

Private. Making HyperEVM apps safe when they lean on Hyperliquid's own prices.

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
  - `LaunchPool`: the C design, M1 draft. A loss-funded counterparty pool for one HIP-3 perp,
    settling two-step at the guarded oracle, capped per minute and by net open interest.
- `docs/safe-limits.md`: which price to use, how to set the bounds, and how to size the cap.
- `docs/c-launch-pool-design.md`: the launch-pool design memo (Japanese), with replay results.
- `cases/`: incidents rebuilt from public data, each replayed under the launch-pool rules.
  - Papertrade, 2026-10-10: one wallet moved HL's ETH mid and settled 500x positions against it.
  - xyz:SKHX, 2026-07-27: the deployer's oracle fell 15.6% in one update, then stepped down.
- `measure/`: `normal_gaps.py` samples the gaps the guard checks; `safe_caps.py` turns book
  depth into a per-minute exposure cap per asset (calibrated on Papertrade).

## Tests
`forge test`. Precompiles are mocked at their real addresses with mainnet values: forge's fork
mode cannot run HyperEVM's custom precompiles, so encodings were checked with `cast call`.

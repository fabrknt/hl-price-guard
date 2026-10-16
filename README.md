# hl-price-guard

Private. Making HyperEVM apps safe when they lean on Hyperliquid's own prices.

HyperEVM contracts can read HyperCore prices through precompiles:

| Precompile | Price | Set by | How hard to move |
|---|---|---|---|
| `0x…807` | oracle | validators, from external venues | hard |
| `0x…806` | mark | oracle combined with the HL book | medium |
| `0x…80e` | best bid / ask (BBO) | the HL book itself | easy |

Index encodings differ between precompiles (checked on mainnet, 2026-10-17):
- `0x807` oracle takes `dex * 10000 + index` (xyz:TSLA = `10001`); the API's asset ID `110001` errors.
- `0x80e` BBO takes the API asset ID `100000 + dex * 10000 + index` (xyz:TSLA = `110001`).

## Contents
- `cases/`: incidents rebuilt from public data. First: Papertrade, 2026-10-10 22:00 UTC,
  where one wallet moved HL's ETH mid and settled 500x positions against it.
- `measure/` (next): per asset, how much it costs to move each price by N bp.
- `contracts/` (next): a Solidity library to read HL prices safely.

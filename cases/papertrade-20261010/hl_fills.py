"""One wallet's fills on Hyperliquid from the public node data
(s3://hl-mainnet-node-data/node_fills_by_block/hourly/DATE/H.lz4, decompressed).

    python3 -I hl_fills.py WALLET OUT.json FILLS.jsonl...
"""
import json, sys

wallet, out, files = sys.argv[1].lower(), sys.argv[2], sys.argv[3:]
fills = []
for path in files:
    for line in open(path):
        if wallet[:10] not in line:
            continue
        for user, f in json.loads(line)["events"]:
            if user == wallet:
                fills.append({k: f[k] for k in ("time", "coin", "side", "px", "sz", "crossed", "fee", "closedPnl")})
json.dump(fills, open(out, "w"), indent=0)
vol = sum(float(f["px"]) * float(f["sz"]) for f in fills)
print(f"{len(fills)} fills, volume ${vol:,.0f}, fees ${sum(float(f['fee']) for f in fills):,.0f}, closed PnL ${sum(float(f['closedPnl']) for f in fills):,.0f}")

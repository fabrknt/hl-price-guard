#!/usr/bin/env bash
# Run safe_caps and normal_gaps side by side from START to END (UTC, e.g. 2026-10-19T13:25:00Z).
# Sleeps until START; if started late it still stops at END. Outcome and exit codes go to OUT/status.
#   measure/session.sh START END OUT
set -u
START=$1 END=$2 OUT=$3
cd "$(dirname "$0")/.." || exit 1
PY=${PY:-python3}
epoch() { $PY -c 'import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1"; }
start=$(epoch "$START") end=$(epoch "$END") now=$(date +%s)
mkdir -p "$OUT"
if (( now >= end )); then echo "skipped: already past $END" > "$OUT/status"; exit 0; fi
(( now < start )) && sleep $(( start - now ))
minutes=$($PY -c "import time; print(round(($end - time.time()) / 60, 2))")
echo "started $(date -u +%FT%TZ) for $minutes min (window $START to $END)" > "$OUT/status"
$PY -I measure/safe_caps.py "$minutes" "$OUT/safe-caps.json" > "$OUT/safe-caps.txt" 2> "$OUT/safe-caps.err" &
caps=$!
$PY -I measure/normal_gaps.py "$minutes" "$OUT/normal-gaps.json" > "$OUT/normal-gaps.txt" 2> "$OUT/normal-gaps.err" &
gaps=$!
wait $caps; rc_caps=$?
wait $gaps; rc_gaps=$?
echo "finished $(date -u +%FT%TZ) safe_caps=$rc_caps normal_gaps=$rc_gaps" >> "$OUT/status"
(( rc_caps == 0 && rc_gaps == 0 ))

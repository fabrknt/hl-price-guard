#!/usr/bin/env bash
# Run safe_caps and normal_gaps side by side from START to END (UTC, e.g. 2026-10-19T13:25:00Z).
# Sleeps until START; if started late it still stops at END. Outcome and exit codes go to OUT/status.
# The samplers stop themselves at END; one still running 10 s later (a slow sweep, a backoff sleep)
# gets SIGTERM from GNU timeout (gtimeout on macOS, if installed), which saves what it has, and
# SIGKILL 30 s after that. Without timeout they just stop themselves.
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
now=$(date +%s)
if (( now >= end )); then echo "skipped: woke after $END" > "$OUT/status"; exit 0; fi
stop=()
if T=$(command -v timeout || command -v gtimeout); then stop=("$T" --preserve-status -s TERM -k 30 $(( end + 10 - now ))); fi
minutes=$($PY -c "import time; print(round(($end - time.time()) / 60, 2))")
echo "started $(date -u +%FT%TZ) for $minutes min (window $START to $END)" > "$OUT/status"
${stop[@]+"${stop[@]}"} $PY -I measure/safe_caps.py "$minutes" "$OUT/safe-caps.json" > "$OUT/safe-caps.txt" 2> "$OUT/safe-caps.err" &
caps=$!
${stop[@]+"${stop[@]}"} $PY -I measure/normal_gaps.py "$minutes" "$OUT/normal-gaps.json" > "$OUT/normal-gaps.txt" 2> "$OUT/normal-gaps.err" &
gaps=$!
wait $caps; rc_caps=$?
wait $gaps; rc_gaps=$?
echo "finished $(date -u +%FT%TZ) safe_caps=$rc_caps normal_gaps=$rc_gaps" >> "$OUT/status"
(( rc_caps == 0 && rc_gaps == 0 ))

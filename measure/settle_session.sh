#!/usr/bin/env bash
# Run settle_window from START to END (UTC, e.g. 2026-11-08T00:00:00Z), like session.sh does for
# safe_caps and normal_gaps: sleep until START, stop at END, SIGTERM 10 s later if still running.
#   measure/settle_session.sh START END OUT
set -u
START=$1 END=$2 OUT=$3
cd "$(dirname "$0")/.." || exit 1
PY=${PY:-python3}
epoch() { $PY -c 'import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1"; }
start=$(epoch "$START") end=$(epoch "$END") now=$(date +%s)
mkdir -p "$OUT"
# a run that starts too late fails, so a missed window shows as a failed job, not an empty success
if (( now >= end )); then echo "missed: already past $END" > "$OUT/status"; exit 1; fi
(( now < start )) && sleep $(( start - now ))
now=$(date +%s)
if (( now >= end )); then echo "missed: woke after $END" > "$OUT/status"; exit 1; fi
stop=()
if T=$(command -v timeout || command -v gtimeout); then stop=("$T" --preserve-status -s TERM -k 30 $(( end + 10 - now ))); fi
minutes=$($PY -c "import time; print(round(($end - time.time()) / 60, 2))")
echo "started $(date -u +%FT%TZ) for $minutes min (window $START to $END)" > "$OUT/status"
${stop[@]+"${stop[@]}"} $PY -I measure/settle_window.py "$minutes" "$OUT" > "$OUT/settle-window.txt" 2> "$OUT/settle-window.err"
rc=$?
echo "finished $(date -u +%FT%TZ) settle_window=$rc" >> "$OUT/status"
exit $rc

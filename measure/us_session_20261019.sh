#!/bin/zsh
# Re-measure safe_caps and normal_gaps through the US session on Mon 2026-10-19:
# 22:25 JST start (5 min before the 09:30 ET open) to 05:00 JST (16:00 ET close), 395 minutes.
# Started by a launchd agent; runs only on that date.
# Needs this user logged in (GUI launchd domain), the Mac awake and online. Outcome: $D/status.
[[ $(TZ=Asia/Tokyo date +%F) == 2026-10-19 ]] || exit 0
cd "$(dirname "$0")/.." || exit 1
PY=python3
M=${1:-395} D=${2:-measure/us-20261019}
mkdir -p $D
echo "started $(date -u +%FT%TZ)" > $D/status
caffeinate -is $PY -I measure/safe_caps.py $M $D/safe-caps.json > $D/safe-caps.txt 2> $D/safe-caps.err &
caps=$!
caffeinate -is $PY -I measure/normal_gaps.py $M $D/normal-gaps.json > $D/normal-gaps.txt 2> $D/normal-gaps.err &
gaps=$!
wait $caps; rc_caps=$?
wait $gaps; rc_gaps=$?
echo "finished $(date -u +%FT%TZ) safe_caps=$rc_caps normal_gaps=$rc_gaps" >> $D/status
(( rc_caps == 0 && rc_gaps == 0 ))

#!/usr/bin/env bash
# Record a timestamped event in the run timeline, so every action can be
# correlated with a row in distribution.csv and with a Prometheus time range.
#
# The timeline is what lets you say "evictions started at 10:52:30Z and skew
# reached zero at 10:56:00Z" instead of guessing from graph shapes.
#
# Usage:
#   ./mark.sh "load-generator scaled to 4"
#   ./mark.sh "FIS experiment started" EXPabc123
#
# Writes UTC to captures/timeline.csv (override with TIMELINE=path) and echoes
# the line so it also appears in your terminal scrollback.
set -euo pipefail

OUT="${TIMELINE:-captures/timeline.csv}"
NOTE="${*:?usage: mark.sh <note>}"

mkdir -p "$(dirname "$OUT")"
[ -s "$OUT" ] || echo "utc_time,local_time,note" >> "$OUT"

TS_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS_LOCAL=$(date +%H:%M:%S)

printf '%s,%s,"%s"\n' "$TS_UTC" "$TS_LOCAL" "${NOTE//\"/\"\"}" >> "$OUT"
printf '%s (local %s)  %s\n' "$TS_UTC" "$TS_LOCAL" "$NOTE"

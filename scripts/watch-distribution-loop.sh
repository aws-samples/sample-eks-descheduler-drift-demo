#!/usr/bin/env bash
# Supervisor for watch-distribution.sh.
#
# watch-distribution.sh runs with `set -e`, so a single transient API failure
# ends it — and it ends SILENTLY, in a terminal you are not watching. In the
# 100-pod run that cost 4h20m of continuous data: one `dial tcp ... i/o timeout`
# at 11:05Z killed the logger, and the gap covered the unavailability window,
# the drift, and the entire control period.
#
# This wrapper restarts the logger whenever it exits, logging each restart so the
# gaps are visible and attributable rather than invisible. The CSV is appended to,
# so a restart costs one sample, not the file.
#
# Run it under nohup so closing the terminal does not kill it:
#   nohup ./scripts/watch-distribution-loop.sh captures/distribution.csv 30 \
#     > /tmp/watch-loop.log 2>&1 &
#
# Usage:
#   ./watch-distribution-loop.sh [outfile] [interval_seconds]
set -uo pipefail

OUT="${1:-captures/distribution.csv}"
INTERVAL="${2:-30}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RESTART_LOG="$(dirname "$OUT")/logger-restarts.log"
FAIL_FILE="$(dirname "$OUT")/LOGGER-FAILED"

mkdir -p "$(dirname "$OUT")"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) supervisor started, logging to $OUT" >> "$RESTART_LOG"

# Backoff: a logger that dies instantly, repeatedly, is not a transient network
# blip — it is usually expired credentials, and no amount of fast retries will
# fix that. (Observed in practice: 187 restarts over 15 hours, all rc=1, because
# the nohup'd environment held expired AWS credentials while interactive shells
# were refreshed.) After 5 consecutive fast exits, back off to 5-minute retries
# and drop a loud marker file so the failure is visible from `ls`.
n=0
fast=0
while true; do
  START=$(date +%s)
  "$HERE/watch-distribution.sh" "$OUT" "$INTERVAL"
  rc=$?
  RAN=$(( $(date +%s) - START ))
  n=$((n + 1))

  if [ "$RAN" -lt 60 ]; then fast=$((fast + 1)); else fast=0; rm -f "$FAIL_FILE"; fi

  if [ "$fast" -ge 5 ]; then
    DELAY=300
    {
      echo "Logger has failed $fast consecutive times (last rc=$rc) as of $(date -u +%Y-%m-%dT%H:%M:%SZ)."
      echo "Most likely cause: expired AWS credentials in this process's environment."
      echo "Fix: refresh credentials, then restart the supervisor from a fresh shell."
      echo "Retrying every ${DELAY}s. Delete this file after recovery."
    } > "$FAIL_FILE"
  else
    DELAY=10
  fi

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) logger exited rc=$rc after ${RAN}s — restart #$n in ${DELAY}s" >> "$RESTART_LOG"
  sleep "$DELAY"
done

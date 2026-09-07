#!/usr/bin/env bash
# Continuous per-AZ distribution logger. Run this in a spare terminal for the
# ENTIRE session — it is the source of every table in the blog.
#
# Appends one CSV row every INTERVAL seconds:
#   utc_time,az_a,az_b,az_c,total_running,skew,skew_frontend,skew_api,skew_orders,unready,pending,hpa_total
#
# The aggregate skew is the fleet-level picture; the per-deployment skews are
# what the descheduler actually evaluates (each Deployment carries its own
# topology spread constraint).
#
# Usage:
#   ./watch-distribution.sh [outfile] [interval_seconds]
#   ./watch-distribution.sh captures/distribution.csv 30
set -euo pipefail

OUT="${1:-captures/distribution.csv}"
INTERVAL="${2:-30}"
NS="demo"
SELECTOR="workload=web"   # shared label across web-frontend / web-api / web-orders
ZA="${AZ_A:-us-east-1a}"
ZB="${AZ_B:-us-east-1b}"
ZC="${AZ_C:-us-east-1c}"

mkdir -p "$(dirname "$OUT")"
if [ ! -s "$OUT" ]; then
  echo "utc_time,${ZA},${ZB},${ZC},total_running,skew,skew_frontend,skew_api,skew_orders,unready,pending,hpa_total" >> "$OUT"
fi
echo "Logging to $OUT every ${INTERVAL}s. Ctrl-C to stop."

while true; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # node -> zone map (client-side join; multi-key field selectors are unreliable)
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' > /tmp/wd_nodes.txt

  # running pods -> "node app" (one query for aggregate AND per-app skews)
  kubectl -n "$NS" get pods -l "$SELECTOR" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName} {.metadata.labels.app}{"\n"}{end}' > /tmp/wd_running.txt

  # readiness + pending, from full pod list
  kubectl -n "$NS" get pods -l "$SELECTOR" --no-headers > /tmp/wd_all.txt || true
  # Ready test: compare the two halves of the READY column ("3/3"). Do NOT use a
  # backreference regex here — macOS/BSD awk has no backreferences and silently
  # turns \1 into a literal 0x01, which makes every Running pod look unready.
  UNREADY=$(awk '$3=="Running" { split($2, r, "/"); if ((r[1]+0) != (r[2]+0)) c++ } END { print c+0 }' /tmp/wd_all.txt)
  PENDING=$(awk '$3=="Pending"' /tmp/wd_all.txt | wc -l | tr -d ' ')
  # combined current replicas across the three HPAs
  HPA=$(kubectl -n "$NS" get hpa -o jsonpath='{range .items[*]}{.status.currentReplicas}{"\n"}{end}' 2>/dev/null \
        | awk '{s+=$1} END{print s+0}')

  awk -v ts="$TS" -v za="$ZA" -v zb="$ZB" -v zc="$ZC" \
      -v unready="$UNREADY" -v pending="$PENDING" -v hpa="$HPA" '
    function skew(app,   mx, mn, z) {
      mx = -1; mn = -1
      # consider all three zones, missing = 0
      split(za SUBSEP zb SUBSEP zc, zs, SUBSEP)
      for (i = 1; i <= 3; i++) {
        v = pc[app, zs[i]] + 0
        if (mx < 0 || v > mx) mx = v
        if (mn < 0 || v < mn) mn = v
      }
      return mx - mn
    }
    NR==FNR { zone[$1] = $2; next }
    {
      z = zone[$1]
      c[z]++                    # aggregate per-zone
      pc[$2, z]++               # per-app per-zone
    }
    END {
      a=c[za]+0; b=c[zb]+0; d=c[zc]+0; t=a+b+d
      mx=a; mn=a
      if (b>mx) mx=b; if (d>mx) mx=d
      if (b<mn) mn=b; if (d<mn) mn=d
      printf "%s,%d,%d,%d,%d,%d,%d,%d,%d,%s,%s,%s\n", ts, a, b, d, t, mx-mn, \
        skew("web-frontend"), skew("web-api"), skew("web-orders"), unready, pending, hpa
    }' /tmp/wd_nodes.txt /tmp/wd_running.txt >> "$OUT"

  tail -n 1 "$OUT"
  sleep "$INTERVAL"
done

#!/usr/bin/env bash
# Point-in-time capture at a phase boundary. Run at EVERY labeled phase of the
# experiment; each snapshot lands in captures/<UTC>-<label>/.
#
# Usage:  ./snapshot.sh <label>
# Labels used by the run plan: baseline, churn-end, window-open, drifted,
#   window-closed, control-end, descheduler-installed, pass-1, pass-2,
#   converged, low-load
set -euo pipefail

LABEL="${1:?usage: snapshot.sh <label>}"
NS="demo"
TS=$(date -u +%Y%m%dT%H%M%SZ)
DIR="captures/${TS}-${LABEL}"
mkdir -p "$DIR"
echo "==> Snapshot '$LABEL' -> $DIR"

kubectl get nodes -L topology.kubernetes.io/zone -o wide          > "$DIR/nodes.txt"
kubectl -n "$NS" get pods -o wide                                 > "$DIR/pods-wide.txt"
kubectl -n "$NS" get hpa -o yaml                                  > "$DIR/hpa.yaml" 2>/dev/null || true
kubectl -n "$NS" describe pdb                                     > "$DIR/pdb.txt"  2>/dev/null || true
kubectl -n "$NS" get events --sort-by=.lastTimestamp              > "$DIR/events.txt" || true

# Eviction events, counted and listed
kubectl -n "$NS" get events \
  --field-selector reason=RemovePodsViolatingTopologySpreadConstraint \
  --sort-by=.lastTimestamp > "$DIR/eviction-events.txt" 2>/dev/null || true
grep -c . "$DIR/eviction-events.txt" > "$DIR/eviction-count.txt" 2>/dev/null || true

# Descheduler job logs, if any jobs exist
for job in $(kubectl -n kube-system get jobs -o name 2>/dev/null | grep descheduler || true); do
  name=$(basename "$job")
  kubectl -n kube-system logs "$job" --tail=-1 > "$DIR/log-${name}.txt" 2>/dev/null || true
done

# CronJob state (suspended or not) — matters for eviction accounting
kubectl -n kube-system get cronjob descheduler -o yaml > "$DIR/descheduler-cronjob.yaml" 2>/dev/null || true

# Allocatable capacity per zone (for the sizing claims)
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,CPU:.status.allocatable.cpu,PODS:.status.allocatable.pods' \
  > "$DIR/allocatable.txt"

echo "==> Done. Files:"
ls -la "$DIR"

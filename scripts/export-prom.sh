#!/usr/bin/env bash
# Export the graph data behind the Grafana panels from Prometheus as CSV, so
# every chart in the blog is reproducible from raw numbers (and survives a
# Grafana/Prometheus restart).
#
# Requires an active port-forward in another terminal:
#   kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
#
# Usage:
#   ./export-prom.sh <start-iso> <end-iso> [outdir]
#   ./export-prom.sh 2026-09-06T10:00:00Z 2026-09-06T14:00:00Z captures/prom
set -euo pipefail

START="${1:?start time, e.g. 2026-09-06T10:00:00Z}"
END="${2:?end time,   e.g. 2026-09-06T14:00:00Z}"
OUTDIR="${3:-captures/prom}"
PROM="http://localhost:9090"
STEP="30s"
mkdir -p "$OUTDIR"

export_query() {
  local name="$1" query="$2"
  echo "==> $name"
  curl -sfG "$PROM/api/v1/query_range" \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$START" \
    --data-urlencode "end=$END" \
    --data-urlencode "step=$STEP" \
    -o "$OUTDIR/$name.json"
  python3 - "$OUTDIR/$name.json" "$OUTDIR/$name.csv" <<'PY'
import json, sys, csv, datetime
data = json.load(open(sys.argv[1]))
rows = {}
series_names = []
for series in data['data']['result']:
    label = ','.join(f'{k}={v}' for k, v in sorted(series['metric'].items()) if k != '__name__') or 'value'
    series_names.append(label)
    for ts, val in series['values']:
        rows.setdefault(ts, {})[label] = val
with open(sys.argv[2], 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['utc_time'] + series_names)
    for ts in sorted(rows):
        t = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        w.writerow([t] + [rows[ts].get(s, '') for s in series_names])
print(f'  {sys.argv[2]}: {len(rows)} samples x {len(series_names)} series')
PY
}

# Per-AZ pod count for the whole web fleet (the fan-apart chart)
export_query "pods-per-az" \
  'sum by (label_topology_kubernetes_io_zone) (kube_pod_info{namespace="demo", created_by_name=~"web-.*"} * on (node) group_left(label_topology_kubernetes_io_zone) kube_node_labels)'

# Observed skew per Deployment (what each constraint — and the descheduler —
# actually evaluates; one series per created_by_name)
export_query "skew-per-deployment" \
  'pod:zone_skew:max_minus_min{namespace="demo"}'

# Aggregate fleet skew (the single-line story chart)
#
# The `or count by (zone) (kube_node_labels) * 0` term is load-bearing, not
# decoration. A zone with zero pods produces NO series at all, so a plain
# max() - min() only spans zones that still have pods: drain an AZ completely and
# skew reads 0 while it is actually at its worst. The `or` supplies a 0 for every
# zone that has nodes but no matching pods, so min() sees the empty zone.
# (Observed in the 100-pod run: true skew 50, chart read 0, for three hours.)
export_query "skew-fleet" \
  'max(sum by (label_topology_kubernetes_io_zone) (kube_pod_info{namespace="demo", created_by_name=~"web-.*"} * on (node) group_left(label_topology_kubernetes_io_zone) kube_node_labels) or count by (label_topology_kubernetes_io_zone) (kube_node_labels) * 0) - min(sum by (label_topology_kubernetes_io_zone) (kube_pod_info{namespace="demo", created_by_name=~"web-.*"} * on (node) group_left(label_topology_kubernetes_io_zone) kube_node_labels) or count by (label_topology_kubernetes_io_zone) (kube_node_labels) * 0)'

# Unready replicas across the fleet (the availability-cost chart)
export_query "unready" \
  'sum(kube_deployment_status_replicas{namespace="demo",deployment=~"web-.*"}) - sum(kube_deployment_status_replicas_ready{namespace="demo",deployment=~"web-.*"})'

# Pending pods (hard-constraint comparison signal)
export_query "pending" \
  'sum(kube_pod_status_phase{namespace="demo", phase="Pending"})'

# Combined HPA replica count (the churn record), plus per-HPA breakdown
export_query "hpa-replicas-total" \
  'sum(kube_horizontalpodautoscaler_status_current_replicas{namespace="demo", horizontalpodautoscaler=~"web-.*"})'
export_query "hpa-replicas-per-deployment" \
  'kube_horizontalpodautoscaler_status_current_replicas{namespace="demo", horizontalpodautoscaler=~"web-.*"}'

echo "==> All exports in $OUTDIR"

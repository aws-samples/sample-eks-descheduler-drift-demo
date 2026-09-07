#!/usr/bin/env bash
# Open or close a node unavailability window in one AZ via cordon.
# This is the low-friction path (no IAM); fis/ has the FIS equivalent.
# Cordon sets node.spec.unschedulable: true — the same API state a Spot
# interruption handler, managed node group upgrade, or autoscaler scale-down
# produces.
#
# Usage:
#   ./induce-window.sh open  [az]     # default az: us-east-1c
#   ./induce-window.sh close [az]
set -euo pipefail

ACTION="${1:?usage: induce-window.sh open|close [az]}"
AZ="${2:-us-east-1c}"

NODES=$(kubectl get nodes -l "topology.kubernetes.io/zone=${AZ}" -o name)
[ -n "$NODES" ] || { echo "No nodes found in ${AZ}" >&2; exit 1; }

case "$ACTION" in
  open)
    echo "==> $(date -u +%H:%M:%SZ) Opening window: cordoning all nodes in ${AZ}"
    for n in $NODES; do kubectl cordon "$n"; done
    ;;
  close)
    echo "==> $(date -u +%H:%M:%SZ) Closing window: uncordoning all nodes in ${AZ}"
    for n in $NODES; do kubectl uncordon "$n"; done
    ;;
  *)
    echo "unknown action: $ACTION (use open|close)" >&2; exit 1
    ;;
esac

kubectl get nodes -L topology.kubernetes.io/zone | grep -E "NAME|${AZ}"

#!/usr/bin/env bash
# Cleanup: Delete the Kind cluster and all resources
set -euo pipefail

CLUSTER_NAME="poc-ingress-gw"

echo "============================================"
echo " Cleanup: Removing PoC Environment"
echo "============================================"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "$CLUSTER_NAME"
  echo "Cluster deleted."
else
  echo "Cluster '${CLUSTER_NAME}' not found. Nothing to delete."
fi

echo ""
echo "============================================"
echo " Cleanup complete!"
echo "============================================"

#!/usr/bin/env bash
# Phase 1, Step 1: Create Kind cluster with port mappings
set -euo pipefail

CLUSTER_NAME="poc-ingress-gw"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo " Phase 1: Creating Kind Cluster"
echo "============================================"

# Check prerequisites
for cmd in docker kind kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed. Please install it first."
    exit 1
  fi
done

# Delete existing cluster if it exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists. Deleting..."
  kind delete cluster --name "$CLUSTER_NAME"
fi

# Create cluster
echo "Creating Kind cluster '${CLUSTER_NAME}'..."
kind create cluster --name "$CLUSTER_NAME" --config "${PROJECT_DIR}/kind-cluster.yaml"

# Verify
echo ""
echo "Verifying cluster..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""
kubectl get nodes
echo ""

echo "============================================"
echo " Kind cluster '${CLUSTER_NAME}' is ready!"
echo "============================================"

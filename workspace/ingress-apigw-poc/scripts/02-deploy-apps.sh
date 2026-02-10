#!/usr/bin/env bash
# Phase 1, Step 2: Deploy sample backend microservices
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo " Phase 1: Deploying Sample Applications"
echo "============================================"

# Deploy app-v1 and app-v2
echo "Deploying app-v1 and app-v2..."
kubectl apply -f "${PROJECT_DIR}/apps/sample-apps.yaml"

# Wait for pods to be ready
echo ""
echo "Waiting for app-v1 pods..."
kubectl wait --for=condition=ready pod \
  --selector=app=demo,version=v1 \
  --timeout=120s

echo "Waiting for app-v2 pods..."
kubectl wait --for=condition=ready pod \
  --selector=app=demo,version=v2 \
  --timeout=120s

# Verify
echo ""
echo "Deployed resources:"
kubectl get deployments,services,pods -l app=demo
echo ""

echo "============================================"
echo " Sample applications deployed!"
echo "============================================"

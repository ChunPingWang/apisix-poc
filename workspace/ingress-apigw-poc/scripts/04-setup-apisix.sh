#!/usr/bin/env bash
# Phase 3: Install Apache APISIX via Helm and configure routes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo " Phase 3: Setting up Apache APISIX"
echo "============================================"

# Check Helm
if ! command -v helm &>/dev/null; then
  echo "ERROR: 'helm' is not installed. Please install it first."
  exit 1
fi

# Add APISIX Helm repo
echo "Adding APISIX Helm repository..."
helm repo add apisix https://charts.apiseven.com
helm repo update

# Install APISIX
echo ""
echo "Installing APISIX via Helm..."
helm install apisix apisix/apisix \
  --namespace apisix \
  --create-namespace \
  -f "${PROJECT_DIR}/apisix/apisix-values.yaml"

# Wait for APISIX to be ready
echo ""
echo "Waiting for APISIX pods to be ready (up to 180s)..."
kubectl -n apisix wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=apisix \
  --timeout=180s

echo ""
echo "Waiting for etcd to be ready..."
kubectl -n apisix wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=etcd \
  --timeout=180s

# Port-forward Admin API so we can configure routes
echo ""
echo "Setting up port-forward for APISIX Admin API (port 9180)..."
kubectl -n apisix port-forward svc/apisix-admin 9180:9180 &
PF_PID=$!
sleep 3

# Configure routes
echo ""
echo "Configuring APISIX routes and plugins..."
bash "${PROJECT_DIR}/apisix/apisix-routes.sh"

# Clean up port-forward
kill $PF_PID 2>/dev/null || true

echo ""
echo "============================================"
echo " Apache APISIX configured!"
echo "============================================"
echo ""
echo "Test with:"
echo "  curl http://localhost:9080/v1/"
echo "  curl http://localhost:9080/v2/"
echo "  curl http://localhost:9080/v1-auth/ -H 'apikey: my-secret-api-key-123'"
echo "  curl http://localhost:9080/canary/"

#!/usr/bin/env bash
# Phase 2: Install NGINX Ingress Controller and configure routing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo " Phase 2: Setting up NGINX Ingress Controller"
echo "============================================"

# Install NGINX Ingress Controller for Kind
echo "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for the controller to be ready
echo ""
echo "Waiting for NGINX Ingress Controller to be ready (up to 120s)..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo ""
echo "NGINX Ingress Controller is running."

# Apply Ingress resources
echo ""
echo "Applying basic routing Ingress..."
kubectl apply -f "${PROJECT_DIR}/nginx-ingress/nginx-ingress.yaml"

echo "Applying rate-limited Ingress..."
kubectl apply -f "${PROJECT_DIR}/nginx-ingress/nginx-ingress-ratelimit.yaml"

# Verify
echo ""
echo "Ingress resources:"
kubectl get ingress
echo ""

echo "============================================"
echo " NGINX Ingress Controller configured!"
echo "============================================"
echo ""
echo "Test with:"
echo "  curl -H 'Host: demo.local' http://localhost/v1"
echo "  curl -H 'Host: demo.local' http://localhost/v2"
echo "  curl -H 'Host: demo-limited.local' http://localhost/"

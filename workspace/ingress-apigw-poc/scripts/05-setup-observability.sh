#!/usr/bin/env bash
# Phase 5: Install Prometheus + Grafana for observability
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo " Phase 5: Setting up Observability Stack"
echo "============================================"

# Check Helm
if ! command -v helm &>/dev/null; then
  echo "ERROR: 'helm' is not installed. Please install it first."
  exit 1
fi

# Add Prometheus Helm repo
echo "Adding Prometheus community Helm repository..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack
echo ""
echo "Installing Prometheus + Grafana..."
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f "${PROJECT_DIR}/observability/prometheus-values.yaml"

# Wait for Prometheus to be ready
echo ""
echo "Waiting for Prometheus pods to be ready (up to 180s)..."
kubectl -n monitoring wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=prometheus \
  --timeout=180s || echo "WARN: Prometheus may still be starting up..."

echo ""
echo "Waiting for Grafana pods to be ready..."
kubectl -n monitoring wait --for=condition=ready pod \
  --selector=app.kubernetes.io/name=grafana \
  --timeout=180s || echo "WARN: Grafana may still be starting up..."

# Verify
echo ""
echo "Monitoring stack pods:"
kubectl -n monitoring get pods
echo ""

echo "============================================"
echo " Observability stack deployed!"
echo "============================================"
echo ""
echo "Access Grafana:"
echo "  URL:      http://localhost:30300"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "To port-forward Prometheus UI:"
echo "  kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090"

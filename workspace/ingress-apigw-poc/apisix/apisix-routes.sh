#!/usr/bin/env bash
# Configure APISIX routes and plugins via Admin API
set -euo pipefail

ADMIN_URL="http://127.0.0.1:9180"
API_KEY="edd1c9f034335f136f87ad84b625c8f1"

echo "============================================"
echo " APISIX Route & Plugin Configuration"
echo "============================================"

# --------------------------------------------------
# Route 1: Basic routing to app-v1
# --------------------------------------------------
echo ""
echo "[1/6] Creating Route 1: /v1/* -> app-v1-svc"
curl -s "${ADMIN_URL}/apisix/admin/routes/1" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PUT -d '{
    "uri": "/v1/*",
    "name": "route-v1",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v1-svc.default.svc.cluster.local:80": 1
      }
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

# --------------------------------------------------
# Route 2: Basic routing to app-v2
# --------------------------------------------------
echo "[2/6] Creating Route 2: /v2/* -> app-v2-svc"
curl -s "${ADMIN_URL}/apisix/admin/routes/2" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PUT -d '{
    "uri": "/v2/*",
    "name": "route-v2",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v2-svc.default.svc.cluster.local:80": 1
      }
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

# --------------------------------------------------
# Route 3: Rate limiting on /v1-limited/*
# --------------------------------------------------
echo "[3/6] Creating Route 3: /v1-limited/* with rate limiting"
curl -s "${ADMIN_URL}/apisix/admin/routes/3" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PUT -d '{
    "uri": "/v1-limited/*",
    "name": "route-v1-ratelimited",
    "plugins": {
      "limit-req": {
        "rate": 10,
        "burst": 5,
        "rejected_code": 429,
        "key_type": "var",
        "key": "remote_addr"
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v1-svc.default.svc.cluster.local:80": 1
      }
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

# --------------------------------------------------
# Consumer: poc-user with API key authentication
# --------------------------------------------------
echo "[4/6] Creating Consumer: poc-user with key-auth"
curl -s "${ADMIN_URL}/apisix/admin/consumers" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PUT -d '{
    "username": "poc-user",
    "plugins": {
      "key-auth": {
        "key": "my-secret-api-key-123"
      }
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

# --------------------------------------------------
# Route 4: Key-auth protected route
# --------------------------------------------------
echo "[5/6] Creating Route 4: /v1-auth/* with key-auth"
curl -s "${ADMIN_URL}/apisix/admin/routes/4" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PUT -d '{
    "uri": "/v1-auth/*",
    "name": "route-v1-auth",
    "plugins": {
      "key-auth": {}
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v1-svc.default.svc.cluster.local:80": 1
      }
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

# --------------------------------------------------
# Route 5: Canary / Traffic splitting (80% v1, 20% v2)
# --------------------------------------------------
echo "[6/6] Creating Route 5: /canary/* with weighted traffic split (80/20)"
curl -s "${ADMIN_URL}/apisix/admin/routes/5" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PUT -d '{
    "uri": "/canary/*",
    "name": "route-canary",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "app-v1-svc.default.svc.cluster.local:80": 8,
        "app-v2-svc.default.svc.cluster.local:80": 2
      }
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

# --------------------------------------------------
# Global Rule: Enable Prometheus plugin
# --------------------------------------------------
echo "[Bonus] Enabling Prometheus plugin globally"
curl -s "${ADMIN_URL}/apisix/admin/global_rules/1" \
  -H "X-API-KEY: ${API_KEY}" \
  -X PUT -d '{
    "plugins": {
      "prometheus": {}
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

echo "============================================"
echo " All APISIX routes configured!"
echo "============================================"
echo ""
echo "Routes summary:"
echo "  /v1/*          -> app-v1-svc (basic)"
echo "  /v2/*          -> app-v2-svc (basic)"
echo "  /v1-limited/*  -> app-v1-svc (rate limited: 10 req/s)"
echo "  /v1-auth/*     -> app-v1-svc (key-auth required)"
echo "  /canary/*      -> 80% app-v1 / 20% app-v2"
echo ""
echo "Test examples:"
echo "  curl http://localhost:9080/v1/"
echo "  curl http://localhost:9080/v2/"
echo "  curl http://localhost:9080/v1-auth/ -H 'apikey: my-secret-api-key-123'"
echo "  curl http://localhost:9080/canary/"

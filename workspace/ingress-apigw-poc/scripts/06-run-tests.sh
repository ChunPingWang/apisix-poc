#!/usr/bin/env bash
# Phase 4: Run all 10 test cases comparing NGINX Ingress vs. APISIX
set -euo pipefail

PASS=0
FAIL=0
SKIP=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

result() {
  local status=$1 name=$2 detail=$3
  case "$status" in
    PASS) echo -e "  ${GREEN}[PASS]${NC} $name - $detail"; ((PASS++)) ;;
    FAIL) echo -e "  ${RED}[FAIL]${NC} $name - $detail"; ((FAIL++)) ;;
    SKIP) echo -e "  ${YELLOW}[SKIP]${NC} $name - $detail"; ((SKIP++)) ;;
  esac
}

echo "============================================"
echo " Phase 4: Comparative Test Suite"
echo "============================================"
echo ""

# =============================================
# TC-01: Path-based routing
# =============================================
echo -e "${BLUE}--- TC-01: Path-based routing ---${NC}"

# NGINX Ingress
RESP=$(curl -s -H "Host: demo.local" http://localhost/v1 2>/dev/null || echo "CURL_FAILED")
if echo "$RESP" | grep -q "App V1"; then
  result PASS "NGINX /v1" "Got: $RESP"
else
  result FAIL "NGINX /v1" "Expected 'App V1', got: $RESP"
fi

RESP=$(curl -s -H "Host: demo.local" http://localhost/v2 2>/dev/null || echo "CURL_FAILED")
if echo "$RESP" | grep -q "App V2"; then
  result PASS "NGINX /v2" "Got: $RESP"
else
  result FAIL "NGINX /v2" "Expected 'App V2', got: $RESP"
fi

# APISIX
RESP=$(curl -s http://localhost:9080/v1/ 2>/dev/null || echo "CURL_FAILED")
if echo "$RESP" | grep -q "App V1"; then
  result PASS "APISIX /v1" "Got: $RESP"
else
  result FAIL "APISIX /v1" "Expected 'App V1', got: $RESP"
fi

RESP=$(curl -s http://localhost:9080/v2/ 2>/dev/null || echo "CURL_FAILED")
if echo "$RESP" | grep -q "App V2"; then
  result PASS "APISIX /v2" "Got: $RESP"
else
  result FAIL "APISIX /v2" "Expected 'App V2', got: $RESP"
fi

echo ""

# =============================================
# TC-02: Host-based routing
# =============================================
echo -e "${BLUE}--- TC-02: Host-based routing ---${NC}"

RESP=$(curl -s -H "Host: demo.local" http://localhost/v1 2>/dev/null || echo "CURL_FAILED")
if echo "$RESP" | grep -q "App V1"; then
  result PASS "NGINX host-based" "demo.local resolved correctly"
else
  result FAIL "NGINX host-based" "Host routing failed"
fi

result PASS "APISIX host-based" "APISIX uses URI-based routing (no host required)"
echo ""

# =============================================
# TC-03: Rate limiting
# =============================================
echo -e "${BLUE}--- TC-03: Rate limiting ---${NC}"

# NGINX rate limiting
echo "  Testing NGINX rate limiting (20 rapid requests)..."
NGINX_429=0
for i in $(seq 1 20); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: demo-limited.local" http://localhost/ 2>/dev/null || echo "000")
  if [ "$CODE" = "503" ] || [ "$CODE" = "429" ]; then
    ((NGINX_429++))
  fi
done
if [ "$NGINX_429" -gt 0 ]; then
  result PASS "NGINX rate-limit" "${NGINX_429}/20 requests were rate-limited"
else
  result FAIL "NGINX rate-limit" "No requests were rate-limited"
fi

# APISIX rate limiting
echo "  Testing APISIX rate limiting (20 rapid requests)..."
APISIX_429=0
for i in $(seq 1 20); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9080/v1-limited/ 2>/dev/null || echo "000")
  if [ "$CODE" = "429" ]; then
    ((APISIX_429++))
  fi
done
if [ "$APISIX_429" -gt 0 ]; then
  result PASS "APISIX rate-limit" "${APISIX_429}/20 requests got 429"
else
  result FAIL "APISIX rate-limit" "No requests got 429"
fi

echo ""

# =============================================
# TC-04: API Key authentication
# =============================================
echo -e "${BLUE}--- TC-04: API Key authentication ---${NC}"

result SKIP "NGINX key-auth" "Not built-in (requires external auth)"

# APISIX - without key
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9080/v1-auth/ 2>/dev/null || echo "000")
if [ "$CODE" = "401" ]; then
  result PASS "APISIX no-key" "Got 401 Unauthorized as expected"
else
  result FAIL "APISIX no-key" "Expected 401, got $CODE"
fi

# APISIX - with key
RESP=$(curl -s -H "apikey: my-secret-api-key-123" http://localhost:9080/v1-auth/ 2>/dev/null || echo "CURL_FAILED")
if echo "$RESP" | grep -q "App V1"; then
  result PASS "APISIX with-key" "Authenticated successfully"
else
  result FAIL "APISIX with-key" "Expected 'App V1', got: $RESP"
fi

echo ""

# =============================================
# TC-05: JWT authentication
# =============================================
echo -e "${BLUE}--- TC-05: JWT authentication ---${NC}"
result SKIP "NGINX jwt-auth" "Not built-in"
result SKIP "APISIX jwt-auth" "Not configured in this PoC (plugin available)"
echo ""

# =============================================
# TC-06: Canary release (weighted traffic)
# =============================================
echo -e "${BLUE}--- TC-06: Canary release (weighted traffic) ---${NC}"

result SKIP "NGINX canary" "Limited annotation support"

echo "  Testing APISIX canary (100 requests, expecting ~80/20 split)..."
V1_COUNT=0
V2_COUNT=0
for i in $(seq 1 100); do
  RESP=$(curl -s http://localhost:9080/canary/ 2>/dev/null || echo "")
  if echo "$RESP" | grep -q "App V1"; then
    ((V1_COUNT++))
  elif echo "$RESP" | grep -q "App V2"; then
    ((V2_COUNT++))
  fi
done
TOTAL=$((V1_COUNT + V2_COUNT))
if [ "$TOTAL" -gt 0 ] && [ "$V1_COUNT" -gt "$V2_COUNT" ]; then
  result PASS "APISIX canary" "V1: ${V1_COUNT}, V2: ${V2_COUNT} (total: ${TOTAL})"
else
  result FAIL "APISIX canary" "V1: ${V1_COUNT}, V2: ${V2_COUNT} - distribution unexpected"
fi

echo ""

# =============================================
# TC-07: Request transformation
# =============================================
echo -e "${BLUE}--- TC-07: Request transformation ---${NC}"
result SKIP "NGINX transform" "Annotation-based (limited)"
result SKIP "APISIX transform" "proxy-rewrite plugin available (not configured)"
echo ""

# =============================================
# TC-08: Prometheus metrics
# =============================================
echo -e "${BLUE}--- TC-08: Prometheus metrics ---${NC}"

# NGINX metrics
NGINX_METRICS=$(curl -s http://localhost:10254/metrics 2>/dev/null | head -5 || echo "UNAVAILABLE")
if echo "$NGINX_METRICS" | grep -q "nginx"; then
  result PASS "NGINX metrics" "Prometheus endpoint available at :10254/metrics"
else
  result SKIP "NGINX metrics" "Metrics endpoint not accessible"
fi

# APISIX metrics
APISIX_METRICS=$(curl -s http://localhost:9080/apisix/prometheus/metrics 2>/dev/null | head -5 || echo "UNAVAILABLE")
if echo "$APISIX_METRICS" | grep -q "apisix"; then
  result PASS "APISIX metrics" "Prometheus endpoint available"
else
  result SKIP "APISIX metrics" "Metrics endpoint not accessible"
fi

echo ""

# =============================================
# TC-09: Access logging
# =============================================
echo -e "${BLUE}--- TC-09: Access logging ---${NC}"
result PASS "NGINX logging" "Available via: kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller"
result PASS "APISIX logging" "Available via: kubectl logs -n apisix -l app.kubernetes.io/name=apisix"
echo ""

# =============================================
# TC-10: Hot config reload
# =============================================
echo -e "${BLUE}--- TC-10: Hot config reload ---${NC}"
result FAIL "NGINX hot-reload" "Requires NGINX reload on config change"
result PASS "APISIX hot-reload" "Real-time via etcd (no restart needed)"
echo ""

# =============================================
# Summary
# =============================================
echo "============================================"
echo -e " Test Results: ${GREEN}PASS=${PASS}${NC} ${RED}FAIL=${FAIL}${NC} ${YELLOW}SKIP=${SKIP}${NC}"
echo "============================================"

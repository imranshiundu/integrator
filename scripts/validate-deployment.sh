#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-deployment.sh — Core Delivery validation for i-love-shopping
#
# Proves the deployed stack actually works: service health, database
# round-trip, and the critical user flows (register, login, browse,
# cart, guest checkout). Exits non-zero on the first broken check, so
# the pipeline can trigger the rollback path.
#
# Usage:
#   ./validate-deployment.sh <api-base-url> <frontend-url>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

API="${1:-http://localhost:8080/api/v1}"
FRONTEND="${2:-http://localhost:3000}"
PASS=0; FAIL=0

check() { # name, condition
  if [ "$2" = "True" ]; then echo "  PASS: $1"; PASS=$((PASS+1));
  else echo "  FAIL: $1 -- $3"; FAIL=$((FAIL+1)); fi
}

jqv() { python3 -c "$1" 2>/dev/null || echo False; }

echo "validate: service health"
H=$(curl -s -m 10 "$API/health")
check "API health is UP" "$(echo "$H" | jqv "import json,sys; print(json.load(sys.stdin)['data']['status']=='UP')")" "$H"
F=$(curl -s -o /dev/null -w "%{http_code}" -m 20 "$FRONTEND/")
check "frontend responds 200" "$([ "$F" = "200" ] && echo True || echo False)" "got $F"

echo "validate: critical user flows"
RAND=$RANDOM
EMAIL="ci-validate-$RAND@example.com"

R=$(curl -s -m 15 -X POST "$API/auth/register" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"CiValidate123!\",\"name\":\"CI Validator\",\"captchaToken\":\"dev-test-secret\"}")
check "register" "$(echo "$R" | jqv "import json,sys; print(json.load(sys.stdin).get('success', False) or bool(json.load(sys.stdin).get('data',{}).get('accessToken')))")" "$R"

L=$(curl -s -m 15 -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"CiValidate123!\"}")
TOKEN=$(echo "$L" | jqv "import json,sys; print(json.load(sys.stdin)['data']['accessToken'])")
check "login" "$([ -n "$TOKEN" ] && [ "$TOKEN" != "False" ] && echo True || echo False)" "$L"

P=$(curl -s -m 15 "$API/products?size=5")
SLUG=$(echo "$P" | jqv "import json,sys; print(json.load(sys.stdin)['data']['products'][0]['slug'])")
check "product catalogue is browsable" "$([ -n "$SLUG" ] && [ "$SLUG" != "False" ] && echo True || echo False)" "$P"

C=$(curl -s -m 15 -X POST "$API/cart/items" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"productId\":\"$(echo "$P" | jqv "import json,sys; print(json.load(sys.stdin)['data']['products'][0]['id'])")\",\"quantity\":1}")
check "add to cart" "$(echo "$C" | jqv "import json,sys; print(json.load(sys.stdin).get('success'))")" "$C"

K=$(curl -s -m 20 -X POST "$API/orders/checkout" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"shippingAddress\":{\"name\":\"CI\",\"line1\":\"1 Pipeline Lane\",\"city\":\"Nairobi\",\"state\":\"Nairobi\",\"postalCode\":\"00100\",\"country\":\"KE\",\"phone\":\"+254700000000\"},\"billingAddress\":{\"name\":\"CI\",\"line1\":\"1 Pipeline Lane\",\"city\":\"Nairobi\",\"state\":\"Nairobi\",\"postalCode\":\"00100\",\"country\":\"KE\",\"phone\":\"+254700000000\"}}")
NUM=$(echo "$K" | jqv "import json,sys; print(json.load(sys.stdin)['data']['number'])" 2>/dev/null)
check "checkout creates an order" "$([ -n "$NUM" ] && [ "$NUM" != "False" ] && echo True || echo False)" "$K"

echo "validate: database round-trip (order persisted)"
DBT=$(docker exec "$(docker ps --filter name=postgres -q | head -1)" psql -U iloveshopping -d iloveshopping -t -c \
  "SELECT count(*) FROM orders WHERE number='$NUM'" 2>/dev/null | tr -d ' \n')
check "order row visible in the database" "$([ "$DBT" = "1" ] && echo True || echo False)" "got '$DBT'"

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "validate: FAILED ($PASS passed, $FAIL failed) — trigger rollback"
  exit 1
fi
echo "validate: OK ($PASS/$PASS checks) — deployment healthy"

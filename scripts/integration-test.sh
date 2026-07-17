#!/bin/sh
# End-to-end auth test against a real Keycloak issuer. Proves the bearer/API
# path works against a live OIDC provider (RFC 7662 introspection), not just
# against mocks: valid token -> 200 + injected identity, forged client header
# -> stripped, invalid/missing token -> 401. Safe to re-run; cleans up on exit.
set -eu

cd "$(dirname "$0")/../spec/integration"
compose="docker compose -f docker-compose.yml"

cleanup() { $compose down --volumes --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> building + starting stack"
$compose up -d --build

deadline=$(( $(date +%s) + 240 ))
wait_for() {
  name=$1 url=$2
  echo "==> waiting for $name"
  until curl -sf "$url" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "$name did not become ready" >&2
      $compose logs "$name" >&2 || true
      exit 1
    fi
    sleep 3
  done
}

wait_for keycloak http://127.0.0.1:8080/realms/kong/.well-known/openid-configuration
wait_for kong http://127.0.0.1:8001/status

echo "==> obtaining access token (resource-owner password grant)"
token=$(curl -sf -X POST \
  http://127.0.0.1:8080/realms/kong/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=kong-client \
  -d client_secret=kong-secret \
  -d username=alice \
  -d password=alice-password \
  -d scope=openid \
  | grep -o '"access_token":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$token" ] || { echo "failed to obtain access token" >&2; exit 1; }
echo "   ok: got token (${#token} chars)"

echo "==> valid bearer token -> 200 with injected, verified X-Userinfo"
body=$(curl -sf -H "Authorization: Bearer $token" http://127.0.0.1:8000/echo/headers)
userinfo=$(printf '%s' "$body" | tr ',' '\n' | grep -i 'x-userinfo' | sed -n 's/.*: *"\([^"]*\)".*/\1/p')
[ -n "$userinfo" ] || { echo "upstream did not receive X-Userinfo" >&2; printf '%s\n' "$body" >&2; exit 1; }
printf '%s' "$userinfo" | base64 -d 2>/dev/null | grep -qi 'alice' \
  || { echo "X-Userinfo did not contain the verified identity" >&2; exit 1; }
echo "   ok: upstream received X-Userinfo with verified claims"

echo "==> forged client X-Userinfo -> stripped, replaced by verified identity"
body=$(curl -sf -H "Authorization: Bearer $token" \
  -H "X-Userinfo: FORGED_IDENTITY" http://127.0.0.1:8000/echo/headers)
if printf '%s' "$body" | grep -q 'FORGED_IDENTITY'; then
  echo "trust boundary breach: forged X-Userinfo reached upstream" >&2
  printf '%s\n' "$body" >&2
  exit 1
fi
echo "   ok: forged identity header was stripped"

echo "==> invalid bearer token -> 401"
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer not-a-real-token" http://127.0.0.1:8000/echo/headers)
[ "$code" = "401" ] || { echo "expected 401 for invalid token, got $code" >&2; exit 1; }
echo "   ok: 401 on invalid token"

echo "==> missing bearer token (bearer_only) -> 401"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/echo/headers)
[ "$code" = "401" ] || { echo "expected 401 for missing token, got $code" >&2; exit 1; }
echo "   ok: 401 on missing token"

echo "==> integration test passed"

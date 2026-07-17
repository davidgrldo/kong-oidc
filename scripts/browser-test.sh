#!/bin/sh
# End-to-end test of the OIDC authorization-code (browser) flow against a real
# Keycloak, driven by a headless Chromium. Proves what the bearer test can't:
# unauthenticated -> Keycloak login -> callback -> encrypted session -> upstream
# with a verified identity, session reuse, and logout. Cleans up on exit.
set -eu

cd "$(dirname "$0")/../spec/integration"
compose="docker compose -f docker-compose.browser.yml"

cleanup() { $compose down --volumes --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> building + starting stack"
$compose up -d --build keycloak httpbin kong

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

echo "==> running headless-browser auth-code flow"
# --no-TTY keeps output clean in CI; the runner exits non-zero on any failed assertion.
$compose run --rm --no-TTY playwright

echo "==> browser flow test passed"

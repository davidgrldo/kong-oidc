#!/bin/sh
# DB-less Kong stack smoke test: validates the config, builds the image, starts
# the stack, waits for the Admin API, asserts the oidc plugin is enabled, and
# tears everything down. Safe to re-run; cleans up via an EXIT trap.
set -eu

cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> validating compose config"
docker compose config --quiet

echo "==> building image"
docker build --no-cache -t kong-oidc:test .

echo "==> starting stack"
docker compose up -d

echo "==> waiting for Admin API"
deadline=$(( $(date +%s) + 60 ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -sf http://127.0.0.1:8001/status >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  echo "Admin API did not become ready within 60s" >&2
  docker compose logs kong >&2 || true
  exit 1
fi

echo "==> asserting oidc plugin is enabled"
if ! curl -sf http://127.0.0.1:8001/plugins/enabled 2>/dev/null | grep -F '"oidc"' >/dev/null; then
  echo "oidc plugin is not in the enabled plugins list" >&2
  exit 1
fi

echo "==> smoke test passed"

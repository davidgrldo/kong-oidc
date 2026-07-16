#!/bin/sh
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/resty"
printf 'return {}\n' > "$tmp/resty/openidc.lua"

parse() {
  docker run --rm \
    -v "$PWD/plugins/oidc/kong/plugins/oidc:/usr/local/share/lua/5.1/kong/plugins/oidc:ro" \
    -v "$1:/tmp/kong.yml:ro" \
    -v "$tmp/resty/openidc.lua:/usr/local/share/lua/5.1/resty/openidc.lua:ro" \
    -e KONG_DATABASE=off \
    -e KONG_PLUGINS=bundled,oidc \
    kong:3.9.3 kong config parse /tmp/kong.yml
}

rejects() {
  name=$1
  fixture=$2
  expected=$3
  if output=$(parse "$fixture" 2>&1); then
    echo "expected rejection: $name" >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf '%s\n' "$output" >&2
    echo "wrong rejection: $name" >&2
    exit 1
  fi
  echo "rejected: $name"
}

parse "$PWD/spec/contract-kong.yml"

sed 's#https://issuer.example#http://issuer.example#' \
  spec/contract-kong.yml > "$tmp/http-discovery.yml"
rejects "HTTP discovery" "$tmp/http-discovery.yml" \
  "OIDC endpoints must use HTTPS unless allow_insecure_http is true"

sed '/session_secret:/d' spec/contract-kong.yml > "$tmp/no-session-secret.yml"
rejects "missing session secret" "$tmp/no-session-secret.yml" \
  "browser mode requires a base64 session_secret of at least 32 decoded bytes"

sed 's#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=#c2hvcnQ=#' \
  spec/contract-kong.yml > "$tmp/short-session-secret.yml"
rejects "short session secret" "$tmp/short-session-secret.yml" \
  "browser mode requires a base64 session_secret of at least 32 decoded bytes"

sed 's#redirect_uri: /callback#bearer_only: true#' \
  spec/contract-kong.yml > "$tmp/bearer-without-introspection.yml"
rejects "bearer only without introspection" "$tmp/bearer-without-introspection.yml" \
  "bearer_only requires introspection_endpoint"

sed '$a\
          filters: ["health"]
' spec/contract-kong.yml > "$tmp/non-absolute-filter.yml"
rejects "non-absolute filter" "$tmp/non-absolute-filter.yml" \
  "filter entries must be non-empty absolute paths"

sed '$a\
          filters: [""]
' spec/contract-kong.yml > "$tmp/empty-filter.yml"
rejects "empty filter" "$tmp/empty-filter.yml" \
  "filter entries must be non-empty absolute paths"

sed '$a\
          token_endpoint_auth_method: private_key_jwt
' spec/contract-kong.yml > "$tmp/private-key-jwt.yml"
rejects "unsupported private key JWT authentication" "$tmp/private-key-jwt.yml" \
  "expected one of"

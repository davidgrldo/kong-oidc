# Changelog

## 2.0.0 - 2026-07-16

### Breaking changes

- Migrated the plugin to Kong OSS 3.9.3 modules; Kong 2.x configs no longer load.
  The legacy `BasePlugin` handler is replaced with a plain Kong 3 handler table.
- Schema is now a Kong 3 typed `record` with cross-field validation.
  Configuration compatibility with 1.x is intentionally broken:
  - String booleans (`"yes"`/`"no"`) are now real booleans.
  - `redirect_uri_path` is renamed to `redirect_uri`.
  - CSV `filters` are now a YAML array of exact absolute paths.
  - Browser mode now requires a base64 `session_secret` of at least 32 decoded bytes.

### Dependencies

- Pinned to `lua-resty-openidc 1.8.0-1` (session 4.x options passed explicitly).
- LuaRock `kong-oidc 2.0.0-1`; Docker image built on `kong:3.9.3`.

### Security

- TLS verification defaults to enabled (`ssl_verify=true`).
- `http://` OIDC endpoints rejected unless `allow_insecure_http=true` (local dev only).
- Plugin-owned identity headers (`X-Userinfo`, `X-ID-Token`, `X-Access-Token`)
  are stripped from client requests before authentication to prevent spoofing.
- Bearer-only mode returns `401` on failure with no browser fallback.
- Browser errors return a generic `500` body; raw provider details stay in logs only.
- `private_key_jwt` authentication is rejected (unsupported).
- Compose stack binds the Admin API to loopback and ships no committed credentials.

### Tests

- Lua unit tests for filters, session, utils, and handler behavior (`spec/`).
- Kong 3 schema contract tests including rejection cases (`scripts/contract-test.sh`).
- DB-less container smoke test (`scripts/smoke-test.sh`).

### Documentation

- README covering compatibility, configuration, security, DB-less and PostgreSQL
  deployments, session secrets, identity headers, filters, troubleshooting, and
  upgrading.

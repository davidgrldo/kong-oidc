# Kong OIDC Modernization Design

## Status

Approved on 2026-07-16.

## Objective

Modernize this Apache-2.0 Kong OIDC plugin for public open-source use on Kong
OSS 3.9.3, fix every security and operability issue found during review, and
provide reproducible builds, automated tests, and safe examples.

Kong OSS 3.9.3 is selected because it is the newest public OSS image available
without an Enterprise license. Kong's formal LTS guarantee applies to the
Enterprise product, so this project must describe 3.9.3 as its supported OSS
baseline rather than claim vendor-backed LTS support.

## Scope

The work includes:

- migrating the plugin from the removed `BasePlugin` API to the Kong 3.x
  handler and schema APIs;
- upgrading and pinning the OIDC/session dependency chain;
- securing transport, sessions, identity headers, bearer-token behavior,
  filters, and client-visible errors;
- producing a minimal DB-less quick-start stack and an optional identity
  provider demo stack;
- preserving compatibility with both DB-less and PostgreSQL-backed Kong
  deployments;
- replacing the empty README and adding open-source project documentation;
- adding unit, contract, build, and container smoke tests in CI.

The work does not add Enterprise-only features, a graphical administration
tool, custom database entities, or new authentication flows beyond browser
OIDC Authorization Code and OAuth 2.0 token introspection.

## Runtime and Distribution

- Runtime baseline: Kong OSS `3.9.3`, pinned exactly in build and CI files.
- Plugin version: `2.0.0`, reflecting the breaking configuration and runtime
  migration from the legacy plugin.
- OIDC library: `lua-resty-openidc 1.8.0-1`, fetched over HTTPS.
- Session library: the `lua-resty-session >= 4.0.3` dependency selected by the
  pinned OIDC rock.
- Primary distribution: source repository and a LuaRock built from the local
  rockspec.
- Supporting distribution: a reproducible Docker image for quick starts,
  integration testing, and CI. The image is not a separate product.
- License: retain Apache License 2.0 and document that this repository is a
  modified fork of Nokia's `kong-oidc`.

The rockspec must use an HTTPS source URL and must not depend on an obsolete
LuaRocks mirror. The Docker build must prove dependency resolution from a clean
cache.

## Plugin Architecture

### Handler

`handler.lua` returns a plain Kong 3.x handler table containing:

- `VERSION = "2.0.0"`;
- `PRIORITY = 1000`;
- `access(self, config)` as the request entry point.

All helper functions remain local to their modules. No authentication helper
is placed in the Lua global namespace.

### Schema

`schema.lua` uses the Kong 3.x record schema:

- plugin name `oidc`;
- HTTP/HTTPS protocols only;
- no Consumer-scoped configuration;
- a `config` record with typed fields and defaults;
- entity checks for endpoint security and session-secret validity.

Boolean behavior is represented as booleans, not the legacy strings `"yes"`
and `"no"`. Filters are an array of exact paths rather than comma-separated
Lua patterns.

### Supporting modules

- `filter.lua` owns exact-path exclusion behavior.
- `session.lua` validates and decodes the session secret and creates the
  session options expected by `lua-resty-session` 4.x.
- `utils.lua` maps Kong configuration to OIDC options, sanitizes identity
  headers, injects authenticated identity, parses Authorization headers, and
  returns safe errors.

These modules expose only the functions needed by the handler and are directly
unit-testable with a small fake `ngx`/Kong request context.

## Request Flow and Security Rules

### Trust boundary

At the beginning of every plugin invocation, before filter evaluation, remove
the following client-supplied request headers:

- `X-Userinfo`;
- `X-ID-Token`;
- `X-Access-Token`.

Only validated OIDC or introspection results may recreate these headers.
Filtered public requests therefore cannot smuggle plugin-owned identity
headers to an upstream service.

### Filter behavior

`config.filters` is an array of absolute URI paths. A request is excluded only
when `ngx.var.uri` exactly equals an entry. For example, `/health` excludes
`/health` but not `/health-admin` or `/health/live`.

The schema rejects entries that are empty or do not start with `/`. Lua pattern
syntax is never evaluated.

### Bearer-token behavior

When `introspection_endpoint` is configured and an Authorization header uses
the Bearer scheme:

1. introspect the token;
2. on success, inject claims derived from the introspection result;
3. on inactive, missing, malformed, or failed introspection, return `401`;
4. never fall back to an interactive browser session for a request that
   supplied a Bearer credential.

When `bearer_only` is true, a request without a valid Bearer token also returns
`401` with a correctly formatted `WWW-Authenticate` header.

### Browser OIDC behavior

Requests without Bearer credentials use the Authorization Code flow unless
`bearer_only` is enabled. Redirect and logout behavior remains configurable.
The plugin passes explicit session options to the supported session API rather
than mutating an Nginx variable.

### Session secret

`session_secret` is required for browser OIDC mode. Its configuration value is
base64 and must decode to at least 32 bytes. Validation occurs when Kong loads
the plugin configuration, not during an end-user request.

The same secret must be supplied to every Kong node. Documentation shows a
portable OpenSSL command that produces a valid value and warns that changing
the secret invalidates existing sessions.

### Transport security

- TLS verification defaults to enabled.
- Discovery and introspection endpoints must use HTTPS.
- An explicit `allow_insecure_http` boolean permits HTTP only for local
  development and defaults to false.
- Enabling `allow_insecure_http` does not disable certificate verification for
  HTTPS endpoints.

### Error handling

Detailed OIDC and HTTP errors are written to Kong's error log. Client responses
contain stable generic messages and appropriate status codes:

- `401` for missing or invalid bearer credentials;
- `500` for an OIDC provider or internal authentication failure;
- redirect to `recovery_page_path` when configured for browser-flow failures.

Raw dependency errors are never echoed in response bodies or interpolated into
response headers.

## Deployment Examples

### Default quick start

The default Compose stack is DB-less and contains only the custom Kong image.
It mounts a valid declarative `kong.yml`, runs as the image's non-root user,
and publishes:

- proxy HTTP/HTTPS ports for testing;
- the Admin API on `127.0.0.1` only.

Because DB-less Admin API entity endpoints are read-only, remote clients cannot
reconfigure the gateway through the example stack.

### Optional identity-provider demo

Keycloak and any supporting datastore live in a separate optional Compose
profile or file. Demo credentials are supplied through ignored environment
variables with non-secret examples in `.env.example`. Database and LDAP ports
are not published unless required by a documented local debugging workflow.

Konga is removed because it is not needed to demonstrate or operate the
plugin. No external Docker network, fixed subnet, static container IP, or
globally named container is required.

### Production guidance

The README documents both DB-less and PostgreSQL-backed Kong deployments. The
plugin itself does not inspect or depend on the Kong database strategy.
Production guidance requires keeping the Admin API on a private management
network and sourcing client/session secrets from the deployment platform's
secret mechanism.

## Testing Strategy

### Unit tests

Plain Lua tests cover:

- exact filter matches and near misses;
- rejection of malformed filter configuration;
- removal of all plugin-owned identity headers;
- injection only from validated response data;
- Bearer scheme parsing, including duplicate/malformed headers;
- base64 session-secret validation and minimum decoded length;
- OIDC option mapping and secure defaults;
- generic client errors that do not contain raw provider failures.

Tests use the smallest local test harness that provides clear assertions and a
non-zero exit code. A new external test framework is added only if Kong's image
already supplies it and it materially reduces test code.

### Kong contract tests

Inside the pinned Kong OSS image, tests load the plugin handler and schema and
assert:

- handler version and priority are valid;
- Kong accepts representative secure DB-less configuration;
- Kong rejects missing/weak session secrets, unsafe endpoints without the
  development escape hatch, and malformed filters.

### Container smoke tests

CI performs a clean Docker build, starts the DB-less stack, waits for Kong
health, confirms the OIDC plugin is enabled, checks proxy/Admin bindings, and
shuts the stack down even after failures.

### Continuous integration

GitHub Actions runs on pull requests and pushes:

1. Lua syntax checks;
2. unit tests;
3. Kong schema/handler contract checks;
4. a clean Docker build;
5. the DB-less smoke test.

## Documentation and Repository Hygiene

The README includes:

- project purpose and security model;
- Kong/dependency compatibility matrix;
- LuaRock and Docker installation;
- DB-less quick start;
- PostgreSQL-backed installation guidance;
- generic Keycloak configuration;
- complete configuration reference;
- session-secret generation and rotation;
- identity-header contract;
- filtering semantics;
- troubleshooting and upgrade notes;
- upstream attribution and license.

The repository also contains:

- `CHANGELOG.md` starting at `2.0.0`;
- `.env.example` containing names and safe placeholders only;
- `.gitignore` entries for real environment files;
- CI workflow files;
- no credential-shaped values in tracked configuration or current examples.

## Acceptance Criteria

The modernization is complete when all of the following are true:

1. A clean Docker build succeeds on the pinned Kong OSS 3.9.3 base.
2. Kong 3.9.3 loads the plugin and accepts a secure configuration.
3. All unit, contract, and smoke tests pass.
4. Identity headers from clients never survive a plugin invocation.
5. Invalid Bearer credentials return `401` without browser fallback.
6. TLS verification is enabled by default and insecure HTTP requires an
   explicit development option.
7. Filters use exact paths and cannot execute Lua patterns.
8. Browser mode cannot be configured with a missing or weak session secret.
9. Default Compose deployment exposes no writable Admin API or database to
   non-loopback interfaces.
10. The repository contains no embedded credentials and documents both
    supported Kong deployment strategies.

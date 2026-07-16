# Kong OIDC Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a secure, documented, reproducibly built Kong OIDC 2.0.0 plugin for Kong OSS 3.9.3.

**Architecture:** Replace the legacy BasePlugin and schema with Kong 3.x modules, isolate request/filter/session behavior in directly testable Lua modules, and pass explicit session options to `lua-resty-openidc 1.8.0`. Distribute the LuaRock as the primary artifact and use a pinned Docker image plus DB-less configuration for contract and smoke testing.

**Tech Stack:** Lua 5.1/LuaJIT, Kong OSS 3.9.3, lua-resty-openidc 1.8.0-1, lua-resty-session 4.x, Docker Compose, GitHub Actions.

## Global Constraints

- Runtime baseline is exactly Kong OSS `3.9.3`; do not describe it as vendor-backed LTS.
- Plugin version is `2.0.0` and configuration compatibility with 1.x is intentionally broken.
- TLS verification defaults to enabled; HTTP endpoints require `allow_insecure_http=true`.
- Browser mode requires a base64 session secret that decodes to at least 32 bytes.
- Client-provided `X-Userinfo`, `X-ID-Token`, and `X-Access-Token` never reach upstream services.
- Filters are exact absolute paths and never Lua patterns.
- Invalid bearer credentials return `401` without browser fallback.
- Keep Apache-2.0 licensing and upstream Nokia attribution.
- Add no Enterprise-only dependency or feature.

---

## File Map

- `plugins/oidc/kong/plugins/oidc/handler.lua`: Kong request phase and OIDC/introspection orchestration.
- `plugins/oidc/kong/plugins/oidc/schema.lua`: Kong 3.x configuration schema and cross-field validation.
- `plugins/oidc/kong/plugins/oidc/filter.lua`: exact-path exclusion.
- `plugins/oidc/kong/plugins/oidc/session.lua`: session secret validation and session 4.x options.
- `plugins/oidc/kong/plugins/oidc/utils.lua`: option mapping, header trust boundary, bearer parsing, identity injection.
- `plugins/oidc/kong-oidc-2.0.0-1.rockspec`: reproducible LuaRock metadata.
- `spec/test_helper.lua`: minimal assertion and fake Kong/ngx helpers.
- `spec/filter_spec.lua`, `spec/session_spec.lua`, `spec/utils_spec.lua`, `spec/handler_spec.lua`: unit regression tests.
- `spec/run.lua`: unit test entry point.
- `spec/contract-kong.yml`, `scripts/contract-test.sh`, `scripts/smoke-test.sh`: Kong/container verification.
- `Dockerfile`, `docker-compose.yml`, `config/kong.yml`: pinned build and safe DB-less quick start.
- `docker-compose.demo.yml`, `.env.example`: optional Keycloak demonstration.
- `.github/workflows/ci.yml`: pull-request and push verification.
- `README.md`, `CHANGELOG.md`, `.gitignore`: public project documentation and hygiene.

### Task 1: Minimal Lua test harness and exact filters

**Files:**
- Create: `spec/test_helper.lua`
- Create: `spec/filter_spec.lua`
- Create: `spec/run.lua`
- Modify: `plugins/oidc/kong/plugins/oidc/filter.lua`

**Interfaces:**
- Produces: `filter.should_process(filters, path) -> boolean`.
- Produces: `test_helper.test(name, fn)`, `test_helper.equal(actual, expected)`, and `test_helper.finish()`.

- [ ] **Step 1: Write the test harness and failing filter regression tests**

```lua
-- spec/test_helper.lua
local M = { failures = 0 }

function M.equal(actual, expected)
  if actual ~= expected then
    error(("expected %s, got %s"):format(tostring(expected), tostring(actual)), 2)
  end
end

function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.write("ok - ", name, "\n")
  else
    M.failures = M.failures + 1
    io.stderr:write("not ok - ", name, ": ", err, "\n")
  end
end

function M.finish()
  if M.failures > 0 then os.exit(1) end
end

return M
```

```lua
-- spec/filter_spec.lua
local t = require "spec.test_helper"
local filter = require "kong.plugins.oidc.filter"

t.test("filters exact path", function()
  t.equal(filter.should_process({ "/health" }, "/health"), false)
end)

t.test("does not filter path prefix", function()
  t.equal(filter.should_process({ "/health" }, "/health-admin"), true)
end)

t.test("does not evaluate Lua patterns", function()
  t.equal(filter.should_process({ "[" }, "/anything"), true)
end)
```

```lua
-- spec/run.lua
require "spec.filter_spec"
require("spec.test_helper").finish()
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `LUA_PATH='./spec/?.lua;./plugins/oidc/?.lua;./plugins/oidc/?/init.lua;;' lua -e 'require "spec.filter_spec"; require("spec.test_helper").finish()'`

Expected: failure because `should_process` does not exist.

- [ ] **Step 3: Implement the exact-match filter**

```lua
local M = {}

function M.should_process(filters, path)
  for _, excluded_path in ipairs(filters or {}) do
    if path == excluded_path then
      return false
    end
  end
  return true
end

return M
```

- [ ] **Step 4: Run the focused test and confirm GREEN**

Run the Step 2 command. Expected: three `ok` lines and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add spec/test_helper.lua spec/filter_spec.lua spec/run.lua plugins/oidc/kong/plugins/oidc/filter.lua
git commit -m "test: define exact OIDC path filters"
```

### Task 2: Session and request trust-boundary utilities

**Files:**
- Create: `spec/session_spec.lua`
- Create: `spec/utils_spec.lua`
- Modify: `spec/run.lua`
- Modify: `plugins/oidc/kong/plugins/oidc/session.lua`
- Modify: `plugins/oidc/kong/plugins/oidc/utils.lua`

**Interfaces:**
- Produces: `session.decode_secret(encoded) -> decoded|nil, error`.
- Produces: `session.options(config) -> lua-resty-session configuration`.
- Produces: `utils.clear_identity_headers()`, `utils.bearer_present(value)`, `utils.get_options(config)`, and `utils.inject_identity(response)`.

- [ ] **Step 1: Write failing session tests**

```lua
-- spec/session_spec.lua
local t = require "spec.test_helper"
_G.ngx = { decode_base64 = function(value)
  if value == "valid" then return string.rep("s", 32) end
  if value == "short" then return "short" end
end }
package.loaded["kong.plugins.oidc.session"] = nil
local session = require "kong.plugins.oidc.session"

t.test("accepts 32 byte decoded secret", function()
  local secret = assert(session.decode_secret("valid"))
  t.equal(#secret, 32)
end)

t.test("rejects malformed secret", function()
  local value, err = session.decode_secret("bad")
  t.equal(value, nil)
  t.equal(err, "session_secret must be valid base64")
end)

t.test("rejects short secret", function()
  local value, err = session.decode_secret("short")
  t.equal(value, nil)
  t.equal(err, "session_secret must decode to at least 32 bytes")
end)
```

- [ ] **Step 2: Run session tests and confirm RED**

Run: `LUA_PATH='./spec/?.lua;./plugins/oidc/?.lua;./plugins/oidc/?/init.lua;;' lua -e 'require "spec.session_spec"; require("spec.test_helper").finish()'`

Expected: failure because `decode_secret` is missing.

- [ ] **Step 3: Implement session 4.x options**

```lua
local M = {}

function M.decode_secret(encoded)
  local decoded = encoded and ngx.decode_base64(encoded)
  if not decoded then
    return nil, "session_secret must be valid base64"
  end
  if #decoded < 32 then
    return nil, "session_secret must decode to at least 32 bytes"
  end
  return decoded
end

function M.options(config)
  local secret, err = M.decode_secret(config.session_secret)
  if not secret then return nil, err end
  return {
    secret = secret,
    cookie_http_only = true,
    cookie_same_site = "Lax",
    cookie_secure = not config.allow_insecure_http,
  }
end

return M
```

- [ ] **Step 4: Run session tests and confirm GREEN**

Run the Step 2 command. Expected: three `ok` lines and exit code 0.

- [ ] **Step 5: Write failing header and option tests**

```lua
-- spec/utils_spec.lua
local t = require "spec.test_helper"
local cleared, set = {}, {}
_G.ngx = {
  encode_base64 = function(value) return "b64:" .. value end,
}
_G.kong = {
  service = { request = {
    clear_header = function(name) cleared[#cleared + 1] = name end,
    set_header = function(name, value) set[name] = value end,
  } },
}
package.loaded.cjson = { encode = function(value) return value.sub or "token" end }
package.loaded["kong.plugins.oidc.utils"] = nil
local utils = require "kong.plugins.oidc.utils"

t.test("clears all owned identity headers", function()
  utils.clear_identity_headers()
  t.equal(table.concat(cleared, ","), "X-Userinfo,X-ID-Token,X-Access-Token")
end)

t.test("detects bearer case insensitively", function()
  t.equal(utils.bearer_present("bEaReR token"), true)
  t.equal(utils.bearer_present("Basic token"), false)
  t.equal(utils.bearer_present({ "Bearer a", "Bearer b" }), false)
end)

t.test("maps secure defaults", function()
  local options = utils.get_options({
    client_id = "client", client_secret = "secret",
    discovery = "https://issuer/.well-known/openid-configuration",
    ssl_verify = true, token_endpoint_auth_method = "client_secret_post",
    scope = "openid", response_type = "code", redirect_uri = "/callback",
    logout_path = "/logout", redirect_after_logout_uri = "/",
  })
  t.equal(options.ssl_verify, "yes")
  t.equal(options.redirect_uri, "/callback")
end)

t.test("does not invent missing user identity", function()
  utils.inject_identity({ id_token = { sub = "id" }, access_token = "access" })
  t.equal(set["X-Userinfo"], nil)
  t.equal(set["X-Access-Token"], "access")
end)
```

- [ ] **Step 6: Run utility tests and confirm RED**

Run: `LUA_PATH='./spec/?.lua;./plugins/oidc/?.lua;./plugins/oidc/?/init.lua;;' lua -e 'require "spec.utils_spec"; require("spec.test_helper").finish()'`

Expected: failure because `clear_identity_headers` is missing.

- [ ] **Step 7: Implement the utility trust boundary**

Replace `utils.lua` with a module that:

```lua
local cjson = require "cjson"
local M = {}
local IDENTITY_HEADERS = { "X-Userinfo", "X-ID-Token", "X-Access-Token" }

function M.clear_identity_headers()
  for _, name in ipairs(IDENTITY_HEADERS) do
    kong.service.request.clear_header(name)
  end
end

function M.bearer_present(value)
  return type(value) == "string" and value:match("^%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+%S+") ~= nil
end

function M.get_options(config)
  return {
    client_id = config.client_id,
    client_secret = config.client_secret,
    discovery = config.discovery,
    introspection_endpoint = config.introspection_endpoint,
    timeout = config.timeout,
    introspection_endpoint_auth_method = config.introspection_endpoint_auth_method,
    redirect_uri = config.redirect_uri,
    scope = config.scope,
    response_type = config.response_type,
    ssl_verify = config.ssl_verify and "yes" or "no",
    token_endpoint_auth_method = config.token_endpoint_auth_method,
    logout_path = config.logout_path,
    redirect_after_logout_uri = config.redirect_after_logout_uri,
  }
end

function M.inject_identity(response)
  if response.user then
    local user = response.user
    user.id = user.sub
    user.username = user.preferred_username
    ngx.ctx.authenticated_credential = user
    kong.service.request.set_header("X-Userinfo", ngx.encode_base64(cjson.encode(user)))
  end
  if response.id_token then
    kong.service.request.set_header("X-ID-Token", ngx.encode_base64(cjson.encode(response.id_token)))
  end
  if response.access_token then
    kong.service.request.set_header("X-Access-Token", response.access_token)
  end
end

return M
```

- [ ] **Step 8: Run utility tests and the complete unit runner**

Add the new specs to `spec/run.lua` before `finish()`:

```lua
require "spec.filter_spec"
require "spec.session_spec"
require "spec.utils_spec"
require("spec.test_helper").finish()
```

Run the Step 6 command, then run:

`LUA_PATH='./spec/?.lua;./plugins/oidc/?.lua;./plugins/oidc/?/init.lua;;' lua spec/run.lua`

Expected: all defined tests emit `ok` and exit 0.

- [ ] **Step 9: Commit**

```bash
git add spec/session_spec.lua spec/utils_spec.lua spec/run.lua plugins/oidc/kong/plugins/oidc/session.lua plugins/oidc/kong/plugins/oidc/utils.lua
git commit -m "fix: enforce OIDC request trust boundary"
```

### Task 3: Modern handler and bearer failure behavior

**Files:**
- Create: `spec/handler_spec.lua`
- Modify: `spec/run.lua`
- Modify: `plugins/oidc/kong/plugins/oidc/handler.lua`

**Interfaces:**
- Consumes: filter, session, and utils interfaces from Tasks 1-2.
- Produces: Kong handler table with `VERSION`, `PRIORITY`, and `access`.

- [ ] **Step 1: Write failing handler tests**

Build `spec/handler_spec.lua` with fake `kong`, `ngx`, and `resty.openidc` modules. The complete behavioral cases are:

```lua
local t = require "spec.test_helper"
local calls, exits = {}, {}
local request_path = "/private"
local authorization = "Bearer invalid"
_G.ngx = {
  ctx = {},
  encode_base64 = function(v) return v end,
  decode_base64 = function() return string.rep("s", 32) end,
}
_G.kong = {
  request = {
    get_path = function() return request_path end,
    get_header = function() return authorization end,
  },
  service = { request = {
    clear_header = function(name) calls[#calls + 1] = "clear:" .. name end,
    set_header = function() end,
  } },
  response = { exit = function(status, body, headers)
    exits[#exits + 1] = { status = status, body = body, headers = headers }
    return exits[#exits]
  end },
  log = { err = function() end },
}
package.loaded.cjson = { encode = function() return "{}" end }
local openidc = {
  introspect = function() return nil, "invalid token" end,
  authenticate = function() error("must not fall back to browser authentication") end,
}
package.loaded["resty.openidc"] = openidc
package.loaded["kong.plugins.oidc.handler"] = nil
local handler = require "kong.plugins.oidc.handler"

local config = {
  filters = {}, client_id = "client", client_secret = "secret",
  discovery = "https://issuer/.well-known/openid-configuration",
  introspection_endpoint = "https://issuer/introspect",
  bearer_only = false, realm = "kong", ssl_verify = true,
  scope = "openid", response_type = "code", redirect_uri = "/callback",
  token_endpoint_auth_method = "client_secret_post",
  introspection_endpoint_auth_method = "client_secret_basic",
  logout_path = "/logout", redirect_after_logout_uri = "/",
}

t.test("exports Kong 3 handler metadata", function()
  t.equal(handler.VERSION, "2.0.0")
  t.equal(handler.PRIORITY, 1000)
end)

t.test("invalid bearer token returns 401 without browser fallback", function()
  local result = handler:access(config)
  t.equal(result.status, 401)
  t.equal(result.body.message, "Unauthorized")
  t.equal(result.headers["WWW-Authenticate"], 'Bearer realm="kong"')
end)

t.test("clears identity headers before authentication", function()
  t.equal(calls[1], "clear:X-Userinfo")
end)
```

- [ ] **Step 2: Run handler tests and confirm RED**

Run: `LUA_PATH='./spec/?.lua;./plugins/oidc/?.lua;./plugins/oidc/?/init.lua;;' lua -e 'require "spec.handler_spec"; require("spec.test_helper").finish()'`

Expected: the legacy `kong.plugins.base_plugin` require fails or VERSION is missing.

- [ ] **Step 3: Implement the Kong 3 handler**

Implement a plain handler table with this control flow:

```lua
local openidc = require "resty.openidc"
local filter = require "kong.plugins.oidc.filter"
local session = require "kong.plugins.oidc.session"
local utils = require "kong.plugins.oidc.utils"

local Handler = { VERSION = "2.0.0", PRIORITY = 1000 }

local function unauthorized(realm)
  return kong.response.exit(401, { message = "Unauthorized" }, {
    ["WWW-Authenticate"] = 'Bearer realm="' .. realm .. '"',
  })
end

function Handler:access(config)
  utils.clear_identity_headers()
  if not filter.should_process(config.filters, kong.request.get_path()) then return end

  local options = utils.get_options(config)
  local bearer = utils.bearer_present(kong.request.get_header("authorization"))
  if bearer or config.bearer_only then
    local response, err = openidc.introspect(options)
    if err or not response or response.active == false then
      kong.log.err("OIDC introspection failed: ", err or "inactive token")
      return unauthorized(config.realm)
    end
    utils.inject_identity({ user = response })
    return
  end

  local session_options, session_err = session.options(config)
  if not session_options then
    kong.log.err("OIDC session configuration failed: ", session_err)
    return kong.response.exit(500, { message = "Authentication failed" })
  end

  local response, err = openidc.authenticate(options, nil, nil, session_options)
  if err then
    kong.log.err("OIDC authentication failed: ", err)
    if config.recovery_page_path then
      return kong.response.exit(302, nil, { Location = config.recovery_page_path })
    end
    return kong.response.exit(500, { message = "Authentication failed" })
  end
  if response then utils.inject_identity(response) end
end

return Handler
```

- [ ] **Step 4: Add success, bearer-only, filter, and generic-error cases**

Extend the same spec by resetting fake state and dependency return values for:

- valid introspection injects user claims and returns no response;
- bearer-only without a token returns `401`;
- filtered paths clear headers but call neither introspection nor authenticate;
- raw provider error text appears in logs but not the response body;
- browser authentication receives a decoded 32-byte session secret.

Use these concrete cases after the initial assertions:

```lua
t.test("valid introspection injects user claims", function()
  authorization = "Bearer valid"
  openidc.introspect = function() return { active = true, sub = "user-1" } end
  local before = #exits
  handler:access(config)
  t.equal(#exits, before)
end)

t.test("bearer only rejects missing token", function()
  authorization = nil
  config.bearer_only = true
  openidc.introspect = function() return nil, "no token" end
  local result = handler:access(config)
  t.equal(result.status, 401)
  config.bearer_only = false
end)

t.test("filtered request clears headers without authenticating", function()
  request_path = "/health"
  authorization = nil
  config.filters = { "/health" }
  local called = false
  openidc.introspect = function() called = true end
  openidc.authenticate = function() called = true end
  handler:access(config)
  t.equal(called, false)
  request_path = "/private"
  config.filters = {}
end)

t.test("browser errors are generic and session options are explicit", function()
  authorization = nil
  config.session_secret = "valid"
  local received
  openidc.authenticate = function(_, _, _, options)
    received = options
    return nil, "provider leaked detail"
  end
  local result = handler:access(config)
  t.equal(#received.secret, 32)
  t.equal(result.status, 500)
  t.equal(result.body.message, "Authentication failed")
end)
```

- [ ] **Step 5: Run all unit tests and confirm GREEN**

Add `require "spec.handler_spec"` immediately before `finish()` in
`spec/run.lua`.

Run: `LUA_PATH='./spec/?.lua;./plugins/oidc/?.lua;./plugins/oidc/?/init.lua;;' lua spec/run.lua`

Expected: all tests pass and output contains no `not ok` lines.

- [ ] **Step 6: Commit**

```bash
git add spec/handler_spec.lua spec/run.lua plugins/oidc/kong/plugins/oidc/handler.lua
git commit -m "feat: migrate OIDC handler to Kong 3"
```

### Task 4: Kong 3 schema and contract validation

**Files:**
- Modify: `plugins/oidc/kong/plugins/oidc/schema.lua`
- Create: `spec/contract-kong.yml`
- Create: `scripts/contract-test.sh`

**Interfaces:**
- Produces: Kong schema named `oidc` with a typed `config` record.
- Consumes: session minimum length and endpoint rules from the approved design.

- [ ] **Step 1: Add a contract fixture that the legacy schema cannot parse on Kong 3.9.3**

```yaml
_format_version: "3.0"
services:
  - name: echo
    url: https://httpbin.org/anything
    routes:
      - name: echo
        paths: ["/echo"]
    plugins:
      - name: oidc
        config:
          client_id: example
          client_secret: example
          discovery: https://issuer.example/.well-known/openid-configuration
          redirect_uri: /callback
          session_secret: MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=
```

```sh
#!/bin/sh
set -eu
docker run --rm \
  -v "$PWD/plugins/oidc/kong/plugins/oidc:/usr/local/share/lua/5.1/kong/plugins/oidc:ro" \
  -v "$PWD/spec/contract-kong.yml:/tmp/kong.yml:ro" \
  -e KONG_DATABASE=off \
  -e KONG_PLUGINS=bundled,oidc \
  kong:3.9.3 kong config parse /tmp/kong.yml
```

- [ ] **Step 2: Run the contract test and confirm RED**

Run: `sh scripts/contract-test.sh`

Expected: Kong rejects the legacy schema or handler.

- [ ] **Step 3: Implement the Kong 3 record schema**

Use `kong.db.schema.typedefs.protocols_http`, typed booleans, `one_of` constraints for authentication methods, an array field for filters, and a `custom_validator(config)` that enforces:

```lua
local function secure_url(value, allow_insecure)
  if not value then return true end
  if value:match("^https://") then return true end
  if allow_insecure and value:match("^http://") then return true end
  return nil, "OIDC endpoints must use HTTPS unless allow_insecure_http is true"
end

local function validate(config)
  local ok, err = secure_url(config.discovery, config.allow_insecure_http)
  if not ok then return nil, err end
  ok, err = secure_url(config.introspection_endpoint, config.allow_insecure_http)
  if not ok then return nil, err end
  if config.bearer_only and not config.introspection_endpoint then
    return nil, "bearer_only requires introspection_endpoint"
  end
  if not config.bearer_only then
    local decoded = config.session_secret and ngx.decode_base64(config.session_secret)
    if not decoded or #decoded < 32 then
      return nil, "browser mode requires a base64 session_secret of at least 32 decoded bytes"
    end
    if not config.redirect_uri then
      return nil, "browser mode requires redirect_uri"
    end
  end
  return true
end
```

The schema must declare defaults: `ssl_verify=true`, `allow_insecure_http=false`, `bearer_only=false`, `realm="kong"`, `scope="openid"`, `response_type="code"`, `token_endpoint_auth_method="client_secret_post"`, `introspection_endpoint_auth_method="client_secret_basic"`, `logout_path="/logout"`, `redirect_after_logout_uri="/"`, and `filters={}`.

- [ ] **Step 4: Run the valid contract and confirm GREEN**

Run the Step 2 command. Expected: `parse successful`.

- [ ] **Step 5: Add invalid contract cases**

Make `scripts/contract-test.sh` create temporary fixture variants with `sed` in a temporary directory and assert that Kong rejects:

- HTTP discovery without `allow_insecure_http`;
- browser mode without `session_secret`;
- a decoded secret shorter than 32 bytes;
- `bearer_only=true` without `introspection_endpoint`;
- a filter entry that does not start with `/`.

The script must remove its temporary directory with `trap 'rm -rf "$tmp"' EXIT`.

- [ ] **Step 6: Run unit and contract tests**

Run `lua spec/run.lua` with the project `LUA_PATH`, then `sh scripts/contract-test.sh`. Expected: both exit 0.

- [ ] **Step 7: Commit**

```bash
git add plugins/oidc/kong/plugins/oidc/schema.lua spec/contract-kong.yml scripts/contract-test.sh
git commit -m "feat: add Kong 3 OIDC configuration schema"
```

### Task 5: Reproducible LuaRock and Kong image

**Files:**
- Delete: `plugins/oidc/kong-oidc-1.1.0-0.rockspec`
- Create: `plugins/oidc/kong-oidc-2.0.0-1.rockspec`
- Modify: `Dockerfile`
- Create: `.dockerignore`

**Interfaces:**
- Produces: local LuaRock `kong-oidc 2.0.0-1` and image based on `kong:3.9.3`.

- [ ] **Step 1: Confirm the existing clean build fails**

Run: `docker build --no-cache -t kong-oidc:test .`

Expected: failure resolving `lua-resty-openidc ~> 1.6.1-1`.

- [ ] **Step 2: Replace the rockspec**

The new rockspec must declare:

```lua
package = "kong-oidc"
version = "2.0.0-1"
source = {
  url = "git+https://github.com/davidgrldo/kong-oidc",
}
description = {
  summary = "OpenID Connect and token introspection plugin for Kong Gateway",
  homepage = "https://github.com/davidgrldo/kong-oidc",
  license = "Apache-2.0",
}
dependencies = {
  "lua >= 5.1",
  "lua-resty-openidc == 1.8.0-1",
}
build = {
  type = "builtin",
  modules = {
    ["kong.plugins.oidc.filter"] = "kong/plugins/oidc/filter.lua",
    ["kong.plugins.oidc.handler"] = "kong/plugins/oidc/handler.lua",
    ["kong.plugins.oidc.schema"] = "kong/plugins/oidc/schema.lua",
    ["kong.plugins.oidc.session"] = "kong/plugins/oidc/session.lua",
    ["kong.plugins.oidc.utils"] = "kong/plugins/oidc/utils.lua",
  },
}
```

- [ ] **Step 3: Modernize the Dockerfile**

Use exact `FROM kong:3.9.3`, copy only the plugin source, switch to root only for `luarocks make`, remove the source after installation, and return to `USER kong`. Set `ENV KONG_PLUGINS=bundled,oidc`; do not bake configuration or secrets into the image.

- [ ] **Step 4: Build from a clean cache and confirm GREEN**

Run: `docker build --no-cache -t kong-oidc:test .`

Expected: successful installation of `kong-oidc 2.0.0-1` and `lua-resty-openidc 1.8.0-1`.

- [ ] **Step 5: Verify installed modules and version**

Run:

```bash
docker run --rm kong-oidc:test kong version
docker run --rm kong-oidc:test luarocks show kong-oidc
```

Expected: Kong `3.9.3` and rock `2.0.0-1`.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile .dockerignore plugins/oidc
git commit -m "build: pin Kong OSS and OIDC dependencies"
```

### Task 6: Safe DB-less quick start and optional demo

**Files:**
- Modify: `docker-compose.yml`
- Modify: `config/kong.yml`
- Create: `docker-compose.demo.yml`
- Create: `.env.example`
- Modify: `.gitignore`
- Delete: `kong.conf`

**Interfaces:**
- Produces: minimal `docker compose up` DB-less stack.
- Produces: opt-in Keycloak demo with secrets supplied via environment.

- [ ] **Step 1: Write the smoke test before changing Compose**

Create `scripts/smoke-test.sh` that runs `docker compose config --quiet`, builds the image, starts the stack, polls `http://127.0.0.1:8001/status` for up to 60 seconds, asserts `/plugins/enabled` contains `oidc`, and always executes `docker compose down --volumes --remove-orphans` from an EXIT trap.

- [ ] **Step 2: Run the smoke test and confirm RED**

Run: `sh scripts/smoke-test.sh`.

Expected: current Compose fails because it requires the external `kong-net`, database migrations, and unrelated services.

- [ ] **Step 3: Replace the default stack**

The default Compose file must contain one `kong` service, use `build: .`, set `KONG_DATABASE=off`, mount `/opt/kong/kong.yml` read-only, bind proxy ports normally, and bind Admin ports as `127.0.0.1:8001:8001` and `127.0.0.1:8444:8444`. It must not override the image user or use `container_name`, static IPs, external networks, databases, Konga, LDAP, or credentials.

`config/kong.yml` must be syntactically valid `_format_version: "3.0"` and contain a disabled-by-documentation example Service/Route that users can replace with their own issuer/client values; no credential-shaped value may be committed.

- [ ] **Step 4: Add the optional demo file**

`docker-compose.demo.yml` adds a Keycloak service only when explicitly combined with the base file. It reads `KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET` from the environment, keeps its datastore internal, and publishes only Keycloak's local HTTP port on `127.0.0.1`.

`.env.example` contains safe placeholders such as `change-me`, never random credential-shaped strings. `.gitignore` ignores `.env` and `.env.*` while allowing `.env.example`.

- [ ] **Step 5: Run Compose validation and smoke test**

Run:

```bash
docker compose config --quiet
docker compose -f docker-compose.yml -f docker-compose.demo.yml config --quiet
sh scripts/smoke-test.sh
```

Expected: all exit 0; Admin API is reachable only through loopback bindings.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml docker-compose.demo.yml config/kong.yml .env.example .gitignore scripts/smoke-test.sh
git rm kong.conf
git commit -m "chore: add secure DB-less quick start"
```

### Task 7: Public documentation and CI

**Files:**
- Modify: `README.md`
- Create: `CHANGELOG.md`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: complete public usage contract and automated verification workflow.

- [ ] **Step 1: Add documentation checks**

Add shell assertions to `scripts/contract-test.sh` that README is non-empty and contains the headings `Compatibility`, `Installation`, `Configuration`, `Security`, `DB-less`, `PostgreSQL`, `Session secret`, `Identity headers`, `Filters`, `Troubleshooting`, `Upgrading`, and `License`.

- [ ] **Step 2: Run contract tests and confirm RED**

Run: `sh scripts/contract-test.sh`.

Expected: failure because README is empty.

- [ ] **Step 3: Write README and changelog**

Document these exact operational facts:

- supported baseline is Kong OSS 3.9.3, not vendor-backed LTS;
- generate a session secret with `openssl rand -base64 32`;
- default TLS verification is enabled;
- `allow_insecure_http` is local-development only;
- filters are exact absolute paths;
- plugin-owned identity headers are stripped from client requests;
- DB-less and PostgreSQL-backed deployments are both supported;
- the Admin API must remain on a private management network;
- upgrading from 1.x requires translating string booleans to booleans, `redirect_uri_path` to `redirect_uri`, CSV filters to an array, and setting a strong session secret;
- the project is a modified Apache-2.0 fork of Nokia `kong-oidc`.

Start `CHANGELOG.md` with `2.0.0 - Unreleased` and list the breaking Kong 3 migration, dependency upgrade, security changes, tests, and documentation.

- [ ] **Step 4: Add CI**

Create `.github/workflows/ci.yml` for `push` and `pull_request`, using `ubuntu-latest`, checkout, Lua syntax checks inside `kong:3.9.3`, unit tests, `scripts/contract-test.sh`, `docker build --no-cache`, and `scripts/smoke-test.sh`. Pin action majors and grant `contents: read` only.

- [ ] **Step 5: Run all local checks**

Run unit tests, contract tests, clean Docker build, Compose validation, and smoke test. Expected: all exit 0.

- [ ] **Step 6: Commit**

```bash
git add README.md CHANGELOG.md .github/workflows/ci.yml scripts/contract-test.sh
git commit -m "docs: publish Kong OIDC 2.0 usage and CI"
```

### Task 8: Final security and release verification

**Files:**
- Modify only files required by failures discovered in this task.

**Interfaces:**
- Produces: release-candidate evidence for every acceptance criterion.

- [ ] **Step 1: Run syntax and unit tests**

```bash
docker run --rm -v "$PWD:/work" -w /work kong:3.9.3 sh -ec '
  find plugins spec -name "*.lua" -exec luac -p {} \;
  LUA_PATH="./spec/?.lua;./plugins/oidc/?.lua;./plugins/oidc/?/init.lua;;" lua spec/run.lua
'
```

Expected: all Lua files parse and every unit test passes.

- [ ] **Step 2: Run contract, build, and smoke tests**

```bash
sh scripts/contract-test.sh
docker build --no-cache -t kong-oidc:2.0.0 .
docker compose config --quiet
sh scripts/smoke-test.sh
```

Expected: all commands exit 0.

- [ ] **Step 3: Scan tracked files for credentials and insecure defaults**

```bash
git ls-files -z | xargs -0 rg -n 'client_secret|PASSWORD=|TOKEN_SECRET|ssl_verify|http://' || true
```

Inspect every match. Expected: only documentation examples using placeholders or explicit local-development examples.

- [ ] **Step 4: Verify repository state and acceptance criteria**

Run `git diff --check`, `git status --short`, and re-read the ten acceptance criteria in the design specification. Fix any unmet criterion with a failing regression test first, then rerun the complete suite.

- [ ] **Step 5: Commit final corrections if necessary**

```bash
git add -A
git commit -m "fix: complete Kong OIDC 2.0 release verification"
```

Skip this commit only when Task 8 produces no file changes.

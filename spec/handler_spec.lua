local t = require "spec.test_helper"
local calls, exits, logs, set = {}, {}, {}, {}
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
    set_header = function(name, value) set[name] = value end,
  } },
  response = { exit = function(status, body, headers)
    exits[#exits + 1] = { status = status, body = body, headers = headers }
    return exits[#exits]
  end },
  log = { err = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    logs[#logs + 1] = table.concat(parts)
  end },
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

t.test("valid introspection injects user claims", function()
  authorization = "Bearer valid"
  openidc.introspect = function() return { active = true, sub = "user-1" } end
  local before = #exits
  handler:access(config)
  t.equal(#exits, before)
  t.equal(ngx.ctx.authenticated_credential.sub, "user-1")
  t.equal(set["X-Userinfo"] ~= nil, true)
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
  local before = #calls
  handler:access(config)
  t.equal(called, false)
  t.equal(#calls, before + 3)
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
  t.equal(logs[#logs], "OIDC authentication failed: provider leaked detail")
end)

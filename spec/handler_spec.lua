local t = require "spec.test_helper"

local function setup()
  local state = {
    calls = {},
    exits = {},
    logs = {},
    set = {},
    request_path = "/private",
    authorization = "Bearer invalid",
    config = {
      filters = {}, client_id = "client", client_secret = "secret",
      discovery = "https://issuer/.well-known/openid-configuration",
      introspection_endpoint = "https://issuer/introspect",
      bearer_only = false, realm = "kong", ssl_verify = true,
      scope = "openid", response_type = "code", redirect_uri = "/callback",
      token_endpoint_auth_method = "client_secret_post",
      introspection_endpoint_auth_method = "client_secret_basic",
      logout_path = "/logout", redirect_after_logout_uri = "/",
    },
  }

  state.introspect = function() return nil, "invalid token" end
  state.authenticate = function() error("must not fall back to browser authentication") end

  _G.ngx = {
    ctx = {},
    encode_base64 = function(v) return v end,
    decode_base64 = function() return string.rep("s", 32) end,
    md5 = function(v) return v end,
    time = function() return 1000 end,
  }
  state.ctx = ngx.ctx

  _G.kong = {
    request = {
      get_path = function()
        state.calls[#state.calls + 1] = "path"
        return state.request_path
      end,
      get_header = function()
        state.calls[#state.calls + 1] = "authorization"
        return state.authorization
      end,
    },
    service = { request = {
      clear_header = function(name)
        state.calls[#state.calls + 1] = "clear:" .. name
      end,
      set_header = function(name, value)
        state.calls[#state.calls + 1] = "set:" .. name
        state.set[name] = value
      end,
    } },
    response = { exit = function(status, body, headers)
      state.exits[#state.exits + 1] = { status = status, body = body, headers = headers }
      return state.exits[#state.exits]
    end },
    client = { authenticate = function(consumer, credential)
      ngx.ctx.authenticated_consumer = consumer
      ngx.ctx.authenticated_credential = credential
    end },
    cache = {
      store = {},
      last_ttl = nil,
      get = function(self, key, _opts, cb)
        local hit = self.store[key]
        if hit ~= nil then return hit end
        -- mlcache honors a ttl returned as the callback's third value.
        local value, err, ttl = cb()
        self.last_ttl = ttl
        if err then return nil, err end
        self.store[key] = value
        return value
      end,
    },
    log = { err = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
      state.logs[#state.logs + 1] = table.concat(parts)
    end },
  }
  state.cache = kong.cache

  package.loaded.cjson = { encode = function() return "{}" end }
  package.loaded["resty.openidc"] = {
    introspect = function(...)
      state.calls[#state.calls + 1] = "introspect"
      return state.introspect(...)
    end,
    authenticate = function(...)
      state.calls[#state.calls + 1] = "authenticate"
      return state.authenticate(...)
    end,
  }
  package.loaded["kong.plugins.oidc.utils"] = nil
  package.loaded["kong.plugins.oidc.handler"] = nil
  state.handler = require "kong.plugins.oidc.handler"

  return state
end

t.test("exports Kong 3 handler metadata", function()
  local state = setup()
  t.equal(state.handler.VERSION, "2.0.0")
  t.equal(state.handler.PRIORITY, 1000)
end)

t.test("clears identity headers before authentication", function()
  local state = setup()
  state.handler:access(state.config)
  t.equal(table.concat(state.calls, ","), table.concat({
    "clear:X-Userinfo",
    "clear:X-ID-Token",
    "clear:X-Access-Token",
    "path",
    "authorization",
    "introspect",
  }, ","))
end)

t.test("invalid bearer token returns 401 without browser fallback", function()
  local state = setup()
  local result = state.handler:access(state.config)
  t.equal(result.status, 401)
  t.equal(result.body.message, "Unauthorized")
  t.equal(result.headers["WWW-Authenticate"], 'Bearer realm="kong"')
end)

t.test("valid introspection injects user claims", function()
  local state = setup()
  state.authorization = "Bearer valid"
  state.introspect = function() return { active = true, sub = "user-1" } end
  local before = #state.exits
  state.handler:access(state.config)
  t.equal(#state.exits, before)
  t.equal(state.ctx.authenticated_credential.sub, "user-1")
  t.equal(state.set["X-Userinfo"] ~= nil, true)
end)

t.test("bearer only rejects missing token", function()
  local state = setup()
  state.authorization = nil
  state.config.bearer_only = true
  state.introspect = function() return nil, "no token" end
  local result = state.handler:access(state.config)
  t.equal(result.status, 401)
end)

t.test("filtered request clears headers without authenticating", function()
  local state = setup()
  state.request_path = "/health"
  state.authorization = nil
  state.config.filters = { "/health" }
  local called = false
  state.introspect = function() called = true end
  state.authenticate = function() called = true end
  state.handler:access(state.config)
  t.equal(called, false)
  t.equal(table.concat(state.calls, ","), table.concat({
    "clear:X-Userinfo",
    "clear:X-ID-Token",
    "clear:X-Access-Token",
    "path",
  }, ","))
end)

t.test("caching reuses one introspection across requests with the same token", function()
  local state = setup()
  state.authorization = "Bearer valid"
  state.config.introspection_cache_ttl = 60
  local calls = 0
  state.introspect = function()
    calls = calls + 1
    return { active = true, sub = "user-1", exp = 9999999999 }
  end
  state.handler:access(state.config)
  state.handler:access(state.config)
  t.equal(calls, 1)
  t.equal(state.ctx.authenticated_credential.sub, "user-1")
end)

t.test("caching disabled introspects on every request", function()
  local state = setup()
  state.authorization = "Bearer valid"
  local calls = 0
  state.introspect = function()
    calls = calls + 1
    return { active = true, sub = "user-1" }
  end
  state.handler:access(state.config)
  state.handler:access(state.config)
  t.equal(calls, 2)
end)

t.test("cache ttl honors exp when below the cap", function()
  local state = setup()
  state.authorization = "Bearer valid"
  state.config.introspection_cache_ttl = 60
  -- ngx.time() is 1000; exp 30s out is below the 60s cap.
  state.introspect = function() return { active = true, sub = "user-1", exp = 1030 } end
  state.handler:access(state.config)
  t.equal(state.cache.last_ttl, 30)
end)

t.test("cache ttl is capped at introspection_cache_ttl", function()
  local state = setup()
  state.authorization = "Bearer valid"
  state.config.introspection_cache_ttl = 20
  state.introspect = function() return { active = true, sub = "user-1", exp = 999999 } end
  state.handler:access(state.config)
  t.equal(state.cache.last_ttl, 20)
end)

t.test("cache ttl falls back to the cap when the token has no exp", function()
  local state = setup()
  state.authorization = "Bearer valid"
  state.config.introspection_cache_ttl = 45
  state.introspect = function() return { active = true, sub = "user-1" } end
  state.handler:access(state.config)
  t.equal(state.cache.last_ttl, 45)
end)

t.test("an already-expired token is not cached and returns 401", function()
  local state = setup()
  state.authorization = "Bearer valid"
  state.config.introspection_cache_ttl = 60
  local calls = 0
  -- Active per introspection, but exp is in the past (< ngx.time() 1000).
  state.introspect = function()
    calls = calls + 1
    return { active = true, sub = "user-1", exp = 995 }
  end
  local first = state.handler:access(state.config)
  local second = state.handler:access(state.config)
  t.equal(calls, 2)
  t.equal(first.status, 401)
  t.equal(second.status, 401)
end)

t.test("caching does not store failed introspection", function()
  local state = setup()
  state.authorization = "Bearer valid"
  state.config.introspection_cache_ttl = 60
  local calls = 0
  state.introspect = function()
    calls = calls + 1
    return nil, "invalid token"
  end
  local first = state.handler:access(state.config)
  local second = state.handler:access(state.config)
  t.equal(calls, 2)
  t.equal(first.status, 401)
  t.equal(second.status, 401)
end)

t.test("browser errors are generic and session options are explicit", function()
  local state = setup()
  state.authorization = nil
  state.config.session_secret = "valid"
  local received
  state.authenticate = function(_, _, _, options)
    received = options
    return nil, "provider leaked detail"
  end
  local result = state.handler:access(state.config)
  t.equal(#received.secret, 32)
  t.equal(result.status, 500)
  t.equal(result.body.message, "Authentication failed")
  t.equal(state.logs[#state.logs], "OIDC authentication failed: provider leaked detail")
end)

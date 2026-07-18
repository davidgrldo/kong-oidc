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

-- Validate a bearer token by introspection, optionally caching active results
-- in kong.cache. TTL honors the token's `exp`, capped by introspection_cache_ttl
-- so a revoked token is trusted for at most that many seconds. Failures and
-- inactive tokens are never cached.
local function introspect(config, options)
  local ttl_max = config.introspection_cache_ttl or 0
  if ttl_max <= 0 then
    return openidc.introspect(options)
  end

  local token = utils.bearer_token(kong.request.get_header("authorization"))
  if not token then
    return openidc.introspect(options)
  end

  local key = "oidc_introspect:" .. ngx.md5((options.introspection_endpoint or "") .. "|" .. token)
  return kong.cache:get(key, nil, function()
    local response, err = openidc.introspect(options)
    if err or not response or response.active == false then
      return nil, err or "inactive token"
    end
    local ttl = response.exp and (response.exp - ngx.time()) or ttl_max
    if ttl > ttl_max then ttl = ttl_max end
    if ttl <= 0 then return nil, "token expired" end
    return response, nil, ttl
  end)
end

function Handler:access(config)
  utils.clear_identity_headers()
  if not filter.should_process(config.filters, config.filters_prefix, kong.request.get_path()) then return end

  local options = utils.get_options(config)
  local bearer = utils.bearer_present(kong.request.get_header("authorization"))
  if bearer or config.bearer_only then
    local response, err = introspect(config, options)
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

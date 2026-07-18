local cjson = require "cjson"
local M = {}
local IDENTITY_HEADERS = { "X-Userinfo", "X-ID-Token", "X-Access-Token" }

function M.clear_identity_headers()
  for _, name in ipairs(IDENTITY_HEADERS) do
    kong.service.request.clear_header(name)
  end
end

function M.bearer_token(value)
  if type(value) ~= "string" then return nil end
  return value:match("^%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+(%S+)")
end

function M.bearer_present(value)
  return M.bearer_token(value) ~= nil
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
    -- Kong 3.x PDK: record the credential so kong.client.get_credential() and
    -- credential-aware plugins see it (no consumer mapping yet — see README).
    kong.client.authenticate(nil, user)
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

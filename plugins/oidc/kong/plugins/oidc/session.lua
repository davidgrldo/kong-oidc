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

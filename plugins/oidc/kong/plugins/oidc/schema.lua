local typedefs = require "kong.db.schema.typedefs"

local function missing(value)
  return value == nil or value == ngx.null
end

local function secure_url(value, allow_insecure)
  if missing(value) then return true end
  if value:match("^https://") then return true end
  if allow_insecure and value:match("^http://") then return true end
  return nil, "OIDC endpoints must use HTTPS unless allow_insecure_http is true"
end

local function validate(config)
  local ok, err = secure_url(config.discovery, config.allow_insecure_http)
  if not ok then return nil, err end
  ok, err = secure_url(config.introspection_endpoint, config.allow_insecure_http)
  if not ok then return nil, err end
  if config.bearer_only and missing(config.introspection_endpoint) then
    return nil, "bearer_only requires introspection_endpoint"
  end
  if not config.bearer_only then
    local decoded = not missing(config.session_secret) and ngx.decode_base64(config.session_secret)
    if not decoded or #decoded < 32 then
      return nil, "browser mode requires a base64 session_secret of at least 32 decoded bytes"
    end
    if missing(config.redirect_uri) then
      return nil, "browser mode requires redirect_uri"
    end
  end
  return true
end

local function validate_realm(value)
  if not value:find('"') then return true end
  return nil, "realm must not contain double quotes"
end

local function validate_filter(value)
  if value ~= "" and value:sub(1, 1) == "/" then return true end
  return nil, "filter entries must be non-empty absolute paths"
end

return {
  name = "oidc",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { client_id = { type = "string", required = true } },
          { client_secret = { type = "string", required = true } },
          { discovery = { type = "string", required = true } },
          { introspection_endpoint = { type = "string" } },
          { timeout = { type = "number" } },
          { introspection_endpoint_auth_method = {
              type = "string",
              default = "client_secret_basic",
              one_of = { "client_secret_basic", "client_secret_post" },
          } },
          { bearer_only = { type = "boolean", default = false } },
          { introspection_cache_ttl = { type = "number", default = 0 } },
          { realm = { type = "string", default = "kong", custom_validator = validate_realm } },
          { redirect_uri = { type = "string" } },
          { scope = { type = "string", default = "openid" } },
          { response_type = { type = "string", default = "code" } },
          { ssl_verify = { type = "boolean", default = true } },
          { allow_insecure_http = { type = "boolean", default = false } },
          { token_endpoint_auth_method = {
              type = "string",
              default = "client_secret_post",
              one_of = {
                "client_secret_basic",
                "client_secret_post",
                "client_secret_jwt",
              },
          } },
          { session_secret = { type = "string" } },
          { recovery_page_path = { type = "string" } },
          { logout_path = { type = "string", default = "/logout" } },
          { redirect_after_logout_uri = { type = "string", default = "/" } },
          { filters = {
              type = "array",
              default = {},
              elements = { type = "string", len_min = 0, custom_validator = validate_filter },
          } },
          { filters_prefix = {
              type = "array",
              default = {},
              elements = { type = "string", len_min = 0, custom_validator = validate_filter },
          } },
        },
        custom_validator = validate,
    } },
  },
}

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

t.test("extracts the bearer token value", function()
  t.equal(utils.bearer_token("Bearer abc.def"), "abc.def")
  t.equal(utils.bearer_token("bearer  xyz"), "xyz")
  t.equal(utils.bearer_token("Basic zzz"), nil)
  t.equal(utils.bearer_token({ "Bearer a" }), nil)
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

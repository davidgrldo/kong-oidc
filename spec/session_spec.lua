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

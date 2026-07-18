local t = require "spec.test_helper"

local rockspec = {}
local load_rockspec
if _VERSION == "Lua 5.1" then
  load_rockspec = assert(loadfile("plugins/oidc/kong-oidc-2.1.0-1.rockspec"))
  setfenv(load_rockspec, rockspec)
else
  load_rockspec = assert(loadfile("plugins/oidc/kong-oidc-2.1.0-1.rockspec", "t", rockspec))
end
load_rockspec()

t.test("pins reproducible public rock source", function()
  t.equal(rockspec.source.url, "git+https://github.com/davidgrldo/kong-oidc.git")
  t.equal(rockspec.source.tag, "v2.1.0")
  t.equal(rockspec.source.dir, "kong-oidc/plugins/oidc")
end)

local t = require "spec.test_helper"
local filter = require "kong.plugins.oidc.filter"

t.test("filters exact path", function()
  t.equal(filter.should_process({ "/health" }, nil, "/health"), false)
end)

t.test("exact filter does not match a path prefix", function()
  t.equal(filter.should_process({ "/health" }, nil, "/health-admin"), true)
end)

t.test("does not evaluate Lua patterns", function()
  t.equal(filter.should_process({ "[" }, nil, "/anything"), true)
end)

t.test("prefix filter matches the prefix and its children", function()
  t.equal(filter.should_process(nil, { "/public" }, "/public"), false)
  t.equal(filter.should_process(nil, { "/public" }, "/public/docs"), false)
  t.equal(filter.should_process(nil, { "/api/v1/docs" }, "/api/v1/docs/index.html"), false)
end)

t.test("prefix filter respects segment boundaries", function()
  t.equal(filter.should_process(nil, { "/public" }, "/publicity"), true)
end)

t.test("processes paths matched by neither list", function()
  t.equal(filter.should_process({ "/health" }, { "/public" }, "/private"), true)
end)

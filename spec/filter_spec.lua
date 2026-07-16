local t = require "spec.test_helper"
local filter = require "kong.plugins.oidc.filter"

t.test("filters exact path", function()
  t.equal(filter.should_process({ "/health" }, "/health"), false)
end)

t.test("does not filter path prefix", function()
  t.equal(filter.should_process({ "/health" }, "/health-admin"), true)
end)

t.test("does not evaluate Lua patterns", function()
  t.equal(filter.should_process({ "[" }, "/anything"), true)
end)

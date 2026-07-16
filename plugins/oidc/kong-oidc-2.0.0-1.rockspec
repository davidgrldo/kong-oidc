package = "kong-oidc"
version = "2.0.0-1"
source = {
  url = "git+https://github.com/davidgrldo/kong-oidc.git",
  tag = "v2.0.0",
  dir = "kong-oidc/plugins/oidc",
}
description = {
  summary = "OpenID Connect and token introspection plugin for Kong Gateway",
  homepage = "https://github.com/davidgrldo/kong-oidc",
  license = "Apache-2.0",
}
dependencies = {
  "lua >= 5.1",
  "lua-resty-openidc == 1.8.0-1",
}
build = {
  type = "builtin",
  modules = {
    ["kong.plugins.oidc.filter"] = "kong/plugins/oidc/filter.lua",
    ["kong.plugins.oidc.handler"] = "kong/plugins/oidc/handler.lua",
    ["kong.plugins.oidc.schema"] = "kong/plugins/oidc/schema.lua",
    ["kong.plugins.oidc.session"] = "kong/plugins/oidc/session.lua",
    ["kong.plugins.oidc.utils"] = "kong/plugins/oidc/utils.lua",
  },
}

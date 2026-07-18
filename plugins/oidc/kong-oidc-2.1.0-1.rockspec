package = "kong-oidc"
version = "2.1.0-1"
source = {
  url = "git+https://github.com/davidgrldo/kong-oidc.git",
  tag = "v2.1.0",
  dir = "kong-oidc/plugins/oidc",
}
description = {
  summary = "OpenID Connect and token introspection plugin for Kong Gateway",
  detailed = [[
kong-oidc secures APIs with OpenID Connect. It authenticates browser
sessions via the authorization-code flow and validates bearer access tokens
via RFC 7662 token introspection, then injects the verified caller identity
into upstream requests.

Built for Kong OSS 3.9.3 on lua-resty-openidc 1.8.0. A modified Apache-2.0
fork of the Nokia kong-oidc plugin, modernized for Kong 3.x.

Highlights:
- Bearer/API mode: introspection with 401 on failure (no browser fallback),
  optional kong.cache introspection caching, or local JWT (JWKS) validation
- Browser mode: authorization-code flow with encrypted session cookies
- Exact-path and segment-boundary prefix filters (no Lua patterns), TLS
  verification on by default
- Identity headers (X-Userinfo / X-ID-Token / X-Access-Token) stripped from
  client requests and re-injected from verified identity to prevent spoofing
- Typed Kong 3 schema with cross-field validation (HTTPS endpoints,
  32-byte session secret)

Install: luarocks install davidgrldo/kong-oidc
Source and documentation: https://github.com/davidgrldo/kong-oidc
]],
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

# syntax=docker/dockerfile:1
FROM scratch AS build-inputs
ADD --checksum=sha256:4d006dd47ce953203e9dc4f4f01e7d1eedf1570afcabbbcf9df4ccb40c5ebea4 \
  https://luarocks.org/manifests/hanszandbelt/lua-resty-openidc-1.8.0-1.src.rock \
  /lua-resty-openidc-1.8.0-1.src.rock
COPY ./plugins/oidc /kong-oidc

FROM kong:3.9.3@sha256:62721edc9669e2a96fe9d188ab8950b9105e69abb033129624a72d3e10da6777
USER root
RUN --mount=type=bind,from=build-inputs,source=/,target=/tmp/build \
  luarocks install /tmp/build/lua-resty-openidc-1.8.0-1.src.rock && \
  cd /tmp/build/kong-oidc && \
  luarocks make kong-oidc-2.0.0-1.rockspec

ENV KONG_PLUGINS=bundled,oidc
USER kong

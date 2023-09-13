FROM kong:2.2-alpine
USER root

COPY kong.conf /etc/kong/

COPY ./config/kong.yml /opt/kong/kong.yml

COPY ./plugins/oidc /custom-plugins/oidc

WORKDIR /custom-plugins/oidc
RUN luarocks make

USER kong

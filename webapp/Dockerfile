FROM nginx:1.28-alpine

ENV STATION_RELAY_UPSTREAM=station-relay-server:3000

# nginx official entrypoint renders templates from /etc/nginx/templates/*.template
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY . /usr/share/nginx/html

ARG ASTATION_WEBAPP_SOURCE_TREE=
RUN if [ -n "$ASTATION_WEBAPP_SOURCE_TREE" ]; then \
      echo "$ASTATION_WEBAPP_SOURCE_TREE" | grep -Eq '^[0-9a-f]{40}$' || exit 1; \
    fi; \
    mkdir -p /usr/share/nginx/html/.well-known; \
    printf '{"version":1,"source_tree":"%s"}\n' "$ASTATION_WEBAPP_SOURCE_TREE" \
      > /usr/share/nginx/html/.well-known/astation-webapp-build.json

EXPOSE 80

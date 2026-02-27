FROM nginx:alpine

ENV STATION_RELAY_UPSTREAM=station-relay-server:3000

# nginx official entrypoint renders templates from /etc/nginx/templates/*.template
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY . /usr/share/nginx/html

EXPOSE 80

FROM pubhub.aiursoft.com/caddy:builder AS caddy-build-env

RUN xcaddy build \
    --with github.com/ueffel/caddy-brotli \
    --with github.com/caddyserver/transform-encoder \
    --with github.com/caddy-dns/cloudflare

FROM pubhub.aiursoft.com/caddy:latest

COPY --from=caddy-build-env /usr/bin/caddy /usr/bin/caddy
COPY Dist/Caddyfile /etc/caddy/Caddyfile

RUN caddy fmt --overwrite /etc/caddy/Caddyfile && \
    CLOUDFLARE_API_TOKEN=ThisIsAFakeTokenForValidationOnly123456 \
    ALLOW_INCOMING_IPS=127.0.0.1 \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

EXPOSE 80 443

ENTRYPOINT ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

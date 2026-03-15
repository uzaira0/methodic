# Build Caddy with Coraza WAF module (includes embedded OWASP CRS)
FROM caddy:2.9.1-builder AS builder

RUN xcaddy build \
    --with github.com/corazawaf/coraza-caddy/v2@v2.1.0

FROM caddy:2.9.1-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

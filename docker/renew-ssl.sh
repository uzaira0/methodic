#!/bin/bash

# SSL Certificate Renewal Script for Chronicle
# Run this periodically (e.g., daily via cron) to renew Let's Encrypt certificates
#
# Crontab example:
#   0 0 * * * /path/to/docker/renew-ssl.sh >> /var/log/chronicle-ssl-renew.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"
WEBROOT_DIR="$SCRIPT_DIR/certbot-webroot"

# Load environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

echo "[$(date)] Starting certificate renewal check..."

# Run certbot renew
docker run --rm \
    -v "$CERTS_DIR:/etc/letsencrypt" \
    -v "$WEBROOT_DIR:/var/www/certbot" \
    certbot/certbot renew --quiet

# Copy renewed certs if they exist
if [ -d "$CERTS_DIR/live/$DOMAIN" ]; then
    cp "$CERTS_DIR/live/$DOMAIN/fullchain.pem" "$CERTS_DIR/fullchain.pem"
    cp "$CERTS_DIR/live/$DOMAIN/privkey.pem" "$CERTS_DIR/privkey.pem"

    # Reload nginx to pick up new certs
    docker exec chronicle-nginx nginx -s reload 2>/dev/null || true

    echo "[$(date)] Certificate renewal complete"
else
    echo "[$(date)] No renewal needed or certificate not found"
fi

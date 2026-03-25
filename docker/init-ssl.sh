#!/bin/bash

# SSL Certificate Initialization Script for Chronicle
# This script sets up SSL certificates for production deployment
#
# Usage: ./init-ssl.sh [self-signed|letsencrypt]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"
WEBROOT_DIR="$SCRIPT_DIR/certbot-webroot"

# Load environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# Check required variables
if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN not set. Please configure .env file first."
    echo "  cp .env.example .env"
    echo "  nano .env"
    exit 1
fi

# Create directories
mkdir -p "$CERTS_DIR"
mkdir -p "$WEBROOT_DIR"

# Function to generate self-signed certificate
generate_self_signed() {
    echo "Generating self-signed certificate for $DOMAIN..."

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERTS_DIR/privkey.pem" \
        -out "$CERTS_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN/O=Chronicle/C=US" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:www.$DOMAIN"

    echo ""
    echo "Self-signed certificate generated successfully!"
    echo "  Certificate: $CERTS_DIR/fullchain.pem"
    echo "  Private key: $CERTS_DIR/privkey.pem"
    echo ""
    echo "WARNING: Self-signed certificates will show security warnings in browsers."
    echo "         For production, use Let's Encrypt or a commercial CA."
}

# Function to get Let's Encrypt certificate
get_letsencrypt() {
    if [ -z "$LETSENCRYPT_EMAIL" ]; then
        echo "ERROR: LETSENCRYPT_EMAIL not set in .env"
        exit 1
    fi

    echo "Getting Let's Encrypt certificate for $DOMAIN..."
    echo ""
    echo "Prerequisites:"
    echo "  1. Domain $DOMAIN must point to this server's IP"
    echo "  2. Port 80 must be accessible from the internet"
    echo ""

    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi

    # Determine staging flag
    STAGING_ARG=""
    if [ "$LETSENCRYPT_STAGING" = "true" ]; then
        echo "Using Let's Encrypt STAGING environment (for testing)"
        STAGING_ARG="--staging"
    fi

    # Run certbot in standalone mode
    docker run -it --rm \
        -v "$CERTS_DIR:/etc/letsencrypt" \
        -v "$WEBROOT_DIR:/var/www/certbot" \
        -p 80:80 \
        certbot/certbot certonly \
        --standalone \
        --preferred-challenges http \
        -d "$DOMAIN" \
        --email "$LETSENCRYPT_EMAIL" \
        --agree-tos \
        --no-eff-email \
        $STAGING_ARG

    # Copy certs to expected location
    if [ -d "$CERTS_DIR/live/$DOMAIN" ]; then
        cp "$CERTS_DIR/live/$DOMAIN/fullchain.pem" "$CERTS_DIR/fullchain.pem"
        cp "$CERTS_DIR/live/$DOMAIN/privkey.pem" "$CERTS_DIR/privkey.pem"
        echo ""
        echo "Let's Encrypt certificate obtained successfully!"
        echo ""
        echo "To set up auto-renewal, add this to your crontab:"
        echo "  0 0 * * * cd $SCRIPT_DIR && ./renew-ssl.sh"
    else
        echo "ERROR: Certificate not found. Check the output above for errors."
        exit 1
    fi
}

# Main logic
case "${1:-}" in
    self-signed)
        generate_self_signed
        ;;
    letsencrypt)
        get_letsencrypt
        ;;
    *)
        echo "Chronicle SSL Certificate Setup"
        echo "================================"
        echo ""
        echo "Domain: $DOMAIN"
        echo ""
        echo "Choose certificate type:"
        echo "  1) Self-signed (for testing, generates browser warnings)"
        echo "  2) Let's Encrypt (free, trusted, requires domain pointing to this server)"
        echo "  3) Exit (I'll provide my own certificates)"
        echo ""
        read -p "Selection [1-3]: " choice

        case $choice in
            1)
                generate_self_signed
                ;;
            2)
                get_letsencrypt
                ;;
            3)
                echo ""
                echo "To use your own certificates, place them here:"
                echo "  $CERTS_DIR/fullchain.pem  (certificate chain)"
                echo "  $CERTS_DIR/privkey.pem    (private key)"
                exit 0
                ;;
            *)
                echo "Invalid selection"
                exit 1
                ;;
        esac
        ;;
esac

echo ""
echo "You can now start Chronicle:"
echo "  docker-compose -f docker-compose.prod.yml up -d"

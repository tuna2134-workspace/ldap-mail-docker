#!/bin/sh
# Create a short-lived self-signed certificate only when no certificate is
# present (for example before certbot's first successful issuance).  Both the
# Postfix and Dovecot containers call this, so a flock serializes them.
set -eu

: "${MAIL_HOSTNAME:?MAIL_HOSTNAME is required}"
CERT_DIR="${CERT_DIR:-/etc/ssl/mail}"
CERT="$CERT_DIR/fullchain.pem"
KEY="$CERT_DIR/privkey.pem"

mkdir -p "$CERT_DIR"
exec 9>"$CERT_DIR/.cert.lock"
flock 9

if [ -s "$CERT" ] && [ -s "$KEY" ]; then
    exit 0
fi

echo "[cert] no certificate found; generating a 30-day self-signed cert for $MAIL_HOSTNAME"
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=$MAIL_HOSTNAME" \
    -addext "subjectAltName=DNS:$MAIL_HOSTNAME" >/dev/null 2>&1

chgrp 5002 "$KEY" "$CERT" 2>/dev/null || true
chmod 0640 "$KEY"
chmod 0644 "$CERT"

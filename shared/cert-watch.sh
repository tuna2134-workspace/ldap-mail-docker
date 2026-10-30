#!/bin/sh
# Watch the shared TLS certificate directory and reload the local daemon when
# certbot's deploy hook replaces the files.
#
# Usage: cert-watch.sh postfix|dovecot
set -eu

CERT_DIR="${CERT_DIR:-/etc/ssl/mail}"
CERT="$CERT_DIR/fullchain.pem"
KEY="$CERT_DIR/privkey.pem"
TARGET="${1:-postfix}"

hash_pair() {
    sha256sum "$CERT" "$KEY" 2>/dev/null | sha256sum | awk '{print $1}'
}

last="$(hash_pair)"
[ -n "$last" ] || last="missing"

while :; do
    sleep 60
    current="$(hash_pair)"
    [ -n "$current" ] || continue
    if [ "$current" != "$last" ]; then
        echo "[cert] certificate changed; reloading $TARGET"
        case "$TARGET" in
            postfix) postfix reload 2>/dev/null || true ;;
            dovecot) doveadm reload 2>/dev/null || true ;;
        esac
        last="$current"
    fi
done

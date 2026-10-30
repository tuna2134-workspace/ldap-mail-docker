#!/bin/sh
# certbot deploy hook: atomically publish the renewed certificate into
# /certs (shared with Postfix and Dovecot).  The private key is installed as
# root:5002 mode 0640; GID 5002 is the "mailcert" group in both mail images.
set -eu

: "${MAIL_HOSTNAME:?MAIL_HOSTNAME is required}"

DEST="${CERT_DEST:-/certs}"
SRC="${RENEWED_LINEAGE:-/etc/letsencrypt/live/$MAIL_HOSTNAME}"

[ -s "$SRC/fullchain.pem" ] || { echo "[certbot] missing $SRC/fullchain.pem" >&2; exit 1; }
[ -s "$SRC/privkey.pem" ]   || { echo "[certbot] missing $SRC/privkey.pem" >&2; exit 1; }

mkdir -p "$DEST"
tmp_full="$DEST/.fullchain.$$"
tmp_key="$DEST/.privkey.$$"
trap 'rm -f "$tmp_full" "$tmp_key"' EXIT INT TERM

cp "$SRC/fullchain.pem" "$tmp_full"
cp "$SRC/privkey.pem" "$tmp_key"
chgrp 5002 "$tmp_full" "$tmp_key" 2>/dev/null || true
chmod 0644 "$tmp_full"
chmod 0640 "$tmp_key"

# Rename is atomic on the same filesystem; running daemons see either the old
# or the new pair, never a half-written file.
mv -f "$tmp_full" "$DEST/fullchain.pem"
mv -f "$tmp_key" "$DEST/privkey.pem"

echo "[certbot] installed certificate for $MAIL_HOSTNAME into $DEST"

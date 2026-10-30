#!/bin/sh
# Generate the DKIM key on first start, make sure the scanner can read it,
# then run Rspamd in the foreground.
set -eu

: "${MAIL_DOMAIN:?MAIL_DOMAIN is required}"

KEY_DIR=/var/lib/rspamd/dkim
KEY="$KEY_DIR/$MAIL_DOMAIN.mail.key"
RECORD="$KEY_DIR/$MAIL_DOMAIN.mail.txt"

mkdir -p "$KEY_DIR"

if [ ! -s "$KEY" ]; then
    echo "[rspamd] generating DKIM key for $MAIL_DOMAIN (selector: mail)"
    rspamadm dkim_keygen -d "$MAIL_DOMAIN" -s mail -k "$KEY" > "$RECORD"
    chmod 0600 "$KEY"
    chmod 0644 "$RECORD"
fi

chown -R _rspamd:_rspamd "$KEY_DIR"

echo "[rspamd] DKIM DNS record for $MAIL_DOMAIN:"
cat "$RECORD" || true

exec "$@"

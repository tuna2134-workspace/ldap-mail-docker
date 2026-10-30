#!/bin/sh
# Obtain and renew the STARTTLS certificate with certbot's standalone
# authenticator (port 80), then install it into the volume shared with
# Postfix and Dovecot.
set -eu

: "${MAIL_HOSTNAME:?MAIL_HOSTNAME is required}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"

LIVE_DIR="/etc/letsencrypt/live/$MAIL_HOSTNAME"
DEPLOY_HOOK=/usr/local/bin/deploy-hook.sh
RETRY_DELAY=600

log() { printf '[certbot] %s\n' "$*"; }

if [ "${CERTBOT_ENABLED:-1}" != "1" ]; then
    log "disabled (CERTBOT_ENABLED=${CERTBOT_ENABLED:-1}); keeping the existing certificate"
    while :; do sleep 3600; done
fi

log "certificate directory: $LIVE_DIR"
log "standalone HTTP-01 requires public DNS for $MAIL_HOSTNAME and TCP/80 reachable from the Internet"

while :; do
    if [ -s "$LIVE_DIR/fullchain.pem" ] && [ -s "$LIVE_DIR/privkey.pem" ]; then
        log "certificate exists; running renewal check"
        # --deploy-hook runs only when a certificate is actually renewed.
        if certbot renew --non-interactive --deploy-hook "$DEPLOY_HOOK"; then
            # Also (re)install on start, in case the shared certs volume was
            # recreated while /etc/letsencrypt survived.
            "$DEPLOY_HOOK" || true
            RETRY_DELAY=600
            sleep 43200
        else
            log "renewal failed; retrying in ${RETRY_DELAY}s" >&2
            sleep "$RETRY_DELAY"
            RETRY_DELAY=$((RETRY_DELAY * 2))
            [ "$RETRY_DELAY" -le 21600 ] || RETRY_DELAY=21600
        fi
    else
        log "requesting a new certificate for $MAIL_HOSTNAME"
        set -- --standalone --non-interactive --agree-tos \
               --email "$CERTBOT_EMAIL" -d "$MAIL_HOSTNAME" \
               --deploy-hook "$DEPLOY_HOOK"
        if [ "${CERTBOT_STAGING:-0}" = "1" ]; then
            set -- "$@" --staging
        fi
        if certbot certonly "$@"; then
            RETRY_DELAY=600
            sleep 43200
        else
            log "issuance failed (DNS, port 80, or rate limit); retrying in ${RETRY_DELAY}s" >&2
            sleep "$RETRY_DELAY"
            RETRY_DELAY=$((RETRY_DELAY * 2))
            [ "$RETRY_DELAY" -le 21600 ] || RETRY_DELAY=21600
        fi
    fi
done

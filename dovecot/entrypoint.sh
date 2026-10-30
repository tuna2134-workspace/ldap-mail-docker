#!/bin/bash
# Render the LDAP credentials, prepare the mail volume and sockets, then run
# Dovecot in the foreground.
set -euo pipefail

: "${LDAP_BASE_DN:?LDAP_BASE_DN is required}"
: "${LDAP_ADMIN_DN:?LDAP_ADMIN_DN is required}"
: "${LDAP_ADMIN_PASSWORD:?LDAP_ADMIN_PASSWORD is required}"
: "${MAIL_DOMAIN:?MAIL_DOMAIN is required}"

log() { printf '[dovecot] %s\n' "$*"; }

log "rendering dovecot-ldap.conf.ext"
envsubst '${LDAP_BASE_DN} ${LDAP_ADMIN_DN} ${LDAP_ADMIN_PASSWORD} ${MAIL_DOMAIN}' \
    < /etc/dovecot/dovecot-ldap.conf.ext.template \
    > /etc/dovecot/dovecot-ldap.conf.ext
chown root:dovecot /etc/dovecot/dovecot-ldap.conf.ext
chmod 0640 /etc/dovecot/dovecot-ldap.conf.ext

# One shared vmail uid owns every Maildir.  Only the top directory is touched
# here; per-user directories are created by Dovecot on first delivery.
install -d -o 5000 -g 5000 -m 0750 /data/maildir

mkdir -p /var/spool/postfix/private /run/dovecot
chmod 0755 /var/spool/postfix/private

/usr/local/bin/ensure-cert.sh

# Reload Dovecot when certbot replaces the certificate.
/usr/local/bin/cert-watch.sh dovecot &

log "starting dovecot"
exec dovecot -F

#!/bin/bash
# Render configs, create a bootstrap certificate if needed, and run Postfix in
# the foreground (required for maillog_file=/dev/stdout).
set -euo pipefail

: "${MAIL_DOMAIN:?MAIL_DOMAIN is required}"
: "${MAIL_HOSTNAME:?MAIL_HOSTNAME is required}"
: "${LDAP_BASE_DN:?LDAP_BASE_DN is required}"
: "${LDAP_ADMIN_DN:?LDAP_ADMIN_DN is required}"
: "${LDAP_ADMIN_PASSWORD:?LDAP_ADMIN_PASSWORD is required}"

log() { printf '[postfix] %s\n' "$*"; }

log "rendering main.cf and LDAP lookup tables"
envsubst '${MAIL_DOMAIN} ${MAIL_HOSTNAME}' \
    < /etc/postfix/main.cf.template > /etc/postfix/main.cf

for name in virtual-mailbox-maps virtual-alias-maps sender-login-maps sender-canonical-maps; do
    src="/etc/postfix/ldap-${name}.cf.template"
    dst="/etc/postfix/ldap-${name}.cf"
    envsubst '${LDAP_BASE_DN} ${LDAP_ADMIN_DN} ${LDAP_ADMIN_PASSWORD} ${MAIL_DOMAIN}' \
        < "$src" > "$dst"
    # The bind password must not be world readable, but every Postfix process
    # (running as user "postfix") has to be able to read the table.
    chown root:postfix "$dst"
    chmod 0640 "$dst"
done

mkdir -p /var/spool/postfix/private /etc/ssl/mail
# The master creates sockets here as root; smtpd must be able to traverse it.
chmod 0755 /var/spool/postfix/private

/usr/local/bin/ensure-cert.sh

# Reload Postfix when certbot replaces the certificate.
/usr/local/bin/cert-watch.sh postfix &

log "starting postfix"
exec postfix start-fg

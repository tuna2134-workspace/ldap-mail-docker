#!/bin/bash
# Render the slapd configuration and seed the database on first start.
set -euo pipefail

: "${LDAP_BASE_DN:?LDAP_BASE_DN is required}"
: "${LDAP_ADMIN_DN:?LDAP_ADMIN_DN is required}"
: "${LDAP_ADMIN_PASSWORD:?LDAP_ADMIN_PASSWORD is required}"
: "${LDAP_ORGANISATION:?LDAP_ORGANISATION is required}"
: "${MAIL_DOMAIN:?MAIL_DOMAIN is required}"
: "${DEMO_USER_PASSWORD:?DEMO_USER_PASSWORD is required}"

LOG_PREFIX='[ldap]'
log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

# dc=example,dc=com -> example
LDAP_DC="$(printf '%s' "$LDAP_BASE_DN" | sed -n 's/^dc=\([^,]*\).*/\1/p')"
if [ -z "$LDAP_DC" ]; then
    echo "$LOG_PREFIX LDAP_BASE_DN must start with dc= (got: $LDAP_BASE_DN)" >&2
    exit 1
fi

LDAP_ADMIN_HASH="$(slappasswd -s "$LDAP_ADMIN_PASSWORD")"
USER_PASSWORD_HASH="$(slappasswd -s "$DEMO_USER_PASSWORD")"
export LDAP_BASE_DN LDAP_ADMIN_DN LDAP_ADMIN_HASH LDAP_ORGANISATION
export MAIL_DOMAIN LDAP_DC USER_PASSWORD_HASH

mkdir -p /var/run/slapd /var/lib/ldap-mail

# Always render: a "docker compose restart" keeps the container filesystem,
# and the admin password or base DN in .env may have changed.
log "rendering slapd.conf"
envsubst '${LDAP_BASE_DN} ${LDAP_ADMIN_DN} ${LDAP_ADMIN_HASH}' \
    < /etc/ldap/slapd.conf.template > /etc/ldap/slapd.conf
# slapd drops to openldap before it reads this file, so it must be owned by
# the daemon user (it contains the rootpw hash).
chown openldap:openldap /etc/ldap/slapd.conf
chmod 0600 /etc/ldap/slapd.conf

if [ ! -f /var/lib/ldap-mail/data.mdb ]; then
    log "seeding LDAP directory"
    envsubst '${LDAP_BASE_DN} ${LDAP_ORGANISATION} ${LDAP_DC} ${MAIL_DOMAIN} ${USER_PASSWORD_HASH}' \
        < /bootstrap/bootstrap.ldif.template > /tmp/bootstrap.ldif
    slapadd -f /etc/ldap/slapd.conf -l /tmp/bootstrap.ldif
    rm -f /tmp/bootstrap.ldif
    log "seeding complete"
fi

chown -R openldap:openldap /var/run/slapd /var/lib/ldap-mail

log "starting slapd on 0.0.0.0:389"
exec slapd -f /etc/ldap/slapd.conf -h 'ldap://0.0.0.0:389/' \
    -d 256 -u openldap -g openldap

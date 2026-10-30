#!/bin/sh
# Compose healthcheck: bind as the rootdn and read the naming context.
set -eu

: "${LDAP_BASE_DN:?}"
: "${LDAP_ADMIN_PASSWORD:?}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,$LDAP_BASE_DN}"

exec ldapsearch -x -H ldap://127.0.0.1:389 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
    -b "$LDAP_BASE_DN" -s base '(objectClass=*)' dn >/dev/null 2>&1

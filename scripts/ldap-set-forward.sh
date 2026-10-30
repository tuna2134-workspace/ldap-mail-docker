#!/usr/bin/env bash
# Replace or clear the mailForward attribute of an existing account.
#
# Usage:
#   scripts/ldap-set-forward.sh UID [ADDRESS]...
#
# With no ADDRESS, mailForward is removed and the account is delivered locally.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-env.sh
source "$SCRIPT_DIR/lib-env.sh"
cd "$ROOT_DIR"

load_env "$ROOT_DIR/.env"

: "${LDAP_BASE_DN:?LDAP_BASE_DN is required in .env}"
: "${LDAP_ADMIN_PASSWORD:?LDAP_ADMIN_PASSWORD is required in .env}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,$LDAP_BASE_DN}"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 UID [ADDRESS]..." >&2
    exit 2
fi

uid="$1"
shift
[[ "$uid" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid uid: $uid" >&2; exit 2; }

for addr in "$@"; do
    [[ "$addr" == *@* && "$addr" != *[[:space:]]* ]] || { echo "invalid address: $addr" >&2; exit 2; }
done

ldif="$(mktemp)"
trap 'rm -f "$ldif"' EXIT
{
    printf 'dn: uid=%s,ou=people,%s\n' "$uid" "$LDAP_BASE_DN"
    printf 'changetype: modify\n'
    printf 'replace: mailForward\n'
    for addr in "$@"; do
        printf 'mailForward: %s\n' "$addr"
    done
    printf -- '-\n'
} > "$ldif"

docker compose exec -T ldap ldapmodify -x -H ldap://127.0.0.1:389 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" < "$ldif"

if [[ $# -eq 0 ]]; then
    printf 'Cleared mailForward for %s (local delivery)\n' "$uid"
else
    printf 'Set mailForward for %s -> %s\n' "$uid" "$*"
fi

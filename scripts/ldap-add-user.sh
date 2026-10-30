#!/usr/bin/env bash
# Add a mail account to OpenLDAP.
#
# Usage:
#   scripts/ldap-add-user.sh -u UID -n "Full Name" [-m ADDRESS]... [-f FORWARD]... [-p PASSWORD]
#
# -m may be repeated; if omitted, UID@MAIL_DOMAIN is used.
# -f may be repeated; if omitted, the account is delivered locally.
# -p may be omitted; a random password is generated and printed.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-env.sh
source "$SCRIPT_DIR/lib-env.sh"
cd "$ROOT_DIR"

load_env "$ROOT_DIR/.env"

: "${LDAP_BASE_DN:?LDAP_BASE_DN is required in .env}"
: "${MAIL_DOMAIN:?MAIL_DOMAIN is required in .env}"
: "${LDAP_ADMIN_PASSWORD:?LDAP_ADMIN_PASSWORD is required in .env}"
LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,$LDAP_BASE_DN}"

usage() {
    cat <<'EOF'
Usage:
  scripts/ldap-add-user.sh -u UID -n "Full Name" [-m ADDRESS]... [-f FORWARD]... [-p PASSWORD]

  -u UID        LDAP uid and Maildir name (/data/maildir/<uid>)
  -n NAME       Full name (cn / displayName)
  -s SURNAME    sn (default: last word of NAME)
  -m ADDRESS    mail value; repeat for aliases (default: UID@MAIL_DOMAIN)
  -f ADDRESS    mailForward value; repeat for multiple targets
  -p PASSWORD   password (default: generate and print one)

Example:
  scripts/ldap-add-user.sh -u jdoe -n "John Doe" \
      -m jdoe@example.com -m john.doe@example.com
  scripts/ldap-add-user.sh -u asmith -n "Alice Smith" \
      -m asmith@example.com -f jdoe@example.com
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

uid=""
full_name=""
surname=""
password=""
declare -a mails=()
declare -a forwards=()

while getopts ":u:n:s:p:m:f:h" opt; do
    case "$opt" in
        u) uid="$OPTARG" ;;
        n) full_name="$OPTARG" ;;
        s) surname="$OPTARG" ;;
        p) password="$OPTARG" ;;
        m) mails+=("$OPTARG") ;;
        f) forwards+=("$OPTARG") ;;
        h) usage; exit 0 ;;
        :) die "option -$OPTARG requires an argument" ;;
        \?) die "unknown option -$OPTARG (try -h)" ;;
    esac
done

[[ -n "$uid" ]] || { usage; die "-u UID is required"; }
[[ -n "$full_name" ]] || { usage; die '-n "Full Name" is required'; }

[[ "$uid" =~ ^[A-Za-z0-9._-]+$ ]] || die "uid may only contain letters, digits, dot, underscore and dash"

if [[ ${#mails[@]} -eq 0 ]]; then
    mails=("${uid}@${MAIL_DOMAIN}")
fi

for addr in "${mails[@]}" "${forwards[@]}"; do
    [[ "$addr" == *@* && "$addr" != *[[:space:]]* ]] || die "not a valid address: $addr"
done

if [[ -z "$surname" ]]; then
    surname="${full_name##* }"
fi
[[ -n "$surname" ]] || surname="$uid"

if [[ -z "$password" ]]; then
    password="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-20)"
    generated_password=1
else
    generated_password=0
fi
[[ "$password" != *$'\n'* ]] || die "password must not contain a newline"

# Hash the password with the same OpenLDAP installation that will verify it.
hash="$(docker compose exec -T ldap slappasswd -s "$password" 2>/dev/null | tr -d '\r\n')"
[[ "$hash" == \{* ]] || die "failed to hash password with slappasswd"

ldif="$(mktemp)"
trap 'rm -f "$ldif"' EXIT
{
    printf 'dn: uid=%s,ou=people,%s\n' "$uid" "$LDAP_BASE_DN"
    printf 'objectClass: top\n'
    printf 'objectClass: inetOrgPerson\n'
    printf 'objectClass: mailAccount\n'
    printf 'uid: %s\n' "$uid"
    printf 'cn: %s\n' "$full_name"
    printf 'sn: %s\n' "$surname"
    printf 'displayName: %s\n' "$full_name"
    for addr in "${mails[@]}"; do
        printf 'mail: %s\n' "$addr"
    done
    for addr in "${forwards[@]}"; do
        printf 'mailForward: %s\n' "$addr"
    done
    printf 'userPassword: %s\n' "$hash"
} > "$ldif"

docker compose exec -T ldap ldapadd -x -H ldap://127.0.0.1:389 \
    -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" < "$ldif"

printf '\nCreated uid=%s\n' "$uid"
printf '  mailbox:   /data/maildir/%s  (created by Dovecot on first use)\n' "$uid"
printf '  addresses: %s\n' "${mails[*]}"
if [[ ${#forwards[@]} -gt 0 ]]; then
    printf '  forward:   %s\n' "${forwards[*]}"
else
    printf '  forward:   (none; delivered locally)\n'
fi
if [[ "$generated_password" -eq 1 ]]; then
    printf '  password:  %s   (generated; store it now)\n' "$password"
fi

#!/usr/bin/env bash
# Minimal .env loader for host-side helper scripts.
#
# .env is a Compose env file, not shell code: values may contain spaces
# (for example LDAP_ORGANISATION=Example Inc.), so "source .env" is unsafe.
# This parser reads KEY=VALUE lines, strips optional quotes and exports them.
# It deliberately does not try to implement interpolation or escapes.

# shellcheck shell=bash

load_env() {
    local file="${1:?load_env: file is required}"
    local line key value

    if [[ ! -f "$file" ]]; then
        printf 'env file not found: %s\n' "$file" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue

        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:${#value}-2}"
        elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi

        export "${key}=${value}"
    done < "$file"
}

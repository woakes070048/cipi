#!/bin/bash
#############################################
# Cipi — Migration 4.6.5
# Defensive repair for installs stuck on 4.6.2/4.6.3/4.6.4 because a lib
# assigned a CIPI_* variable without a guard, exploding when sourced inside
# a migration context (readonly re-assignment, or unset -> empty path).
#
# Runs AFTER self-update.sh has copied the new lib/*.sh into /opt/cipi/lib,
# so it sources fixed code. This is a belt-and-suspenders pass that wraps any
# top-level `export`/`readonly` `CIPI_<NAME>=...` assignment in a
# `if [[ -z "${CIPI_<NAME>:-}" ]]; then ... fi` guard, unless already guarded.
#
# Pure bash + sed only (no gawk gensub - Ubuntu default awk is mawk).
# Fully idempotent: re-running on already-guarded files is a no-op.
#############################################

echo "Migration 4.6.5 - guard CIPI_* assignments in lib (idempotent)..."

CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

_guard_assignments() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local tmp="${file}.4.6.5.tmp"
    local changed=0
    local prev=""
    local line indent stripped varname

    : > "$tmp"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ (export|readonly) ]] \
            && [[ "$line" =~ ^([[:space:]]*)(export[[:space:]]+)?(readonly[[:space:]]+)?(CIPI_[A-Za-z0-9_]+)= ]]; then
            indent="${BASH_REMATCH[1]}"
            varname="${BASH_REMATCH[4]}"

            if [[ "$prev" == *"if [[ -z \"\${${varname}:-}\" ]]; then"* ]]; then
                printf '%s\n' "$line" >> "$tmp"
                prev="$line"
                continue
            fi

            stripped="${line#"${line%%[![:space:]]*}"}"

            {
                printf '%sif [[ -z "${%s:-}" ]]; then\n' "$indent" "$varname"
                printf '%s    %s\n' "$indent" "$stripped"
                printf '%sfi\n' "$indent"
            } >> "$tmp"
            prev="fi"
            changed=1
        else
            printf '%s\n' "$line" >> "$tmp"
            prev="$line"
        fi
    done < "$file"

    if [[ "$changed" -eq 1 ]]; then
        chmod --reference="$file" "$tmp" 2>/dev/null || chmod 700 "$tmp"
        chown --reference="$file" "$tmp" 2>/dev/null || chown root:root "$tmp"
        mv "$tmp" "$file"
        echo "  guarded CIPI_* assignments -> $(basename "$file")"
    else
        rm -f "$tmp"
    fi
    return 0
}

shopt -s nullglob
for f in "${CIPI_LIB}"/*.sh; do
    case "$(basename "$f")" in
        *.bak.*) continue ;;
    esac
    _guard_assignments "$f"
done
shopt -u nullglob

if ( set +e
     CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
     CIPI_LIB="${CIPI_LIB}"
     readonly CIPI_API_ROOT="/opt/cipi/api"
     [[ -f "${CIPI_LIB}/common.sh" ]] && source "${CIPI_LIB}/common.sh"
     [[ -f "${CIPI_LIB}/api.sh" ]]    && source "${CIPI_LIB}/api.sh"
   ) 2>/dev/null; then
    echo "  verified: common.sh + api.sh source cleanly under readonly CIPI_API_ROOT"
else
    echo "  WARN: post-patch source check still reported an issue - inspect ${CIPI_LIB}/common.sh and api.sh" >&2
fi

echo "Migration 4.6.5 complete."

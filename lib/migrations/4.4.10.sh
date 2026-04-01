#!/bin/bash
#############################################
# Cipi Migration 4.4.10 — Strip ACLs on Laravel log files (deploy:writable chmod)
#
# Older migrations could leave per-file ACLs on shared/storage/logs/*.log; chmod
# then fails with EPERM. ensure_app_logs_permissions now clears those files
# before re-applying directory ACLs. This migration runs that for every app once.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.4.10 — Laravel storage log ACL cleanup..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/common.sh"
fi

if type ensure_app_logs_permissions &>/dev/null; then
    if [[ -f "${CIPI_CONFIG}/apps.json" ]] && command -v jq &>/dev/null; then
        while IFS= read -r app; do
            [[ -n "$app" ]] && ensure_app_logs_permissions "$app"
        done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    fi
    for home in /home/*/; do
        u=$(basename "$home")
        [[ "$u" == "cipi" ]] && continue
        [[ -d "${home}/shared/storage/logs" ]] || continue
        id "$u" &>/dev/null || continue
        ensure_app_logs_permissions "$u"
    done
fi

echo "Migration 4.4.10 complete"

#!/bin/bash
#############################################
# Cipi Migration 4.5.5 — add `ll` alias to existing apps
#
# Cipi now ships the convenience alias `ll='ls -al'` in the .bashrc generated
# for every new app user (lib/app.sh). Apps created before 4.5.5 already have
# their .bashrc written, so this migration retro-fits the alias for them by
# appending it once (only when missing), preserving file ownership.
#
# Idempotent: skips any .bashrc that already defines `ll`. Safe to re-run.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.5.5 — add 'll' alias to existing apps..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/common.sh"
fi

if [[ ! -f "${CIPI_CONFIG}/apps.json" ]]; then
    echo "  No apps configured — nothing to do"
    echo "Migration 4.5.5 complete"
    exit 0
fi

added=0
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    bashrc="/home/${app}/.bashrc"
    [[ -f "$bashrc" ]] || continue
    if grep -qE "^alias ll=" "$bashrc" 2>/dev/null; then
        continue
    fi
    echo "alias ll='ls -al'" >> "$bashrc"
    chown "${app}:${app}" "$bashrc" 2>/dev/null || true
    echo "  ${app}: alias added"
    added=$((added + 1))
done < <(vault_read apps.json | jq -r 'keys[]' 2>/dev/null)

if (( added == 0 )); then
    echo "  All apps already have the 'll' alias — nothing to do"
fi

echo "Migration 4.5.5 complete"

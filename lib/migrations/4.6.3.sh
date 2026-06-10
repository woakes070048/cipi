#!/bin/bash
#############################################
# Cipi Migration 4.6.3 — API token ability list + notification triggers
#
# - Syncs token-abilities.txt into the panel API and patches lib/api.sh so
#   `cipi api token create` shows status-view, apps-suspend, apps-basicauth, etc.
# - Seeds /etc/cipi/notifications.json with all triggers enabled.
# Idempotent — safe to re-run.
#############################################

set -e

readonly CIPI_API_ROOT="/opt/cipi/api"
readonly API_SH="/opt/cipi/lib/api.sh"

echo "Migration 4.6.3 — API token ability list..."

# 1. Write token-abilities.txt (used by _api_ability_lines before artisan)
mkdir -p "${CIPI_API_ROOT}"
cat > "${CIPI_API_ROOT}/token-abilities.txt" <<'EOF'
apps-view|Read apps
apps-create|Create apps
apps-edit|Edit apps
apps-delete|Delete apps
apps-suspend|Suspend / unsuspend apps
apps-basicauth|HTTP Basic Auth
deploy-manage|Deploy, rollback, unlock
ssl-manage|SSL certificates
aliases-view|Read aliases
aliases-create|Add aliases
aliases-delete|Remove aliases
dbs-view|List databases
dbs-create|Create databases
dbs-delete|Delete databases
dbs-manage|Backup, restore, DB password
status-view|Server status
mcp-access|MCP server
EOF
chown www-data:www-data "${CIPI_API_ROOT}/token-abilities.txt" 2>/dev/null || true
echo "  token-abilities.txt → ${CIPI_API_ROOT}/token-abilities.txt"

# 2. Patch lib/api.sh when it still has the legacy 14-line hardcoded list
if [[ -f "$API_SH" ]] && ! grep -q 'token-abilities.txt' "$API_SH" 2>/dev/null; then
    echo "  Patching ${API_SH}..."
    python3 << 'PY'
from pathlib import Path

api_sh = Path("/opt/cipi/lib/api.sh")
text = api_sh.read_text()
marker = "# ability|description"
end_marker = "\n_api_token_abilities_default"
if marker not in text or end_marker not in text:
    raise SystemExit("  WARN: api.sh layout unexpected — skip patch")

start = text.index(marker)
end = text.index(end_marker, start)
replacement = '''# ability|description — sourced from the API package (token-abilities.txt / artisan)
_api_ability_lines() {
    local f src out=""
    for f in \\
        "${CIPI_API_ROOT}/token-abilities.txt" \\
        "${CIPI_API_ROOT}/vendor/cipi/api/token-abilities.txt" \\
        "/opt/cipi/cipi-api/token-abilities.txt"; do
        if [[ -f "$f" ]]; then
            cat "$f"
            return
        fi
    done
    if [[ -d "${CIPI_API_ROOT}" && -f "${CIPI_API_ROOT}/artisan" ]]; then
        out=$(cd "${CIPI_API_ROOT}" && _api_timeout 15 sudo -u www-data php artisan cipi:token-abilities 2>/dev/null) || true
    fi
    if [[ -n "$out" ]]; then
        echo "$out"
        return
    fi
    cat <<'EOF'
apps-view|Read apps
apps-create|Create apps
apps-edit|Edit apps
apps-delete|Delete apps
apps-suspend|Suspend / unsuspend apps
apps-basicauth|HTTP Basic Auth
deploy-manage|Deploy, rollback, unlock
ssl-manage|SSL certificates
aliases-view|Read aliases
aliases-create|Add aliases
aliases-delete|Remove aliases
dbs-view|List databases
dbs-create|Create databases
dbs-delete|Delete databases
dbs-manage|Backup, restore, DB password
status-view|Server status
mcp-access|MCP server
EOF
}

_api_sync_token_abilities_file() {
    local dest="${CIPI_API_ROOT}/token-abilities.txt"
    local src=""
    for src in \\
        "${CIPI_API_ROOT}/vendor/cipi/api/token-abilities.txt" \\
        "/opt/cipi/cipi-api/token-abilities.txt"; do
        if [[ -f "$src" ]]; then
            cp "$src" "$dest"
            chown www-data:www-data "$dest" 2>/dev/null || true
            return 0
        fi
    done
    if [[ -d "${CIPI_API_ROOT}" && -f "${CIPI_API_ROOT}/artisan" ]]; then
        (cd "${CIPI_API_ROOT}" && _api_timeout 15 sudo -u www-data php artisan cipi:token-abilities > "$dest" 2>/dev/null) \\
            && chown www-data:www-data "$dest" 2>/dev/null \\
            && return 0
    fi
    return 1
}
'''
api_sh.write_text(text[:start] + replacement + text[end:])
print("  api.sh patched")
PY
else
    echo "  api.sh already reads token-abilities.txt — skip patch"
fi

# 3. Nightly cipi api update cron + helper (refresh from _api_setup_cron when API is installed)
if [[ -f "${CIPI_LIB:-/opt/cipi/lib}/common.sh" && -f "$API_SH" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB:-/opt/cipi/lib}/common.sh"
    # shellcheck source=/dev/null
    source "$API_SH"
    if [[ -f "${CIPI_CONFIG:-/etc/cipi}/api.json" ]]; then
        _api_setup_cron
        echo "  /etc/cron.d/cipi-api refreshed (nightly api update @ 04:30)"
    else
        echo "  Panel API not configured — skip cron refresh"
    fi
fi

# 4. Notification triggers
if [[ -f "${CIPI_LIB:-/opt/cipi/lib}/notifications.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB:-/opt/cipi/lib}/vault.sh"
    # shellcheck source=/dev/null
    source "${CIPI_LIB:-/opt/cipi/lib}/notifications.sh"
    if [[ -f "${CIPI_CONFIG:-/etc/cipi}/notifications.json" ]]; then
        echo "  notifications.json already exists — skip"
    else
        _notify_ensure_config
        echo "  notifications.json created (all triggers enabled)"
    fi
else
    echo "  notifications.sh not found — skip notifications.json"
fi

echo "Migration 4.6.3 complete"

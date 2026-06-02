#!/bin/bash
#############################################
# Cipi Migration 4.5.4 — Deployer 8 / PHP < 8.3 compatibility check
#
# Cipi now bundles Deployer 8, which requires PHP >= 8.3. Because `dep` is
# executed with the *app's* PHP version (/usr/bin/phpX.Y /usr/local/bin/dep),
# any app still pinned to PHP 7.4/8.0/8.1/8.2 will fail at its next deploy:
# the v8 phar cannot even start on those interpreters.
#
# This migration does NOT change anything — it only inspects the installed
# Deployer binary and the apps, and warns the operator about apps that need a
# PHP upgrade. It is intentionally a no-op when Deployer 7 is installed
# (v7 still supports the older PHP versions).
#
# Read-only. Safe to re-run.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.5.4 — Deployer 8 / PHP < 8.3 compatibility check..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/common.sh"
fi

# Only relevant when Deployer 8+ is the installed binary.
dep_major=""
if declare -f deployer_major_version >/dev/null 2>&1; then
    dep_major=$(deployer_major_version 2>/dev/null || echo "")
fi

if [[ -z "$dep_major" ]]; then
    echo "  Deployer binary not found/readable — skipping"
    echo "Migration 4.5.4 complete"
    exit 0
fi

if (( dep_major < 8 )); then
    echo "  Deployer ${dep_major} installed — PHP < 8.3 still deploys fine, no action needed"
    echo "Migration 4.5.4 complete"
    exit 0
fi

if [[ ! -f "${CIPI_CONFIG}/apps.json" ]]; then
    echo "  No apps configured — nothing to check"
    echo "Migration 4.5.4 complete"
    exit 0
fi

# Collect apps whose PHP is not Deployer-8 compatible (validate_php_version is
# now the 8.3+ set, so any app failing it is pinned to PHP < 8.3).
affected=()
while IFS=$'\t' read -r app php; do
    [[ -z "$app" ]] && continue
    [[ "$php" == "null" || -z "$php" ]] && continue
    if declare -f validate_php_version >/dev/null 2>&1; then
        validate_php_version "$php" && continue
    fi
    affected+=("${app}|${php}")
done < <(vault_read apps.json | jq -r 'to_entries[] | "\(.key)\t\(.value.php)"' 2>/dev/null)

if (( ${#affected[@]} == 0 )); then
    echo "  All apps run PHP >= 8.3 — compatible with Deployer ${dep_major}"
    echo "Migration 4.5.4 complete"
    exit 0
fi

echo ""
echo "  WARNING: Deployer ${dep_major} requires PHP >= 8.3, but these apps are pinned to older PHP."
echo "  Their next deploy WILL FAIL (cipi now blocks it) until you upgrade them:"
for entry in "${affected[@]}"; do
    echo "    - ${entry%%|*}  (PHP ${entry##*|})"
done
echo ""
echo "  Fix each app:"
echo "    cipi php install 8.3        # if 8.3+ is not installed yet"
echo "    cipi app edit <app>         # set PHP to 8.3, 8.4 or 8.5"
echo ""

echo "Migration 4.5.4 complete"

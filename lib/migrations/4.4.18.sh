#!/bin/bash
#############################################
# Cipi Migration 4.4.18 — Restore app crontabs wiped by 4.4.14
#
# Migration 4.4.14 used `|` as the sed delimiter while the replacement
# string contained `||` (bash OR). sed treated the first `|` of `||`
# as the end of the replacement, failed to parse the command, and
# produced no output — which was then piped into `crontab -u <user> -`,
# effectively wiping the entire per-app crontab.
#
# This migration re-creates the crontab for every Laravel app that is
# missing its schedule:run line.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.4.18 — Restore app crontabs (fix 4.4.14 sed wipe)..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    source "${CIPI_LIB}/common.sh"
fi

restored=0

for home_dir in /home/*/; do
    u=$(basename "$home_dir")
    home="/home/${u}"
    [[ "$u" == "cipi" ]] && continue
    id "$u" &>/dev/null || continue

    # Only restore for Laravel apps (have shared/.env with artisan-style config)
    [[ -f "${home}/shared/.env" ]] || continue

    # Detect PHP version
    php_ver=""
    php_ver=$(grep -oP '(?<=CIPI_PHP_VERSION=).+' "${home}/shared/.env" 2>/dev/null || true)
    if [[ -z "$php_ver" ]] && type app_get &>/dev/null; then
        php_ver=$(app_get "$u" php 2>/dev/null || true)
    fi
    [[ -z "$php_ver" ]] && php_ver="8.4"

    # Check if custom app (skip — custom apps have no cron)
    if type app_get &>/dev/null; then
        is_custom=$(app_get "$u" custom 2>/dev/null || true)
        [[ "$is_custom" == "true" ]] && continue
    fi

    # If the user already has a working schedule:run line, skip
    if crontab -u "$u" -l 2>/dev/null | grep -q 'schedule:run'; then
        continue
    fi

    # Restore the full crontab
    cat <<CRON | crontab -u "$u" -
# Laravel Scheduler
* * * * * /usr/bin/php${php_ver} ${home}/current/artisan schedule:run >> /dev/null 2>&1
# Cipi deploy trigger (written by cipi/agent webhook)
* * * * * test -f ${home}/.deploy-trigger && rm -f ${home}/.deploy-trigger && cd ${home} && { /usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php >> ${home}/logs/deploy.log 2>&1 || sudo /usr/local/bin/cipi-app-notify ${u} deploy \$? ${home}/logs/deploy.log; }
CRON

    # Ensure sudoers entry for cipi-app-notify exists
    local_sudoers="/etc/sudoers.d/cipi-${u}"
    if [[ -f "$local_sudoers" ]] && ! grep -q 'cipi-app-notify' "$local_sudoers"; then
        echo "${u} ALL=(root) NOPASSWD: /usr/local/bin/cipi-app-notify ${u} *" >> "$local_sudoers"
    fi

    echo "  Restored crontab for ${u} (php${php_ver})"
    restored=$((restored + 1))
done

if [[ $restored -eq 0 ]]; then
    echo "  No crontabs needed restoring"
else
    echo "  Restored ${restored} app crontab(s)"
fi

echo "Migration 4.4.18 complete"

#!/bin/bash
#############################################
# Cipi Migration 4.4.14 — Deploy failure notifications
#
# Adds SMTP notification on webhook-triggered deploy failures.
# - Updates app crontabs: deploy trigger now calls cipi-app-notify on failure
# - Adds sudoers entry so app users can invoke cipi-app-notify via sudo
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.4.14 — Deploy failure notifications..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    source "${CIPI_LIB}/common.sh"
fi

for home_dir in /home/*/; do
    u=$(basename "$home_dir")
    home="/home/${u}"
    [[ "$u" == "cipi" ]] && continue
    id "$u" &>/dev/null || continue

    # Skip users without a crontab (non-app users)
    crontab -u "$u" -l &>/dev/null || continue

    # Update deploy trigger cron line to add failure notification
    if crontab -u "$u" -l 2>/dev/null | grep -q 'deploy-trigger' && \
       ! crontab -u "$u" -l 2>/dev/null | grep -q 'cipi-app-notify'; then

        php_ver=""
        if [[ -f "${home}/shared/.env" ]]; then
            php_ver=$(grep -oP '(?<=CIPI_PHP_VERSION=).+' "${home}/shared/.env" 2>/dev/null || true)
        fi
        if [[ -z "$php_ver" ]] && type app_get &>/dev/null; then
            php_ver=$(app_get "$u" php 2>/dev/null || true)
        fi
        [[ -z "$php_ver" ]] && php_ver="8.4"

        crontab -u "$u" -l 2>/dev/null | sed \
            "s#cd ${home} && /usr/bin/php[0-9.]* /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php >> ${home}/logs/deploy.log 2>&1#cd ${home} \&\& { /usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php >> ${home}/logs/deploy.log 2>\&1 || sudo /usr/local/bin/cipi-app-notify ${u} deploy \$? ${home}/logs/deploy.log; }#" \
            | crontab -u "$u" -

        echo "  Updated crontab for ${u}"
    fi

    # Add sudoers entry for cipi-app-notify (if not already present)
    local_sudoers="/etc/sudoers.d/cipi-${u}"
    if [[ -f "$local_sudoers" ]] && ! grep -q 'cipi-app-notify' "$local_sudoers"; then
        echo "${u} ALL=(root) NOPASSWD: /usr/local/bin/cipi-app-notify ${u} *" >> "$local_sudoers"
        echo "  Updated sudoers for ${u}"
    fi
done

echo "Migration 4.4.14 complete"

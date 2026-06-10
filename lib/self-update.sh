#!/bin/bash
#############################################
# Cipi — Self-Update
#############################################

readonly _CIPI_REPO="cipi-sh/cipi"
readonly _CIPI_SELFUPDATE_BACKUP_KEEP=7

_selfupdate_prune_backups() {
    local keep="${_CIPI_SELFUPDATE_BACKUP_KEEP}" dir count=0 removed=0
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        ((count++)) || true
        if (( count > keep )); then
            rm -rf "$dir" && ((removed++)) || true
        fi
    done < <(ls -1dt /opt/cipi.bak.* 2>/dev/null)
    if (( removed > 0 )); then
        info "Pruned ${removed} old self-update backup(s) (keeping ${keep} newest)"
        log_action "SELF-UPDATE: pruned ${removed} /opt/cipi.bak.* (keep=${keep})"
    fi
}

selfupdate_command() {
    parse_args "$@"
    local branch="${ARG_branch:-latest}"
    if [[ "${ARG_check:-}" == "true" ]]; then
        local rv; rv=$(curl -fsSL "https://raw.githubusercontent.com/${_CIPI_REPO}/refs/heads/${branch}/version.md" 2>/dev/null | tr -d '[:space:]')
        [[ -z "$rv" ]] && { error "Cannot check updates"; exit 1; }
        [[ "$rv" == "$CIPI_VERSION" ]] && success "Up to date (v${CIPI_VERSION})" || info "Update: v${CIPI_VERSION} → v${rv}"
        return
    fi

    step "Downloading from '${branch}'..."
    local tmp="/tmp/cipi-update-$$"; rm -rf "$tmp"
    GIT_TERMINAL_PROMPT=0 git clone -b "$branch" --depth 1 "https://github.com/${_CIPI_REPO}.git" "$tmp" 2>/dev/null \
        || { error "Download failed"; exit 1; }
    local nv; nv=$(tr -d '[:space:]' < "${tmp}/version.md" 2>/dev/null)
    [[ -z "$nv" ]] && { error "Invalid package (version.md missing)"; rm -rf "$tmp"; exit 1; }
    info "Updating v${CIPI_VERSION} → v${nv}"
    cp -r /opt/cipi "/opt/cipi.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null||true
    cp "${tmp}/cipi" /usr/local/bin/cipi; chmod 700 /usr/local/bin/cipi
    cp "${tmp}"/lib/*.sh /opt/cipi/lib/; chmod 700 /opt/cipi/lib/*.sh
    [[ -d "${tmp}/lib/deployer" ]] && cp -r "${tmp}/lib/deployer" /opt/cipi/lib/
    [[ -f "${tmp}/lib/cipi-worker.sh" ]] && cp "${tmp}/lib/cipi-worker.sh" /usr/local/bin/cipi-worker && chmod 700 /usr/local/bin/cipi-worker
    [[ -f "${tmp}/lib/cipi-cron-notify.sh" ]] && cp "${tmp}/lib/cipi-cron-notify.sh" /usr/local/bin/cipi-cron-notify && chmod 700 /usr/local/bin/cipi-cron-notify
    [[ -f "${tmp}/lib/cipi-auth-notify.sh" ]] && cp "${tmp}/lib/cipi-auth-notify.sh" /usr/local/bin/cipi-auth-notify && chmod 700 /usr/local/bin/cipi-auth-notify
    [[ -f "${tmp}/lib/cipi-app-notify.sh" ]] && cp "${tmp}/lib/cipi-app-notify.sh" /usr/local/bin/cipi-app-notify && chmod 700 /usr/local/bin/cipi-app-notify
    [[ -d "${tmp}/cipi-api" ]] && rm -rf /opt/cipi/cipi-api && cp -a "${tmp}/cipi-api" /opt/cipi/cipi-api
    chown -R root:root /usr/local/bin/cipi /opt/cipi

    # The blanket `chown -R root:root /opt/cipi` above also re-roots the panel
    # Laravel app under /opt/cipi/api: storage/, database/ and bootstrap/cache/
    # become root:root, so PHP-FPM (www-data) can no longer open
    # storage/logs/laravel.log or write the SQLite DB → the panel returns HTTP
    # 500 after EVERY self-update (including the nightly cron). The cipi-api
    # block below only reclaims them when /opt/cipi/cipi-api exists, so on
    # package-from-packagist installs it was skipped and the panel stayed
    # broken. Reclaim the writable paths unconditionally, right here.
    ensure_cipi_api_permissions

    # Run migrations — export CIPI_* so scripts sourced inside migrations work even
    # when the runner does not go through the main cipi binary (belt to common.sh auto-path).
    export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
    export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
    export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"
    export CIPI_API_ROOT="${CIPI_API_ROOT:-/opt/cipi/api}"
    if [[ -d "${tmp}/lib/migrations" ]]; then
        for m in $(ls "${tmp}/lib/migrations/"*.sh 2>/dev/null|sort -V); do
            local mv; mv=$(basename "$m" .sh)
            if [[ "$(printf '%s\n' "$CIPI_VERSION" "$mv"|sort -V|head -1)" == "$CIPI_VERSION" && "$mv" != "$CIPI_VERSION" ]]; then
                step "Migration ${mv}..."
                if ! ( set -euo pipefail; bash "$m" ); then
                    error "Migration ${mv} failed — version not updated, installation unchanged at v${CIPI_VERSION}"
                    rm -rf "$tmp"
                    exit 1
                fi
            fi
        done
    fi

    # Auto-update cipi-api package in installed API app
    if [[ -f "${CIPI_API_ROOT:-/opt/cipi/api}/artisan" ]] && [[ -d /opt/cipi/cipi-api ]]; then
        step "Updating cipi-api in Laravel app..."
        local api_root="${CIPI_API_ROOT:-/opt/cipi/api}"
        (cd "$api_root" && composer config repositories.cipi-api path /opt/cipi/cipi-api 2>/dev/null) || true
        (cd "$api_root" && composer update cipi/api --no-interaction 2>/dev/null) || true
        # Composer runs as root; reclaim ownership before migrate (SQLite/logs must be www-data-writable).
        chown -R www-data:www-data "$api_root"
        (cd "$api_root" && sudo -u www-data php artisan vendor:publish --tag=cipi-assets --force 2>/dev/null) || true
        (cd "$api_root" && sudo -u www-data php artisan migrate --force 2>/dev/null) || true
        systemctl restart cipi-queue 2>/dev/null || true
        success "cipi-api package updated in Laravel app"
    fi

    echo "$nv" > "${CIPI_CONFIG}/version"
    rm -rf "$tmp"
    _selfupdate_prune_backups
    log_action "SELF-UPDATE: v${CIPI_VERSION} → v${nv}"
    success "Updated to v${nv}"
}

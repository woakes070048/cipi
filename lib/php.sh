#!/bin/bash
#############################################
# Cipi — PHP Version Management
#############################################

readonly _PHP_EXT="fpm common cli curl bcmath mbstring mysql sqlite3 pgsql memcached redis zip xml soap gd imagick intl"

php_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        install) _php_install "$@" ;;
        remove)  _php_remove "$@" ;;
        switch)  _php_switch "$@" ;;
        list|ls) _php_list ;;
        *) error "Use: install remove switch list"; exit 1 ;;
    esac
}

_php_install() {
    local v="${1:-}"
    [[ -z "$v" ]] && { error "Usage: cipi php install <8.3|8.4|8.5>"; exit 1; }
    validate_php_version "$v" || { error "Invalid PHP version: $v (Deployer 8 requires PHP >= 8.3; use 8.3, 8.4 or 8.5)"; exit 1; }
    php_is_installed "$v" && { info "PHP $v already installed"; return; }
    step "Adding PPA..."
    add-apt-repository -y ppa:ondrej/php &>/dev/null; apt-get update -qq
    step "Installing PHP ${v}..."
    local pkgs=""
    for e in $_PHP_EXT; do pkgs+=" php${v}-${e}"; done
    apt-get install -y -qq $pkgs
    cat > "/etc/php/${v}/fpm/conf.d/99-cipi.ini" <<EOF
memory_limit = 256M
upload_max_filesize = 256M
post_max_size = 256M
max_execution_time = 300
max_input_time = 300
expose_php = Off
EOF
    cat > "/etc/php/${v}/fpm/pool.d/www.conf" <<POOLEOF
[www]
user = www-data
group = www-data
listen = /run/php/php${v}-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
POOLEOF
    systemctl restart "php${v}-fpm"; systemctl enable "php${v}-fpm"
    log_action "PHP INSTALLED: $v"; success "PHP ${v} installed"
}

_php_switch() {
    local v="${1:-}"
    [[ -z "$v" ]] && { error "Usage: cipi php switch <8.3|8.4|8.5>"; exit 1; }
    validate_php_version "$v" || { error "Invalid PHP version: $v (use 8.3, 8.4 or 8.5)"; exit 1; }
    php_is_installed "$v" || { error "PHP $v not installed. Run: cipi php install $v"; exit 1; }

    local cur; cur=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    [[ "$cur" == "$v" ]] && { info "PHP $v is already the system default"; return; }

    step "Switching system PHP CLI to ${v}..."
    update-alternatives --set php "/usr/bin/php${v}" 2>/dev/null || {
        error "update-alternatives failed"; exit 1;
    }
    success "CLI: php → /usr/bin/php${v}"

    # Migrate Cipi API FPM pool to new PHP version (if API is configured)
    if [[ -f "${CIPI_CONFIG}/api.json" ]]; then
        local old_pool="" new_pool="/etc/php/${v}/fpm/pool.d/cipi-api.conf"
        for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
            [[ "$pv" == "$v" ]] && continue
            if [[ -f "/etc/php/${pv}/fpm/pool.d/cipi-api.conf" ]]; then
                old_pool="/etc/php/${pv}/fpm/pool.d/cipi-api.conf"
                break
            fi
        done
        if [[ -n "$old_pool" ]]; then
            step "Migrating API FPM pool..."
            mv "$old_pool" "$new_pool"
            local old_ver; old_ver=$(echo "$old_pool" | grep -oP '/php/\K[0-9]+\.[0-9]+')
            reload_php_fpm "$old_ver" 2>/dev/null || true
            reload_php_fpm "$v"
            success "API FPM pool → PHP ${v}"
        fi
    fi

    # Restart cipi-queue (uses /usr/bin/php which is now the new version)
    if systemctl is-active --quiet cipi-queue 2>/dev/null; then
        step "Restarting API queue worker..."
        systemctl restart cipi-queue
        success "Queue worker restarted"
    fi

    log_action "PHP SWITCH: ${cur:-?} → $v"

    cipi_notify \
        "Cipi system PHP switched on $(hostname)" \
        "The system default PHP was changed.\n\nServer: $(hostname)\nFrom: ${cur:-unknown}\nTo: ${v}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo ""
    echo -e "  ${GREEN}${BOLD}System PHP switched to ${v}${NC}"
    [[ -n "$cur" ]] && echo -e "  ${DIM}Previous: ${cur}${NC}"
    echo -e "  ${DIM}App PHP versions are independent (per-app setting)${NC}"
    echo ""
}

_php_remove() {
    local v="${1:-}"
    [[ -z "$v" ]] && { error "Usage: cipi php remove <ver>"; exit 1; }
    validate_php_version_known "$v" || { error "Invalid: $v"; exit 1; }
    local sys_ver; sys_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    [[ "$v" == "$sys_ver" ]] && { error "PHP $v is the system default. Switch first: cipi php switch <other-ver>"; exit 1; }
    if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        local using; using=$(vault_read apps.json | jq -r --arg v "$v" 'to_entries[]|select(.value.php==$v)|.key' 2>/dev/null)
        [[ -n "$using" ]] && { error "In use by: $using"; exit 1; }
    fi
    confirm "Remove PHP ${v}?" || return
    systemctl stop "php${v}-fpm" 2>/dev/null; systemctl disable "php${v}-fpm" 2>/dev/null
    apt-get purge -y "php${v}-*" &>/dev/null; apt-get autoremove -y &>/dev/null
    log_action "PHP REMOVED: $v"; success "PHP ${v} removed"
}

_php_list() {
    local sys_ver; sys_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    echo -e "\n${BOLD}PHP Versions${NC}"
    for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        if php_is_installed "$v"; then
            local st="${RED}stopped" c="${RED}"
            systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && st="running" && c="${GREEN}"
            local n=0; [[ -f "${CIPI_CONFIG}/apps.json" ]] && n=$(vault_read apps.json | jq --arg v "$v" '[to_entries[]|select(.value.php==$v)]|length' 2>/dev/null||echo 0)
            local def=""; [[ "$v" == "$sys_ver" ]] && def=" ${CYAN}← system default${NC}"
            printf "  PHP %-6s ${c}● %-8s${NC}  %d apps%b\n" "$v" "$st" "$n" "$def"
        fi
    done; echo ""
}

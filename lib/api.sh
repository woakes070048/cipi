#!/bin/bash
#############################################
# Cipi — API & MCP Server Management
#############################################

readonly CIPI_API_ROOT="/opt/cipi/api"
readonly CIPI_API_CONFIG="${CIPI_CONFIG}/api.json"

# All Sanctum abilities for Cipi API
CIPI_ABILITIES="apps-view apps-create apps-edit apps-delete ssl-manage aliases-view aliases-create aliases-delete mcp-access"

# ── API SETUP (cipi api [domain]) ──────────────────────────────

api_setup() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && { error "Usage: cipi api <domain>"; exit 1; }
    validate_domain "$domain" || { error "Invalid domain '${domain}'"; exit 1; }

    echo ""; info "Configuring Cipi API at ${domain}..."; echo ""

    # Save config
    mkdir -p "${CIPI_CONFIG}"
    if [[ -f "${CIPI_API_CONFIG}" ]]; then
        local cur; cur=$(jq -r '.domain' "${CIPI_API_CONFIG}" 2>/dev/null)
        [[ -n "$cur" && "$cur" != "$domain" ]] && step "Updating domain: ${cur} → ${domain}"
    fi
    echo "{\"domain\": \"${domain}\"}" > "${CIPI_API_CONFIG}"
    chmod 600 "${CIPI_API_CONFIG}"
    success "Config saved"

    # Ensure Laravel API app exists
    _api_ensure_laravel_app

    # Update APP_URL in Laravel .env
    if [[ -f "${CIPI_API_ROOT}/.env" ]]; then
        sed -i "s|^APP_URL=.*|APP_URL=https://${domain}|" "${CIPI_API_ROOT}/.env"
    fi

    # PHP-FPM pool for API
    step "PHP-FPM pool..."
    _api_create_fpm_pool
    reload_php_fpm "8.4"
    success "PHP-FPM pool (cipi-api)"

    # Nginx vhost for API (no aliases)
    step "Nginx vhost..."
    _api_create_nginx_vhost "$domain"
    ln -sf /etc/nginx/sites-available/cipi-api /etc/nginx/sites-enabled/cipi-api
    reload_nginx
    success "Nginx → ${domain}"

    log_action "API CONFIGURED: $domain"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}Cipi API configured${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Domain:     ${CYAN}https://${domain}${NC}"
    echo -e "  API:        ${CYAN}https://${domain}/api${NC}"
    echo -e "  Docs:       ${CYAN}https://${domain}/docs${NC}"
    echo -e "  MCP:        ${CYAN}https://${domain}/mcp${NC}"
    echo ""
    echo -e "  ${BOLD}Next:${NC} cipi api ssl  (to install SSL certificate)"
    echo -e "        cipi api token create  (to create API token)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

_api_ensure_laravel_app() {
    if [[ ! -f "${CIPI_API_ROOT}/artisan" ]]; then
        step "Installing Laravel API app..."
        local overlay_dir="/opt/cipi/api-overlay"
        [[ -d "${CIPI_LIB}/../api" ]] && overlay_dir="${CIPI_LIB}/../api"
        rm -rf /tmp/cipi-api-build 2>/dev/null
        (cd /tmp && composer create-project laravel/laravel cipi-api-build --no-interaction --prefer-dist 2>/dev/null) || {
            error "Failed to create Laravel app. Ensure composer is available."
            exit 1
        }
        (cd /tmp/cipi-api-build && composer require laravel/sanctum laravel/mcp --no-interaction 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan vendor:publish --tag=ai-routes --force 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan vendor:publish --provider="Laravel\Sanctum\SanctumServiceProvider" --force 2>/dev/null) || true
        if [[ -d "${overlay_dir}/overlay" ]]; then
            cp -r "${overlay_dir}/overlay/"* /tmp/cipi-api-build/
        fi
        (cd /tmp/cipi-api-build && composer dump-autoload 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan key:generate --force 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan migrate --force 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan db:seed --class=ApiUserSeeder --force 2>/dev/null) || true
        rm -rf "${CIPI_API_ROOT}" 2>/dev/null
        mv /tmp/cipi-api-build "${CIPI_API_ROOT}"
        chown -R www-data:www-data "${CIPI_API_ROOT}"
        success "Laravel API app"
    else
        step "Laravel API app already at ${CIPI_API_ROOT}"
    fi
}

_api_create_fpm_pool() {
    cat > /etc/php/8.4/fpm/pool.d/cipi-api.conf <<POOL
[cipi-api]
user = www-data
group = www-data
listen = /run/php/cipi-api.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500
request_terminate_timeout = 300
php_admin_value[open_basedir] = ${CIPI_API_ROOT}/:/tmp/:/etc/cipi/:/proc/
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = /var/log/nginx/cipi-api-php-error.log
php_admin_flag[log_errors] = on
POOL
}

_api_create_nginx_vhost() {
    local domain="$1"
    cat > /etc/nginx/sites-available/cipi-api <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root ${CIPI_API_ROOT}/public;
    index index.php;
    access_log /var/log/nginx/cipi-api-access.log;
    error_log /var/log/nginx/cipi-api-error.log;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    client_max_body_size 256M;
    location /api-docs {
        alias ${CIPI_API_ROOT}/public/api-docs;
        try_files \$uri =404;
    }
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/cipi-api.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
    }
    location ~ /\.(?!well-known) { deny all; }
    error_page 404 /index.php;
}
EOF
}

# ── API SSL (cipi api ssl) ─────────────────────────────────────

api_ssl() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    local domain; domain=$(jq -r '.domain' "${CIPI_API_CONFIG}")
    [[ -z "$domain" || "$domain" == "null" ]] && { error "No domain in api.json"; exit 1; }

    echo ""
    step "Installing SSL for ${domain}..."
    echo ""

    if certbot --nginx -d "${domain}" \
        --cert-name "${domain}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect 2>&1; then
        nginx -t 2>&1 && systemctl reload nginx 2>/dev/null || true
        log_action "API SSL INSTALLED: $domain"
        echo ""; success "SSL installed for ${domain}"; echo ""
    else
        echo ""; error "SSL failed. Check DNS, port 80, and domain."; exit 1
    fi
}

# ── TOKEN LIST ─────────────────────────────────────────────────

api_token_list() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    echo -e "\n${BOLD}API Tokens${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    sudo -u www-data php "${CIPI_API_ROOT}/artisan" cipi:token-list 2>/dev/null || {
        echo "  No tokens or run: cipi api token create"
    }
    echo ""
}

# ── TOKEN CREATE ───────────────────────────────────────────────

api_token_create() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    echo ""; info "Create API token"; echo ""

    # Name (slug)
    local name=""
    while true; do
        read_input "Token name (slug: a-z, 0-9, hyphens)" "" name
        if [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
            break
        fi
        error "Invalid slug. Use lowercase letters, numbers, hyphens only."
    done

    # Abilities (multiselect with all pre-selected)
    local abilities_str
    if command -v whiptail &>/dev/null; then
        local items=()
        for a in $CIPI_ABILITIES; do
            items+=("$a" "$a" "ON")
        done
        abilities_str=$(whiptail --title "Permissions" --checklist "Select abilities (Space=toggle, Enter=confirm):" 18 60 8 "${items[@]}" 3>&1 1>&2 2>&3 | tr -d '"' | tr ' ' ',')
    else
        # Fallback: simple prompt, all selected
        echo -e "${CYAN}Permissions (comma-separated, or Enter for all):${NC}"
        echo "  $CIPI_ABILITIES"
        read -r abilities_str
        [[ -z "$abilities_str" ]] && abilities_str=$(echo $CIPI_ABILITIES | tr ' ' ',')
    fi
    [[ -z "$abilities_str" ]] && abilities_str=$(echo $CIPI_ABILITIES | tr ' ' ',')

    # Expiry date (YYYY-MM-DD, empty = no expiry)
    local expiry=""
    read_input "Expiry date (YYYY-MM-DD, empty = never)" "" expiry
    if [[ -n "$expiry" ]]; then
        if ! date -d "$expiry" &>/dev/null; then
            error "Invalid date format. Use YYYY-MM-DD"; exit 1
        fi
    fi

    echo ""
    step "Creating token..."
    local out rc
    out=$(cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan cipi:token-create --name="$name" --abilities="$abilities_str" --expires-at="${expiry}" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo ""; success "Token created"
        echo ""; echo "$out"; echo ""
        echo -e "${YELLOW}${BOLD}⚠ Save the token — it will not be shown again${NC}"
        echo ""
    else
        error "$out"; exit 1
    fi
}

# ── TOKEN REVOKE ───────────────────────────────────────────────

api_token_revoke() {
    local name="${1:-}"
    [[ -z "$name" ]] && { error "Usage: cipi api token revoke <name>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    local out rc
    out=$(cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan cipi:token-revoke --name="$name" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        success "Token '${name}' revoked"
    else
        error "Failed to revoke: $out"; exit 1
    fi
}

# ── ROUTER ─────────────────────────────────────────────────────

api_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        "")     error "Usage: cipi api <domain>"; exit 1 ;;
        ssl)    api_ssl ;;
        token)  _api_token_command "$@" ;;
        *)
            if validate_domain "$sub" 2>/dev/null; then
                api_setup "$sub"
            else
                error "Unknown: $sub"; echo "Use: <domain> | ssl | token list|create|revoke"; exit 1
            fi ;;
    esac
}

_api_token_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        list)   api_token_list ;;
        create) api_token_create ;;
        revoke) api_token_revoke "$@" ;;
        *)      error "Usage: cipi api token list|create|revoke <name>"; exit 1 ;;
    esac
}

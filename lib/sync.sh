#!/bin/bash
#############################################
# Cipi — Sync (Export / Import / List)
#############################################

sync_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        export) _sync_export "$@" ;;
        import) _sync_import "$@" ;;
        list)   _sync_list "$@" ;;
        push)   _sync_push "$@" ;;
        *) error "Use: export import list push"; exit 1 ;;
    esac
}

# ── EXPORT ────────────────────────────────────────────────────

_sync_export() {
    parse_args "$@"

    local with_db="${ARG_with_db:-false}"
    local with_storage="${ARG_with_storage:-false}"
    local output="${ARG_output:-}"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local hostname; hostname=$(hostname 2>/dev/null || echo "unknown")
    local tmp="/tmp/cipi-sync-${ts}"
    local archive="${output:-/tmp/cipi-sync-${hostname}-${ts}.tar.gz}"

    # Collect app names: positional args (excluding --flags)
    local -a apps=()
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        apps+=("$arg")
    done

    # If no apps specified, export all
    if [[ ${#apps[@]} -eq 0 ]]; then
        if [[ ! -f "${CIPI_CONFIG}/apps.json" ]] || [[ $(jq 'length' "${CIPI_CONFIG}/apps.json") -eq 0 ]]; then
            error "No apps found"; exit 1
        fi
        mapfile -t apps < <(jq -r 'keys[]' "${CIPI_CONFIG}/apps.json")
    fi

    # Validate all requested apps exist
    for a in "${apps[@]}"; do
        app_exists "$a" || { error "App '$a' not found"; exit 1; }
    done

    info "Exporting ${#apps[@]} app(s): ${apps[*]}"
    [[ "$with_db" == "true" ]] && info "Including database dumps"
    [[ "$with_storage" == "true" ]] && info "Including shared storage"
    echo ""

    mkdir -p "${tmp}/config" "${tmp}/apps"

    # 1. Filter apps.json to only included apps
    step "Config files..."
    local apps_filter; apps_filter=$(printf '%s\n' "${apps[@]}" | jq -R . | jq -s .)
    jq --argjson sel "$apps_filter" 'with_entries(select(.key as $k | $sel | index($k) != null))' \
        "${CIPI_CONFIG}/apps.json" > "${tmp}/config/apps.json"

    # databases.json: include app DBs + standalone DBs that match app names
    if [[ -f "${CIPI_CONFIG}/databases.json" ]]; then
        cp "${CIPI_CONFIG}/databases.json" "${tmp}/config/databases.json"
    fi

    # Optional configs (backup, api)
    [[ -f "${CIPI_CONFIG}/backup.json" ]] && cp "${CIPI_CONFIG}/backup.json" "${tmp}/config/backup.json"
    [[ -f "${CIPI_CONFIG}/api.json" ]]    && cp "${CIPI_CONFIG}/api.json" "${tmp}/config/api.json"
    [[ -f "${CIPI_CONFIG}/version" ]]     && cp "${CIPI_CONFIG}/version" "${tmp}/config/version"
    success "Config files"

    # 2. Per-app data
    local dbr=""
    [[ "$with_db" == "true" ]] && dbr=$(get_db_root_password)

    for app in "${apps[@]}"; do
        local ad="${tmp}/apps/${app}"
        mkdir -p "${ad}/ssh"
        step "Exporting '${app}'..."

        # .env
        [[ -f "/home/${app}/shared/.env" ]] && cp "/home/${app}/shared/.env" "${ad}/env"

        # auth.json
        [[ -f "/home/${app}/shared/auth.json" ]] && cp "/home/${app}/shared/auth.json" "${ad}/auth.json"

        # Deployer config
        [[ -f "/home/${app}/.deployer/deploy.php" ]] && cp "/home/${app}/.deployer/deploy.php" "${ad}/deploy.php"

        # SSH keys
        for f in id_ed25519 id_ed25519.pub known_hosts config authorized_keys; do
            [[ -f "/home/${app}/.ssh/${f}" ]] && cp "/home/${app}/.ssh/${f}" "${ad}/ssh/${f}"
        done

        # Supervisor config
        [[ -f "/etc/supervisor/conf.d/${app}.conf" ]] && cp "/etc/supervisor/conf.d/${app}.conf" "${ad}/supervisor.conf"

        # Crontab
        crontab -u "$app" -l 2>/dev/null > "${ad}/crontab" || true
        [[ ! -s "${ad}/crontab" ]] && rm -f "${ad}/crontab"

        # Database dump
        if [[ "$with_db" == "true" ]]; then
            step "  Database dump..."
            if mariadb-dump -u root -p"$dbr" --single-transaction --routines --triggers "$app" 2>/dev/null | gzip > "${ad}/db.sql.gz"; then
                local sz; sz=$(du -h "${ad}/db.sql.gz" | cut -f1)
                success "  Database (${sz})"
            else
                warn "  Database dump failed (skipping)"
                rm -f "${ad}/db.sql.gz"
            fi
        fi

        # Shared storage
        if [[ "$with_storage" == "true" ]]; then
            step "  Shared storage..."
            if [[ -d "/home/${app}/shared/storage" ]]; then
                if tar -czf "${ad}/storage.tar.gz" -C "/home/${app}/shared" storage/ 2>/dev/null; then
                    local sz; sz=$(du -h "${ad}/storage.tar.gz" | cut -f1)
                    success "  Storage (${sz})"
                else
                    warn "  Storage archive failed (skipping)"
                    rm -f "${ad}/storage.tar.gz"
                fi
            else
                info "  No storage directory"
            fi
        fi

        success "'${app}'"
    done

    # 3. Manifest
    local ip; ip=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "unknown")
    jq -n \
        --arg ver "$CIPI_VERSION" \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg host "$hostname" \
        --arg ip "$ip" \
        --argjson apps "$apps_filter" \
        --arg with_db "$with_db" \
        --arg with_storage "$with_storage" \
        '{
            cipi_version: $ver,
            exported_at: $ts,
            hostname: $host,
            ip: $ip,
            apps: $apps,
            with_db: ($with_db == "true"),
            with_storage: ($with_storage == "true")
        }' > "${tmp}/manifest.json"

    # 4. Create archive
    step "Creating archive..."
    tar -czf "$archive" -C /tmp "cipi-sync-${ts}"
    rm -rf "$tmp"

    local total_sz; total_sz=$(du -h "$archive" | cut -f1)
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}EXPORT COMPLETE${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  File:     ${CYAN}${archive}${NC}"
    echo -e "  Size:     ${CYAN}${total_sz}${NC}"
    echo -e "  Apps:     ${CYAN}${#apps[@]}${NC} (${apps[*]})"
    echo -e "  Database: ${CYAN}${with_db}${NC}"
    echo -e "  Storage:  ${CYAN}${with_storage}${NC}"
    echo ""
    echo -e "  ${BOLD}Transfer to target server:${NC}"
    echo -e "  ${CYAN}scp ${archive} root@<target>:/tmp/${NC}"
    echo ""
    echo -e "  ${BOLD}Then import:${NC}"
    echo -e "  ${CYAN}cipi sync import /tmp/$(basename "$archive")${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_action "SYNC EXPORT: ${#apps[@]} apps (${apps[*]}) db=${with_db} storage=${with_storage} → ${archive}"
}

# ── LIST (inspect archive) ────────────────────────────────────

_sync_list() {
    local file="${1:-}"
    [[ -z "$file" ]] && { error "Usage: cipi sync list <archive.tar.gz>"; exit 1; }
    [[ ! -f "$file" ]] && { error "File not found: $file"; exit 1; }

    local tmp; tmp=$(mktemp -d)
    tar -xzf "$file" -C "$tmp" 2>/dev/null || { error "Invalid archive"; rm -rf "$tmp"; exit 1; }

    local base; base=$(ls "$tmp" | head -1)
    local dir="${tmp}/${base}"

    [[ ! -f "${dir}/manifest.json" ]] && { error "Not a Cipi sync archive (missing manifest)"; rm -rf "$tmp"; exit 1; }

    echo ""
    echo -e "${BOLD}Cipi Sync Archive${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ver ts host ip with_db with_storage
    ver=$(jq -r '.cipi_version' "${dir}/manifest.json")
    ts=$(jq -r '.exported_at' "${dir}/manifest.json")
    host=$(jq -r '.hostname' "${dir}/manifest.json")
    ip=$(jq -r '.ip' "${dir}/manifest.json")
    with_db=$(jq -r '.with_db' "${dir}/manifest.json")
    with_storage=$(jq -r '.with_storage' "${dir}/manifest.json")

    printf "  %-14s ${CYAN}%s${NC}\n" "Cipi" "v${ver}"
    printf "  %-14s ${CYAN}%s${NC}\n" "Exported" "$ts"
    printf "  %-14s ${CYAN}%s${NC}\n" "Source" "${host} (${ip})"
    printf "  %-14s ${CYAN}%s${NC}\n" "Database" "$with_db"
    printf "  %-14s ${CYAN}%s${NC}\n" "Storage" "$with_storage"

    echo -e "\n  ${BOLD}Apps${NC}"
    printf "  ${BOLD}%-14s %-28s %-6s %-8s %s${NC}\n" "APP" "DOMAIN" "PHP" "DB" "STORAGE"

    jq -r 'to_entries[]|"\(.key)\t\(.value.domain)\t\(.value.php)"' "${dir}/config/apps.json" 2>/dev/null | while IFS=$'\t' read -r a d p; do
        local has_db="—" has_st="—"
        [[ -f "${dir}/apps/${a}/db.sql.gz" ]] && has_db="${GREEN}yes${NC}"
        [[ -f "${dir}/apps/${a}/storage.tar.gz" ]] && has_st="${GREEN}yes${NC}"
        printf "  %-14s %-28s %-6s %-8b %b\n" "$a" "$d" "$p" "$has_db" "$has_st"
    done

    if [[ -f "${dir}/config/databases.json" ]] && [[ $(jq 'length' "${dir}/config/databases.json" 2>/dev/null) -gt 0 ]]; then
        echo -e "\n  ${BOLD}Standalone Databases${NC}"
        jq -r 'to_entries[]|"  \(.key) (user: \(.value.user))"' "${dir}/config/databases.json"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Import all:      ${CYAN}cipi sync import $(basename "$file")${NC}"
    echo -e "  Import specific: ${CYAN}cipi sync import $(basename "$file") app1 app2${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    rm -rf "$tmp"
}

# ── IMPORT ────────────────────────────────────────────────────

_sync_import() {
    local file="" run_deploy="${ARG_deploy:-false}" skip_confirm="${ARG_yes:-false}"
    local -a selected_apps=()

    parse_args "$@"
    run_deploy="${ARG_deploy:-false}"
    skip_confirm="${ARG_yes:-false}"

    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        if [[ -z "$file" && "$arg" == *.tar.gz ]]; then
            file="$arg"
        else
            [[ -n "$arg" ]] && selected_apps+=("$arg")
        fi
    done

    [[ -z "$file" ]] && { error "Usage: cipi sync import <archive.tar.gz> [app1 app2 ...] [--deploy] [--yes]"; exit 1; }
    [[ ! -f "$file" ]] && { error "File not found: $file"; exit 1; }

    # Extract archive
    local tmp; tmp=$(mktemp -d)
    tar -xzf "$file" -C "$tmp" 2>/dev/null || { error "Invalid archive"; rm -rf "$tmp"; exit 1; }

    local base; base=$(ls "$tmp" | head -1)
    local dir="${tmp}/${base}"
    [[ ! -f "${dir}/manifest.json" ]] && { error "Not a Cipi sync archive"; rm -rf "$tmp"; exit 1; }

    # Read manifest
    local src_ver src_host src_ip
    src_ver=$(jq -r '.cipi_version' "${dir}/manifest.json")
    src_host=$(jq -r '.hostname' "${dir}/manifest.json")
    src_ip=$(jq -r '.ip' "${dir}/manifest.json")

    # Determine which apps to import
    local -a apps=()
    if [[ ${#selected_apps[@]} -gt 0 ]]; then
        for a in "${selected_apps[@]}"; do
            jq -e --arg a "$a" '.[$a]' "${dir}/config/apps.json" &>/dev/null || { error "App '$a' not in archive"; rm -rf "$tmp"; exit 1; }
            apps+=("$a")
        done
    else
        mapfile -t apps < <(jq -r 'keys[]' "${dir}/config/apps.json")
    fi

    echo ""
    echo -e "${BOLD}Cipi Sync Import${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Source:  ${CYAN}${src_host} (${src_ip}) — Cipi v${src_ver}${NC}"
    echo -e "  Target:  ${CYAN}$(hostname) — Cipi v${CIPI_VERSION}${NC}"
    echo -e "  Apps:    ${CYAN}${#apps[@]}${NC} (${apps[*]})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Pre-flight checks
    local -a warnings=() blocked=() domain_conflict_msgs=()
    for app in "${apps[@]}"; do
        local php_ver; php_ver=$(jq -r --arg a "$app" '.[$a].php' "${dir}/config/apps.json")
        if ! php_is_installed "$php_ver" 2>/dev/null; then
            warnings+=("  ${YELLOW}!${NC} '${app}' needs PHP ${php_ver} — not installed (run: cipi php install ${php_ver})")
        fi
        if app_exists "$app" 2>/dev/null; then
            blocked+=("$app")
        fi
        if id "$app" &>/dev/null 2>&1; then
            [[ ! " ${blocked[*]} " =~ " ${app} " ]] && blocked+=("$app")
        fi

        # Domain conflict check: domain and aliases vs target server + other apps in this batch
        local dom aliases_arr
        dom=$(jq -r --arg a "$app" '.[$a].domain' "${dir}/config/apps.json")
        mapfile -t aliases_arr < <(jq -r --arg a "$app" '.[$a].aliases // [] | .[]' "${dir}/config/apps.json")
        local -a to_check=("$dom")
        to_check+=("${aliases_arr[@]}")
        for d in "${to_check[@]}"; do
            [[ -z "$d" ]] && continue
            # Check against apps already on target
            if domain_is_used_by_other_app "$d" "" 2>/dev/null; then
                domain_conflict_msgs+=("  ${RED}✗${NC} '${app}' domain ${CYAN}${d}${NC} already used by app '${DOMAIN_USED_BY_APP}'")
                [[ ! " ${blocked[*]} " =~ " ${app} " ]] && blocked+=("$app")
            fi
            # Check against other apps in this import batch
            for other in "${apps[@]}"; do
                [[ "$other" == "$app" ]] && continue
                local other_dom other_aliases
                other_dom=$(jq -r --arg a "$other" '.[$a].domain' "${dir}/config/apps.json")
                other_aliases=$(jq -r --arg a "$other" '.[$a].aliases // [] | join(" ")' "${dir}/config/apps.json")
                if [[ "$d" == "$other_dom" ]] || [[ " ${other_aliases} " == *" ${d} "* ]]; then
                    domain_conflict_msgs+=("  ${RED}✗${NC} '${app}' domain ${CYAN}${d}${NC} conflicts with app '${other}' in same import")
                    [[ ! " ${blocked[*]} " =~ " ${app} " ]] && blocked+=("$app")
                fi
            done
        done
    done

    if [[ ${#blocked[@]} -gt 0 ]]; then
        echo ""
        for dc in "${domain_conflict_msgs[@]}"; do
            echo -e "$dc"
        done
        for b in "${blocked[@]}"; do
            # Only print "already exists" if not covered by a domain conflict message
            if [[ ! " ${domain_conflict_msgs[*]} " =~ "'${b}'" ]]; then
                echo -e "  ${RED}✗${NC} '${b}' already exists on this server"
            fi
        done
        echo ""
        error "Cannot import: app(s) already exist or domain conflict. Delete existing apps or exclude from import."
        echo -e "  ${DIM}Exclude: cipi sync import ${file} $(printf '%s ' "${apps[@]}" | sed "s/$(printf '%s ' "${blocked[@]}")//g")${NC}"
        rm -rf "$tmp"; exit 1
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo ""
        for w in "${warnings[@]}"; do echo -e "$w"; done
        echo ""
        if [[ "$skip_confirm" != "true" ]]; then
            confirm "Continue with warnings?" || { rm -rf "$tmp"; exit 0; }
        fi
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        echo ""
        confirm "Import ${#apps[@]} app(s) into this server?" || { info "Cancelled"; rm -rf "$tmp"; exit 0; }
    fi

    echo ""
    local dbr; dbr=$(get_db_root_password)
    local -a imported=() failed=()
    source "${CIPI_LIB}/app.sh"

    for app in "${apps[@]}"; do
        echo -e "\n${BOLD}Importing '${app}'...${NC}"
        echo "────────────────────────────────────────────────"
        local ad="${dir}/apps/${app}"
        local php_ver domain branch repository aliases webhook_token created_at
        php_ver=$(jq -r --arg a "$app" '.[$a].php' "${dir}/config/apps.json")
        domain=$(jq -r --arg a "$app" '.[$a].domain' "${dir}/config/apps.json")
        branch=$(jq -r --arg a "$app" '.[$a].branch // "main"' "${dir}/config/apps.json")
        repository=$(jq -r --arg a "$app" '.[$a].repository' "${dir}/config/apps.json")
        aliases=$(jq -r --arg a "$app" '.[$a].aliases // [] | join(" ")' "${dir}/config/apps.json")
        webhook_token=$(jq -r --arg a "$app" '.[$a].webhook_token' "${dir}/config/apps.json")
        created_at=$(jq -r --arg a "$app" '.[$a].created_at' "${dir}/config/apps.json")
        local home="/home/${app}"

        if ! php_is_installed "$php_ver" 2>/dev/null; then
            warn "PHP ${php_ver} not installed — skipping '${app}'"
            failed+=("$app")
            continue
        fi

        # 1. Linux user
        step "User..."
        local user_pass; user_pass=$(generate_password 32)
        useradd -m -s /bin/bash -G www-data "$app"
        echo "${app}:${user_pass}" | chpasswd
        chmod 750 "$home"
        usermod -aG "$app" www-data
        success "User (password: ${user_pass})"

        # 2. Directories
        step "Directories..."
        mkdir -p "${home}"/{shared/storage/{app/public,framework/{cache/data,sessions,views},logs},logs,.ssh,.deployer}
        cat > "${home}/.bashrc" <<BASH
export PATH="/usr/local/bin:\$PATH"
alias php='/usr/bin/php${php_ver}'
alias artisan='php ${home}/current/artisan'
alias composer='/usr/local/bin/composer'
alias tinker='artisan tinker'
alias deploy='dep deploy -f ${home}/.deployer/deploy.php'
PS1='\[\033[0;32m\]\u\[\033[0m\]@\h:\[\033[0;34m\]\w\[\033[0m\]\$ '
BASH
        success "Directories"

        # 3. SSH keys (restore from archive)
        step "SSH keys..."
        if [[ -d "${ad}/ssh" ]]; then
            for f in id_ed25519 id_ed25519.pub known_hosts config authorized_keys; do
                [[ -f "${ad}/ssh/${f}" ]] && cp "${ad}/ssh/${f}" "${home}/.ssh/${f}"
            done
            chmod 700 "${home}/.ssh"
            chmod 600 "${home}/.ssh/"* 2>/dev/null || true
            # Re-scan localhost for the new server
            ssh-keyscan -H localhost 127.0.0.1 2>/dev/null >> "${home}/.ssh/known_hosts"
            success "SSH keys (restored from source)"
        else
            sudo -u "$app" ssh-keygen -t ed25519 -C "${app}@cipi" -f "${home}/.ssh/id_ed25519" -N "" -q
            cat "${home}/.ssh/id_ed25519.pub" >> "${home}/.ssh/authorized_keys"
            ssh-keyscan -H localhost 127.0.0.1 github.com gitlab.com 2>/dev/null >> "${home}/.ssh/known_hosts"
            chmod 600 "${home}/.ssh/authorized_keys" "${home}/.ssh/known_hosts"
            warn "SSH keys (generated new — update deploy key on git provider)"
        fi

        # 4. Database
        step "Database..."
        local db_pass; db_pass=$(generate_password 24)
        mariadb -u root -p"$dbr" <<SQL
CREATE DATABASE IF NOT EXISTS \`${app}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${app}'@'localhost' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${app}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${app}\`.* TO '${app}'@'localhost';
GRANT ALL PRIVILEGES ON \`${app}\`.* TO '${app}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
        success "Database (new credentials)"

        # 5. Import DB dump if present
        if [[ -f "${ad}/db.sql.gz" ]]; then
            step "Restoring database..."
            if gunzip -c "${ad}/db.sql.gz" | mariadb -u root -p"$dbr" "$app" 2>/dev/null; then
                success "Database data restored"
            else
                warn "Database restore had issues (empty DB created)"
            fi
        fi

        # 6. .env (restore and update DB credentials)
        step ".env..."
        if [[ -f "${ad}/env" ]]; then
            cp "${ad}/env" "${home}/shared/.env"
            # Update DB credentials to new server's values
            sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${db_pass}|" "${home}/shared/.env"
            sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${app}|" "${home}/shared/.env"
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${app}|" "${home}/shared/.env"
            sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" "${home}/shared/.env"
            success ".env (restored, DB credentials updated)"
        else
            warn "No .env in archive — app will need manual .env configuration"
        fi

        # 7. auth.json
        if [[ -f "${ad}/auth.json" ]]; then
            cp "${ad}/auth.json" "${home}/shared/auth.json"
            success "auth.json restored"
        fi

        # 8. Restore shared storage
        if [[ -f "${ad}/storage.tar.gz" ]]; then
            step "Shared storage..."
            tar -xzf "${ad}/storage.tar.gz" -C "${home}/shared/" 2>/dev/null && \
                success "Storage restored" || warn "Storage restore failed"
        fi

        # 9. Fix ownership (before service configs)
        chown -R "${app}:${app}" "$home"

        # 10. Save to apps.json early (so nginx vhost can read aliases)
        local app_json; app_json=$(jq --arg a "$app" '.[$a]' "${dir}/config/apps.json")
        app_save "$app" "$app_json"

        # 11. PHP-FPM pool
        step "PHP-FPM pool..."
        _create_fpm_pool "$app" "$php_ver"
        reload_php_fpm "$php_ver"
        success "PHP-FPM ${php_ver}"

        # 12. Nginx vhost (reads aliases from apps.json)
        step "Nginx vhost..."
        _create_nginx_vhost "$app" "$domain" "$php_ver"
        ln -sf "/etc/nginx/sites-available/${app}" "/etc/nginx/sites-enabled/${app}"
        reload_nginx
        success "Nginx → ${domain}"

        # 13. Supervisor workers (restore from archive or create default)
        step "Workers..."
        if [[ -f "${ad}/supervisor.conf" ]] && [[ -s "${ad}/supervisor.conf" ]]; then
            local sup_content; sup_content=$(cat "${ad}/supervisor.conf}")
            echo "$sup_content" | sed "s|/usr/bin/php[0-9]\.[0-9]|/usr/bin/php${php_ver}|g" \
                > "/etc/supervisor/conf.d/${app}.conf"
            success "Workers (restored from source)"
        else
            echo "" > "/etc/supervisor/conf.d/${app}.conf"
            _create_supervisor_worker "$app" "$php_ver" "default"
            success "Worker (default queue)"
        fi
        reload_supervisor

        # 14. Crontab
        step "Crontab..."
        cat <<CRON | crontab -u "$app" -
* * * * * /usr/bin/php${php_ver} ${home}/current/artisan schedule:run >> /dev/null 2>&1
* * * * * test -f ${home}/.deploy-trigger && rm -f ${home}/.deploy-trigger && cd ${home} && /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php >> ${home}/logs/deploy.log 2>&1
CRON
        success "Scheduler + deploy trigger"

        # 15. Deployer config (restore or recreate)
        step "Deployer..."
        if [[ -f "${ad}/deploy.php" ]]; then
            mkdir -p "${home}/.deployer"
            cp "${ad}/deploy.php" "${home}/.deployer/deploy.php"
            sed -i "s|set('bin/php', '/usr/bin/php[0-9]\.[0-9]')|set('bin/php', '/usr/bin/php${php_ver}')|" \
                "${home}/.deployer/deploy.php"
            chown -R "${app}:${app}" "${home}/.deployer"
            success "Deployer (restored)"
        else
            _create_deployer_config "$app" "$repository" "$branch" "$php_ver"
            success "Deployer (recreated)"
        fi

        # 16. Sudoers
        step "Permissions..."
        cat > "/etc/sudoers.d/cipi-${app}" <<SUDO
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker restart ${app}
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker status ${app}
SUDO
        chmod 440 "/etc/sudoers.d/cipi-${app}"
        success "Permissions"

        # 18. Deploy if requested
        if [[ "$run_deploy" == "true" ]]; then
            step "Deploying..."
            if sudo -u "$app" bash -c "cd ${home} && /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php" 2>&1; then
                success "Deploy completed"
            else
                warn "Deploy failed — run manually: cipi deploy ${app}"
            fi
        fi

        imported+=("$app")

        echo ""
        echo -e "  ${GREEN}${BOLD}✓ '${app}' imported${NC}"
        echo -e "  SSH password: ${CYAN}${user_pass}${NC}"
        echo -e "  DB password:  ${CYAN}${db_pass}${NC}"
        echo -e "  ${YELLOW}⚠ Save these credentials!${NC}"
    done

    rm -rf "$tmp"

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}IMPORT COMPLETE${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Imported: ${CYAN}${#imported[@]}${NC} (${imported[*]})"
    [[ ${#failed[@]} -gt 0 ]] && echo -e "  Failed:   ${RED}${#failed[@]}${NC} (${failed[*]})"
    echo ""
    if [[ "$run_deploy" != "true" ]]; then
        echo -e "  ${BOLD}Next steps:${NC}"
        for a in "${imported[@]}"; do
            echo -e "    ${CYAN}cipi deploy ${a}${NC}"
        done
        echo -e "    ${CYAN}cipi ssl install <app>${NC}  (for each app)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    log_action "SYNC IMPORT: ${#imported[@]} apps (${imported[*]}) from ${src_host} (${src_ip})"
}

# ── PUSH (export + transfer + optional remote import) ─────────

_sync_push() {
    parse_args "$@"

    local remote_host="${ARG_host:-}" remote_port="${ARG_port:-}" remote_user="${ARG_user:-root}"
    local remote_import="${ARG_import:-false}"
    local with_db="${ARG_with_db:-false}"
    local with_storage="${ARG_with_storage:-false}"

    # Collect app names (positional args, excluding --flags)
    local -a app_args=()
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        app_args+=("$arg")
    done

    # Interactive prompts for connection details
    [[ -z "$remote_host" ]] && read_input "Target server (IP or hostname)" "" remote_host
    [[ -z "$remote_host" ]] && { error "Target server required"; exit 1; }
    [[ -z "$remote_port" ]] && read_input "SSH port" "22" remote_port

    echo ""
    info "Target: ${remote_user}@${remote_host}:${remote_port}"

    # Test SSH connectivity
    step "Testing SSH connection..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -p "$remote_port" "${remote_user}@${remote_host}" "echo ok" &>/dev/null; then
        echo ""
        warn "SSH key-based auth failed. Trying with password..."
        echo -e "${DIM}  You may be prompted for the root password of ${remote_host}${NC}"
        echo ""
        if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
                -p "$remote_port" "${remote_user}@${remote_host}" "echo ok" </dev/tty; then
            error "Cannot connect to ${remote_user}@${remote_host}:${remote_port}"
            echo ""
            echo -e "  ${BOLD}Troubleshooting:${NC}"
            echo -e "  ${DIM}1. Check the IP/hostname is correct${NC}"
            echo -e "  ${DIM}2. Ensure SSH is running on port ${remote_port}${NC}"
            echo -e "  ${DIM}3. Ensure root login is allowed (PermitRootLogin yes)${NC}"
            echo -e "  ${DIM}4. Or copy your SSH key: ssh-copy-id -p ${remote_port} ${remote_user}@${remote_host}${NC}"
            exit 1
        fi
    fi
    success "SSH connection OK"

    # Verify Cipi is installed on remote
    step "Checking Cipi on remote..."
    local remote_ver
    remote_ver=$(ssh -p "$remote_port" "${remote_user}@${remote_host}" \
        "cat /etc/cipi/version 2>/dev/null || echo ''" </dev/null)
    if [[ -z "$remote_ver" ]]; then
        error "Cipi is not installed on ${remote_host}"
        echo -e "  ${DIM}Install it first: curl -sSL https://cipi.sh/setup.sh | sudo bash${NC}"
        exit 1
    fi
    remote_ver=$(echo "$remote_ver" | tr -d '[:space:]')
    success "Remote Cipi v${remote_ver}"

    # Build export flags
    local -a export_flags=()
    [[ "$with_db" == "true" ]] && export_flags+=("--with-db")
    [[ "$with_storage" == "true" ]] && export_flags+=("--with-storage")

    # Run local export
    echo ""
    info "Phase 1: Export"
    echo "────────────────────────────────────────────────"
    _sync_export "${app_args[@]}" "${export_flags[@]}" 2>&1

    # Find the archive that was just created
    local archive
    archive=$(ls -t /tmp/cipi-sync-*.tar.gz 2>/dev/null | head -1)
    [[ -z "$archive" || ! -f "$archive" ]] && { error "Export archive not found"; exit 1; }

    local archive_name; archive_name=$(basename "$archive")
    local archive_sz; archive_sz=$(du -h "$archive" | cut -f1)

    # Transfer via rsync (falls back to scp)
    echo ""
    info "Phase 2: Transfer (${archive_sz})"
    echo "────────────────────────────────────────────────"
    step "Sending ${archive_name} → ${remote_host}:/tmp/"

    if command -v rsync &>/dev/null; then
        if rsync -az --progress -e "ssh -p ${remote_port}" \
                "$archive" "${remote_user}@${remote_host}:/tmp/${archive_name}"; then
            success "Transfer complete (rsync)"
        else
            error "rsync transfer failed"; exit 1
        fi
    else
        if scp -P "$remote_port" "$archive" "${remote_user}@${remote_host}:/tmp/${archive_name}"; then
            success "Transfer complete (scp)"
        else
            error "scp transfer failed"; exit 1
        fi
    fi

    # Clean up local archive
    rm -f "$archive"

    # Remote import (optional)
    if [[ "$remote_import" == "true" ]]; then
        echo ""
        info "Phase 3: Remote Import"
        echo "────────────────────────────────────────────────"
        local -a remote_cmd=("cipi" "sync" "import" "/tmp/${archive_name}" "--yes")
        [[ ${#app_args[@]} -gt 0 ]] && remote_cmd+=("${app_args[@]}")

        step "Running: ${remote_cmd[*]}"
        echo ""
        ssh -t -p "$remote_port" "${remote_user}@${remote_host}" "${remote_cmd[*]}"
        local rc=$?
        echo ""
        if [[ $rc -eq 0 ]]; then
            success "Remote import completed"
        else
            warn "Remote import exited with code ${rc}"
            echo -e "  ${DIM}You can retry manually on the remote:${NC}"
            echo -e "  ${CYAN}ssh -p ${remote_port} ${remote_user}@${remote_host}${NC}"
            echo -e "  ${CYAN}cipi sync import /tmp/${archive_name}${NC}"
        fi
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${GREEN}${BOLD}PUSH COMPLETE${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  Archive:  ${CYAN}/tmp/${archive_name}${NC} on ${CYAN}${remote_host}${NC}"
        echo ""
        echo -e "  ${BOLD}Next: SSH into the target and import${NC}"
        echo -e "  ${CYAN}ssh -p ${remote_port} ${remote_user}@${remote_host}${NC}"
        echo -e "  ${CYAN}cipi sync list /tmp/${archive_name}${NC}"
        echo -e "  ${CYAN}cipi sync import /tmp/${archive_name}${NC}"
        echo ""
        echo -e "  ${DIM}Or re-run with --import to auto-import:${NC}"
        echo -e "  ${CYAN}cipi sync push ${app_args[*]} --host=${remote_host} --port=${remote_port} --import${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    log_action "SYNC PUSH: → ${remote_user}@${remote_host}:${remote_port} import=${remote_import}"
}

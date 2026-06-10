#!/bin/bash
#############################################
# Cipi — Database Management (MariaDB)
#############################################

db_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        create)   _db_create "$@" ;;
        list|ls)  _db_list ;;
        delete)   _db_delete "$@" ;;
        backup)   _db_backup "$@" ;;
        restore)  _db_restore "$@" ;;
        password) _db_password "$@" ;;
        *) error "Use: create list delete backup restore password"; exit 1 ;;
    esac
}

_db_create() {
    parse_args "$@"
    local name="${ARG_name:-}" user="${ARG_user:-}"
    [[ -z "$name" ]] && read_input "Database name" "" name
    [[ -z "$name" ]] && { error "Name required"; exit 1; }
    [[ ! "$name" =~ ^[a-z][a-z0-9_]{1,63}$ ]] && { error "Invalid name"; exit 1; }
    [[ -z "$user" ]] && user="$name"
    local pass; pass=$(generate_password 40)
    local dbr; dbr=$(get_db_root_password)
    mariadb -u root -p"$dbr" <<SQL
CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
SQL
    vault_read databases.json | \
        jq --arg n "$name" --arg u "$user" '.[$n]={"user":$u,"created_at":(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' | \
        vault_write databases.json
    log_action "DB CREATED: $name"
    cipi_notify \
        "Cipi database created: ${name} on $(hostname)" \
        "A database was created.\n\nServer: $(hostname)\nDatabase: ${name}\nUser: ${user}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        db_create
    echo -e "\n${GREEN}✓${NC} Database: ${CYAN}${name}${NC}  User: ${CYAN}${user}${NC}  Password: ${CYAN}${pass}${NC}"
    echo -e "${YELLOW}Save this password!${NC}\n"
}

_db_list() {
    local dbr; dbr=$(get_db_root_password)
    echo -e "\n${BOLD}Databases${NC}"
    printf "  ${BOLD}%-20s %-15s %s${NC}\n" "DATABASE" "USER" "SIZE"
    mariadb -u root -p"$dbr" -N -e "
        SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,2)
        FROM information_schema.tables
        WHERE table_schema NOT IN('information_schema','mysql','performance_schema','sys')
        GROUP BY table_schema ORDER BY table_schema;" 2>/dev/null | while IFS=$'\t' read -r db sz; do
        local u; u=$(vault_read databases.json | jq -r --arg n "$db" '.[$n].user//"—"' 2>/dev/null)
        printf "  %-20s %-15s %s MB\n" "$db" "$u" "$sz"
    done; echo ""
}

_db_delete() {
    local name="${1:-}"; [[ -z "$name" ]] && { error "Usage: cipi db delete <name>"; exit 1; }
    confirm "Delete database '${name}'?" || return
    local dbr; dbr=$(get_db_root_password)
    local u; u=$(vault_read databases.json | jq -r --arg n "$name" '.[$n].user//$n' 2>/dev/null)
    mariadb -u root -p"$dbr" -e "DROP DATABASE IF EXISTS \`${name}\`; DROP USER IF EXISTS '${u}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
    vault_read databases.json | jq --arg n "$name" 'del(.[$n])' | vault_write databases.json
    log_action "DB DELETED: $name"
    cipi_notify \
        "Cipi database deleted: ${name} on $(hostname)" \
        "A database was deleted.\n\nServer: $(hostname)\nDatabase: ${name}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        db_delete
    success "'${name}' deleted"
}

_db_backup() {
    local name="${1:-}"; [[ -z "$name" ]] && { error "Usage: cipi db backup <name>"; exit 1; }
    local dbr; dbr=$(get_db_root_password)
    local dir="${CIPI_LOG}/backups"; mkdir -p "$dir"
    local f="${dir}/${name}_$(date +%Y%m%d_%H%M%S).sql.gz"
    step "Backing up '${name}'..."
    mysqldump -u root -p"$dbr" --single-transaction --routines --triggers "$name" 2>/dev/null | gzip >"$f"
    success "Saved: ${f} ($(du -h "$f"|cut -f1))"
}

_db_restore() {
    local name="${1:-}" file="${2:-}"
    [[ -z "$name" || -z "$file" ]] && { error "Usage: cipi db restore <name> <file>"; exit 1; }
    [[ ! -f "$file" ]] && { error "File not found: $file"; exit 1; }
    confirm "Restore '${name}' from '${file}'?" || return
    local dbr; dbr=$(get_db_root_password)
    if [[ "$file" == *.gz ]]; then gunzip -c "$file"|mariadb -u root -p"$dbr" "$name" 2>/dev/null
    else mariadb -u root -p"$dbr" "$name"<"$file" 2>/dev/null; fi
    success "'${name}' restored"
}

_db_password() {
    local name="${1:-}"; [[ -z "$name" ]] && { error "Usage: cipi db password <name>"; exit 1; }
    local dbr; dbr=$(get_db_root_password)
    local u; u=$(vault_read databases.json | jq -r --arg n "$name" '.[$n].user//$n' 2>/dev/null)
    local np; np=$(generate_password 40)
    mariadb -u root -p"$dbr" -e "ALTER USER '${u}'@'localhost' IDENTIFIED BY '${np}'; FLUSH PRIVILEGES;" 2>/dev/null
    echo -e "\n${GREEN}✓${NC} New password for '${u}': ${CYAN}${np}${NC}"
    echo -e "${YELLOW}Update DB_PASSWORD in your .env!${NC}\n"
}

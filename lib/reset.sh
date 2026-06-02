#!/bin/bash
#############################################
# Cipi — Reset Server Passwords
#############################################

# ── ROOT SSH PASSWORD ────────────────────────────────────────

reset_root_password() {
    local new_pass
    new_pass=$(generate_password 40)
    echo "root:${new_pass}" | chpasswd

    # Update server.json
    local tmp
    tmp=$(mktemp)
    vault_read server.json | jq --arg p "$new_pass" '. + {root_password: $p}' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"

    log_action "ROOT SSH PASSWORD RESET"

    cipi_notify \
        "Cipi root SSH password reset on $(hostname)" \
        "The root SSH password was regenerated.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo ""
    echo -e "${GREEN}✓${NC} New root password: ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

# ── DB ROOT PASSWORD ─────────────────────────────────────────

reset_db_root_password() {
    local old_pass new_pass
    old_pass=$(get_db_root_password)
    new_pass=$(generate_password 40)

    mariadb -u root -p"${old_pass}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_pass}'; FLUSH PRIVILEGES;" 2>/dev/null

    # Update server.json
    local tmp
    tmp=$(mktemp)
    vault_read server.json | jq --arg p "$new_pass" '. + {db_root_password: $p}' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"

    log_action "DB ROOT PASSWORD RESET"

    cipi_notify \
        "Cipi DB root password reset on $(hostname)" \
        "The MariaDB root password was regenerated.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo ""
    echo -e "${GREEN}✓${NC} New MariaDB root password: ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

# ── VALKEY PASSWORD ──────────────────────────────────────────

reset_valkey_password() {
    local new_pass
    new_pass=$(generate_password 40)

    # Update valkey.conf
    if grep -q "^requirepass" /etc/valkey/valkey.conf; then
        sed -i "s/^requirepass.*/requirepass ${new_pass}/" /etc/valkey/valkey.conf
    else
        echo "requirepass ${new_pass}" >> /etc/valkey/valkey.conf
    fi

    systemctl restart valkey-server

    # Update server.json (write valkey_password; drop legacy redis_password)
    local tmp
    tmp=$(mktemp)
    vault_read server.json | jq --arg p "$new_pass" '. + {valkey_password: $p} | del(.redis_password)' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"

    log_action "VALKEY PASSWORD RESET"

    cipi_notify \
        "Cipi Valkey password reset on $(hostname)" \
        "The Valkey password was regenerated.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo ""
    echo -e "${GREEN}✓${NC} New Valkey password: ${CYAN}${new_pass}${NC}"
    echo -e "${DIM}Valkey has been restarted.${NC}"
    echo -e "${YELLOW}Update REDIS_PASSWORD in your app .env files!${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

# ── ROUTER ───────────────────────────────────────────────────

reset_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        root-password)  reset_root_password ;;
        db-password)    reset_db_root_password ;;
        valkey-password|redis-password) reset_valkey_password ;;
        *) error "Unknown: $sub"; echo "Use: root-password db-password valkey-password"; exit 1 ;;
    esac
}

#!/bin/bash
#############################################
# Cipi — SMTP / Email Notifications
# Optional: notify on errors (backup, deploy, cron, workers)
#############################################

readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"
readonly SMTP_RC="${CIPI_CONFIG}/.msmtprc"

_smtp_is_enabled() {
    [[ -f "$SMTP_CFG" ]] && [[ "$(jq -r '.enabled // false' "$SMTP_CFG")" == "true" ]]
}

_smtp_ensure_msmtp() {
    if ! command -v msmtp &>/dev/null; then
        step "Installing msmtp..."
        apt-get update -qq && apt-get install -y -qq msmtp msmtp-mta
        success "msmtp installed"
    fi
}

# Generate .msmtprc from smtp.json (called after configure)
_smtp_write_rc() {
    [[ ! -f "$SMTP_CFG" ]] && return 1
    local host port user pass from tls starttls
    host=$(jq -r '.host // ""' "$SMTP_CFG")
    port=$(jq -r '.port // 587' "$SMTP_CFG")
    user=$(jq -r '.user // ""' "$SMTP_CFG")
    pass=$(jq -r '.password // ""' "$SMTP_CFG")
    from=$(jq -r '.from // ""' "$SMTP_CFG")
    tls=$(jq -r '.tls // true' "$SMTP_CFG")
    # Port 465: implicit TLS, no STARTTLS. Port 587: use STARTTLS.
    [[ "$port" == "465" ]] && starttls="off" || starttls="on"

    [[ -z "$host" || -z "$user" || -z "$pass" ]] && return 1

    cat > "$SMTP_RC" <<MSMTP
defaults
auth           on
tls            $tls
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/cipi/msmtp.log

account        cipi
host           $host
port           $port
user           $user
password       $pass
from           $from
tls_starttls   $starttls

account default : cipi
MSMTP
    chmod 600 "$SMTP_RC"
}

_smtp_configure() {
    _smtp_ensure_msmtp
    local host="" port="587" user="" pass="" from="" to="" tls="true" enabled="true"

    if [[ -f "$SMTP_CFG" ]]; then
        host=$(jq -r '.host // ""' "$SMTP_CFG")
        port=$(jq -r '.port // "587"' "$SMTP_CFG")
        user=$(jq -r '.user // ""' "$SMTP_CFG")
        pass=$(jq -r '.password // ""' "$SMTP_CFG")
        from=$(jq -r '.from // ""' "$SMTP_CFG")
        to=$(jq -r '.to // ""' "$SMTP_CFG")
        tls=$(jq -r '.tls // true' "$SMTP_CFG")
        enabled=$(jq -r '.enabled // true' "$SMTP_CFG")
    fi

    echo -e "\n${BOLD}SMTP — Email notifications for Cipi errors${NC}"
    echo -e "${DIM}Configure an SMTP server to receive alerts on backup/deploy/cron failures.${NC}\n"

    read_input "SMTP host (e.g. smtp.gmail.com)" "$host" host
    read_input "SMTP port" "${port}" port
    read_input "SMTP user" "$user" user
    read_input "SMTP password" "$pass" pass
    read_input "From address (e.g. noreply@yourdomain.com)" "$from" from
    read_input "Notification recipient (To)" "$to" to
    echo -e "  ${DIM}Use TLS? (recommended for 587)${NC}"
    read_input "TLS (true/false)" "$tls" tls
    echo -e "  ${DIM}Enable notifications?${NC}"
    read_input "Enabled (true/false)" "$enabled" enabled

    jq -n \
        --arg h "$host" --arg p "$port" --arg u "$user" --arg s "$pass" \
        --arg f "$from" --arg t "$to" --arg tl "$tls" --argjson e "$([[ "$enabled" == "true" ]] && echo true || echo false)" \
        '{host:$h,port:$p,user:$u,password:$s,from:$f,to:$t,tls:($tl=="true"),enabled:$e}' \
        > "$SMTP_CFG"
    chmod 600 "$SMTP_CFG"

    _smtp_write_rc || { error "Failed to write msmtp config"; exit 1; }

    step "Testing SMTP..."
    if _smtp_send "Cipi SMTP test" "This is a test email from Cipi. Notifications are configured correctly." 2>/dev/null; then
        success "SMTP configured and test email sent to ${to}"
    else
        warn "SMTP saved but test send failed. Check credentials and firewall (port ${port})."
    fi
}

_smtp_send() {
    local subject="$1" body="$2"
    [[ ! -f "$SMTP_CFG" ]] && return 1
    _smtp_is_enabled || return 1
    local to; to=$(jq -r '.to // empty' "$SMTP_CFG")
    [[ -z "$to" ]] && return 1
    _smtp_write_rc || return 1

    local from; from=$(jq -r '.from // "noreply@localhost"' "$SMTP_CFG")
    printf "From: %s\nTo: %s\nSubject: %s\n\n%s\n" "$from" "$to" "$subject" "$body" | \
        msmtp -C "$SMTP_RC" "$to" 2>/dev/null
}

_smtp_disable() {
    if [[ -f "$SMTP_CFG" ]]; then
        local tmp; tmp=$(mktemp)
        jq '.enabled = false' "$SMTP_CFG" > "$tmp"
        mv "$tmp" "$SMTP_CFG"
        chmod 600 "$SMTP_CFG"
        success "Email notifications disabled"
    else
        warn "SMTP not configured. Run: cipi smtp configure"
    fi
}

_smtp_enable() {
    if [[ -f "$SMTP_CFG" ]]; then
        local tmp; tmp=$(mktemp)
        jq '.enabled = true' "$SMTP_CFG" > "$tmp"
        mv "$tmp" "$SMTP_CFG"
        chmod 600 "$SMTP_CFG"
        success "Email notifications enabled"
    else
        error "SMTP not configured. Run: cipi smtp configure"
        exit 1
    fi
}

_smtp_delete() {
    if confirm "Remove SMTP config and disable notifications?"; then
        rm -f "$SMTP_CFG" "$SMTP_RC"
        success "SMTP config removed"
    fi
}

_smtp_status() {
    echo -e "\n${BOLD}SMTP / Email Notifications${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ ! -f "$SMTP_CFG" ]]; then
        echo -e "  ${DIM}Not configured${NC}"
        echo -e "  Run ${CYAN}cipi smtp configure${NC} to enable error notifications"
        echo ""
        return
    fi

    local enabled to host
    enabled=$(jq -r '.enabled // false' "$SMTP_CFG")
    to=$(jq -r '.to // ""' "$SMTP_CFG")
    host=$(jq -r '.host // ""' "$SMTP_CFG")

    if [[ "$enabled" == "true" ]]; then
        echo -e "  Status:    ${GREEN}enabled${NC}"
    else
        echo -e "  Status:    ${YELLOW}disabled${NC}"
    fi
    echo -e "  Recipient: ${CYAN}${to}${NC}"
    echo -e "  Host:      ${CYAN}${host}${NC}"
    echo ""
}

_smtp_test() {
    if ! _smtp_is_enabled; then
        error "SMTP not configured or disabled. Run: cipi smtp configure"
        exit 1
    fi
    step "Sending test email..."
    if _smtp_send "Cipi test $(date '+%Y-%m-%d %H:%M')" "Test notification from Cipi."; then
        success "Test email sent"
    else
        error "Failed to send. Check: cipi smtp status"
        exit 1
    fi
}

# Called from common.sh and other scripts — sends notification if SMTP is configured
cipi_notify() {
    local subject="$1" body="$2"
    [[ -z "$subject" || -z "$body" ]] && return 0
    _smtp_send "$subject" "$body" || true
}

smtp_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        configure) _smtp_configure ;;
        disable)   _smtp_disable ;;
        enable)    _smtp_enable ;;
        delete)    _smtp_delete ;;
        status)    _smtp_status ;;
        test)      _smtp_test ;;
        *) error "Use: configure disable enable delete status test"; exit 1 ;;
    esac
}

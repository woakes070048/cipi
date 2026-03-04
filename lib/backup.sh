#!/bin/bash
#############################################
# Cipi — Backup (S3 / S3-compatible)
#############################################

backup_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        configure) _bk_configure ;;
        run)       _bk_run "$@" ;;
        list)      _bk_list "$@" ;;
        prune)     _bk_prune "$@" ;;
        *) error "Use: configure run list prune"; exit 1 ;;
    esac
}

_ensure_awscli() {
    if ! command -v aws &>/dev/null; then
        step "Installing AWS CLI v2..."
        local tmp; tmp=$(mktemp -d)
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp}/awscliv2.zip"
        unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
        "${tmp}/aws/install" --update -i /usr/local/aws-cli -b /usr/local/bin &>/dev/null
        rm -rf "${tmp}"
        command -v aws &>/dev/null || { error "AWS CLI install failed"; exit 1; }
        success "AWS CLI $(aws --version 2>&1 | awk '{print $1}')"
    fi
}

# Wrapper: adds --endpoint-url when a custom endpoint is configured
_aws_s3() {
    local cf="${CIPI_CONFIG}/backup.json"
    local ep=""
    [[ -f "$cf" ]] && ep=$(jq -r '.endpoint_url // ""' "$cf")
    if [[ -n "$ep" ]]; then
        aws s3 --endpoint-url "$ep" "$@"
    else
        aws s3 "$@"
    fi
}

_bk_configure() {
    _ensure_awscli
    local cf="${CIPI_CONFIG}/backup.json"
    local ck="" cs="" cb="" cr="" ce=""
    if [[ -f "$cf" ]]; then
        ck=$(jq -r '.aws_key    // ""' "$cf")
        cs=$(jq -r '.aws_secret // ""' "$cf")
        cb=$(jq -r '.bucket     // ""' "$cf")
        cr=$(jq -r '.region     // ""' "$cf")
        ce=$(jq -r '.endpoint_url // ""' "$cf")
    fi

    read_input "Access Key ID" "$ck" ck
    read_input "Secret Access Key" "$cs" cs
    read_input "Bucket name" "$cb" cb
    read_input "Region" "${cr:-eu-central-1}" cr
    echo -e "  ${DIM}Leave empty for AWS S3. For other providers set the endpoint URL.${NC}"
    echo -e "  ${DIM}Examples:${NC}"
    echo -e "  ${DIM}  Hetzner:    https://<datacenter>.your-objectstorage.com${NC}"
    echo -e "  ${DIM}  DO Spaces:  https://<region>.digitaloceanspaces.com${NC}"
    echo -e "  ${DIM}  Backblaze:  https://s3.<region>.backblazeb2.com${NC}"
    echo -e "  ${DIM}  MinIO:      https://your-minio-host${NC}"
    read_input "Endpoint URL (optional)" "$ce" ce

    jq -n \
        --arg k "$ck" --arg s "$cs" --arg b "$cb" \
        --arg r "$cr" --arg e "$ce" \
        '{"aws_key":$k,"aws_secret":$s,"bucket":$b,"region":$r,"endpoint_url":$e}' \
        > "$cf"
    chmod 600 "$cf"

    mkdir -p /root/.aws
    cat > /root/.aws/credentials <<AWSCREDS
[default]
aws_access_key_id = ${ck}
aws_secret_access_key = ${cs}
AWSCREDS
    cat > /root/.aws/config <<AWSCFG
[default]
region = ${cr}
output = json
AWSCFG
    chmod 600 /root/.aws/credentials /root/.aws/config

    step "Testing S3 connectivity..."
    local test_err
    if ! test_err=$(_aws_s3 ls "s3://${cb}" 2>&1); then
        error "S3 connection failed:"
        echo "$test_err" | sed 's/^/  /'
        exit 1
    fi
    success "Backup configured (S3 connection OK)"
}

_bk_run() {
    _ensure_awscli
    local target="${1:-}" cf="${CIPI_CONFIG}/backup.json"
    [[ ! -f "$cf" ]] && { error "Run: cipi backup configure"; exit 1; }
    local bucket; bucket=$(jq -r '.bucket' "$cf")
    local dbr; dbr=$(get_db_root_password)
    local ts; ts=$(date +%Y-%m-%d_%H%M%S)
    local tmp="/tmp/cipi-bk-${ts}"; mkdir -p "$tmp"

    _do_backup() {
        local app="$1"; local d="${tmp}/${app}"; mkdir -p "$d"
        local ok=true
        step "Backup '${app}'..."

        mariadb-dump -u root -p"$dbr" --single-transaction "$app" 2>"${d}/db.err" | gzip >"${d}/db.sql.gz"
        local dump_rc=${PIPESTATUS[0]}
        if [[ $dump_rc -ne 0 ]]; then
            error "  DB dump failed:"; sed 's/^/    /' "${d}/db.err"; ok=false
        fi
        rm -f "${d}/db.err"

        local tar_err
        tar_err=$(tar -czf "${d}/shared.tar.gz" -C "/home/${app}" shared/ 2>&1) || {
            error "  Files archive failed: ${tar_err}"; ok=false
        }

        local s3_err
        if ! s3_err=$(_aws_s3 cp "${d}/" "s3://${bucket}/cipi/${app}/${ts}/" --recursive 2>&1); then
            error "  S3 upload failed:"
            echo "$s3_err" | sed 's/^/    /'
            ok=false
        else
            success "  → s3://${bucket}/cipi/${app}/${ts}/"
        fi

        [[ "$ok" == false ]] && warn "  Backup '${app}' completed with errors"
    }

    if [[ -n "$target" ]]; then
        app_exists "$target" || { error "Not found"; exit 1; }
        _do_backup "$target"
    else
        jq -r 'keys[]' "${CIPI_CONFIG}/apps.json" 2>/dev/null | while read -r a; do _do_backup "$a"; done
    fi
    rm -rf "$tmp"
    success "Backup complete"
}

_bk_prune() {
    local target="" weeks=""

    # Parse arguments: [app] --weeks=N (in any order)
    for arg in "$@"; do
        case "$arg" in
            --weeks=*) weeks="${arg#--weeks=}" ;;
            --*)       error "Unknown flag: ${arg}"; exit 1 ;;
            *)         target="$arg" ;;
        esac
    done

    [[ -z "$weeks" ]]           && { error "--weeks=<N> is required  (e.g. cipi backup prune --weeks=4)"; exit 1; }
    [[ ! "$weeks" =~ ^[0-9]+$ ]] && { error "--weeks must be a positive integer"; exit 1; }
    [[ "$weeks" -eq 0 ]]        && { error "--weeks must be greater than 0"; exit 1; }

    local cf="${CIPI_CONFIG}/backup.json"
    local cutoff; cutoff=$(date -d "${weeks} weeks ago" +%s 2>/dev/null \
                           || date -v "-${weeks}w"    +%s)

    _prune_local() {
        local app="$1"
        local pattern="/var/log/cipi/backups/${app}_*.sql.gz"
        local found=0
        for f in $pattern; do
            [[ -f "$f" ]] || continue
            local fname; fname=$(basename "$f")
            # filename format: <app>_YYYYMMDD_HHMMSS.sql.gz
            local date_str; date_str=$(echo "$fname" | grep -oP '\d{8}' | head -1)
            [[ -z "$date_str" ]] && continue
            local file_ts; file_ts=$(date -d "${date_str}" +%s 2>/dev/null \
                                     || date -j -f "%Y%m%d" "${date_str}" +%s 2>/dev/null) || continue
            if [[ "$file_ts" -lt "$cutoff" ]]; then
                rm -f "$f"
                step "  Deleted local: $(basename "$f")"
                found=1
            fi
        done
        [[ $found -eq 0 ]] && info "  No local backups older than ${weeks} week(s) for '${app}'"
    }

    _prune_s3() {
        local app="$1"
        [[ ! -f "$cf" ]] && { warn "S3 not configured — skipping S3 prune for '${app}'"; return; }
        _ensure_awscli
        local bucket; bucket=$(jq -r '.bucket' "$cf")
        local prefix="cipi/${app}/"
        local found=0
        while IFS= read -r folder; do
            [[ -z "$folder" ]] && continue
            local date_str; date_str=$(echo "$folder" | grep -oP '^\d{4}-\d{2}-\d{2}')
            [[ -z "$date_str" ]] && continue
            local folder_ts; folder_ts=$(date -d "${date_str}" +%s 2>/dev/null \
                                         || date -j -f "%Y-%m-%d" "${date_str}" +%s 2>/dev/null) || continue
            if [[ "$folder_ts" -lt "$cutoff" ]]; then
                local s3_err
                if s3_err=$(_aws_s3 rm "s3://${bucket}/${prefix}${folder}" --recursive 2>&1); then
                    step "  Deleted S3:   s3://${bucket}/${prefix}${folder}"
                    found=1
                else
                    error "  S3 delete failed for ${folder}:"; echo "$s3_err" | sed 's/^/    /'
                fi
            fi
        done < <(_aws_s3 ls "s3://${bucket}/${prefix}" 2>/dev/null | awk '{print $NF}')
        [[ $found -eq 0 ]] && info "  No S3 backups older than ${weeks} week(s) for '${app}'"
    }

    _prune_app() {
        local app="$1"
        echo -e "\n${BOLD}Pruning '${app}'${NC} ${DIM}(older than ${weeks} week(s))${NC}"
        _prune_local "$app"
        _prune_s3    "$app"
    }

    if [[ -n "$target" ]]; then
        app_exists "$target" || { error "App not found: ${target}"; exit 1; }
        _prune_app "$target"
    else
        local apps
        apps=$(jq -r 'keys[]' "${CIPI_CONFIG}/apps.json" 2>/dev/null) || true
        [[ -z "$apps" ]] && { warn "No apps found"; exit 0; }
        while IFS= read -r a; do _prune_app "$a"; done <<< "$apps"
    fi

    echo ""
    success "Prune complete"
    log_action "backup prune${target:+ $target} --weeks=${weeks}"
}

_bk_list() {
    _ensure_awscli
    local target="${1:-}" cf="${CIPI_CONFIG}/backup.json"
    [[ ! -f "$cf" ]] && { error "Run: cipi backup configure"; exit 1; }
    local bucket; bucket=$(jq -r '.bucket' "$cf")
    echo -e "\n${BOLD}Backups${NC}"
    local ls_err
    if [[ -n "$target" ]]; then
        ls_err=$(_aws_s3 ls "s3://${bucket}/cipi/${target}/" 2>&1) || { error "$ls_err"; exit 1; }
        echo "$ls_err" | sed 's/^/  /'
    else
        ls_err=$(_aws_s3 ls "s3://${bucket}/cipi/" 2>&1) || { error "$ls_err"; exit 1; }
        echo "$ls_err" | sed 's/^/  /'
    fi
    echo ""
}

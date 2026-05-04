#!/bin/bash
#############################################
# Cipi Migration 4.5.0 — Panel API resilience: FPM pool, logging, SQLite WAL
#
# Pre-4.5.0 the Cipi API stack had three structural defects that combined
# into the well-known "API drops to 500 with no log after a while":
#
# 1. PHP-FPM pool too small (max_children=10, no slowlog, no
#    catch_workers_output). Long sync ops (deploy, artisan, MCP, sudo cipi)
#    saturated the pool; FPM eventually killed workers at
#    request_terminate_timeout=300 — *after* SIGKILL Laravel can no longer
#    write to laravel.log, so the 500 left no application-level trace.
#
# 2. SQLite default journal_mode=DELETE + Laravel's ~5s busy_timeout: the
#    queue worker (cipi-queue) and the FPM children compete for the single
#    writer; under burst traffic this surfaces as "database is locked"
#    500s, sometimes silent if Monolog itself stalls on the same DB.
#
# 3. LOG_CHANNEL=stack with a single "single" sub-channel: when the worker
#    dies before the exception handler runs, nothing reaches stderr → the
#    only place that captures it (FPM master / journalctl) sees nothing.
#
# This migration retrofits installed servers to match what `cipi api`
# now writes on fresh installs:
#
#  - rewrites /etc/php/<ver>/fpm/pool.d/cipi-api.conf with a sane pool
#    (max_children=25, listen.backlog=1024, slowlog=30s,
#    catch_workers_output=yes, error_log moved out of /var/log/nginx)
#  - rewrites /etc/systemd/system/cipi-queue.service so the queue worker
#    auto-recycles every hour / 200 jobs (PHP long-running mem leaks)
#  - forces LOG_CHANNEL=stack and LOG_STACK=single,stderr in .env
#  - applies WAL + busy_timeout=15000 to the panel SQLite DB
#  - registers the new log files in cipi-http-logs logrotate
#  - rebuilds Nginx vhost (FastCGI buffers + /cipi-api-fpm-status local)
#  - reloads systemd, restarts php-fpm and cipi-queue
#
# Idempotent: pool/service/vhost are full rewrites; .env edits are
# grep-then-sed-or-append; SQLite PRAGMAs are settings, not schema.
# Safe to re-run.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
CIPI_API_ROOT="${CIPI_API_ROOT:-/opt/cipi/api}"
CIPI_API_CONFIG="${CIPI_CONFIG}/api.json"

echo "Migration 4.5.0 — Panel API resilience (FPM pool, logging, SQLite WAL)..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/common.sh"
fi

# Skip cleanly if API was never installed on this server.
if [[ ! -f "$CIPI_API_CONFIG" ]] || [[ ! -f "${CIPI_API_ROOT}/artisan" ]]; then
    echo "  API not installed on this server — nothing to do"
    echo "Migration 4.5.0 complete"
    exit 0
fi

# 1. Detect PHP version actively serving the API. The pool may live under
#    /etc/php/8.4/ or /etc/php/8.5/ depending on `cipi php switch` history.
PHP_VER=""
for pv in 8.5 8.4 8.3 8.2 8.1 8.0 7.4; do
    if [[ -f "/etc/php/${pv}/fpm/pool.d/cipi-api.conf" ]]; then
        PHP_VER="$pv"
        break
    fi
done

if [[ -z "$PHP_VER" ]]; then
    echo "  WARN: no /etc/php/<ver>/fpm/pool.d/cipi-api.conf found"
    echo "  Run: sudo cipi api fix-permissions && sudo cipi api status"
    echo "Migration 4.5.0 complete"
    exit 0
fi

echo "  Detected API PHP-FPM pool: php${PHP_VER}"

# 2. Rewrite FPM pool — same template as lib/api.sh::_api_create_fpm_pool
#    Kept inline (not sourced) so this migration is a self-contained
#    snapshot, surviving lib/api.sh edits in future versions.
cat > "/etc/php/${PHP_VER}/fpm/pool.d/cipi-api.conf" <<POOL
[cipi-api]
user = www-data
group = www-data
listen = /run/php/cipi-api.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
listen.backlog = 1024
pm = dynamic
pm.max_children = 25
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 200
pm.process_idle_timeout = 60s
pm.status_path = /cipi-api-fpm-status
request_terminate_timeout = 300
request_slowlog_timeout = 30
slowlog = /var/log/cipi-api-fpm-slow.log
catch_workers_output = yes
decorate_workers_output = no
php_admin_value[open_basedir] = ${CIPI_API_ROOT}/:/tmp/:/etc/cipi/:/proc/
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = /var/log/cipi-api-php-error.log
php_admin_flag[log_errors] = on
POOL
echo "  /etc/php/${PHP_VER}/fpm/pool.d/cipi-api.conf rewritten"

# 3. Provision the new log files (slowlog, php-error)
for f in /var/log/cipi-api-fpm-slow.log /var/log/cipi-api-php-error.log; do
    : > "$f" 2>/dev/null || true
    chown www-data:adm "$f" 2>/dev/null || true
    chmod 640 "$f" 2>/dev/null || true
done
echo "  /var/log/cipi-api-{fpm-slow,php-error}.log provisioned"

# 4. logrotate — extend cipi-http-logs to include the new API logs
#    (still copytruncate; same policy as 4.4.6).
if [[ -d /etc/logrotate.d ]]; then
    cat > /etc/logrotate.d/cipi-api-logs <<'LR'
/var/log/cipi-api-fpm-slow.log
/var/log/cipi-api-php-error.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
}
LR
    echo "  /etc/logrotate.d/cipi-api-logs installed"
fi

# 5. Rewrite Nginx vhost (adds FastCGI buffers + local /cipi-api-fpm-status)
DOMAIN=""
if command -v jq &>/dev/null && [[ -f "$CIPI_API_CONFIG" ]]; then
    if type vault_read &>/dev/null; then
        DOMAIN=$(vault_read api.json | jq -r '.domain' 2>/dev/null)
    else
        DOMAIN=$(jq -r '.domain' "$CIPI_API_CONFIG" 2>/dev/null)
    fi
fi
[[ "$DOMAIN" == "null" ]] && DOMAIN=""

if [[ -n "$DOMAIN" ]]; then
    cat > /etc/nginx/sites-available/cipi-api <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
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
    location = /cipi-api-fpm-status {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        fastcgi_pass unix:/run/php/cipi-api.sock;
        fastcgi_param SCRIPT_FILENAME \$fastcgi_script_name;
        include fastcgi_params;
    }
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/cipi-api.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_connect_timeout 60;
        fastcgi_buffers 16 32k;
        fastcgi_buffer_size 64k;
        fastcgi_busy_buffers_size 128k;
        fastcgi_intercept_errors off;
    }
    location ~ /\.(?!well-known) { deny all; }
    error_page 404 /index.php;
}
NGINX
    # Re-apply certbot redirect/SSL block if certbot has touched the site.
    # certbot edits sites-available/cipi-api in place; if SSL was already
    # configured, calling `certbot --nginx --reinstall` keeps the cert and
    # re-injects the listen 443 block. Skip if we cannot find the cert.
    if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]] && command -v certbot &>/dev/null; then
        certbot --nginx -d "${DOMAIN}" --cert-name "${DOMAIN}" \
            --reinstall --redirect --non-interactive 2>/dev/null || true
    fi
    if nginx -t &>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        echo "  /etc/nginx/sites-available/cipi-api rewritten"
    else
        echo "  WARN: nginx -t failed after vhost rewrite — please review manually"
    fi
else
    echo "  WARN: domain not in api.json — Nginx vhost not rewritten"
fi

# 6. Rewrite cipi-queue.service so the worker auto-recycles
cat > /etc/systemd/system/cipi-queue.service <<SYSTEMD
[Unit]
Description=Cipi API Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=${CIPI_API_ROOT}
ExecStart=/usr/bin/php artisan queue:work database --sleep=3 --tries=1 --timeout=600 --queue=default --max-time=3600 --max-jobs=200 --rest=1
Restart=always
RestartSec=5
StandardOutput=append:/var/log/cipi-queue.log
StandardError=append:/var/log/cipi-queue.log

[Install]
WantedBy=multi-user.target
SYSTEMD
systemctl daemon-reload
echo "  /etc/systemd/system/cipi-queue.service rewritten"

# 7. Force LOG_CHANNEL=stack + LOG_STACK=single,stderr in .env
if [[ -f "${CIPI_API_ROOT}/.env" ]]; then
    if grep -q '^LOG_CHANNEL=' "${CIPI_API_ROOT}/.env" 2>/dev/null; then
        sed -i 's|^LOG_CHANNEL=.*|LOG_CHANNEL=stack|' "${CIPI_API_ROOT}/.env"
    else
        echo 'LOG_CHANNEL=stack' >> "${CIPI_API_ROOT}/.env"
    fi
    if grep -q '^LOG_STACK=' "${CIPI_API_ROOT}/.env" 2>/dev/null; then
        sed -i 's|^LOG_STACK=.*|LOG_STACK=single,stderr|' "${CIPI_API_ROOT}/.env"
    else
        echo 'LOG_STACK=single,stderr' >> "${CIPI_API_ROOT}/.env"
    fi
    chown www-data:www-data "${CIPI_API_ROOT}/.env" 2>/dev/null || true
    chmod 640 "${CIPI_API_ROOT}/.env" 2>/dev/null || true
    echo "  ${CIPI_API_ROOT}/.env: LOG_CHANNEL=stack, LOG_STACK=single,stderr"
fi

# 8. Apply SQLite pragmas (WAL + busy_timeout=15s)
DB_FILE=""
if [[ -f "${CIPI_API_ROOT}/.env" ]] && grep -q '^DB_CONNECTION=sqlite' "${CIPI_API_ROOT}/.env" 2>/dev/null; then
    raw=$(grep '^DB_DATABASE=' "${CIPI_API_ROOT}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]"\r')
    [[ -z "$raw" || "$raw" == "null" ]] && raw="database/database.sqlite"
    if [[ "$raw" =~ ^/ ]]; then
        DB_FILE="$raw"
    else
        DB_FILE="${CIPI_API_ROOT}/${raw}"
    fi
fi
if [[ -n "$DB_FILE" && -f "$DB_FILE" ]] && command -v sqlite3 &>/dev/null; then
    sudo -u www-data sqlite3 "$DB_FILE" <<'SQL' 2>/dev/null || true
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=15000;
SQL
    mode=$(sudo -u www-data sqlite3 "$DB_FILE" 'PRAGMA journal_mode;' 2>/dev/null)
    echo "  ${DB_FILE}: journal_mode=${mode:-?}, busy_timeout=15s"
else
    echo "  SQLite DB not found or sqlite3 missing — skipped pragma step"
fi

# 9. Permissions sweep (restore-the-world, like 4.4.16)
if type ensure_cipi_api_permissions &>/dev/null; then
    ensure_cipi_api_permissions
fi

# 10. Restart services
systemctl enable cipi-queue 2>/dev/null || true
systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || echo "  WARN: php${PHP_VER}-fpm restart failed — check 'systemctl status php${PHP_VER}-fpm'"
systemctl restart cipi-queue 2>/dev/null || echo "  WARN: cipi-queue restart failed — check 'systemctl status cipi-queue'"
echo "  php${PHP_VER}-fpm and cipi-queue restarted"

echo "Migration 4.5.0 complete"

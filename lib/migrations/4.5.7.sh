#!/bin/bash
#############################################
# Cipi Migration 4.5.7 — switch Redis → Valkey (self-contained, package fix)
#
# Migration 4.5.6 tried to install an APT package named `valkey`, but on Ubuntu
# 24.04 the daemon package is `valkey-server` (source `valkey`; binaries
# `valkey-server` + `valkey-tools`). On servers already on 4.5.6 the switch
# aborted with "valkey package not available" and left redis-server running
# (nothing was touched). 4.5.6 has already shipped and cannot be re-run, so this
# migration performs the full, corrected switch itself.
#
# It REUSES the current Redis password (so no app .env needs editing) and
# PRESERVES the dataset: it forces an RDB save and snapshots dump.rdb/AOF, then
# stops and PURGES redis-server (avoiding any apt Conflicts/Replaces ambiguity),
# installs valkey-server + valkey-tools, restores the snapshot into Valkey's
# data dir (Valkey reads the Redis 7.2 RDB/AOF format), and configures it on the
# same port with the same requirepass/bind. If valkey can't be installed it
# restores redis-server with the saved password, so the server is never left
# without a cache backend.
#
# Idempotent: skips when Valkey is already the active server. Safe to re-run.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.5.7 — switch Redis → Valkey (valkey-server)..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/common.sh"
fi

# Resolve the systemd unit name the valkey package installs (valkey-server on
# Ubuntu 24.04; fall back to valkey just in case).
valkey_unit() {
    if systemctl list-unit-files --quiet "valkey-server.service" &>/dev/null; then
        echo "valkey-server"
    else
        echo "valkey"
    fi
}

# Already migrated? (valkey running and redis-server not running)
if systemctl is-active --quiet valkey-server 2>/dev/null \
   && ! systemctl is-active --quiet redis-server 2>/dev/null; then
    echo "  Valkey already active and redis-server not running — nothing to do"
    echo "Migration 4.5.7 complete"
    exit 0
fi

# 1. Recover the existing password so apps keep authenticating unchanged.
PASS=""
if [[ -f "${CIPI_CONFIG}/server.json" ]] && declare -f vault_read >/dev/null 2>&1; then
    PASS=$(vault_read server.json | jq -r '.valkey_password // .redis_password // empty' 2>/dev/null || echo "")
fi
if [[ -z "$PASS" && -f /etc/redis/redis.conf ]]; then
    PASS=$(grep -E '^requirepass ' /etc/redis/redis.conf 2>/dev/null | awk '{print $2}' | head -1)
fi
if [[ -z "$PASS" ]]; then
    PASS=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 40)
    echo "  No existing Redis password found — generated a new one (update REDIS_PASSWORD in app .env files)"
else
    echo "  Reusing existing password (app .env files need no change)"
fi

# valkey-server lives in the 'universe' component. Enable it without pulling in
# software-properties-common: prefer add-apt-repository when present, else edit
# the apt sources directly (deb822 on 24.04, legacy sources.list as fallback).
_ensure_universe() {
    if apt-cache policy 2>/dev/null | grep -q 'universe'; then
        return 0
    fi
    echo "  'universe' component not enabled — enabling it..."
    if command -v add-apt-repository >/dev/null 2>&1; then
        add-apt-repository -y universe >/dev/null 2>&1 || true
    else
        local deb822=/etc/apt/sources.list.d/ubuntu.sources
        if [[ -f "$deb822" ]] && grep -q '^Components:' "$deb822" && ! grep -q '^Components:.*universe' "$deb822"; then
            sed -i '/^Components:/ s/$/ universe/' "$deb822"
        fi
        local cn; cn=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-noble}")
        if [[ -f /etc/apt/sources.list ]] && ! grep -qE "^deb .*\b${cn}\b.*universe" /etc/apt/sources.list; then
            {
                echo "deb http://archive.ubuntu.com/ubuntu ${cn} universe"
                echo "deb http://archive.ubuntu.com/ubuntu ${cn}-updates universe"
            } >> /etc/apt/sources.list
        fi
    fi
    apt-get update -qq 2>/dev/null || true
}

# 2. Confirm valkey-server is actually installable BEFORE touching redis-server,
#    so a server that can't get the package keeps its working cache backend.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>/dev/null || true
_valkey_candidate() { apt-cache policy valkey-server 2>/dev/null | awk '/Candidate:/{print $2}'; }
candidate=$(_valkey_candidate)
if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    _ensure_universe
    candidate=$(_valkey_candidate)
fi
if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    echo "  ERROR: 'valkey-server' package not available from APT (even after enabling universe)."
    echo "  Leaving redis-server untouched. Check your APT sources/mirror."
    echo "Migration 4.5.7 aborted (Valkey package unavailable)"
    exit 0
fi
echo "  valkey-server candidate: ${candidate}"

# 3. Snapshot the Redis dataset (Valkey reads the Redis 7.2 RDB/AOF format, so
#    the switch is lossless), then stop and PURGE redis-server. Purging up-front
#    avoids any apt Conflicts/Replaces ambiguity between the valkey-server and
#    redis-server packages, so the Valkey install is always clean.
REDIS_DATADIR=$(grep -E '^dir ' /etc/redis/redis.conf 2>/dev/null | awk '{print $2}' | tail -1)
[[ -z "$REDIS_DATADIR" ]] && REDIS_DATADIR=/var/lib/redis
DUMP_TMP=""
if dpkg -l redis-server 2>/dev/null | grep -q '^ii'; then
    # Force a synchronous RDB save so dump.rdb reflects the live dataset.
    if command -v redis-cli >/dev/null 2>&1; then
        if [[ -n "$PASS" ]]; then
            redis-cli -a "$PASS" SAVE >/dev/null 2>&1 || true
        else
            redis-cli SAVE >/dev/null 2>&1 || true
        fi
    fi
    if [[ -f "${REDIS_DATADIR}/dump.rdb" || -d "${REDIS_DATADIR}/appendonlydir" ]]; then
        DUMP_TMP=$(mktemp -d)
        cp -a "${REDIS_DATADIR}/dump.rdb" "${DUMP_TMP}/" 2>/dev/null || true
        cp -a "${REDIS_DATADIR}/appendonlydir" "${DUMP_TMP}/" 2>/dev/null || true
        echo "  Captured Redis dataset (dump.rdb/AOF) for migration"
    fi

    systemctl stop redis-server 2>/dev/null || true
    apt-get purge -y -qq redis-server redis-tools 2>/dev/null || true
    echo "  redis-server purged (password preserved in server.json)"
fi

# Restore redis as a fallback if valkey can't be installed or won't come up
# healthy — so the server is never left without a working cache backend. Also
# restores the captured dataset (DUMP_TMP) so no data is lost on rollback.
_restore_redis() {
    echo "  Rolling back to redis-server..."
    # Free :6379 in case a broken valkey is occupying it.
    if systemctl list-unit-files --quiet "$(valkey_unit).service" &>/dev/null; then
        systemctl stop "$(valkey_unit)" 2>/dev/null || true
        systemctl disable "$(valkey_unit)" 2>/dev/null || true
    fi
    if apt-get install -y -qq redis-server 2>/dev/null; then
        if grep -q "^# *requirepass\|^requirepass" /etc/redis/redis.conf 2>/dev/null; then
            sed -i "s/^# *requirepass.*/requirepass ${PASS}/; s/^requirepass.*/requirepass ${PASS}/" /etc/redis/redis.conf
        else
            echo "requirepass ${PASS}" >> /etc/redis/redis.conf
        fi
        # Put the dataset back so the fallback isn't empty.
        if [[ -n "${DUMP_TMP:-}" && -d "$DUMP_TMP" ]]; then
            systemctl stop redis-server 2>/dev/null || true
            mkdir -p "$REDIS_DATADIR"
            [[ -f "${DUMP_TMP}/dump.rdb" ]] && cp -a "${DUMP_TMP}/dump.rdb" "${REDIS_DATADIR}/dump.rdb" 2>/dev/null || true
            [[ -d "${DUMP_TMP}/appendonlydir" ]] && { rm -rf "${REDIS_DATADIR}/appendonlydir" 2>/dev/null || true; cp -a "${DUMP_TMP}/appendonlydir" "${REDIS_DATADIR}/appendonlydir" 2>/dev/null || true; }
            chown -R redis:redis "$REDIS_DATADIR" 2>/dev/null || true
        fi
        systemctl enable redis-server 2>/dev/null || true
        systemctl restart redis-server 2>/dev/null || true
        echo "  redis-server restored with the saved password and dataset."
    else
        echo "  WARNING: could not reinstall redis-server — manual intervention needed."
    fi
}

if ! apt-get install -y -qq valkey-server valkey-tools 2>/dev/null; then
    echo "  ERROR: failed to install 'valkey-server valkey-tools'."
    _restore_redis
    echo "Migration 4.5.7 aborted"
    exit 0
fi

if [[ ! -f /etc/valkey/valkey.conf ]]; then
    echo "  ERROR: /etc/valkey/valkey.conf missing after install — aborting."
    _restore_redis
    echo "Migration 4.5.7 aborted"
    exit 0
fi

# 3c. Restore the captured dataset into Valkey's data dir BEFORE its first real
#     start (the package auto-started an empty instance on install).
if [[ -n "$DUMP_TMP" ]]; then
    VALKEY_DATADIR=$(grep -E '^dir ' /etc/valkey/valkey.conf 2>/dev/null | awk '{print $2}' | tail -1)
    [[ -z "$VALKEY_DATADIR" ]] && VALKEY_DATADIR=/var/lib/valkey
    systemctl stop "$(valkey_unit)" 2>/dev/null || true
    mkdir -p "$VALKEY_DATADIR"
    [[ -f "${DUMP_TMP}/dump.rdb" ]] && cp -a "${DUMP_TMP}/dump.rdb" "${VALKEY_DATADIR}/dump.rdb" 2>/dev/null || true
    if [[ -d "${DUMP_TMP}/appendonlydir" ]]; then
        rm -rf "${VALKEY_DATADIR}/appendonlydir" 2>/dev/null || true
        cp -a "${DUMP_TMP}/appendonlydir" "${VALKEY_DATADIR}/appendonlydir" 2>/dev/null || true
    fi
    chown -R valkey:valkey "$VALKEY_DATADIR" 2>/dev/null || true
    echo "  Restored Redis dataset into ${VALKEY_DATADIR}"
fi

# 4. Configure requirepass + bind to localhost (mirror the Redis setup).
if grep -q "^# *requirepass" /etc/valkey/valkey.conf; then
    sed -i "s/^# *requirepass.*/requirepass ${PASS}/" /etc/valkey/valkey.conf
elif grep -q "^requirepass" /etc/valkey/valkey.conf; then
    sed -i "s/^requirepass.*/requirepass ${PASS}/" /etc/valkey/valkey.conf
else
    echo "requirepass ${PASS}" >> /etc/valkey/valkey.conf
fi
if grep -q "^bind " /etc/valkey/valkey.conf; then
    sed -i "s/^bind .*/bind 127.0.0.1 -::1/" /etc/valkey/valkey.conf
else
    echo "bind 127.0.0.1 -::1" >> /etc/valkey/valkey.conf
fi

# 5. Enable + (re)start Valkey.
UNIT=$(valkey_unit)
systemctl enable "$UNIT" 2>/dev/null || true
systemctl restart "$UNIT" 2>/dev/null || true

# 5b. Health check: Valkey must be active AND answer PING with the password,
#     otherwise roll back to redis-server (with the saved password + dataset) so
#     the server is never left without a working cache backend.
_valkey_healthy() {
    systemctl is-active --quiet "$UNIT" 2>/dev/null || return 1
    local cli; cli=$(command -v valkey-cli || command -v redis-cli || echo "")
    [[ -z "$cli" ]] && return 0
    local pong; pong=$("$cli" -a "$PASS" ping 2>/dev/null | tr -d '[:space:]')
    [[ "$pong" == "PONG" ]]
}
healthy=1
for _ in 1 2 3 4 5; do
    if _valkey_healthy; then healthy=0; break; fi
    sleep 1
done
if [[ "$healthy" -ne 0 ]]; then
    echo "  ERROR: Valkey did not come up healthy (no PONG) — rolling back to redis-server."
    _restore_redis
    [[ -n "${DUMP_TMP:-}" && -d "$DUMP_TMP" ]] && rm -rf "$DUMP_TMP"
    echo "Migration 4.5.7 aborted (Valkey unhealthy)"
    exit 0
fi
echo "  ${UNIT} healthy on 127.0.0.1:6379"

# Switch confirmed working — the dataset snapshot is no longer needed.
[[ -n "${DUMP_TMP:-}" && -d "$DUMP_TMP" ]] && rm -rf "$DUMP_TMP"

# 6. Persist credentials under valkey_* (drop legacy redis_* keys).
if [[ -f "${CIPI_CONFIG}/server.json" ]] && declare -f vault_read >/dev/null 2>&1; then
    tmp=$(mktemp)
    vault_read server.json \
        | jq --arg u "default" --arg p "$PASS" \
            '. + {valkey_user: $u, valkey_password: $p} | del(.redis_user, .redis_password)' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"
    echo "  server.json: redis_* → valkey_user/valkey_password"
fi

# 7. Update the unattended-upgrades blacklist (redis-server → valkey).
UU=/etc/apt/apt.conf.d/50cipi-unattended-upgrades
if [[ -f "$UU" ]] && grep -q '"redis-server";' "$UU"; then
    sed -i 's|"redis-server";|"valkey";\n    "valkey-server";|' "$UU"
    echo "  unattended-upgrades blacklist updated"
fi

echo "Migration 4.5.7 complete"

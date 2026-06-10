#!/bin/bash
#############################################
# Cipi — App-level failure notification
# Sends SMTP alert when an app deploy or cron
# job fails. Called by app users via sudo.
# Usage: cipi-app-notify <app> <label> <exit_code> [log_file]
#############################################
set -uo pipefail

APP="${1:-}"; LABEL="${2:-}"; EXIT_CODE="${3:-}"; LOG_FILE="${4:-}"
[[ -z "$APP" || -z "$LABEL" || -z "$EXIT_CODE" ]] && exit 0
[[ "$EXIT_CODE" -eq 0 ]] 2>/dev/null && exit 0

readonly CIPI_LIB="/opt/cipi/lib"
readonly CIPI_CONFIG="/etc/cipi"
readonly CIPI_LOG="/var/log/cipi"
readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"
readonly SMTP_RC="${CIPI_CONFIG}/.msmtprc"

source "${CIPI_LIB}/vault.sh"
source "${CIPI_LIB}/notifications.sh" 2>/dev/null || true

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
NOTIFY_TRIGGER="cron_fail"
[[ "$(printf '%s' "$LABEL" | tr '[:upper:]' '[:lower:]')" == "deploy" ]] && NOTIFY_TRIGGER="deploy_fail"
SUBJECT="Cipi ${LABEL} failed: ${APP} (${HOSTNAME})"

OUTPUT="<no output>"
if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    OUTPUT=$(tail -30 "$LOG_FILE" 2>/dev/null || echo "<could not read log>")
fi

BODY="${LABEL^} for '${APP}' failed with exit code ${EXIT_CODE} on ${HOSTNAME} at $(date '+%Y-%m-%d %H:%M:%S').

Output (last 30 lines):
${OUTPUT}"

# Log event
mkdir -p "$CIPI_LOG" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [local] [key:n/a] ${SUBJECT}" >> "${CIPI_LOG}/events.log" 2>/dev/null || true

# Send email (only if SMTP configured and trigger enabled)
if [[ -n "$NOTIFY_TRIGGER" ]] && declare -f _notify_trigger_enabled &>/dev/null && ! _notify_trigger_enabled "$NOTIFY_TRIGGER"; then
    exit 0
fi
[[ ! -f "$SMTP_CFG" ]] && exit 0
_SJ=$(vault_read smtp.json 2>/dev/null) || exit 0
[[ "$(echo "$_SJ" | jq -r '.enabled // false')" != "true" ]] && exit 0

TO=$(echo "$_SJ" | jq -r '.to // empty')
FROM=$(echo "$_SJ" | jq -r '.from // "noreply@localhost"')
[[ -z "$TO" ]] && exit 0

printf "From: %s\nTo: %s\nSubject: %s\n\n%s\n" "$FROM" "$TO" "$SUBJECT" "$BODY" | \
    msmtp -C "$SMTP_RC" "$TO" 2>/dev/null || true

exit 0

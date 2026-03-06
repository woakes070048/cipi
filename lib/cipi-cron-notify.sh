#!/bin/bash
#############################################
# Cipi — Cron wrapper with error notification
# Usage: cipi-cron-notify <label> <command...>
# Runs command; on failure sends email via cipi smtp (if configured).
#############################################
set -uo pipefail

LABEL="${1:-cron}"; shift || { echo "Usage: cipi-cron-notify <label> <command...>"; exit 1; }

readonly CIPI_LIB="/opt/cipi/lib"
readonly CIPI_CONFIG="/etc/cipi"
readonly CIPI_LOG="/var/log/cipi"
readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"
readonly SMTP_RC="${CIPI_CONFIG}/.msmtprc"

OUTPUT=$("$@" 2>&1)
RC=$?

if [[ $RC -ne 0 ]]; then
    echo "$OUTPUT"

    [[ ! -f "$SMTP_CFG" ]] && exit $RC
    [[ "$(jq -r '.enabled // false' "$SMTP_CFG" 2>/dev/null)" != "true" ]] && exit $RC

    TO=$(jq -r '.to // empty' "$SMTP_CFG" 2>/dev/null)
    FROM=$(jq -r '.from // "noreply@localhost"' "$SMTP_CFG" 2>/dev/null)
    [[ -z "$TO" ]] && exit $RC

    HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    SUBJECT="Cipi cron failed: ${LABEL} (${HOSTNAME})"
    BODY="Cron job '${LABEL}' failed with exit code ${RC} on ${HOSTNAME} at $(date '+%Y-%m-%d %H:%M:%S').

Output:
${OUTPUT:-<no output>}"

    printf "From: %s\nTo: %s\nSubject: %s\n\n%s\n" "$FROM" "$TO" "$SUBJECT" "$BODY" | \
        msmtp -C "$SMTP_RC" "$TO" 2>/dev/null || true
fi

exit $RC

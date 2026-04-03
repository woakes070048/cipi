#!/bin/bash
#############################################
# Cipi Migration 4.4.15 — Root crontab: global S3 backup / prune
#
# Normalizes root crontab lines from per-app form:
#   cipi backup run <app>  →  cipi backup run
#   cipi backup prune <app> --weeks=N  →  cipi backup prune --weeks=N
# Removes duplicate identical lines after normalization.
#############################################

set -e

echo "Migration 4.4.15 — Root crontab: S3 backup/prune for all apps..."

if [[ $EUID -ne 0 ]]; then
    echo "  Not root — skip"
    exit 0
fi

if ! crontab -l 2>/dev/null | grep -q 'cipi backup'; then
    echo "  No cipi backup lines in root crontab — skip"
    exit 0
fi

tmp=$(mktemp)
# Match "cipi backup …" inside the line (works with /usr/local/bin/cipi or plain cipi).
crontab -l 2>/dev/null | sed -E \
    -e 's|cipi backup run[[:space:]]+[a-zA-Z0-9][a-zA-Z0-9._-]*|cipi backup run|g' \
    -e 's|cipi backup prune[[:space:]]+[a-zA-Z0-9][a-zA-Z0-9._-]*[[:space:]]+(--weeks=[0-9]+)|cipi backup prune \1|g' \
    | awk '!seen[$0]++' > "$tmp"

crontab "$tmp"
rm -f "$tmp"

echo "  Root crontab updated (global backup/prune)"
echo "Migration 4.4.15 complete"

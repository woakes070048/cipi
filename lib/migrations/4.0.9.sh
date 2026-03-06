#!/bin/bash
#############################################
# Cipi Migration 4.0.9 — SMTP notifications
# + cron wrapper for error alerts
#############################################

set -e

# 1. Update root crontab: wrap critical jobs with cipi-cron-notify
if crontab -l 2>/dev/null | grep -q "CIPI CRON"; then
    if ! crontab -l 2>/dev/null | grep -q "cipi-cron-notify"; then
        echo "Updating root crontab with notification wrapper..."
        crontab -l 2>/dev/null | sed \
            -e 's|/usr/local/bin/cipi self-update|/usr/local/bin/cipi-cron-notify self-update /usr/local/bin/cipi self-update|' \
            -e 's|certbot renew|/usr/local/bin/cipi-cron-notify ssl-renew certbot renew|' \
        | crontab -
        echo "Root crontab updated"
    else
        echo "Root crontab already uses cipi-cron-notify — skip"
    fi
else
    echo "No Cipi cron jobs found — skip"
fi

echo "Migration 4.0.9 complete"

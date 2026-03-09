#!/bin/bash
#############################################
# Cipi Migration 4.2.3
# - Add PAM auth notification for su
#############################################

set -e

echo "Adding PAM auth notification for su..."

if [[ -x /usr/local/bin/cipi-auth-notify ]]; then
    if ! grep -q 'cipi-auth-notify' /etc/pam.d/su 2>/dev/null; then
        echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/su
        echo "  PAM su notification added"
    else
        echo "  PAM su notification already configured — skip"
    fi
else
    echo "  cipi-auth-notify not found — skip"
fi

echo "Migration 4.2.3 complete"

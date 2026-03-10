#!/bin/bash
#############################################
# Cipi Migration 4.2.7
# - Supervisor: autorestart=unexpected → true
#   so workers survive --max-time graceful exits
#############################################

set -e

echo "Fixing Supervisor autorestart for queue workers..."

for conf in /etc/supervisor/conf.d/*.conf; do
    [[ ! -f "$conf" ]] && continue

    if grep -q 'autorestart=unexpected' "$conf" 2>/dev/null; then
        sed -i 's/autorestart=unexpected/autorestart=true/' "$conf"
        echo "  Patched: $(basename "$conf")"
    fi
done

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

echo "Migration 4.2.7 complete"

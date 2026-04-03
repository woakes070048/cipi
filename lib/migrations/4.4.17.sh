#!/bin/bash
#############################################
# Cipi Migration 4.4.17 — API sudoers: allow cipi db * for www-data
#
# Panel API runs `sudo cipi db list` (and async db jobs) as www-data. The
# cipi-api sudoers whitelist did not include db subcommands, so sudo asked
# for a password and failed without a TTY ("a terminal is required").
#############################################

set -e

echo "Migration 4.4.17 — Extend /etc/sudoers.d/cipi-api with cipi db commands..."

cat > /etc/sudoers.d/cipi-api <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi app create *, \
                               /usr/local/bin/cipi app edit *, \
                               /usr/local/bin/cipi app delete *, \
                               /usr/local/bin/cipi deploy *, \
                               /usr/local/bin/cipi alias add *, \
                               /usr/local/bin/cipi alias remove *, \
                               /usr/local/bin/cipi ssl install *, \
                               /usr/local/bin/cipi db list, \
                               /usr/local/bin/cipi db create *, \
                               /usr/local/bin/cipi db delete *, \
                               /usr/local/bin/cipi db backup *, \
                               /usr/local/bin/cipi db restore * *, \
                               /usr/local/bin/cipi db password *, \
                               /bin/cat /etc/cipi/apps.json
SUDOEOF
chmod 440 /etc/sudoers.d/cipi-api

echo "Migration 4.4.17 complete"

#!/bin/bash
#############################################
# Cipi Migration 4.2.2
# - Fix default nginx host to always serve index.html
# - Install PAM auth notifications (sudo & SSH)
# - Fix cipi ssh list/remove silent exit (set -e + arithmetic)
# - SSH access groups (app users can SSH with password)
#############################################

set -e

# ── Fix default nginx host ──────────────────────────────────

echo "Fixing default nginx host..."

cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;
    server_tokens off;

    # All requests serve the Server Up page (no 404 leaks)
    location / {
        rewrite ^ /index.html break;
    }
}
EOF

nginx -t && systemctl reload nginx
echo "Default nginx host fixed"

# ── PAM auth notifications ──────────────────────────────────

echo "Setting up PAM auth notifications..."

cp /opt/cipi/lib/cipi-auth-notify.sh /usr/local/bin/cipi-auth-notify
chmod 700 /usr/local/bin/cipi-auth-notify
chown root:root /usr/local/bin/cipi-auth-notify

if [[ -x /usr/local/bin/cipi-auth-notify ]]; then
    if ! grep -q 'cipi-auth-notify' /etc/pam.d/sudo 2>/dev/null; then
        echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sudo
    fi
    if ! grep -q 'cipi-auth-notify' /etc/pam.d/sshd 2>/dev/null; then
        echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sshd
    fi
    echo "PAM auth notifications installed"
fi

echo "Migration 4.2.2 complete (includes fix: cipi ssh list/remove with set -e)"


# ── Restrict www-data sudoers ─────────────────────────────────

echo "Restricting www-data sudoers to API command whitelist..."

cat > /etc/sudoers.d/cipi-api <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi app create *, \
                               /usr/local/bin/cipi app edit *, \
                               /usr/local/bin/cipi app delete *, \
                               /usr/local/bin/cipi deploy *, \
                               /usr/local/bin/cipi alias add *, \
                               /usr/local/bin/cipi alias remove *, \
                               /usr/local/bin/cipi ssl install *, \
                               /bin/cat /etc/cipi/apps.json
SUDOEOF
chmod 440 /etc/sudoers.d/cipi-api

echo "www-data sudoers restricted to API whitelist"

# ── SSH access groups + password auth for app users ──────────

echo "Setting up SSH access groups..."

SSHD="/etc/ssh/sshd_config"

groupadd -f cipi-ssh
groupadd -f cipi-apps
usermod -aG cipi-ssh cipi

# Add existing app users to cipi-apps
if [[ -f /etc/cipi/apps.json ]]; then
    for app in $(jq -r 'keys[]' /etc/cipi/apps.json 2>/dev/null); do
        if id "$app" &>/dev/null; then
            usermod -aG cipi-apps "$app"
            echo "  Added ${app} to cipi-apps"
        fi
    done
fi

# Replace AllowUsers with AllowGroups
sed -i '/^AllowUsers/d' "$SSHD"
if grep -qE "^#?\s*AllowGroups\b" "$SSHD"; then
    sed -i "s/^#*\s*AllowGroups\b.*/AllowGroups cipi-ssh cipi-apps/" "$SSHD"
else
    echo "AllowGroups cipi-ssh cipi-apps" >> "$SSHD"
fi

# Add Match block for app users (password auth)
if ! grep -q 'Match Group cipi-apps' "$SSHD"; then
    cat >> "$SSHD" <<'MATCHEOF'

Match Group cipi-apps
    PasswordAuthentication yes
MATCHEOF
fi

systemctl restart ssh || systemctl restart sshd
echo "SSH access groups configured (app users can now SSH with password)"

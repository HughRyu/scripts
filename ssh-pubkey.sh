#!/bin/bash

GH_USER="HughRyu"

mkdir -p ~/.ssh
chmod 700 ~/.ssh

TEMP_KEYS=$(mktemp)

echo "Fetching keys from GitHub user: ${GH_USER}"

if ! curl -fsSL "https://github.com/${GH_USER}.keys" -o "$TEMP_KEYS"; then
    echo "Error: Failed to fetch keys from GitHub."
    rm -f "$TEMP_KEYS"
    exit 1
fi

# 防止获取到空文件导致锁死自己
if [ ! -s "$TEMP_KEYS" ]; then
    echo "Error: GitHub returned no public keys."
    rm -f "$TEMP_KEYS"
    exit 1
fi

cp "$TEMP_KEYS" ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

rm -f "$TEMP_KEYS"

echo "Success: authorized_keys synced with GitHub user ${GH_USER}"

if [ "$EUID" -ne 0 ]; then
    echo
    echo "Notice: Not running as root."
    echo "SSH configuration was not modified."
    exit 0
fi

SSHD_CONFIG="/etc/ssh/sshd_config"

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

sed -i '/^#\?PubkeyAuthentication/d' "$SSHD_CONFIG"
sed -i '/^#\?PasswordAuthentication/d' "$SSHD_CONFIG"
sed -i '/^#\?PermitRootLogin/d' "$SSHD_CONFIG"

cat >> "$SSHD_CONFIG" <<EOF

PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF

if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue

        sed -i '/PubkeyAuthentication/d' "$f"
        sed -i '/PasswordAuthentication/d' "$f"
        sed -i '/PermitRootLogin/d' "$f"
    done
fi

echo
echo "Effective SSH settings:"
sshd -T | grep -E 'pubkeyauthentication|passwordauthentication|permitrootlogin'

systemctl restart ssh 2>/dev/null || \
systemctl restart sshd 2>/dev/null || \
service ssh restart

echo
echo "================================="
echo "✔ GitHub keys synced"
echo "✔ Root key login allowed"
echo "✔ Password login disabled"
echo "✔ Public key login enabled"
echo "✔ SSH configured successfully"
echo "================================="

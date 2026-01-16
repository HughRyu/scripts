#!/bin/bash

# Define the GitHub username
GH_USER="HughRyu"

# 1. Ensure .ssh directory exists with correct permissions
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 2. Fetch public keys from GitHub and append to authorized_keys
TEMP_KEYS=$(mktemp)
if curl -fsSL "https://ghproxy.net/https://github.com/${GH_USER}.keys" -o "$TEMP_KEYS"; then
    cat "$TEMP_KEYS" >> ~/.ssh/authorized_keys
    sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    echo "Success: Public keys for ${GH_USER} imported."
else
    echo "Error: Failed to fetch keys from GitHub."
    rm -f "$TEMP_KEYS"
    exit 1
fi
rm -f "$TEMP_KEYS"

# 3. Enable PubkeyAuthentication in sshd_config
# This part requires sudo/root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Notice: Not running as root. Skipping SSH config modification."
else
    SSHD_CONFIG="/etc/ssh/sshd_config"
    if [ -f "$SSHD_CONFIG" ]; then
        # Check if PubkeyAuthentication is already set to yes
        if ! grep -q "^PubkeyAuthentication yes" "$SSHD_CONFIG"; then
            # Remove existing lines and append the correct one
            sed -i '/^#\?PubkeyAuthentication/d' "$SSHD_CONFIG"
            echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
            
            # Restart SSH service to apply changes
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart ssh
            elif command -v service >/dev/null 2>&1; then
                service ssh restart
            fi
            echo "Success: PubkeyAuthentication enabled and SSH service restarted."
        else
            echo "Info: PubkeyAuthentication is already enabled."
        fi
    fi
fi

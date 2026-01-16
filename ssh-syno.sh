#!/bin/bash

# Configuration
GH_USER="HughRyu"

# 1. Elevate to root if not already
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# 2. Setup /root/.ssh directory and permissions as per guide
echo "Setting up /root/.ssh directory..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys

# 3. Import Public Keys from GitHub
echo "Importing keys from GitHub: ${GH_USER}..."
TEMP_KEYS=$(mktemp)
if curl -fsSL "https://github.com/${GH_USER}.keys" -o "$TEMP_KEYS"; then
    cat "$TEMP_KEYS" >> /root/.ssh/authorized_keys
    # Remove duplicates
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    echo "Success: Public keys imported to /root/.ssh/authorized_keys."
else
    echo "Error: Failed to fetch keys from GitHub."
    rm -f "$TEMP_KEYS"
    exit 1
fi
rm -f "$TEMP_KEYS"

# 4. Modify sshd_config for Root Login and Pubkey Auth
SSHD_CONFIG="/etc/ssh/sshd_config"
echo "Configuring ${SSHD_CONFIG}..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' $SSHD_CONFIG
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSHD_CONFIG
sed -i 's/^#\?RSAAuthentication.*/RSAAuthentication yes/' $SSHD_CONFIG

# 5. Restart SSH Service based on DSM version
echo "Restarting SSH service..."
if command -v systemctl >/dev/null 2>&1; then
    # For DSM 7
    systemctl restart sshd
    echo "SSH service restarted (DSM 7+)."
else
    # For DSM 6
    synoservicectl --restart sshd
    echo "SSH service restarted (DSM 6)."
fi

echo "All done! You can now login as root with your SSH key."

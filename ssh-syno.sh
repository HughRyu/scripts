#!/bin/bash
# ==============================================================================
# Title:        Synology SSH Key Setup (Hardcoded Version)
# Description:  Optimized for DSM 6/7. Fixed for restricted network environments.
# Author:       HughRyu
# ==============================================================================

GH_USER="HughRyu"
# Verified fingerprint: SHA256:i2bIHYYr...
MY_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ6M78GLUmsxQzt3GDgOZN18HjIcTiYbXOYcgwbPoAGu hughryu@gmail.com"

# 1. Check Root Privilege
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run with sudo."
    exit 1
fi

# 2. Initialize .ssh Directory
echo "Step 1: Setting up /root/.ssh..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# 3. Import and Deduplicate Key
echo "Step 2: Importing key for ${GH_USER}..."
echo "$MY_KEY" >> /root/.ssh/authorized_keys
sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys

# 4. Configure SSHD (Root Login & Pubkey Auth)
echo "Step 3: Configuring sshd_config..."
SSHD_CONFIG="/etc/ssh/sshd_config"
# Update config to allow root login
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' $SSHD_CONFIG
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSHD_CONFIG

# 5. Restart SSH Service (Compatible with DSM 6/7)
echo "Step 4: Restarting SSH service..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sshd
else
    synoservicectl --restart sshd
fi

echo "Success: Passwordless access enabled for root."

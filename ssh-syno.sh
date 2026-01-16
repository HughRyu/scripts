#!/bin/bash
# ==============================================================================
# Title:        Synology SSH Key Setup (Hardcoded Version)
# Description:  Universal SSH Key Setup for Synology DSM 6/7.
#               Optimized for environments with restricted GitHub access.
# Author:       HughRyu
# ==============================================================================

GH_USER="HughRyu"
# Your ED25519 Public Key (Verified fingerprint: SHA256:i2bIHYYr...)
MY_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ6M78GLUmsxQzt3GDgOZN18HjIcTiYbXOYcgwbPoAGu hughryu@gmail.com"

# 1. Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script with sudo (e.g., sudo bash)."
    exit 1
fi

# 2. Setup /root/.ssh directory and permissions
echo "Step 1: Setting up /root/.ssh directory..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# 3. Import the hardcoded public key
echo "Step 2: Importing SSH public key for ${GH_USER}..."
echo "$MY_KEY" >> /root/.ssh/authorized_keys
# Remove duplicate keys to keep it clean
sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys

# 4. Modify sshd_config to allow Root Login and Pubkey Auth
echo "Step 3: Configuring sshd_config..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Ensure PermitRootLogin is set to yes
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' $SSHD_CONFIG
# Ensure PubkeyAuthentication is enabled
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSHD_CONFIG

# 5. Restart SSH Service based on DSM version
echo "Step 4: Restarting SSH service..."
if command -v systemctl >/dev/null 2>&1; then
    # For DSM 7.x
    systemctl restart sshd
    echo "SSH service restarted via systemctl (DSM 7)."
else
    # For DSM 6.x
    synoservicectl --restart sshd
    echo "SSH service restarted via synoservicectl (DSM 6)."
fi

echo "------------------------------------------------------------"
echo "Success: SSH public key imported for passwordless access."
echo "You can now login as root using your SSH key."

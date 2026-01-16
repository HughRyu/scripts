#!/bin/bash
GH_USER="HughRyu"

# 1. Prepare directory
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# 2. Try fetching keys using multiple mirrors
TEMP_KEYS=$(mktemp)
# List of mirrors to try
MIRRORS=(
    "https://ghproxy.net/https://github.com/${GH_USER}.keys"
    "https://mirror.ghproxy.com/https://github.com/${GH_USER}.keys"
)

SUCCESS=false
for URL in "${MIRRORS[@]}"; do
    echo "Attempting to fetch keys from: $URL"
    if curl -fsSL "$URL" -o "$TEMP_KEYS"; then
        SUCCESS=true
        break
    fi
done

if [ "$SUCCESS" = true ]; then
    cat "$TEMP_KEYS" >> /root/.ssh/authorized_keys
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys
    echo "Success: Public keys for ${GH_USER} imported to /root/.ssh/authorized_keys."
    echo "Universal SSH Key Setup for All Linux Hosts completed."
else
    echo "Error: All mirrors failed. Please check Synology network settings."
    rm -f "$TEMP_KEYS"
    exit 1
fi
rm -f "$TEMP_KEYS"

#!/bin/bash

# ==========================================
# Configuration
# ==========================================

# Base directory
WORK_DIR="$HOME/trivy"
CACHE_DIR="$WORK_DIR/cache"
OUTPUT_FILE="$WORK_DIR/scan_result.txt"

# Mirror List (Added generic ghproxy as backup)
MIRRORS=(
    "https://ghproxy.net/https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-db.tar.gz"
    "https://gh.llkk.cc/https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-db.tar.gz"
    "https://github.moeyy.xyz/https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-db.tar.gz"
)

# ==========================================
# 1. Preparation
# ==========================================
echo "🚀 Starting security scan..."
mkdir -p "$CACHE_DIR/db"

echo "Scan Report - $(date)" > "$OUTPUT_FILE"
echo "📂 Working Directory: $WORK_DIR"

# ==========================================
# 2. Smart DB Download (Using curl)
# ==========================================
echo "📥 Downloading DB tarball..."

DOWNLOAD_SUCCESS=false

for url in "${MIRRORS[@]}"; do
    echo "Trying mirror: $url ..."
    
    # Switched to curl (since it worked for you)
    # -L: Follow redirects
    # -k: Skip SSL check
    # --connect-timeout 60: Increased timeout
    # --retry 2: Retry twice on failure
    curl -L -k --connect-timeout 60 --retry 2 -o "$WORK_DIR/db_temp.tar.gz" "$url"
    
    if [ $? -eq 0 ]; then
        # Check if file is valid (not empty)
        if [ -s "$WORK_DIR/db_temp.tar.gz" ]; then
            echo "✅ Download successful using: $url"
            DOWNLOAD_SUCCESS=true
            break
        else
             echo "⚠️ File is empty. Mirror failed."
        fi
    else
        echo "⚠️ Connection failed or timed out. Switching to next..."
    fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "❌ All mirrors failed. Network is too unstable."
    exit 1
fi

echo "📦 Extracting DB..."
tar -xzf "$WORK_DIR/db_temp.tar.gz" -C "$CACHE_DIR/db"
rm "$WORK_DIR/db_temp.tar.gz"

echo "✅ DB updated successfully."

# ==========================================
# 3. Batch Scan
# ==========================================
echo "🔍 Scanning all local images..."

TOTAL=$(docker images -q | wc -l)
CURRENT=0

for img in $(docker images -q); do
    ((CURRENT++))
    echo "[$CURRENT/$TOTAL] Scanning ID: $img ..."
    echo -e "\n\n=== Target: $img ===" >> "$OUTPUT_FILE"
    
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$CACHE_DIR":/root/.cache/trivy \
        aquasec/trivy:latest image \
        --skip-db-update \
        --scanners vuln \
        --severity HIGH,CRITICAL \
        "$img" >> "$OUTPUT_FILE"
done

echo "✅ Scan complete! Check $OUTPUT_FILE"

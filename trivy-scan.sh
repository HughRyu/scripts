#!/bin/bash

# ==========================================
# Configuration
# ==========================================

# Base directory
WORK_DIR="$HOME/trivy"
CACHE_DIR="$WORK_DIR/cache"
OUTPUT_FILE="$WORK_DIR/scan_result.txt"

# List of Mirrors (Failover Strategy)
# If one fails, the script will automatically try the next one.
MIRRORS=(
    "https://gh.llkk.cc/https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-db.tar.gz"
    "https://github.moeyy.xyz/https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-db.tar.gz"
    "https://ghproxy.net/https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-db.tar.gz"
)

# ==========================================
# 1. Preparation
# ==========================================
echo "🚀 Starting security scan..."
mkdir -p "$CACHE_DIR/db"

echo "Scan Report - $(date)" > "$OUTPUT_FILE"
echo "📂 Working Directory: $WORK_DIR"

# ==========================================
# 2. Smart DB Download (Auto-Switching)
# ==========================================
echo "📥 Downloading DB tarball..."

DOWNLOAD_SUCCESS=false

for url in "${MIRRORS[@]}"; do
    echo "Trying mirror: $url ..."
    
    # -T 15: Timeout after 15 seconds
    # -t 2: Retry 2 times per mirror
    wget --no-check-certificate -q --show-progress -T 15 -t 2 -O "$WORK_DIR/db_temp.tar.gz" "$url"
    
    if [ $? -eq 0 ]; then
        echo "✅ Download successful using: $url"
        DOWNLOAD_SUCCESS=true
        break
    else
        echo "⚠️ Mirror failed or timed out. Switching to next..."
    fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "❌ All mirrors failed. Please check your network or try again later."
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

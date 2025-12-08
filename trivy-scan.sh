#!/bin/bash

# ==========================================
# Configuration
# ==========================================

# Base directory for all Trivy files
# Resolves to /root/trivy if you are root
WORK_DIR="$HOME/trivy"

# Sub-directory for database cache
CACHE_DIR="$WORK_DIR/cache"

# Final report file path
OUTPUT_FILE="$WORK_DIR/scan_result.txt"

# Download URL for Trivy DB (via ghproxy)
DB_URL="https://mirror.ghproxy.com/https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-db.tar.gz"

# ==========================================
# 1. Preparation
# ==========================================
echo "🚀 Starting security scan..."

# Create the specific directory structure Trivy expects
# We need a 'db' folder inside our cache directory
mkdir -p "$CACHE_DIR/db"

# Reset output file
echo "Scan Report - $(date)" > "$OUTPUT_FILE"
echo "📂 Working Directory: $WORK_DIR"
echo "📄 Report will be saved to: $OUTPUT_FILE"

# ==========================================
# 2. Manual DB Download (Wget Method)
# ==========================================
echo "📥 Downloading DB tarball..."

# Download to a temporary path inside WORK_DIR
wget --no-check-certificate -q --show-progress -O "$WORK_DIR/db_temp.tar.gz" "$DB_URL"

if [ $? -ne 0 ]; then
    echo "❌ Download failed. Check network."
    exit 1
fi

echo "📦 Extracting DB..."
# Extract files into the 'db' folder
tar -xzf "$WORK_DIR/db_temp.tar.gz" -C "$CACHE_DIR/db"

# Cleanup the compressed file
rm "$WORK_DIR/db_temp.tar.gz"

echo "✅ DB updated successfully."

# ==========================================
# 3. Batch Scan (Offline Mode)
# ==========================================
echo "🔍 Scanning all local images..."

TOTAL=$(docker images -q | wc -l)
CURRENT=0

for img in $(docker images -q); do
    ((CURRENT++))
    echo "[$CURRENT/$TOTAL] Scanning ID: $img ..."
    echo -e "\n\n=== Target: $img ===" >> "$OUTPUT_FILE"
    
    # Map the host CACHE_DIR to the container's cache location
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

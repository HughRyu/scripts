#!/bin/bash

# ==========================================
# Configuration
# ==========================================
CACHE_DIR=~/trivy-cache
OUTPUT_FILE="scan_result.txt"

# Public Mirror for Trivy DB (DaoCloud)
# Eliminates the need for a proxy.
DB_REPO="ghcr.m.daocloud.io/aquasecurity/trivy-db"

# ==========================================
# 1. Preparation
# ==========================================
echo "🚀 Starting security scan..."
mkdir -p "$CACHE_DIR"

# Reset output file
echo "Scan Report - $(date)" > "$OUTPUT_FILE"

# ==========================================
# 2. Update DB (via Mirror)
# ==========================================
echo "📥 Updating DB from mirror..."

docker run --rm \
    -v "$CACHE_DIR":/root/.cache/trivy \
    aquasec/trivy:latest image \
    --download-db-only \
    --db-repository "$DB_REPO"

# Exit if DB update fails
if [ $? -ne 0 ]; then
    echo "❌ DB update failed. Check network."
    exit 1
fi

# ==========================================
# 3. Batch Scan (Offline Mode)
# ==========================================
echo "🔍 Scanning all local images..."

# Get total count for progress bar
TOTAL=$(docker images -q | wc -l)
CURRENT=0

for img in $(docker images -q); do
    ((CURRENT++))
    echo "[$CURRENT/$TOTAL] Scanning ID: $img ..."
    
    # Append separator to report
    echo -e "\n\n=== Target: $img ===" >> "$OUTPUT_FILE"
    
    # Run Trivy (High/Critical only, Skip DB update)
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$CACHE_DIR":/root/.cache/trivy \
        aquasec/trivy:latest image \
        --skip-db-update \
        --db-repository "$DB_REPO" \
        --scanners vuln \
        --severity HIGH,CRITICAL \
        "$img" >> "$OUTPUT_FILE"
done

echo "✅ Scan complete! Check $OUTPUT_FILE"

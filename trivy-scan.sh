#!/bin/bash

# ==========================================
# Configuration
# ==========================================
WORK_DIR="$HOME/trivy"
CACHE_DIR="$WORK_DIR/cache"
OUTPUT_FILE="$WORK_DIR/scan_result.txt"

# [CRITICAL FIX]
# GitHub Releases are deprecated. We MUST use OCI registry.
# Using Huawei Cloud Mirror (DDN) to accelerate ghcr.io
# This mimics ghcr.io/aquasecurity/trivy-db but via China Network
DB_REPO="swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/aquasecurity/trivy-db"

# ==========================================
# 1. Preparation
# ==========================================
echo "🚀 Starting security scan..."
mkdir -p "$CACHE_DIR"

echo "Scan Report - $(date)" > "$OUTPUT_FILE"
echo "📂 Working Directory: $WORK_DIR"

# ==========================================
# 2. Update DB (Via Docker + China Mirror)
# ==========================================
echo "📥 Updating DB using Huawei Mirror..."

# We use docker to pull the DB because wget is no longer supported for v2 DB.
docker run --rm \
    -v "$CACHE_DIR":/root/.cache/trivy \
    aquasec/trivy:latest image \
    --download-db-only \
    --db-repository "$DB_REPO"

if [ $? -ne 0 ]; then
    echo "❌ DB update failed. Huawei mirror might be busy."
    echo "👉 Attempting to scan with existing cache (if any)..."
else
    echo "✅ DB updated successfully."
fi

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
    
    # Run scan pointing to the same mirror repo to avoid network checks
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

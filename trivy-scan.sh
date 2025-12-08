#!/bin/bash

# ==========================================
# Configuration
# ==========================================
WORK_DIR="$HOME/trivy"
CACHE_DIR="$WORK_DIR/cache"
OUTPUT_FILE="$WORK_DIR/scan_result.txt"

# OCI Mirror List for ghcr.io (Failover Strategy)
# Docker will try these one by one to pull the DB.
OCI_MIRRORS=(
    "ghcr.m.daocloud.io/aquasecurity/trivy-db"
    "ghcr.dockerproxy.com/aquasecurity/trivy-db"
    "ghcr.nju.edu.cn/aquasecurity/trivy-db"
    "ghcr.io/aquasecurity/trivy-db" 
)

# ==========================================
# 1. Preparation
# ==========================================
echo "🚀 Starting security scan..."
mkdir -p "$CACHE_DIR"

echo "Scan Report - $(date)" > "$OUTPUT_FILE"
echo "📂 Working Directory: $WORK_DIR"

# ==========================================
# 2. Smart DB Update (OCI Failover)
# ==========================================
echo "📥 Updating DB via OCI Mirrors..."

UPDATE_SUCCESS=false
FINAL_REPO=""

for repo in "${OCI_MIRRORS[@]}"; do
    echo "Trying OCI mirror: $repo ..."
    
    # Try to download DB only using the current mirror
    # We use 'timeout 60s' to prevent it from hanging on bad mirrors
    timeout 60s docker run --rm \
        -v "$CACHE_DIR":/root/.cache/trivy \
        aquasec/trivy:latest image \
        --download-db-only \
        --db-repository "$repo"
        
    if [ $? -eq 0 ]; then
        echo "✅ DB Update successful using: $repo"
        UPDATE_SUCCESS=true
        FINAL_REPO="$repo"
        break
    else
        echo "⚠️ Mirror $repo failed or timed out. Switching..."
    fi
done

if [ "$UPDATE_SUCCESS" = false ]; then
    echo "❌ All OCI mirrors failed. Cannot proceed."
    exit 1
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
    
    # Important: We must use the SAME repository that worked
    # Otherwise Trivy might try to verify the DB against default ghcr.io and fail
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$CACHE_DIR":/root/.cache/trivy \
        aquasec/trivy:latest image \
        --skip-db-update \
        --db-repository "$FINAL_REPO" \
        --scanners vuln \
        --severity HIGH,CRITICAL \
        "$img" >> "$OUTPUT_FILE"
done

echo "✅ Scan complete! Check $OUTPUT_FILE"

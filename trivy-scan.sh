#!/bin/bash

# --- Configuration Section ---
PROXY_URL="http://192.168.199.5:1888"
CACHE_DIR=~/trivy-cache
OUTPUT_FILE="scan_result.txt"

# 1. Preparation
echo "🚀 Starting security scan process..."
mkdir -p "$CACHE_DIR"

# Clear old scan results to ensure the output is fresh
echo "Cleaning up old report..." > "$OUTPUT_FILE"

# 2. Update Vulnerability Database (via Proxy)
echo "📥 Updating vulnerability database via proxy..."
docker run --rm \
    -e HTTP_PROXY="$PROXY_URL" \
    -e HTTPS_PROXY="$PROXY_URL" \
    -v "$CACHE_DIR":/root/.cache/trivy \
    aquasec/trivy:latest image --download-db-only

# Check if the download was successful; exit if it failed
if [ $? -ne 0 ]; then
    echo "❌ Database download failed. Please check your proxy settings."
    exit 1
fi

# 3. Perform Offline Batch Scan
echo "🔍 Database updated. Starting offline scan of all local images..."
echo "    Results will be saved to: $OUTPUT_FILE"

# Count total images (optional, for progress display)
TOTAL_IMAGES=$(docker images -q | wc -l)
CURRENT=0

for img in $(docker images -q); do
    CURRENT=$((CURRENT+1))
    echo "[$CURRENT/$TOTAL_IMAGES] Scanning image ID: $img ..."
    
    # Log the current image ID to the file for better readability
    echo -e "\n\n=== Scanning Image: $img ===" >> "$OUTPUT_FILE"
    
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$CACHE_DIR":/root/.cache/trivy \
        aquasec/trivy:latest image \
        --skip-db-update \
        --scanners vuln \
        --severity HIGH,CRITICAL \
        "$img" >> "$OUTPUT_FILE"
done

echo "✅ All scans completed! Please check $OUTPUT_FILE"

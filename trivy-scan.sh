#!/bin/bash

# ==============================================================================
# Automated Docker Offline Vulnerability Scanner (ADOVS) - v2025.12
# 
# Description:
#   A robust security tool designed for restricted network environments.
#   It automatically updates the Trivy database using accessible OCI mirrors
#   (failover mechanism) and performs offline scanning of all local Docker images.
#
# Features:
#   1. Smart DB Update: Auto-switches between mirrors (DaoCloud, DockerProxy, NJU).
#   2. Dual Reporting: Generates a full technical report and a high-risk summary.
#   3. Cluster Friendly: Output filenames include the hostname.
#   4. Noise Reduction: Focuses on HIGH and CRITICAL vulnerabilities.
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration Section
# ------------------------------------------------------------------------------

# Base working directory for cache and reports
WORK_DIR="$HOME/trivy"
CACHE_DIR="$WORK_DIR/cache"

# Hostname identification for report naming (useful for multi-server management)
HOST_NAME=$(hostname)

# [Report 1] Full Technical Report (Contains all logs and details)
OUTPUT_FILE="$WORK_DIR/scan_result_${HOST_NAME}.txt"

# [Report 2] Executive Risk Summary (Contains only High/Critical risks)
RISKY_FILE="$WORK_DIR/risky_images_${HOST_NAME}.txt"

# OCI Mirror List for ghcr.io (Failover Strategy)
# The script will attempt to pull the DB from these mirrors sequentially.
OCI_MIRRORS=(
    "ghcr.m.daocloud.io/aquasecurity/trivy-db"
    "ghcr.dockerproxy.com/aquasecurity/trivy-db"
    "ghcr.nju.edu.cn/aquasecurity/trivy-db"
    "ghcr.io/aquasecurity/trivy-db" 
)

# ------------------------------------------------------------------------------
# 1. Environment Preparation
# ------------------------------------------------------------------------------
echo "🚀 Starting ADOVS Security Scan on Host: $HOST_NAME ..."

# Create directory structure
mkdir -p "$CACHE_DIR"

# Initialize Full Report with Header
echo "Scan Report - $(date) - Host: $HOST_NAME" > "$OUTPUT_FILE"

# Initialize Risk Summary with Header
echo "==========================================" > "$RISKY_FILE"
echo "RISKY IMAGES SUMMARY - $(date)" >> "$RISKY_FILE"
echo "Host: $HOST_NAME" >> "$RISKY_FILE"
echo "==========================================" >> "$RISKY_FILE"

echo "📂 Working Directory: $WORK_DIR"
echo "📄 Full Report: $OUTPUT_FILE"
echo "⚠️  Risk Summary: $RISKY_FILE"

# ------------------------------------------------------------------------------
# 2. Database Update (Smart Failover)
# ------------------------------------------------------------------------------
echo "📥 Updating Vulnerability Database via OCI Mirrors..."

UPDATE_SUCCESS=false
FINAL_REPO=""

for repo in "${OCI_MIRRORS[@]}"; do
    echo "👉 Attempting connection to: $repo ..."
    
    # Try to download DB only using the current mirror.
    # Set a 60s timeout to prevent hanging on unresponsive mirrors.
    timeout 60s docker run --rm \
        -v "$CACHE_DIR":/root/.cache/trivy \
        aquasec/trivy:latest image \
        --download-db-only \
        --db-repository "$repo"
        
    # Check if docker command was successful (Exit code 0)
    if [ $? -eq 0 ]; then
        echo "✅ Database updated successfully using: $repo"
        UPDATE_SUCCESS=true
        FINAL_REPO="$repo"
        break
    else
        echo "⚠️  Mirror failed or timed out. Switching to next candidate..."
    fi
done

# If all mirrors fail, exit the script to prevent scanning with an empty DB.
if [ "$UPDATE_SUCCESS" = false ]; then
    echo "❌ CRITICAL ERROR: All OCI mirrors failed. Check your network connection."
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Batch Scanning & Analysis
# ------------------------------------------------------------------------------
echo "🔍 Starting offline scan of all local images..."

# Retrieve all local images. Format: "Repository:Tag|ImageID"
# Grep excludes intermediate images (<none>)
docker images --format "{{.Repository}}:{{.Tag}}|{{.ID}}" | grep -v "<none>" | while IFS='|' read -r IMAGE_NAME IMAGE_ID; do
    
    echo "Scanning target: $IMAGE_NAME ($IMAGE_ID) ..."
    
    # --- A. Update Full Report ---
    echo -e "\n\n==========================================" >> "$OUTPUT_FILE"
    echo "Target: $IMAGE_NAME" >> "$OUTPUT_FILE"
    echo "ID:     $IMAGE_ID" >> "$OUTPUT_FILE"
    echo "==========================================" >> "$OUTPUT_FILE"
    
    # --- B. Execute Trivy Scan ---
    # --skip-db-update: We already updated the DB in Step 2.
    # --db-repository: Force usage of the working mirror to avoid network checks.
    # --exit-code 1: Returns exit code 1 if HIGH/CRITICAL vulnerabilities are found.
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$CACHE_DIR":/root/.cache/trivy \
        aquasec/trivy:latest image \
        --skip-db-update \
        --db-repository "$FINAL_REPO" \
        --scanners vuln \
        --severity HIGH,CRITICAL \
        --exit-code 1 \
        "$IMAGE_ID" > "$WORK_DIR/temp_scan.log" 2>&1
    
    SCAN_STATUS=$?
    
    # Append raw logs to the full report
    cat "$WORK_DIR/temp_scan.log" >> "$OUTPUT_FILE"
    
    # --- C. Process Risk Analysis ---
    if [ $SCAN_STATUS -eq 1 ]; then
        echo "⚠️  RISK DETECTED: $IMAGE_NAME"
        
        # Add entry to Risk Summary File
        echo "" >> "$RISKY_FILE"
        echo "🔴 IMAGE: $IMAGE_NAME" >> "$RISKY_FILE" 
        echo "   ID:    $IMAGE_ID" >> "$RISKY_FILE"
        
        # Extract Statistics (Total/High/Critical counts)
        grep "Total:" "$WORK_DIR/temp_scan.log" | head -n 1 | sed 's/^/   STAT:  /' >> "$RISKY_FILE"
        
        # Extract Top 20 CVEs for quick preview
        echo "   VULNS: (Top 20 preview)" >> "$RISKY_FILE"
        grep -E "CVE-[0-9]{4}-[0-9]+" "$WORK_DIR/temp_scan.log" | \
        awk '{print "     - " $2 " [" $3 "]"}' | sort | uniq | head -n 20 >> "$RISKY_FILE"
        
        echo "----------------------------------------" >> "$RISKY_FILE"
    else
        echo "✅ Clean (No High/Critical vulnerabilities found)"
    fi

done

# Cleanup temporary log file
rm -f "$WORK_DIR/temp_scan.log"

# ------------------------------------------------------------------------------
# 4. Completion
# ------------------------------------------------------------------------------
echo "------------------------------------------------"
echo "🎉 Scan Completed Successfully!"
echo "📄 Full Technical Report:  $OUTPUT_FILE"
echo "⚠️  Executive Risk Summary: $RISKY_FILE"
echo "------------------------------------------------"

cat > trivy.sh << 'EOF'
#!/bin/bash

# ==========================================
# Configuration
# ==========================================
WORK_DIR="$HOME/trivy"
CACHE_DIR="$WORK_DIR/cache"

# Get Hostname
HOST_NAME=$(hostname)

# [File 1] Full Detail Report
OUTPUT_FILE="$WORK_DIR/scan_result_${HOST_NAME}.txt"

# [File 2] Rich Risky Images List
RISKY_FILE="$WORK_DIR/risky_images_${HOST_NAME}.txt"

# OCI Mirror List
OCI_MIRRORS=(
    "ghcr.m.daocloud.io/aquasecurity/trivy-db"
    "ghcr.dockerproxy.com/aquasecurity/trivy-db"
    "ghcr.nju.edu.cn/aquasecurity/trivy-db"
    "ghcr.io/aquasecurity/trivy-db" 
)

# ==========================================
# 1. Preparation
# ==========================================
echo "🚀 Starting security scan on host: $HOST_NAME..."
mkdir -p "$CACHE_DIR"

# Init Files
echo "Scan Report - $(date) - Host: $HOST_NAME" > "$OUTPUT_FILE"

echo "==========================================" > "$RISKY_FILE"
echo "RISKY IMAGES SUMMARY - $(date)" >> "$RISKY_FILE"
echo "Host: $HOST_NAME" >> "$RISKY_FILE"
echo "==========================================" >> "$RISKY_FILE"

echo "📂 Working Directory: $WORK_DIR"
echo "📄 Full Report: $OUTPUT_FILE"
echo "⚠️ Risky List:  $RISKY_FILE"

# ==========================================
# 2. Smart DB Update (OCI Failover)
# ==========================================
echo "📥 Updating DB via OCI Mirrors..."

UPDATE_SUCCESS=false
FINAL_REPO=""

for repo in "${OCI_MIRRORS[@]}"; do
    echo "Trying OCI mirror: $repo ..."
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
# 3. Batch Scan with Rich Summary
# ==========================================
echo "🔍 Scanning all local images..."

# Format: "Repo:Tag|ID"
docker images --format "{{.Repository}}:{{.Tag}}|{{.ID}}" | grep -v "<none>" | while IFS='|' read -r IMAGE_NAME IMAGE_ID; do
    
    echo "Scanning: $IMAGE_NAME ($IMAGE_ID) ..."
    
    # 1. Write Header to Main Report
    echo -e "\n\n==========================================" >> "$OUTPUT_FILE"
    echo "Target: $IMAGE_NAME" >> "$OUTPUT_FILE"
    echo "ID:     $IMAGE_ID" >> "$OUTPUT_FILE"
    echo "==========================================" >> "$OUTPUT_FILE"
    
    # 2. Run Trivy & Capture Output to Temp File
    # We allow exit-code 1 to detect failure, but we pipe output to file
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
    
    # 3. Append Temp Log to Full Report
    cat "$WORK_DIR/temp_scan.log" >> "$OUTPUT_FILE"
    
    # 4. Process Risks for Summary File
    if [ $SCAN_STATUS -eq 1 ]; then
        echo "⚠️  RISK FOUND: $IMAGE_NAME"
        
        # --- Add to Risky File ---
        echo "" >> "$RISKY_FILE"
        echo "🔴 IMAGE: $IMAGE_NAME" >> "$RISKY_FILE" 
        echo "   ID:    $IMAGE_ID" >> "$RISKY_FILE"
        
        # Extract "Total: X (HIGH: X, CRITICAL: X)" line if exists
        grep "Total:" "$WORK_DIR/temp_scan.log" | head -n 1 | sed 's/^/   STAT:  /' >> "$RISKY_FILE"
        
        echo "   VULNS: (Top 20)" >> "$RISKY_FILE"
        
        # Extract CVEs and Severity using grep and awk
        # Logic: Find lines with CVE-xxxx, print Col 2 (ID) and Col 3 (Severity)
        # Sort and unique to avoid duplicates from multi-layer scanning
        grep -E "CVE-[0-9]{4}-[0-9]+" "$WORK_DIR/temp_scan.log" | \
        awk '{print "     - " $2 " [" $3 "]"}' | sort | uniq | head -n 20 >> "$RISKY_FILE"
        
        # Check if there are more lines
        VULN_COUNT=$(grep -E "CVE-[0-9]{4}-[0-9]+" "$WORK_DIR/temp_scan.log" | wc -l)
        if [ "$VULN_COUNT" -gt 20 ]; then
             echo "     ... (Total $VULN_COUNT vulns, see full report)" >> "$RISKY_FILE"
        fi
        echo "----------------------------------------" >> "$RISKY_FILE"
        
    else
        echo "✅ Clean"
    fi

done

# Cleanup
rm -f "$WORK_DIR/temp_scan.log"

echo "------------------------------------------------"
echo "✅ Scan complete!"
echo "📄 Full Report:  $OUTPUT_FILE"
echo "⚠️ Risky Summary: $RISKY_FILE"
EOF

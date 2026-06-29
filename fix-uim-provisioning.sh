#!/bin/bash

DEV="/dev/wwan0qmi0"
LOG="/tmp/fix-uim.log"

# 防止重复执行
[ -e /tmp/fix-uim-done ] && exit 0
touch /tmp/fix-uim-done

log() {
    echo "[fix-uim] $(date '+%H:%M:%S') $1" | tee -a "$LOG"
}

log "启动 UIM 修复流程"

# 等设备出现
log "等待 QMI 设备..."
while [ ! -e "$DEV" ]; do
    sleep 1
done

log "设备已出现，检测 SIM 状态..."

# 等 SIM present
while true; do
    output=$(qmicli -p -d "$DEV" --uim-get-card-status 2>/dev/null)

    if echo "$output" | grep -q "Card state: 'present'"; then
        log "SIM 已识别"
        break
    fi

    sleep 1
done

# 判断是否需要修复
if echo "$output" | grep -q "Primary GW:   session doesn't exist"; then

    log "检测到未 provisioning，开始修复"

    # 停止占用
    systemctl stop vohive 2>/dev/null
    pkill qmi-proxy 2>/dev/null
    sleep 2

    # 获取 AID
    AID=$(echo "$output" | awk '
/Application type:  '\''usim/ {flag=1}
flag && /A0:/ {print; exit}
' | tr -d " \t")

    if [ -z "$AID" ]; then
        log "❌ AID 获取失败"
        exit 1
    fi

    log "使用 AID: $AID"

    # ✅ 重试机制（3次）
    for i in $(seq 1 3); do
        log "尝试激活 provisioning (第 $i 次)"

        if qmicli -p -d "$DEV" \
        --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID"; then
            log "provisioning 成功"
            break
        fi

        sleep 2
    done

    sleep 2

    # 拉 online
    log "设置 modem online"
    qmicli -p -d "$DEV" --dms-set-operating-mode=online

    sleep 2

    # 再检查一次
    output2=$(qmicli -p -d "$DEV" --uim-get-card-status 2>/dev/null)
    if echo "$output2" | grep -q "Application state: 'ready'"; then
        log "✅ SIM 已 ready"
    else
        log "⚠️ SIM 未 ready（可能需要手动检查）"
    fi

    log "启动 VoHive"
    systemctl start vohive 2>/dev/null

    log "✅ 修复完成"

else
    log "✅ SIM 已正常，无需修复"
fi

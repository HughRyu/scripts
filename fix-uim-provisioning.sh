#!/bin/bash

DEV="/dev/wwan0qmi0"

echo "[fix-uim] 等待 QMI 设备..."

# ✅ 等设备出现
while [ ! -e "$DEV" ]; do
    sleep 1
done

echo "[fix-uim] QMI 设备已出现，开始检测 SIM 状态..."

# ✅ 等 SIM 被识别（present）
while true; do
    output=$(qmicli -p -d "$DEV" --uim-get-card-status 2>/dev/null)

    if echo "$output" | grep -q "Card state: 'present'"; then
        echo "[fix-uim] SIM 卡已识别"
        break
    fi

    sleep 1
done

# ✅ 判断是否需要修复（关键逻辑）
if echo "$output" | grep -q "Primary GW:   session doesn't exist"; then

    echo "[fix-uim] 检测到未 provisioning，开始修复..."

    # 停止占用
    systemctl stop vohive 2>/dev/null
    pkill qmi-proxy 2>/dev/null
    sleep 2

    # ✅ 获取 USIM AID
    AID=$(echo "$output" | awk '
/Application type:  '\''usim/ {flag=1}
flag && /A0:/ {print; exit}
' | tr -d " \t")

    if [ -z "$AID" ]; then
        echo "[fix-uim] ❌ 未找到 USIM AID"
        exit 1
    fi

    echo "[fix-uim] 使用 AID: $AID"

    # ✅ 激活
    qmicli -p -d "$DEV" \
    --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID"

    sleep 2

    # ✅ 拉 online
    qmicli -p -d "$DEV" --dms-set-operating-mode=online

    sleep 2

    echo "[fix-uim] 启动 VoHive..."
    systemctl start vohive 2>/dev/null

    echo "[fix-uim] ✅ 修复完成"

else
    echo "[fix-uim] ✅ 不需要修复（已正常）"
fi

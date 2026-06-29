#!/bin/bash

DEV="/dev/wwan0qmi0"

sleep 20

# 停止占用
systemctl stop vohive 2>/dev/null
pkill qmi-proxy 2>/dev/null
sleep 2

# 检查设备
[ ! -e "$DEV" ] && exit 1

echo "[fix-modem] 查找 USIM AID..."

# ✅ 精准提取 USIM 的 AID（只取 usim 对应）
AID=$(qmicli -p -d $DEV --uim-get-card-status | awk '
/Application type:  '\''usim/ {flag=1}
flag && /A0:/ {print; exit}
' | tr -d " \t")

if [ -z "$AID" ]; then
    echo "[fix-modem] ❌ 未找到 USIM AID"
    exit 1
fi

echo "[fix-modem] 使用 AID: $AID"

# ✅ 激活 SIM
qmicli -p -d "$DEV" \
--uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID"

sleep 2

# ✅ 拉 online
qmicli -p -d "$DEV" --dms-set-operating-mode=online

sleep 3

# ✅ 启动 vohive
systemctl start vohive 2>/dev/null

echo "[fix-modem] ✅ 完成"

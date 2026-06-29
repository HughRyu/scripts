# ===== 1. 写入脚本 =====
cat << 'EOF' > /usr/local/bin/fix-uim-provisioning.sh
#!/bin/bash

DEV="/dev/wwan0qmi0"

echo "[fix-uim] 等待系统初始化..."
sleep 20

echo "[fix-uim] 停止 VoHive 和 QMI 占用..."
systemctl stop vohive 2>/dev/null
pkill qmi-proxy 2>/dev/null
sleep 2

# 检查设备
if [ ! -e "$DEV" ]; then
    echo "[fix-uim] QMI设备不存在，退出"
    exit 1
fi

echo "[fix-uim] 解析 USIM AID..."

# ✅ 自动识别 USIM AID（正确版本）
AID=$(qmicli -p -d $DEV --uim-get-card-status | awk '
/Application type:  '\''usim/ {flag=1}
flag && /A0:/ {print; exit}
' | tr -d " \t")

if [ -z "$AID" ]; then
    echo "[fix-uim] ❌ 未找到 USIM AID"
    exit 1
fi

echo "[fix-uim] 使用 AID: $AID"

echo "[fix-uim] 激活 SIM provisioning..."

qmicli -p -d "$DEV" \
--uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID"

sleep 2

echo "[fix-uim] 拉起 modem..."

qmicli -p -d "$DEV" --dms-set-operating-mode=online

sleep 3

echo "[fix-uim] 启动 VoHive..."

systemctl start vohive 2>/dev/null

echo "[fix-uim] ✅ 完成"

EOF

chmod +x /usr/local/bin/fix-uim-provisioning.sh


# ===== 2. 写入 systemd =====
cat << 'EOF' > /etc/systemd/system/fix-uim-provisioning.service
[Unit]
Description=Fix UIM Provisioning (SP970 QMI SIM fix)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-uim-provisioning.sh

[Install]
WantedBy=multi-user.target
EOF


# ===== 3. 启用自启动 =====
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable fix-uim-provisioning

echo "✅ 安装完成，重启测试：reboot"

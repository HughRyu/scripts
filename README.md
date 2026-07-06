# SSH Key OneKey Setup
```
curl -fsSL https://hughr.de/ssh-onekey | bash
curl -fsSL https://gh-proxy.com/https://hughr.de/ssh-onekey | bash

curl -fsSL https://hughr.de/ssh-onekey | bash -s -- --key-dir /root/.ssh -p 18122


SSH_ONEKEY_HOST=infosp \
SSH_ONEKEY_HOSTNAME=172.17.18.18 \
SSH_ONEKEY_USER=openclaw \
SSH_ONEKEY_PORT=18122 \
curl -fsSL https://hughr.de/ssh-onekey | bash


```
#Import my SSH public key to allow passwordless remote access.  
```
curl -fsSL https://hughr.de/ssh | bash
curl -x http://192.168.199.5:1999 -fsSL https://hughr.de/ssh | bash  
```
#Import SSH public key to Syno-DSM.  
```
curl -fsSL https://hughr.de/ssh-syno | bash  
```

#Trivy Scanning Tool Optimized for Automated Docker Image Security Inspection Script.
```
curl -fsSL https://hughr.de/trivy | bash
```

```
curl -L https://gh-proxy.com/https://raw.githubusercontent.com/HughRyu/scripts/main/fix-uim-provisioning.sh \
-o /usr/local/bin/fix-uim-provisioning.sh && \
chmod +x /usr/local/bin/fix-uim-provisioning.sh && \
cat > /etc/systemd/system/fix-uim-provisioning.service << 'EOF'
[Unit]
Description=Fix UIM Provisioning (SP970 QMI SIM fix)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-uim-provisioning.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reexec && \
systemctl daemon-reload && \
systemctl enable fix-uim-provisioning && \
systemctl restart fix-uim-provisioning && \
echo "✅ 完成：脚本已更新 + 已加入启动项 + 已执行一次"
``
```

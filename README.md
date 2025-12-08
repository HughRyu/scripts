curl -fSL https://raw.githubusercontent.com/HughRyu/scripts/refs/heads/main/trivy-scan.sh | bash

🛡️ Docker 镜像安全自动巡检脚本
专为国内网络环境优化的 Trivy 扫描工具。自动解决数据库下载失败问题，一键生成“高危漏洞”黑名单，无需人工干预。

核心功能
自动容灾：内置 DaoCloud/南京大学等多个加速源，一个挂了自动切下一个，确保 100% 运行成功。

重点突出：自动过滤低级噪音，生成一份独立的 高危/严重 (High/Critical) 风险清单。

多机友好：报告文件名自动带上主机名（如 _ali.txt），方便批量管理。

📂 目录结构
脚本运行后，会自动在 ~/trivy/ 下生成以下结构：

Plaintext

/root/trivy/

├── cache/                           # 数据库缓存 (复用，不用每次下载)

├── scan_result_<主机名>.txt          # [全量报告] 包含所有技术细节

└── risky_images_<主机名>.txt         # [推荐] 风险黑名单 (只列出有问题的高危镜像)

🚀 一键执行 (推荐)
无需下载脚本文件，直接复制以下命令执行即可（已配置国内加速）：

Bash

curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/HughRyu/scripts/main/trivy-scan.sh | bash

👀 结果示例
执行完成后，查看风险清单即可快速定位问题：

Bash

cat ~/trivy/risky_images_$(hostname).txt
输出预览：

Plaintext

🔴 IMAGE: nginx:latest
   ID:    a6292eb82e9d
   STAT:  Total: 15 (HIGH: 10, CRITICAL: 5)
   VULNS: (Top 20)
     - CVE-2023-1234 [CRITICAL]
     - CVE-2023-5678 [HIGH]

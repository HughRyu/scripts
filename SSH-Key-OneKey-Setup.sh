#!/usr/bin/env bash
set -euo pipefail

# SSH OneKey Manual Edition
# 新增 -m 参数：不连接目标机器，只生成可复制执行的命令

HOST_ALIAS=""
HOSTNAME=""
REMOTE_USER="root"
SSH_PORT="22"
KEY_DIR="$HOME/.ssh"
KEY_PATH=""
MANUAL_MODE="no"

usage(){
cat <<EOF
Usage:
  $0 --host alias --hostname ip [options]

Options:
  --host NAME
  --hostname IP/HOST
  --user USER
  -p, --port PORT
  --key FILE
  -m, --manual
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST_ALIAS="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --user) REMOTE_USER="$2"; shift 2;;
    -p|--port) SSH_PORT="$2"; shift 2;;
    --key) KEY_PATH="$2"; shift 2;;
    -m|--manual) MANUAL_MODE=yes; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

[ -n "$HOST_ALIAS" ] || read -rp "Host Alias: " HOST_ALIAS
[ -n "$HOSTNAME" ] || read -rp "Host/IP: " HOSTNAME

if [ -z "$KEY_PATH" ]; then
  KEY_PATH="$KEY_DIR/id_ed25519_${HOST_ALIAS}"
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$KEY_PATH" ]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "$(hostname)-to-${HOST_ALIAS}"
fi

PUB_KEY="$(cat ${KEY_PATH}.pub)"

cat > "$HOME/.ssh/config.tmp.$$" <<EOF
Host ${HOST_ALIAS}
    HostName ${HOSTNAME}
    User ${REMOTE_USER}
    Port ${SSH_PORT}
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
EOF

if [ "$MANUAL_MODE" = "yes" ]; then
cat <<EOF

==================================================
复制下面内容到目标机器执行
==================================================

mkdir -p ~/.ssh
chmod 700 ~/.ssh

cat >> ~/.ssh/authorized_keys <<'KEYEOF'
${PUB_KEY}
KEYEOF

chmod 600 ~/.ssh/authorized_keys

==================================================
如果目标机需要启用公钥登录（root执行）
==================================================

mkdir -p /etc/ssh/sshd_config.d

cat >/etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf <<'SSHEOF'
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
SSHEOF

systemctl restart ssh || systemctl restart sshd

==================================================
本机连接
==================================================

ssh ${HOST_ALIAS}

EOF
exit 0
fi

echo "当前版本仅优化 manual 模式，请使用 -m"

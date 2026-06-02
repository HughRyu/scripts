#!/usr/bin/env bash
set -euo pipefail

# ssh-onekey-setup.sh
# 一键配置当前机器通过 SSH key 免密访问目标 Ubuntu/Linux 服务器。

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf "%b\n" "${BLUE}==>${NC} $*"; }
ok() { printf "%b\n" "${GREEN}OK:${NC} $*"; }
warn() { printf "%b\n" "${YELLOW}WARN:${NC} $*"; }
err() { printf "%b\n" "${RED}ERROR:${NC} $*" >&2; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "缺少必要命令: $1"
    exit 1
  fi
}

read_tty() {
  local prompt_text="$1"
  local value=""
  if [ -r /dev/tty ]; then
    read -r -p "$prompt_text" value </dev/tty
  else
    err "当前环境没有可用 TTY，无法交互输入。请改用非交互参数。"
    exit 1
  fi
  printf '%s' "$value"
}

prompt() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local value=""

  if [ -n "$default_value" ]; then
    value="$(read_tty "$label [$default_value]: ")"
    value="${value:-$default_value}"
  else
    while true; do
      value="$(read_tty "$label: ")"
      if [ -n "$value" ]; then break; fi
      warn "这个值不能为空。"
    done
  fi

  printf -v "$var_name" '%s' "$value"
}

usage() {
  cat <<'EOF'
Usage:
  ssh-onekey-setup.sh [options]

Options:
  --host <alias>              SSH 别名，例如 dev
  --hostname <ip/host>        目标主机，例如 192.168.199.8
  --user <user>               目标登录用户，例如 root
  --key <path>                当前机器上的私钥路径，例如 ~/.ssh/id_ed25519_dev
  --port <port>               SSH 端口，默认 22
  --comment <comment>         新生成 key 的注释
  --no-install-key            不向目标服务器安装公钥，只写本机 SSH config
  --no-enable-remote-sshd     不修改目标服务器 sshd 配置
  --help                      显示帮助

Examples:
  curl -fsSL https://example.com/ssh-onekey | bash

  curl -fsSL https://example.com/ssh-onekey | bash -s -- \
    --host dev --hostname 192.168.199.8 --user root --key ~/.ssh/id_ed25519_dev
EOF
}

HOST_ALIAS=""
HOSTNAME=""
REMOTE_USER=""
KEY_PATH=""
SSH_PORT="22"
KEY_COMMENT=""
INSTALL_KEY="yes"
ENABLE_REMOTE_SSHD="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      HOST_ALIAS="${2:-}"; shift 2 ;;
    --hostname)
      HOSTNAME="${2:-}"; shift 2 ;;
    --user)
      REMOTE_USER="${2:-}"; shift 2 ;;
    --key)
      KEY_PATH="${2:-}"; shift 2 ;;
    --port)
      SSH_PORT="${2:-}"; shift 2 ;;
    --comment)
      KEY_COMMENT="${2:-}"; shift 2 ;;
    --no-install-key)
      INSTALL_KEY="no"; shift ;;
    --no-enable-remote-sshd)
      ENABLE_REMOTE_SSHD="no"; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      err "未知选项: $1"
      usage
      exit 1 ;;
  esac
done

need_cmd ssh
need_cmd ssh-keygen
need_cmd awk
need_cmd sed
need_cmd mktemp
need_cmd date

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ -z "$HOST_ALIAS" ]; then prompt HOST_ALIAS "SSH 别名 / Host" "dev"; fi
if [ -z "$HOSTNAME" ]; then prompt HOSTNAME "目标 hostname/IP" "192.168.199.8"; fi
if [ -z "$REMOTE_USER" ]; then prompt REMOTE_USER "目标 SSH 用户" "root"; fi
if [ -z "$SSH_PORT" ]; then prompt SSH_PORT "目标 SSH 端口" "22"; fi
if [ -z "$KEY_PATH" ]; then prompt KEY_PATH "当前机器私钥路径" "$HOME/.ssh/id_ed25519_${HOST_ALIAS}"; fi

KEY_PATH="${KEY_PATH/#\~/$HOME}"
PUB_PATH="${KEY_PATH}.pub"

if [ -z "$KEY_COMMENT" ]; then
  LOCAL_USER="$(id -un 2>/dev/null || echo user)"
  LOCAL_HOST="$(hostname 2>/dev/null || echo host)"
  KEY_COMMENT="${LOCAL_USER}@${LOCAL_HOST}-to-${HOST_ALIAS}"
fi

log "SSH 别名: $HOST_ALIAS"
log "目标地址: ${REMOTE_USER}@${HOSTNAME}:${SSH_PORT}"
log "本机私钥: $KEY_PATH"

if [ ! -f "$KEY_PATH" ]; then
  log "未发现私钥，正在生成新的 ed25519 key..."
  mkdir -p "$(dirname "$KEY_PATH")"
  ssh-keygen -t ed25519 -f "$KEY_PATH" -C "$KEY_COMMENT"
  chmod 600 "$KEY_PATH"
  ok "已生成私钥: $KEY_PATH"
else
  chmod 600 "$KEY_PATH" || true
  if [ ! -f "$PUB_PATH" ]; then
    log "未发现公钥，正在从私钥导出公钥..."
    ssh-keygen -y -f "$KEY_PATH" > "$PUB_PATH"
    chmod 644 "$PUB_PATH"
  fi
  ok "使用已有私钥: $KEY_PATH"
fi

if [ "$INSTALL_KEY" = "yes" ]; then
  log "准备把公钥安装到目标服务器: ${REMOTE_USER}@${HOSTNAME}"
  warn "第一次连接通常需要输入一次目标服务器 ${REMOTE_USER} 用户的密码。"

  PUB_KEY_CONTENT="$(cat "$PUB_PATH")"
  ESCAPED_PUB_KEY="$(printf '%s' "$PUB_KEY_CONTENT" | sed "s/'/'\\\\''/g")"

  ssh -p "$SSH_PORT" \
    -o PreferredAuthentications=password,keyboard-interactive,publickey \
    -o PubkeyAuthentication=yes \
    -tt "${REMOTE_USER}@${HOSTNAME}" \
    "PUB_KEY='$ESCAPED_PUB_KEY' ENABLE_REMOTE_SSHD='$ENABLE_REMOTE_SSHD' REMOTE_USER_NAME='$REMOTE_USER' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

log_remote() { printf '%s\n' "==> $*"; }
warn_remote() { printf '%s\n' "WARN: $*"; }

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

if ! grep -qxF "$PUB_KEY" "$HOME/.ssh/authorized_keys"; then
  printf '%s\n' "$PUB_KEY" >> "$HOME/.ssh/authorized_keys"
fi

if command -v id >/dev/null 2>&1; then
  chown -R "$(id -un):$(id -gn)" "$HOME/.ssh" 2>/dev/null || true
fi

log_remote "公钥已写入: $HOME/.ssh/authorized_keys"

if [ "${ENABLE_REMOTE_SSHD:-yes}" != "yes" ]; then
  log_remote "跳过 sshd 配置修改。"
  exit 0
fi

SUDO=""
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    SUDO="sudo"
  else
    warn_remote "当前用户不是 root，且 sudo 需要密码/不可用；跳过 sshd 配置修改。"
    warn_remote "公钥已导入，但如果目标 sshd 禁用了 PubkeyAuthentication，仍需手动开启。"
    exit 0
  fi
else
  warn_remote "当前用户不是 root，且无 sudo；跳过 sshd 配置修改。"
  exit 0
fi

SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="$SSHD_DROPIN_DIR/99-openclaw-pubkey.conf"

if [ -d "$SSHD_DROPIN_DIR" ]; then
  $SUDO sh -c "cat > '$SSHD_DROPIN_FILE'" <<EOF
# Managed by ssh-onekey-setup.sh
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
EOF

  if [ "${REMOTE_USER_NAME:-}" = "root" ]; then
    $SUDO sh -c "cat >> '$SSHD_DROPIN_FILE'" <<EOF
PermitRootLogin prohibit-password
EOF
  fi
  log_remote "已写入 sshd drop-in: $SSHD_DROPIN_FILE"
else
  SSHD_CONFIG="/etc/ssh/sshd_config"
  if [ -f "$SSHD_CONFIG" ]; then
    BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp "$SSHD_CONFIG" "$BACKUP"
    $SUDO sed -i '/^[#[:space:]]*PubkeyAuthentication[[:space:]]/d' "$SSHD_CONFIG"
    $SUDO sed -i '/^[#[:space:]]*AuthorizedKeysFile[[:space:]]/d' "$SSHD_CONFIG"
    $SUDO sh -c "cat >> '$SSHD_CONFIG'" <<EOF

# Managed by ssh-onekey-setup.sh
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
EOF
    if [ "${REMOTE_USER_NAME:-}" = "root" ]; then
      $SUDO sed -i '/^[#[:space:]]*PermitRootLogin[[:space:]]/d' "$SSHD_CONFIG"
      $SUDO sh -c "cat >> '$SSHD_CONFIG'" <<EOF
PermitRootLogin prohibit-password
EOF
    fi
    log_remote "已修改 sshd_config，备份: $BACKUP"
  else
    warn_remote "未找到 /etc/ssh/sshd_config，跳过 sshd 配置修改。"
    exit 0
  fi
fi

if command -v sshd >/dev/null 2>&1; then
  $SUDO sshd -t
elif [ -x /usr/sbin/sshd ]; then
  $SUDO /usr/sbin/sshd -t
else
  warn_remote "未找到 sshd 命令，无法校验配置；跳过重启。"
  exit 0
fi

if command -v systemctl >/dev/null 2>&1; then
  $SUDO systemctl restart ssh 2>/dev/null || $SUDO systemctl restart sshd 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
  $SUDO service ssh restart 2>/dev/null || $SUDO service sshd restart 2>/dev/null || true
fi

log_remote "sshd 公钥登录已启用并尝试重启 SSH 服务。"
REMOTE_SCRIPT

  ok "目标端公钥安装完成。"
fi

CONFIG_FILE="$HOME/.ssh/config"
BACKUP_FILE=""
if [ -f "$CONFIG_FILE" ]; then
  BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP_FILE"
fi

tmp_config="$(mktemp)"
if [ -f "$CONFIG_FILE" ]; then
  awk -v host="$HOST_ALIAS" '
    BEGIN { skip=0 }
    /^[[:space:]]*Host[[:space:]]+/ {
      skip=0
      for (i=2; i<=NF; i++) {
        if ($i == host) { skip=1; break }
      }
    }
    skip == 0 { print }
  ' "$CONFIG_FILE" > "$tmp_config"
else
  : > "$tmp_config"
fi

IDENTITY_FOR_CONFIG="$KEY_PATH"
case "$KEY_PATH" in
  "$HOME"/*) IDENTITY_FOR_CONFIG="~/${KEY_PATH#"$HOME"/}" ;;
esac

{
  sed -e '${/^$/d;}' "$tmp_config"
  printf '\n\nHost %s\n' "$HOST_ALIAS"
  printf '    HostName %s\n' "$HOSTNAME"
  printf '    User %s\n' "$REMOTE_USER"
  printf '    Port %s\n' "$SSH_PORT"
  printf '    IdentityFile %s\n' "$IDENTITY_FOR_CONFIG"
  printf '    IdentitiesOnly yes\n'
} > "$CONFIG_FILE"
rm -f "$tmp_config"
chmod 600 "$CONFIG_FILE"

if [ -n "$BACKUP_FILE" ]; then
  ok "已备份旧 SSH config: $BACKUP_FILE"
fi
ok "已写入本机 SSH config: $CONFIG_FILE"

log "测试免密登录: ssh $HOST_ALIAS true"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST_ALIAS" true >/dev/null 2>&1; then
  ok "成功。以后可以直接连接: ssh $HOST_ALIAS"
else
  warn "配置已写入，但免密测试失败。你可以手动执行查看详情: ssh -vvv $HOST_ALIAS"
  warn "常见原因：目标端禁止 root 登录、sshd 配置未重启、authorized_keys 权限/路径异常。"
  exit 2
fi

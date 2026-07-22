#!/usr/bin/env bash
set -euo pipefail

# SSH OneKey Setup - safe manual mode
# 重点修复：curl | bash 时，交互输入必须从 /dev/tty 读取，不能直接 read stdin。

HOST_ALIAS=""
HOSTNAME=""
REMOTE_USER="root"
SSH_PORT="22"
KEY_DIR="${SSH_ONEKEY_KEY_DIR:-$HOME/.ssh}"
KEY_PATH=""
KEY_COMMENT=""
MANUAL_MODE="no"
INSTALL_KEY="yes"
ENABLE_REMOTE_SSHD="yes"

log(){ printf '%s\n' "==> $*"; }
ok(){ printf '%s\n' "OK: $*"; }
warn(){ printf '%s\n' "WARN: $*"; }
err(){ printf '%s\n' "ERROR: $*" >&2; }

usage(){
cat <<'EOF'
Usage:
  ssh-onekey.sh [options]

Options:
  --host <alias>              Local SSH alias, e.g. cookie
  --hostname <ip/host>        Remote host/IP, e.g. 192.168.199.8
  --user <user>               Remote SSH user, default root
  -p, --port <port>           Remote SSH port, default 22
  --key <path>                Local private key path, default ~/.ssh/id_ed25519_<alias>
  --key-dir <dir>             Directory for default key path, default ~/.ssh
  --comment <text>            SSH key comment
  -m, --manual                Do not connect remote host; print copy-paste commands only
  --no-install-key            Only write local SSH config; do not install/print remote key command
  --no-enable-remote-sshd     Do not print/apply sshd config changes
  -h, --help                  Show help
EOF
}

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }
require_arg(){ [ -n "${2:-}" ] || { err "Option $1 requires a value"; usage; exit 1; }; }

read_from_tty(){
  local prompt_text="$1" value=""
  if [ -r /dev/tty ]; then
    read -r -p "$prompt_text" value </dev/tty
  else
    err "No TTY available. Please pass --host and --hostname explicitly."
    exit 1
  fi
  printf '%s' "$value"
}

prompt_required(){
  local var="$1" label="$2" value=""
  while true; do
    value="$(read_from_tty "$label: ")"
    [ -n "$value" ] && break
    warn "Value cannot be empty."
  done
  printf -v "$var" '%s' "$value"
}

validate_port(){
  case "$1" in ''|*[!0-9]*) err "Invalid port: $1"; exit 1;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { err "Invalid port: $1"; exit 1; }
}

validate_alias(){
  case "$1" in
    ''|*[[:space:]]*) err "Invalid Host alias: '$1'"; exit 1;;
    '*'*|'?'*) err "Host alias must not contain wildcard: '$1'"; exit 1;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) require_arg "$@"; HOST_ALIAS="$2"; shift 2;;
    --hostname) require_arg "$@"; HOSTNAME="$2"; shift 2;;
    --user) require_arg "$@"; REMOTE_USER="$2"; shift 2;;
    -p|--port) require_arg "$@"; SSH_PORT="$2"; shift 2;;
    --key) require_arg "$@"; KEY_PATH="$2"; shift 2;;
    --key-dir) require_arg "$@"; KEY_DIR="$2"; shift 2;;
    --comment) require_arg "$@"; KEY_COMMENT="$2"; shift 2;;
    -m|--manual) MANUAL_MODE="yes"; shift;;
    --no-install-key) INSTALL_KEY="no"; shift;;
    --no-enable-remote-sshd) ENABLE_REMOTE_SSHD="no"; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 1;;
  esac
done

need_cmd ssh
need_cmd ssh-keygen
need_cmd awk
need_cmd sed
need_cmd mktemp
need_cmd date

[ -n "$HOST_ALIAS" ] || prompt_required HOST_ALIAS "SSH alias / Host"
[ -n "$HOSTNAME" ] || prompt_required HOSTNAME "Remote hostname/IP"

validate_alias "$HOST_ALIAS"
validate_port "$SSH_PORT"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

KEY_DIR="${KEY_DIR/#\~/$HOME}"
if [ -z "$KEY_PATH" ]; then
  KEY_PATH="${KEY_DIR%/}/id_ed25519_${HOST_ALIAS}"
fi
KEY_PATH="${KEY_PATH/#\~/$HOME}"
PUB_PATH="${KEY_PATH}.pub"

if [ -z "$KEY_COMMENT" ]; then
  KEY_COMMENT="$(hostname 2>/dev/null || echo host)-to-${HOST_ALIAS}"
fi

log "Alias: $HOST_ALIAS"
log "Remote: ${REMOTE_USER}@${HOSTNAME}:${SSH_PORT}"
log "Local key: $KEY_PATH"

if [ ! -f "$KEY_PATH" ]; then
  log "Private key not found; generating ed25519 key..."
  mkdir -p "$(dirname "$KEY_PATH")"
  ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "$KEY_COMMENT"
  chmod 600 "$KEY_PATH"
else
  chmod 600 "$KEY_PATH" || true
  if [ ! -f "$PUB_PATH" ]; then
    ssh-keygen -y -f "$KEY_PATH" > "$PUB_PATH"
    chmod 644 "$PUB_PATH"
  fi
  ok "Using existing key."
fi

PUB_KEY="$(cat "$PUB_PATH")"

CONFIG_FILE="$HOME/.ssh/config"
TMP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/ssh-onekey-config.XXXXXX")"
TMP_OLD="$(mktemp "${TMPDIR:-/tmp}/ssh-onekey-config-old.XXXXXX")"
trap 'rm -f "$TMP_CONFIG" "$TMP_OLD"' EXIT

if [ -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  awk -v host="$HOST_ALIAS" '
    function has_host(    i) { for (i=2; i<=NF; i++) if ($i == host) return 1; return 0 }
    /^[[:space:]]*Host[[:space:]]+/ { skip = has_host() ? 1 : 0; if (skip) next }
    /^[[:space:]]*Match[[:space:]]+/ { skip = 0 }
    skip == 0 { print }
  ' "$CONFIG_FILE" > "$TMP_OLD"
else
  : > "$TMP_OLD"
fi

IDENTITY_FOR_CONFIG="$KEY_PATH"
case "$IDENTITY_FOR_CONFIG" in "$HOME"/*) IDENTITY_FOR_CONFIG="~/${IDENTITY_FOR_CONFIG#"$HOME"/}";; esac

awk 'NF { line[NR]=$0; last=NR } END { for (i=1; i<=last; i++) print line[i] }' "$TMP_OLD" > "$TMP_CONFIG"
{
  cat "$TMP_CONFIG"
  printf '\n\nHost %s\n' "$HOST_ALIAS"
  printf '    HostName %s\n' "$HOSTNAME"
  printf '    User %s\n' "$REMOTE_USER"
  printf '    Port %s\n' "$SSH_PORT"
  printf '    IdentityFile %s\n' "$IDENTITY_FOR_CONFIG"
  printf '    IdentitiesOnly yes\n'
  printf '    StrictHostKeyChecking accept-new\n'
  printf '    UserKnownHostsFile ~/.ssh/known_hosts\n'
  printf '    LogLevel ERROR\n'
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
ok "Wrote local SSH config: $CONFIG_FILE"

if [ "$INSTALL_KEY" = "no" ]; then
  ok "Skip remote key install because --no-install-key was set."
  exit 0
fi

if [ "$MANUAL_MODE" = "yes" ]; then
cat <<EOF

============================================================
Manual mode: this script did NOT connect to the remote host.
Copy and run the following block ON THE TARGET MACHINE:
============================================================

mkdir -p ~/.ssh
chmod 700 ~/.ssh

grep -qxF '$PUB_KEY' ~/.ssh/authorized_keys 2>/dev/null || cat >> ~/.ssh/authorized_keys <<'KEYEOF'
$PUB_KEY
KEYEOF

chmod 600 ~/.ssh/authorized_keys

EOF

if [ "$ENABLE_REMOTE_SSHD" = "yes" ]; then
cat <<'EOF'
============================================================
Optional: if public-key login is not enabled, run this as root ON THE TARGET MACHINE:
============================================================

mkdir -p /etc/ssh/sshd_config.d

cat >/etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf <<'SSHEOF'
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
SSHEOF

if command -v sshd >/dev/null 2>&1; then
  sshd -t
elif [ -x /usr/sbin/sshd ]; then
  /usr/sbin/sshd -t
fi

systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true

EOF
fi

cat <<EOF
============================================================
Then connect FROM THIS MACHINE:
============================================================

ssh $HOST_ALIAS

EOF
  ok "Manual mode finished."
  exit 0
fi

# Auto mode
ESCAPED_PUB_KEY="$(printf '%s' "$PUB_KEY" | sed "s/'/'\\''/g")"
ssh -T -p "$SSH_PORT" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
  -o PreferredAuthentications=password,keyboard-interactive,publickey \
  -o PubkeyAuthentication=yes \
  "${REMOTE_USER}@${HOSTNAME}" \
  "PUB_KEY='$ESCAPED_PUB_KEY' ENABLE_REMOTE_SSHD='$ENABLE_REMOTE_SSHD' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
grep -qxF "$PUB_KEY" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$PUB_KEY" >> "$HOME/.ssh/authorized_keys"
chown -R "$(id -un):$(id -gn)" "$HOME/.ssh" 2>/dev/null || true
if [ "${ENABLE_REMOTE_SSHD:-yes}" = "yes" ] && [ "$(id -u)" -eq 0 ]; then
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf <<'SSHEOF'
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
SSHEOF
  if command -v sshd >/dev/null 2>&1; then sshd -t; elif [ -x /usr/sbin/sshd ]; then /usr/sbin/sshd -t; fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
fi
printf '%s\n' 'SSH public key installed.'
REMOTE_SCRIPT

log "Testing key-only login: ssh $HOST_ALIAS true"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST_ALIAS" true >/dev/null 2>&1; then
  ok "Success. Connect with: ssh $HOST_ALIAS"
else
  warn "Config written, but key-only test failed. Debug with: ssh -vvv $HOST_ALIAS"
  exit 2
fi

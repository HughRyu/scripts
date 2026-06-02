#!/usr/bin/env bash
set -euo pipefail

# Universal SSH one-key setup for macOS/Linux clients and mostly Ubuntu/Linux targets.
# Safe with: curl -fsSL URL | bash
#
# What it does:
# 1) Create/reuse a local SSH key
# 2) Install the public key into remote ~/.ssh/authorized_keys
# 3) If remote is root or passwordless sudo is available, enable sshd public-key login
# 4) Write/update local ~/.ssh/config Host alias
# 5) Test key-only login
#
# Examples:
#   curl -fsSL https://hughr.de/ssh-onekey | bash
#   curl -fsSL https://hughr.de/ssh-onekey | bash -s -- --host dev --hostname 192.168.199.8 --user root

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log(){ printf "%b\n" "${BLUE}==>${NC} $*"; }
ok(){ printf "%b\n" "${GREEN}OK:${NC} $*"; }
warn(){ printf "%b\n" "${YELLOW}WARN:${NC} $*"; }
err(){ printf "%b\n" "${RED}ERROR:${NC} $*" >&2; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }; }

read_tty(){
  local prompt_text="$1" value=""
  if [ -r /dev/tty ]; then
    read -r -p "$prompt_text" value </dev/tty
  else
    err "No TTY available for interactive input. Use non-interactive flags instead."
    exit 1
  fi
  printf '%s' "$value"
}

prompt(){
  local var_name="$1" label="$2" default_value="${3:-}" value=""
  if [ -n "$default_value" ]; then
    value="$(read_tty "$label [$default_value]: ")"
    value="${value:-$default_value}"
  else
    while true; do
      value="$(read_tty "$label: ")"
      [ -n "$value" ] && break
      warn "Value cannot be empty."
    done
  fi
  printf -v "$var_name" '%s' "$value"
}

usage(){
cat <<'EOF'
Usage:
  ssh-onekey-universal.sh [options]

Options:
  --host <alias>              Local SSH alias, e.g. dev
  --hostname <ip/host>        Remote host/IP, e.g. 192.168.199.8
  --user <user>               Remote SSH user, e.g. root
  --port <port>               Remote SSH port, default 22
  --key <path>                Local private key path, e.g. ~/.ssh/id_ed25519_dev
  --comment <comment>         New key comment
  --no-install-key            Only write local SSH config; do not install remote key
  --no-enable-remote-sshd     Do not modify remote sshd config
  --help                      Show help

Examples:
  curl -fsSL https://hughr.de/ssh-onekey | bash
  curl -fsSL https://hughr.de/ssh-onekey | bash -s -- --host dev --hostname 192.168.199.8 --user root
EOF
}

HOST_ALIAS=""; HOSTNAME=""; REMOTE_USER=""; SSH_PORT="22"; KEY_PATH=""; KEY_COMMENT=""
INSTALL_KEY="yes"; ENABLE_REMOTE_SSHD="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST_ALIAS="${2:-}"; shift 2;;
    --hostname) HOSTNAME="${2:-}"; shift 2;;
    --user) REMOTE_USER="${2:-}"; shift 2;;
    --port) SSH_PORT="${2:-}"; shift 2;;
    --key) KEY_PATH="${2:-}"; shift 2;;
    --comment) KEY_COMMENT="${2:-}"; shift 2;;
    --no-install-key) INSTALL_KEY="no"; shift;;
    --no-enable-remote-sshd) ENABLE_REMOTE_SSHD="no"; shift;;
    --help|-h) usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 1;;
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

[ -n "$HOST_ALIAS" ] || prompt HOST_ALIAS "SSH alias / Host"
[ -n "$HOSTNAME" ] || prompt HOSTNAME "Remote hostname/IP"
[ -n "$REMOTE_USER" ] || prompt REMOTE_USER "Remote SSH user" "root"
[ -n "$SSH_PORT" ] || prompt SSH_PORT "Remote SSH port" "22"
[ -n "$KEY_PATH" ] || prompt KEY_PATH "Local private key path" "$HOME/.ssh/id_ed25519_${HOST_ALIAS}"

KEY_PATH="${KEY_PATH/#\~/$HOME}"
PUB_PATH="${KEY_PATH}.pub"

if [ -z "$KEY_COMMENT" ]; then
  KEY_COMMENT="$(id -un 2>/dev/null || echo user)@$(hostname 2>/dev/null || echo host)-to-${HOST_ALIAS}"
fi

log "Alias: $HOST_ALIAS"
log "Remote: ${REMOTE_USER}@${HOSTNAME}:${SSH_PORT}"
log "Local key: $KEY_PATH"

if [ ! -f "$KEY_PATH" ]; then
  log "Private key not found; generating ed25519 key..."
  mkdir -p "$(dirname "$KEY_PATH")"
  ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "$KEY_COMMENT"
  chmod 600 "$KEY_PATH"
  ok "Generated: $KEY_PATH"
else
  chmod 600 "$KEY_PATH" || true
  if [ ! -f "$PUB_PATH" ]; then
    log "Public key missing; deriving from private key..."
    ssh-keygen -y -f "$KEY_PATH" > "$PUB_PATH"
    chmod 644 "$PUB_PATH"
  fi
  ok "Using existing key."
fi

if [ "$INSTALL_KEY" = "yes" ]; then
  log "Installing public key on remote. Password may be required once."
  PUB_KEY_CONTENT="$(cat "$PUB_PATH")"
  ESCAPED_PUB_KEY="$(printf '%s' "$PUB_KEY_CONTENT" | sed "s/'/'\\''/g")"

  ssh -T -p "$SSH_PORT" \
    -o PreferredAuthentications=password,keyboard-interactive,publickey \
    -o PubkeyAuthentication=yes \
    "${REMOTE_USER}@${HOSTNAME}" \
    "PUB_KEY='$ESCAPED_PUB_KEY' ENABLE_REMOTE_SSHD='$ENABLE_REMOTE_SSHD' REMOTE_USER_NAME='$REMOTE_USER' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

rlog(){ printf '%s\n' "==> $*"; }
rwarn(){ printf '%s\n' "WARN: $*"; }

OS="unknown"
if [ -s /etc/os-release ]; then
  . /etc/os-release
  OS="${ID:-linux}"
elif [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
  OS="macos"
fi

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
rlog "Public key installed: $HOME/.ssh/authorized_keys"

[ "${ENABLE_REMOTE_SSHD:-yes}" = "yes" ] || { rlog "Skipped remote sshd changes."; exit 0; }

SUDO=""
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  SUDO="sudo"
else
  rwarn "No root/passwordless sudo. Remote sshd config not changed."
  exit 0
fi

backup_file(){ [ -f "$1" ] && $SUDO cp "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; }

restart_sshd(){
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl restart ssh 2>/dev/null || $SUDO systemctl restart sshd 2>/dev/null || true
  elif command -v service >/dev/null 2>&1; then
    $SUDO service ssh restart 2>/dev/null || $SUDO service sshd restart 2>/dev/null || true
  elif [ "$OS" = "macos" ]; then
    $SUDO launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
  fi
}

validate_sshd(){
  if command -v sshd >/dev/null 2>&1; then
    $SUDO sshd -t
  elif [ -x /usr/sbin/sshd ]; then
    $SUDO /usr/sbin/sshd -t
  else
    rwarn "sshd command not found; cannot validate config."
  fi
}

if [ -d /etc/ssh/sshd_config.d ] && [ "$OS" != "macos" ]; then
  DROPIN=/etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf
  $SUDO sh -c "cat > '$DROPIN'" <<EOF
# Managed by ssh-onekey-universal.sh
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
EOF
  rlog "Wrote sshd drop-in: $DROPIN"
elif [ -f /etc/ssh/sshd_config ]; then
  CFG=/etc/ssh/sshd_config
  backup_file "$CFG"
  TMP="$(mktemp)"
  $SUDO awk '
    /^[#[:space:]]*PubkeyAuthentication[[:space:]]/ { next }
    /^[#[:space:]]*AuthorizedKeysFile[[:space:]]/ { next }
    { print }
  ' "$CFG" > "$TMP"
  {
    cat "$TMP"
    printf '\n# Managed by ssh-onekey-universal.sh\n'
    printf 'PubkeyAuthentication yes\n'
    printf 'AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2\n'
  } | $SUDO tee "$CFG" >/dev/null
  rm -f "$TMP"
  rlog "Updated sshd_config: $CFG"
else
  rwarn "No sshd_config found."
  exit 0
fi

if [ "$OS" = "macos" ] && command -v systemsetup >/dev/null 2>&1; then
  $SUDO systemsetup -setremotelogin on >/dev/null 2>&1 || true
fi

validate_sshd
restart_sshd
rlog "Remote sshd public-key login is enabled/restarted when possible."
REMOTE_SCRIPT
  ok "Remote setup finished."
fi

CONFIG_FILE="$HOME/.ssh/config"
BACKUP_FILE=""
if [ -f "$CONFIG_FILE" ]; then
  BACKUP_FILE="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP_FILE"
fi

TMP_CONFIG="$(mktemp)"
if [ -f "$CONFIG_FILE" ]; then
  awk -v host="$HOST_ALIAS" '
    BEGIN { skip=0 }
    /^[[:space:]]*Host[[:space:]]+/ {
      skip=0
      for (i=2; i<=NF; i++) if ($i == host) { skip=1; break }
    }
    skip == 0 { print }
  ' "$CONFIG_FILE" > "$TMP_CONFIG"
else
  : > "$TMP_CONFIG"
fi

IDENTITY_FOR_CONFIG="$KEY_PATH"
case "$KEY_PATH" in "$HOME"/*) IDENTITY_FOR_CONFIG="~/${KEY_PATH#"$HOME"/}";; esac

{
  sed -e '${/^$/d;}' "$TMP_CONFIG"
  printf '\n\nHost %s\n' "$HOST_ALIAS"
  printf '    HostName %s\n' "$HOSTNAME"
  printf '    User %s\n' "$REMOTE_USER"
  printf '    Port %s\n' "$SSH_PORT"
  printf '    IdentityFile %s\n' "$IDENTITY_FOR_CONFIG"
  printf '    IdentitiesOnly yes\n'
} > "$CONFIG_FILE"
rm -f "$TMP_CONFIG"
chmod 600 "$CONFIG_FILE"
[ -z "$BACKUP_FILE" ] || ok "Backed up old SSH config: $BACKUP_FILE"
ok "Wrote local SSH config: $CONFIG_FILE"

log "Testing key-only login: ssh $HOST_ALIAS true"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST_ALIAS" true >/dev/null 2>&1; then
  ok "Success. Connect with: ssh $HOST_ALIAS"
else
  warn "Config written, but key-only test failed. Debug with: ssh -vvv $HOST_ALIAS"
  warn "Common causes: wrong remote user, root login policy, sshd restart failed, authorized_keys permission/path."
  exit 2
fi

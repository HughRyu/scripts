#!/usr/bin/env bash
set -euo pipefail

# Universal SSH one-key setup for macOS/Linux clients and mostly Ubuntu/Linux targets.
#
# Safe with: curl -fsSL URL | bash
#
# What it does:
# 1) Create/reuse a local SSH key
# 2) Automatically clear stale Host Keys if the remote OS was reinstalled
# 3) Install the public key into remote ~/.ssh/authorized_keys
# 4) If remote is root or passwordless sudo is available, enable sshd public-key login
# 5) Replace any existing local ~/.ssh/config Host stanza with the same alias
# 6) Test key-only login
#
# Manual mode:
#   -m, --manual
#   Do not connect to the remote host. Print a one-line command that can be copied
#   to the target machine and executed manually.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log(){ printf "%b\n" "${BLUE}==>${NC} $*"; }
ok(){ printf "%b\n" "${GREEN}OK:${NC} $*"; }
warn(){ printf "%b\n" "${YELLOW}WARN:${NC} $*"; }
err(){ printf "%b\n" "${RED}ERROR:${NC} $*" >&2; }

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

SSH_HOSTKEY_OPTS=()
SSH_CONFIG_HOSTKEY_MODE="accept-new"

init_ssh_hostkey_opts(){
  local mode="accept-new"
  if ssh -G -o "StrictHostKeyChecking=$mode" ssh-onekey.invalid >/dev/null 2>&1; then
    SSH_CONFIG_HOSTKEY_MODE="$mode"
  elif ssh -G -o StrictHostKeyChecking=no ssh-onekey.invalid >/dev/null 2>&1; then
    SSH_CONFIG_HOSTKEY_MODE="no"
    warn "This ssh client does not support StrictHostKeyChecking=accept-new; falling back to no."
  else
    err "Unsupported StrictHostKeyChecking mode: $mode"
    exit 1
  fi

  SSH_HOSTKEY_OPTS=(
    -o "StrictHostKeyChecking=$SSH_CONFIG_HOSTKEY_MODE"
    -o "UserKnownHostsFile=$HOME/.ssh/known_hosts"
    -o "LogLevel=ERROR"
  )
}

TMP_FILES=""
TMP_BASE="${TMPDIR:-/tmp}"

cleanup(){
  local f
  for f in $TMP_FILES; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM HUP

cleanup_stale_temps(){
  local user
  user="$(id -un 2>/dev/null || true)"
  if [ -n "$user" ]; then
    find "$TMP_BASE" -maxdepth 1 -type f -name 'ssh-onekey.*' -user "$user" -exec rm -f {} \; 2>/dev/null || true
  else
    find "$TMP_BASE" -maxdepth 1 -type f -name 'ssh-onekey.*' -exec rm -f {} \; 2>/dev/null || true
  fi
}

make_tmp(){
  local t
  t="$(mktemp "${TMP_BASE%/}/ssh-onekey.XXXXXX")"
  TMP_FILES="${TMP_FILES:+$TMP_FILES }$t"
  printf '%s' "$t"
}

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
  cat <<'EOF_USAGE'
Usage:
  ssh-onekey-universal.sh [options]

Options:
  --host <alias>              Local SSH alias, e.g. dev
  --hostname <ip/host>        Remote host/IP, e.g. 192.168.199.8
  --user <user>               Remote SSH user, e.g. root
  -p, --port <port>           Remote SSH port, default 22
  --key <path>                Local private key path, e.g. ~/.ssh/id_ed25519_dev
  --key-dir <dir>             Directory for default key path, default ~/.ssh
  --comment <comment>         New key comment
  -m, --manual                Do not connect remote host; print one-line command only
  --no-install-key            Only write local SSH config; do not install remote key
  --no-enable-remote-sshd     Do not modify remote sshd config
  --help, -h                  Show help
EOF_USAGE
}

require_arg(){
  [ -n "${2:-}" ] || { err "Option $1 requires a value."; usage; exit 1; }
}

validate_port(){
  case "$1" in ''|*[!0-9]*) err "Invalid SSH port: $1"; exit 1;; esac
  if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
    err "Invalid SSH port: $1 (expected 1-65535)"
    exit 1
  fi
}

validate_host_alias(){
  case "$1" in
    ''|*[[:space:]]*) err "Invalid SSH alias: '$1'"; exit 1;;
    '*'*|'?'*) err "SSH alias must be a literal name, not a wildcard pattern: '$1'"; exit 1;;
  esac
}

shell_quote(){
  # Print a POSIX shell single-quoted string.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

print_manual_command(){
  local pub_key="$1"
  local enable_remote_sshd="$2"
  local q_pub_key
  q_pub_key="$(shell_quote "$pub_key")"

  cat <<EOF

============================================================
Manual mode enabled: this script did NOT connect to remote.
Copy the following ONE-LINE command to the target machine and run it:
============================================================

EOF

  if [ "$enable_remote_sshd" = "yes" ]; then
    printf "bash -c %s\n" "$(shell_quote "set -e; mkdir -p \"\$HOME/.ssh\"; chmod 700 \"\$HOME/.ssh\"; touch \"\$HOME/.ssh/authorized_keys\"; chmod 600 \"\$HOME/.ssh/authorized_keys\"; grep -qxF $q_pub_key \"\$HOME/.ssh/authorized_keys\" || printf '%s\\n' $q_pub_key >> \"\$HOME/.ssh/authorized_keys\"; if command -v id >/dev/null 2>&1; then chown -R \"\$(id -un):\$(id -gn)\" \"\$HOME/.ssh\" 2>/dev/null || true; fi; if [ \"\$(id -u)\" -eq 0 ]; then if [ -d /etc/ssh/sshd_config.d ]; then printf '%s\\n' '# Managed by ssh-onekey-universal.sh' 'PubkeyAuthentication yes' 'AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2' > /etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf; elif [ -f /etc/ssh/sshd_config ]; then cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.\$(date +%Y%m%d%H%M%S); awk '!/^[#[:space:]]*PubkeyAuthentication[[:space:]]/ && !/^[#[:space:]]*AuthorizedKeysFile[[:space:]]/' /etc/ssh/sshd_config > /tmp/ssh-onekey-sshd.$$; { cat /tmp/ssh-onekey-sshd.$$; printf '\\n# Managed by ssh-onekey-universal.sh\\nPubkeyAuthentication yes\\nAuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2\\n'; } > /etc/ssh/sshd_config; rm -f /tmp/ssh-onekey-sshd.$$; fi; if command -v sshd >/dev/null 2>&1; then sshd -t; elif [ -x /usr/sbin/sshd ]; then /usr/sbin/sshd -t; fi; if command -v systemctl >/dev/null 2>&1; then systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true; elif command -v service >/dev/null 2>&1; then service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true; fi; fi; echo 'SSH public key installed.'")"
  else
    printf "bash -c %s\n" "$(shell_quote "set -e; mkdir -p \"\$HOME/.ssh\"; chmod 700 \"\$HOME/.ssh\"; touch \"\$HOME/.ssh/authorized_keys\"; chmod 600 \"\$HOME/.ssh/authorized_keys\"; grep -qxF $q_pub_key \"\$HOME/.ssh/authorized_keys\" || printf '%s\\n' $q_pub_key >> \"\$HOME/.ssh/authorized_keys\"; if command -v id >/dev/null 2>&1; then chown -R \"\$(id -un):\$(id -gn)\" \"\$HOME/.ssh\" 2>/dev/null || true; fi; echo 'SSH public key installed.'")"
  fi

  cat <<EOF

============================================================
After running it on the target machine, connect from this machine with:

  ssh $HOST_ALIAS

EOF
}

HOST_ALIAS=""
HOSTNAME=""
REMOTE_USER=""
SSH_PORT=""
KEY_PATH=""
KEY_DIR="${SSH_ONEKEY_KEY_DIR:-$HOME/.ssh}"
KEY_COMMENT=""
INSTALL_KEY="yes"
ENABLE_REMOTE_SSHD="yes"
MANUAL_MODE="no"

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
need_cmd find

cleanup_stale_temps

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
init_ssh_hostkey_opts

[ -n "$HOST_ALIAS" ] || prompt HOST_ALIAS "SSH alias / Host"
[ -n "$HOSTNAME" ] || prompt HOSTNAME "Remote hostname/IP"
[ -n "$REMOTE_USER" ] || prompt REMOTE_USER "Remote SSH user" "root"
[ -n "$SSH_PORT" ] || prompt SSH_PORT "Remote SSH port" "22"

validate_host_alias "$HOST_ALIAS"
validate_port "$SSH_PORT"

# Clean local known_hosts entries to avoid host-identification-changed blocking.
log "Checking for stale host keys in known_hosts..."
if ssh-keygen -F "$HOSTNAME" >/dev/null 2>&1 || ssh-keygen -F "[$HOSTNAME]:$SSH_PORT" >/dev/null 2>&1 || ssh-keygen -F "$HOST_ALIAS" >/dev/null 2>&1; then
  warn "Detected existing host key signatures. Cleaning up to prevent 'Host identification changed' errors..."
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$HOSTNAME" >/dev/null 2>&1 || true
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "[$HOSTNAME]:$SSH_PORT" >/dev/null 2>&1 || true
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$HOST_ALIAS" >/dev/null 2>&1 || true
  ok "Stale host keys cleared from known_hosts."
fi

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
  PUB_KEY_CONTENT="$(cat "$PUB_PATH")"
  ESCAPED_PUB_KEY="$(printf '%s' "$PUB_KEY_CONTENT" | sed "s/'/'\\''/g")"

  if [ "$MANUAL_MODE" = "yes" ]; then
    print_manual_command "$PUB_KEY_CONTENT" "$ENABLE_REMOTE_SSHD"
  else
    log "Installing public key on remote. Password may be required once."
    ssh -T -p "$SSH_PORT" \
      "${SSH_HOSTKEY_OPTS[@]}" \
      -o PreferredAuthentications=password,keyboard-interactive,publickey \
      -o PubkeyAuthentication=yes \
      "${REMOTE_USER}@${HOSTNAME}" \
      "PUB_KEY='$ESCAPED_PUB_KEY' ENABLE_REMOTE_SSHD='$ENABLE_REMOTE_SSHD' REMOTE_USER_NAME='$REMOTE_USER' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

rlog(){ printf '%s\n' "==> $*"; }
rwarn(){ printf '%s\n' "WARN: $*"; }

REMOTE_TMP_FILES=""
REMOTE_TMP_BASE="${TMPDIR:-/tmp}"
remote_cleanup(){
  local f
  for f in $REMOTE_TMP_FILES; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done
}
trap remote_cleanup EXIT INT TERM HUP

remote_cleanup_stale(){
  local user
  user="$(id -un 2>/dev/null || true)"
  if [ -n "$user" ]; then
    find "$REMOTE_TMP_BASE" -maxdepth 1 -type f -name 'ssh-onekey.remote.*' -user "$user" -exec rm -f {} \; 2>/dev/null || true
  else
    find "$REMOTE_TMP_BASE" -maxdepth 1 -type f -name 'ssh-onekey.remote.*' -exec rm -f {} \; 2>/dev/null || true
  fi
}

remote_mktemp(){
  local t
  t="$(mktemp "${REMOTE_TMP_BASE%/}/ssh-onekey.remote.XXXXXX")"
  REMOTE_TMP_FILES="${REMOTE_TMP_FILES:+$REMOTE_TMP_FILES }$t"
  printf '%s' "$t"
}

OS_FAMILY="unknown"
OS_ID="unknown"
UNAME_S="$(uname -s 2>/dev/null || true)"
case "$UNAME_S" in
  Darwin) OS_FAMILY="macos"; OS_ID="macos";;
  Linux) OS_FAMILY="linux";;
esac
if [ "$OS_FAMILY" = "linux" ] && [ -s /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
fi

remote_cleanup_stale

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

if [ "${ENABLE_REMOTE_SSHD:-yes}" != "yes" ]; then
  rlog "Skipped remote sshd changes."
  exit 0
fi

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

sshd_bin(){
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
  elif [ -x /usr/sbin/sshd ]; then
    printf '%s\n' /usr/sbin/sshd
  else
    return 1
  fi
}

restart_sshd(){
  if [ "$OS_FAMILY" = "macos" ]; then
    $SUDO systemsetup -setremotelogin on >/dev/null 2>&1 || true
    $SUDO launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
  elif command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl restart ssh 2>/dev/null || $SUDO systemctl restart sshd 2>/dev/null || true
  elif command -v service >/dev/null 2>&1; then
    $SUDO service ssh restart 2>/dev/null || $SUDO service sshd restart 2>/dev/null || true
  fi
}

validate_sshd(){
  local bin
  if bin="$(sshd_bin)"; then
    $SUDO "$bin" -t
  else
    rwarn "sshd command not found; cannot validate config."
  fi
}

write_sshd_dropin(){
  local dropin=/etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf
  $SUDO sh -c "cat > '$dropin'" <<EOF_DROPIN
# Managed by ssh-onekey-universal.sh
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
EOF_DROPIN
  rlog "Wrote sshd drop-in: $dropin"
}

update_sshd_config(){
  local cfg=/etc/ssh/sshd_config tmp
  backup_file "$cfg"
  tmp="$(remote_mktemp)"
  $SUDO awk '
    !/^[#[:space:]]*PubkeyAuthentication[[:space:]]/ &&
    !/^[#[:space:]]*AuthorizedKeysFile[[:space:]]/
  ' "$cfg" > "$tmp"
  {
    cat "$tmp"
    printf '\n# Managed by ssh-onekey-universal.sh\n'
    printf 'PubkeyAuthentication yes\n'
    printf 'AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2\n'
  } | $SUDO tee "$cfg" >/dev/null
  rlog "Updated sshd_config: $cfg"
}

if [ "$OS_FAMILY" = "linux" ] && [ -d /etc/ssh/sshd_config.d ]; then
  write_sshd_dropin
elif [ -f /etc/ssh/sshd_config ]; then
  update_sshd_config
else
  rwarn "No sshd_config found."
  exit 0
fi

validate_sshd
restart_sshd
rlog "Remote sshd public-key login is enabled/restarted when possible."
REMOTE_SCRIPT
    ok "Remote setup finished."
  fi
fi

CONFIG_FILE="$HOME/.ssh/config"
BACKUP_FILE=""
if [ -f "$CONFIG_FILE" ]; then
  BACKUP_FILE="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP_FILE"
fi

TMP_CONFIG="$(make_tmp)"
if [ -f "$CONFIG_FILE" ]; then
  awk -v host="$HOST_ALIAS" '
    function stanza_has_host(    i) {
      for (i=2; i<=NF; i++) if ($i == host) return 1
      return 0
    }
    /^[[:space:]]*Host[[:space:]]+/ {
      skip = stanza_has_host() ? 1 : 0
      if (skip) next
    }
    /^[[:space:]]*Match[[:space:]]+/ { skip = 0 }
    skip == 0 { print }
  ' "$CONFIG_FILE" > "$TMP_CONFIG"
else
  : > "$TMP_CONFIG"
fi

IDENTITY_FOR_CONFIG="$KEY_PATH"
case "$KEY_PATH" in
  "$HOME"/*) IDENTITY_FOR_CONFIG="~/${KEY_PATH#"$HOME"/}";;
esac

awk 'NF { line[NR]=$0; last=NR } END { for (i=1; i<=last; i++) print line[i] }' "$TMP_CONFIG" > "$TMP_CONFIG.trimmed"
TMP_FILES="$TMP_FILES $TMP_CONFIG.trimmed"

{
  cat "$TMP_CONFIG.trimmed"
  printf '\n\nHost %s\n' "$HOST_ALIAS"
  printf '    HostName %s\n' "$HOSTNAME"
  printf '    User %s\n' "$REMOTE_USER"
  printf '    Port %s\n' "$SSH_PORT"
  printf '    IdentityFile %s\n' "$IDENTITY_FOR_CONFIG"
  printf '    IdentitiesOnly yes\n'
  printf '    StrictHostKeyChecking %s\n' "$SSH_CONFIG_HOSTKEY_MODE"
  printf '    UserKnownHostsFile ~/.ssh/known_hosts\n'
  printf '    LogLevel ERROR\n'
} > "$TMP_CONFIG.new"
TMP_FILES="$TMP_FILES $TMP_CONFIG.new"

if ssh -G -F "$TMP_CONFIG.new" "$HOST_ALIAS" >/dev/null 2>&1; then
  :
elif ssh -F "$TMP_CONFIG.new" -o BatchMode=yes -G "$HOST_ALIAS" >/dev/null 2>&1; then
  :
else
  warn "Could not pre-validate SSH config with ssh -G; writing anyway."
fi

mv "$TMP_CONFIG.new" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
[ -z "$BACKUP_FILE" ] || ok "Backed up old SSH config: $BACKUP_FILE"
ok "Wrote local SSH config: $CONFIG_FILE (replaced existing Host $HOST_ALIAS if present)"

if [ "$MANUAL_MODE" = "yes" ]; then
  ok "Manual mode finished. Remote command was printed above; key-only login test was skipped."
  exit 0
fi

log "Testing key-only login: ssh $HOST_ALIAS true"
if ssh "${SSH_HOSTKEY_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "$HOST_ALIAS" true >/dev/null 2>&1; then
  ok "Success. Connect with: ssh $HOST_ALIAS"
else
  warn "Config written, but key-only test failed. Debug with: ssh -vvv $HOST_ALIAS"
  exit 2
fi

#!/usr/bin/env bash
set -euo pipefail

# SSH OneKey Setup - optimized manual mode
# - default: generate/reuse local key, write local ssh config, install key to remote via ssh, test login
# - -m/--manual: generate/reuse local key, write local ssh config, print safe multi-line commands for target host, no remote connection, no login test

log(){ printf '%s\n' "==> $*"; }
ok(){ printf '%s\n' "OK: $*"; }
warn(){ printf '%s\n' "WARN: $*"; }
err(){ printf '%s\n' "ERROR: $*" >&2; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

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
  -m, --manual                Do not connect to remote; print copy-paste commands only
  --no-install-key            Only write local SSH config; do not install remote key
  --no-enable-remote-sshd     Do not print/apply sshd config changes
  -h, --help                  Show help
EOF
}

require_arg(){ [ -n "${2:-}" ] || { err "Option $1 requires a value"; usage; exit 1; }; }

read_tty(){
  local prompt_text="$1" value=""
  if [ -r /dev/tty ]; then
    read -r -p "$prompt_text" value </dev/tty
  else
    err "No TTY available. Please provide required options."
    exit 1
  fi
  printf '%s' "$value"
}

prompt_required(){
  local var_name="$1" label="$2" value=""
  while true; do
    value="$(read_tty "$label: ")"
    [ -n "$value" ] && break
    warn "Value cannot be empty."
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_default(){
  local var_name="$1" label="$2" default_value="$3" value=""
  value="$(read_tty "$label [$default_value]: ")"
  value="${value:-$default_value}"
  printf -v "$var_name" '%s' "$value"
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

shell_quote(){
  # Quote one string for POSIX shell.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

write_local_config(){
  local config_file="$HOME/.ssh/config"
  local tmp old backup identity
  tmp="$(mktemp "${TMPDIR:-/tmp}/ssh-onekey-config.XXXXXX")"
  old="$(mktemp "${TMPDIR:-/tmp}/ssh-onekey-config-old.XXXXXX")"
  trap 'rm -f "$tmp" "$old"' RETURN

  if [ -f "$config_file" ]; then
    backup="$config_file.bak.$(date +%Y%m%d%H%M%S)"
    cp "$config_file" "$backup"
    awk -v host="$HOST_ALIAS" '
      function has_host(    i) {
        for (i=2; i<=NF; i++) if ($i == host) return 1
        return 0
      }
      /^[[:space:]]*Host[[:space:]]+/ {
        skip = has_host() ? 1 : 0
        if (skip) next
      }
      /^[[:space:]]*Match[[:space:]]+/ { skip = 0 }
      skip == 0 { print }
    ' "$config_file" > "$old"
    ok "Backed up old SSH config: $backup"
  else
    : > "$old"
  fi

  identity="$KEY_PATH"
  case "$identity" in "$HOME"/*) identity="~/${identity#"$HOME"/}";; esac

  awk 'NF { line[NR]=$0; last=NR } END { for (i=1; i<=last; i++) print line[i] }' "$old" > "$tmp"
  {
    cat "$tmp"
    printf '\n\nHost %s\n' "$HOST_ALIAS"
    printf '    HostName %s\n' "$HOSTNAME"
    printf '    User %s\n' "$REMOTE_USER"
    printf '    Port %s\n' "$SSH_PORT"
    printf '    IdentityFile %s\n' "$identity"
    printf '    IdentitiesOnly yes\n'
    printf '    StrictHostKeyChecking accept-new\n'
    printf '    UserKnownHostsFile ~/.ssh/known_hosts\n'
    printf '    LogLevel ERROR\n'
  } > "$config_file"
  chmod 600 "$config_file"
  ok "Wrote local SSH config: $config_file"
}

print_manual_commands(){
  local pub_key="$1"
  cat <<EOF

============================================================
Manual mode: this script did NOT connect to the remote host.
Copy and run the following block ON THE TARGET MACHINE:
============================================================

mkdir -p ~/.ssh
chmod 700 ~/.ssh

grep -qxF '$pub_key' ~/.ssh/authorized_keys 2>/dev/null || cat >> ~/.ssh/authorized_keys <<'KEYEOF'
$pub_key
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
}

install_remote(){
  local pub_key="$1" escaped
  escaped="$(printf '%s' "$pub_key" | sed "s/'/'\\''/g")"
  log "Installing public key on remote. Password may be required once."
  ssh -T -p "$SSH_PORT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
    -o PreferredAuthentications=password,keyboard-interactive,publickey \
    -o PubkeyAuthentication=yes \
    "${REMOTE_USER}@${HOSTNAME}" \
    "PUB_KEY='$escaped' ENABLE_REMOTE_SSHD='$ENABLE_REMOTE_SSHD' bash -s" <<'REMOTE'
set -euo pipefail
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
grep -qxF "$PUB_KEY" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$PUB_KEY" >> "$HOME/.ssh/authorized_keys"
chown -R "$(id -un):$(id -gn)" "$HOME/.ssh" 2>/dev/null || true

if [ "${ENABLE_REMOTE_SSHD:-yes}" = "yes" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf <<'SSHEOF'
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
SSHEOF
    if command -v sshd >/dev/null 2>&1; then sshd -t; elif [ -x /usr/sbin/sshd ]; then /usr/sbin/sshd -t; fi
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo mkdir -p /etc/ssh/sshd_config.d
    printf '%s\n' 'PubkeyAuthentication yes' 'AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2' | sudo tee /etc/ssh/sshd_config.d/99-ssh-onekey-pubkey.conf >/dev/null
    if command -v sshd >/dev/null 2>&1; then sudo sshd -t; elif [ -x /usr/sbin/sshd ]; then sudo /usr/sbin/sshd -t; fi
    sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || sudo service ssh restart 2>/dev/null || sudo service sshd restart 2>/dev/null || true
  fi
fi
printf '%s\n' 'SSH public key installed.'
REMOTE
  ok "Remote setup finished."
}

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
[ -n "$REMOTE_USER" ] || prompt_default REMOTE_USER "Remote SSH user" "root"
[ -n "$SSH_PORT" ] || prompt_default SSH_PORT "Remote SSH port" "22"

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
write_local_config

if [ "$INSTALL_KEY" = "yes" ]; then
  if [ "$MANUAL_MODE" = "yes" ]; then
    print_manual_commands "$PUB_KEY"
    ok "Manual mode finished. Key-only login test skipped."
    exit 0
  else
    install_remote "$PUB_KEY"
  fi
fi

log "Testing key-only login: ssh $HOST_ALIAS true"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST_ALIAS" true >/dev/null 2>&1; then
  ok "Success. Connect with: ssh $HOST_ALIAS"
else
  warn "Config written, but key-only test failed. Debug with: ssh -vvv $HOST_ALIAS"
  exit 2
fi

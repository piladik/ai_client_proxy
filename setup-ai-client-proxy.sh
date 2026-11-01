#!/usr/bin/env bash
# Install and maintain a loopback-only sing-box proxy reached through SSH.
set -Eeuo pipefail

readonly APP_NAME="ai-client-proxy"
readonly CONFIG_DIR="/etc/${APP_NAME}"
readonly CREDENTIALS_FILE="${CONFIG_DIR}/credentials"
readonly SING_BOX_CONFIG="/etc/sing-box/config.json"
readonly KEYRING="/usr/share/keyrings/sing-box.gpg"
readonly APT_SOURCE="/etc/apt/sources.list.d/sing-box.list"

SSH_USER=""
SSH_PORT=22
PROXY_PORT=1080
ROTATE_PASSWORD=false
SKIP_FIREWALL=false
PRINT_PASSWORD=false
SOURCE_AUTHORIZED_KEYS=""
declare -a AUTHORIZED_KEYS=()

usage() {
  cat <<'EOF'
Usage: setup-ai-client-proxy.sh --ssh-user NAME [options]

Install a loopback-only sing-box HTTP/SOCKS proxy and an SSH tunnel user.
The existing authorized SSH keys of the administrative user are copied to NAME.

Required:
  --ssh-user NAME       SSH user to create and HTTP/SOCKS proxy login.

Options:
  --ssh-port PORT       SSH daemon port to allow through UFW (default: 22).
  --proxy-port PORT     Local sing-box proxy port (default: 1080).
  --rotate-password     Generate and apply a new proxy password.
  --skip-firewall       Do not alter UFW rules.
  --print-password      Print the saved password on an interactive repeat run.
  -h, --help            Show this help message.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf 'Error: installation failed at line %s (exit code %s).\n' "$1" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_value() {
  [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-user)
      require_value "$1" "${2:-}"
      SSH_USER=$2
      shift 2
      ;;
    --ssh-port)
      require_value "$1" "${2:-}"
      SSH_PORT=$2
      shift 2
      ;;
    --proxy-port)
      require_value "$1" "${2:-}"
      PROXY_PORT=$2
      shift 2
      ;;
    --rotate-password)
      ROTATE_PASSWORD=true
      shift
      ;;
    --skip-firewall)
      SKIP_FIREWALL=true
      shift
      ;;
    --print-password)
      PRINT_PASSWORD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown argument: $1. Use --help for usage." ;;
  esac
done

validate_port() {
  local name=$1 port=$2
  if [[ ! $port =~ ^[0-9]+$ ]]; then
    die "$name must be an integer between 1 and 65535."
  fi
  if (( port < 1 || port > 65535 )); then
    die "$name must be an integer between 1 and 65535."
  fi
}

validate_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == "ubuntu" && ( ${VERSION_ID:-} == "22.04" || ${VERSION_ID:-} == "24.04" ) ]] || die "Only Ubuntu 22.04 and 24.04 are supported."
}

determine_key_source() {
  local source_user source_home
  if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
    source_user=$SUDO_USER
    source_home=$(getent passwd "$source_user" | cut -d: -f6)
    [[ -n $source_home ]] || die "Cannot determine the home directory for $source_user."
    SOURCE_AUTHORIZED_KEYS="${source_home}/.ssh/authorized_keys"
  else
    SOURCE_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
  fi
}

load_authorized_keys() {
  local line
  [[ -r $SOURCE_AUTHORIZED_KEYS ]] || die "Cannot read administrative authorized_keys: $SOURCE_AUTHORIZED_KEYS"

  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    if ssh-keygen -l -f <(printf '%s\n' "$line") >/dev/null 2>&1; then
      AUTHORIZED_KEYS+=("$line")
    fi
  done < "$SOURCE_AUTHORIZED_KEYS"

  (( ${#AUTHORIZED_KEYS[@]} > 0 )) || die "No valid public SSH keys found in $SOURCE_AUTHORIZED_KEYS."
}

port_is_available() {
  local listeners
  listeners=$(ss -lntp "sport = :${PROXY_PORT}" 2>/dev/null || true)
  [[ $listeners != *":${PROXY_PORT}"* ]] && return 0

  # A running managed sing-box service already owns this port on repeat runs.
  if [[ -f $SING_BOX_CONFIG ]] && systemctl is-active --quiet sing-box && [[ $listeners == *"sing-box"* ]]; then
    return 0
  fi
  die "Proxy port ${PROXY_PORT} is already in use."
}

validate_prerequisites() {
  [[ $EUID -eq 0 ]] || die "Run this script as root or through sudo."
  [[ -n $SSH_USER ]] || die "--ssh-user is required."
  [[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*[$]?$ && ${#SSH_USER} -le 32 && $SSH_USER != "root" ]] || die "--ssh-user must be a valid non-root Linux username."
  validate_port "--ssh-port" "$SSH_PORT"
  validate_port "--proxy-port" "$PROXY_PORT"
  command -v ssh-keygen >/dev/null || die "ssh-keygen is required to validate authorized_keys."
  command -v ss >/dev/null || die "ss is required to check the proxy port."
  validate_os
  determine_key_source
  load_authorized_keys
  port_is_available
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl gnupg openssl ca-certificates
}

install_sing_box() {
  local key_tmp
  key_tmp=$(mktemp)
  curl -fsSL https://sing-box.app/gpg.key | gpg --dearmor --batch --yes -o "$key_tmp"
  install -m 0644 "$key_tmp" "$KEYRING"
  rm -f "$key_tmp"
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/sing-box.gpg] https://deb.sagernet.org/ * *' > "$APT_SOURCE"
  apt-get update
  apt-get install -y sing-box
  command -v sing-box >/dev/null || die "sing-box installation did not provide a binary."
}

create_ssh_user() {
  local home group
  if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$SSH_USER"
  fi
  home=$(getent passwd "$SSH_USER" | cut -d: -f6)
  [[ -n $home && -d $home ]] || die "Cannot determine the home directory for $SSH_USER."
  group=$(id -gn "$SSH_USER")
  install -d -m 0700 -o "$SSH_USER" -g "$group" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  chown "$SSH_USER:$group" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"

  for key in "${AUTHORIZED_KEYS[@]}"; do
    grep -Fqx -- "$key" "$home/.ssh/authorized_keys" || printf '%s\n' "$key" >> "$home/.ssh/authorized_keys"
  done
}

read_or_create_password() {
  local password=""
  if [[ -f $CREDENTIALS_FILE && $ROTATE_PASSWORD == false ]]; then
    password=$(awk -F= '$1 == "PROXY_PASSWORD" { print $2 }' "$CREDENTIALS_FILE")
    [[ $password =~ ^[0-9a-f]{64}$ || $password =~ ^[0-9a-f]{128}$ ]] || die "Existing credentials file is invalid: $CREDENTIALS_FILE"
    printf '%s' "$password"
    return
  fi

  password=$(openssl rand -hex 32)
  install -d -m 0700 -o root -g root "$CONFIG_DIR"
  umask 077
  printf 'PROXY_PASSWORD=%s\n' "$password" > "$CREDENTIALS_FILE"
  chown root:root "$CREDENTIALS_FILE"
  chmod 0600 "$CREDENTIALS_FILE"
  printf '%s' "$password"
}

write_sing_box_config() {
  local password=$1 config_tmp
  config_tmp=$(mktemp)
  cat > "$config_tmp" <<EOF
{
  "inbounds": [
    {
      "type": "mixed",
      "tag": "ai-client-proxy",
      "listen": "127.0.0.1",
      "listen_port": ${PROXY_PORT},
      "users": [
        {
          "username": "${SSH_USER}",
          "password": "${password}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  sing-box check -c "$config_tmp"
  install -m 0600 -o root -g root "$config_tmp" "$SING_BOX_CONFIG"
  rm -f "$config_tmp"
}

configure_firewall() {
  [[ $SKIP_FIREWALL == true ]] && return
  apt-get install -y ufw
  ufw allow "${SSH_PORT}/tcp"
}

wait_for_listener() {
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if ss -lnt "sport = :${PROXY_PORT}" | grep -Fq ":${PROXY_PORT}"; then
      return 0
    fi
    sleep 0.5
  done
  die "sing-box did not open proxy port ${PROXY_PORT} within 15 seconds."
}

verify_loopback_listener() {
  local listeners
  listeners=$(ss -lnt "sport = :${PROXY_PORT}")
  [[ $listeners == *"127.0.0.1:${PROXY_PORT}"* ]] || die "sing-box is not listening on 127.0.0.1:${PROXY_PORT}."
  [[ $listeners != *"0.0.0.0:${PROXY_PORT}"* && $listeners != *"[::]:${PROXY_PORT}"* ]] || die "Proxy port ${PROXY_PORT} is exposed beyond loopback."
}

print_summary() {
  local password=$1 show_password=$2
  printf '\n============================================================\n'
  printf ' AI Client Proxy: installation complete\n'
  printf '============================================================\n'
  printf '\n[ PROXY CREDENTIALS ]\n'
  printf 'Username: %s\nLocal address: 127.0.0.1:%s\n' "$SSH_USER" "$PROXY_PORT"
  if [[ $show_password == true ]]; then
    printf 'Proxy password: %s\n' "$password"
  else
    printf 'Proxy password: not shown on a normal repeat run.\n'
    printf 'Show it interactively: sudo bash setup-ai-client-proxy.sh --ssh-user %s --print-password\n' "$SSH_USER"
  fi

  printf '\n[ COPY: SSH CLIENT CONFIG ]\n'
  cat <<EOF
Host ai-client-proxy
    HostName SERVER_IP
    User ${SSH_USER}
    IdentityFile ~/.ssh/YOUR_PRIVATE_KEY
    IdentitiesOnly yes
    LocalForward 127.0.0.1:${PROXY_PORT} 127.0.0.1:${PROXY_PORT}
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes

EOF

  printf '\n[ START SSH TUNNEL ]\n'
  printf 'ssh -N ai-client-proxy\n'

  if [[ $show_password == true ]]; then
    printf '\n[ COPY: UNIVERSAL CLIENT WRAPPER ]\n'
    cat <<EOF
ai-proxy() {
  HTTPS_PROXY='http://${SSH_USER}:${password}@127.0.0.1:${PROXY_PORT}' \\
  HTTP_PROXY='http://${SSH_USER}:${password}@127.0.0.1:${PROXY_PORT}' \\
  NO_PROXY='localhost,127.0.0.1,::1' \\
  "\$@"
}
EOF
    printf '\nAdd the function to ~/.zshrc or ~/.bashrc, then reload the shell.\n'
    printf 'Verified clients: OpenCode and Codex.\n'
    printf 'Examples: ai-proxy opencode\n          ai-proxy codex\n'
    printf '\n[ VERIFY PROXY ]\n'
    printf "curl --proxy 'http://%s:%s@127.0.0.1:%s' https://api.ipify.org\n" "$SSH_USER" "$password" "$PROXY_PORT"
  else
    printf '\n[ UNIVERSAL CLIENT WRAPPER ]\n'
    printf 'Use --print-password to display the copyable ai-proxy function.\n'
  fi

  printf '\n[ SERVER DIAGNOSTICS ]\n'
  printf 'Configuration: %s\nJournal:       journalctl -u sing-box\n' "$SING_BOX_CONFIG"
  printf '============================================================\n'
}

main() {
  local password first_install=false show_password=false
  validate_prerequisites
  [[ ! -f $CREDENTIALS_FILE || $ROTATE_PASSWORD == true ]] && first_install=true
  install_dependencies
  install_sing_box
  create_ssh_user
  password=$(read_or_create_password)
  write_sing_box_config "$password"
  configure_firewall
  systemctl enable sing-box
  systemctl restart sing-box
  wait_for_listener
  verify_loopback_listener
  [[ $first_install == true || ( $PRINT_PASSWORD == true && -t 1 ) ]] && show_password=true
  print_summary "$password" "$show_password"
}

main "$@"

#!/usr/bin/env bash
#
# Backhaul Manager — interactive installer & manager for Musixal/Backhaul
# reverse tunnels (Iran server + kharej client). wsmux today; tcp/tcpmux
# planned — see README.
#
# Repo   : https://github.com/power0matin/backhaul-manager
# License: MIT
#
# Usage:
#   Note: `sudo bash <(curl -fsSL ...)` (process substitution) can fail with
#   "bash: /dev/fd/NN: No such file or directory" because sudo closes
#   inherited file descriptors above stdio before exec'ing the command,
#   which breaks the pipe backing <(...). Use a pipe or download-then-run
#   instead:
#
#   curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh | sudo bash
#
#   or download first and run locally:
#
#   curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh -o backhaul-manager.sh
#   sudo bash backhaul-manager.sh

set -Eeuo pipefail

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[ !! ]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }

# Exit immediately and cleanly on Ctrl+C / termination, instead of only
# interrupting whatever `read` happens to be running at that moment.
on_interrupt() {
  echo
  err "Interrupted by user (Ctrl+C). Exiting."
  exit 130
}
on_terminate() {
  echo
  err "Terminated."
  exit 143
}
trap on_interrupt INT
trap on_terminate TERM

BACKHAUL_DIR="/opt/backhaul"
CONFIG_DIR="/root/backhaul"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/backhaul.service"
INFO_FILE="${CONFIG_DIR}/backhaul-info.txt"
LOG_FILE="/var/log/backhaul-manager-$(date +%Y%m%d%H%M%S).log"

mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'err "Script stopped due to an error at line $LINENO. Full details: $LOG_FILE"' ERR

# reads from /dev/tty so prompts still work when piped via curl | bash
tty_read() {
  local __out
  read -rp "$1" __out < /dev/tty
  echo "$__out"
}

# ask PROMPT [DEFAULT]
ask() {
  local prompt_text="$1" default_val="${2:-}" input
  if [[ -n "$default_val" ]]; then
    input=$(tty_read "${prompt_text} ${C_YELLOW}[default: ${default_val}]${C_RESET}: ")
  else
    input=$(tty_read "${prompt_text}: ")
  fi
  echo "${input:-$default_val}"
}

ask_required() {
  local prompt_text="$1" input
  while true; do
    input=$(tty_read "${prompt_text}: ")
    if [[ -n "$input" ]]; then
      echo "$input"
      return
    fi
    warn "This value is required, please enter it again." >&2
  done
}

# ask_yn PROMPT [y|n default]
ask_yn() {
  local prompt_text="$1" default_val="${2:-n}" input hint="y/N"
  [[ "$default_val" == "y" ]] && hint="Y/n"
  input=$(tty_read "${prompt_text} [${hint}]: ")
  input="${input:-$default_val}"
  [[ "$input" =~ ^[Yy]$ ]]
}

require_tty() {
  if [[ ! -r /dev/tty ]]; then
    err "This script is interactive and requires a terminal. Run it directly over SSH."
    exit 1
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Please run it with sudo."
    exit 1
  fi
}

check_dependencies() {
  local missing=()
  local cmd
  for cmd in curl tar systemctl ss awk grep sed; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "The following commands were not found on this system: ${missing[*]}"
    info "Install on Debian/Ubuntu: apt update && apt install -y iproute2 curl tar gawk grep sed"
    exit 1
  fi
  if ! command -v nc >/dev/null 2>&1; then
    warn "nc command not found; the client connectivity test at the end will be skipped (install: apt install -y netcat-openbsd)"
  fi
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 40
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40
  fi
}

detect_arch_asset() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)          echo "backhaul_linux_amd64.tar.gz" ;;
    aarch64|arm64)   echo "backhaul_linux_arm64.tar.gz" ;;
    *) err "Unsupported architecture: $arch"; exit 1 ;;
  esac
}

download_backhaul() {
  local version="$1" asset url
  asset=$(detect_arch_asset)

  if [[ -z "$version" || "$version" == "latest" ]]; then
    url="https://github.com/Musixal/Backhaul/releases/latest/download/${asset}"
  else
    url="https://github.com/Musixal/Backhaul/releases/download/${version}/${asset}"
  fi

  mkdir -p "$BACKHAUL_DIR"
  cd "$BACKHAUL_DIR"

  info "Downloading Backhaul (${version:-latest}) from: $url"
  curl -fsSL --retry 3 --retry-delay 2 -o backhaul.tar.gz "$url"
  tar -tzf backhaul.tar.gz >/dev/null 2>&1 || { err "Downloaded file is not valid (corrupt tar)."; exit 1; }
  tar -xzf backhaul.tar.gz
  chmod +x backhaul
  rm -f backhaul.tar.gz
  ok "Backhaul binary installed at ${BACKHAUL_DIR}/backhaul"
}

backup_config_if_exists() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local bkp
    bkp="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG_FILE" "$bkp"
    info "Previous config was backed up: $bkp"
  fi
}

write_service_file() {
  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul Reverse Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=${BACKHAUL_DIR}/backhaul -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

handle_old_services() {
  echo
  echo "${C_BOLD}===== Currently running services on this server =====${C_RESET}"

  local -a RUNNING=()
  mapfile -t RUNNING < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}')

  if [[ ${#RUNNING[@]} -eq 0 ]]; then
    info "No running services found."
    return
  fi

  local keywords="paqet|backhaul|gost|chisel|rathole|wstunnel|frps?|frpc?|v2ray|xray|sing-?box|hysteria|shadowsocks|ssr-|wireguard|openvpn|nps|ngrok|udp2raw|ligolo"

  local i svc
  for i in "${!RUNNING[@]}"; do
    svc="${RUNNING[$i]}"
    if echo "$svc" | grep -qiE "$keywords"; then
      printf "  %2d) %s   ${C_YELLOW}<-- possibly tunnel-related${C_RESET}\n" "$((i + 1))" "$svc"
    else
      printf "  %2d) %s\n" "$((i + 1))" "$svc"
    fi
  done

  echo
  echo "If you want to stop and disable old service(s) (e.g. a previous tunnel),"
  echo "enter the number or exact service name. Use ',' to separate multiple items"
  echo "(example: 2,paqet-client.service,5). Press Enter to skip."
  local sel
  sel=$(tty_read "Service(s) to stop: ")

  if [[ -z "$sel" ]]; then
    info "No services were removed."
    return
  fi

  local -a items=()
  IFS=',' read -ra items <<< "$sel"
  local item name idx
  for item in "${items[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -z "$item" ]] && continue

    if [[ "$item" =~ ^[0-9]+$ ]]; then
      idx=$((item - 1))
      if [[ $idx -ge 0 && $idx -lt ${#RUNNING[@]} ]]; then
        name="${RUNNING[$idx]}"
      else
        warn "Number '$item' is invalid, skipped."
        continue
      fi
    else
      name="$item"
      [[ "$name" != *.service ]] && name="${name}.service"
    fi

    info "Stopping and disabling: $name"
    systemctl stop "$name" 2>/dev/null || warn "Failed to stop $name (it may already be stopped)"
    systemctl disable "$name" 2>/dev/null || true
    ok "Processed: $name"
  done
}

# warns about open ports needed; never modifies firewall rules itself
firewall_hint() {
  local ports_list="$1"
  local p
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
    warn "ufw firewall is active. Make sure the following ports are open:"
    for p in $ports_list; do
      echo "    ufw allow ${p}/tcp"
    done
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active. Make sure the following ports are open:"
    for p in $ports_list; do
      echo "    firewall-cmd --add-port=${p}/tcp --permanent"
    done
    echo "    firewall-cmd --reload"
  fi
}

start_and_verify_service() {
  systemctl daemon-reload
  systemctl enable backhaul.service
  systemctl restart backhaul.service
  sleep 2

  echo "===== Service status ====="
  if systemctl is-active --quiet backhaul.service; then
    ok "backhaul service is active"
  else
    err "backhaul service failed to start!"
    journalctl -u backhaul -n 30 --no-pager || true
    exit 1
  fi
}

configure_server() {
  echo
  echo "${C_BOLD}===== Iran Server Configuration (Server side) =====${C_RESET}"

  local control_port ports_raw version token token_input

  control_port=$(ask "Backhaul control port" "8080")
  ports_raw=$(ask "Tunnel ports (comma-separated)" "2052,2082,8002,443")

  echo
  echo "For the shared token between server and client you can enter"
  echo "a custom value, or press Enter to auto-generate a secure token."
  token_input=$(tty_read "Token (Enter = auto-generate): ")
  if [[ -z "$token_input" ]]; then
    token="$(generate_token)"
    ok "Secure token generated (shown in the final summary)"
  else
    token="$token_input"
  fi

  version=$(ask "Backhaul version (or latest)" "latest")

  handle_old_services

  download_backhaul "$version"
  backup_config_if_exists

  local -a ports_arr=()
  IFS=', ' read -ra ports_arr <<< "$ports_raw"

  local ports_toml
  ports_toml=$(printf '  "%s",\n' "${ports_arr[@]}")

  # transport is hardcoded to wsmux; branch here when adding tcp/tcpmux/ws/udp (see README roadmap)
  cat > "$CONFIG_FILE" << EOF
[server]
bind_addr = "0.0.0.0:${control_port}"
transport = "wsmux"
token = "${token}"
keepalive_period = 20
heartbeat = 20
nodelay = true
channel_size = 2048
mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 2060
log_level = "info"

ports = [
${ports_toml}]
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Config written: $CONFIG_FILE"

  write_service_file
  start_and_verify_service

  echo "===== Checking ports ====="
  local p
  for p in "${ports_arr[@]}" "${control_port}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
      ok "Port $p is listening"
    else
      warn "Port $p is not open yet (it may take a few seconds)"
    fi
  done

  firewall_hint "${ports_arr[*]} ${control_port}"

  cat > "$INFO_FILE" << EOF
Backhaul Manager - Server (Iran) Info
Generated: $(date)

Control Port : ${control_port}
Tunnel Ports : ${ports_arr[*]}
Token        : ${token}
Config       : ${CONFIG_FILE}
Service      : backhaul.service

These values (especially the Token and this server's IP) are needed
for configuring the client side (foreign server).

Useful commands:
  systemctl status backhaul
  journalctl -u backhaul -f
EOF
  chmod 600 "$INFO_FILE"

  echo
  echo "${C_BOLD}${C_GREEN}===== Configuration Summary =====${C_RESET}"
  echo "  Token         : ${token}"
  echo "  Control Port  : ${control_port}"
  echo "  Tunnel Ports  : ${ports_arr[*]}"
  echo
  warn "Copy this token for the client side (foreign server) — it was also saved in ${INFO_FILE}."
  echo
  ok "Done. Live log: journalctl -u backhaul -f"
}

configure_client() {
  echo
  echo "${C_BOLD}===== Foreign Server Configuration (Client side) =====${C_RESET}"

  local iran_ip control_port token version

  iran_ip=$(ask_required "Iran server IP")
  control_port=$(ask "Backhaul control port" "8080")
  token=$(ask_required "Shared token (must match the server side exactly)")
  version=$(ask "Backhaul version (or latest)" "latest")

  handle_old_services

  download_backhaul "$version"
  backup_config_if_exists

  # transport is hardcoded to wsmux; branch here when adding tcp/tcpmux/ws/udp (see README roadmap)
  cat > "$CONFIG_FILE" << EOF
[client]
remote_addr = "${iran_ip}:${control_port}"
transport = "wsmux"
token = "${token}"
connection_pool = 8
aggressive_pool = false
keepalive_period = 20
heartbeat = 20
nodelay = true
retry_interval = 3
dial_timeout = 10
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 2061
log_level = "info"
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Config written: $CONFIG_FILE"

  write_service_file
  start_and_verify_service

  if command -v nc >/dev/null 2>&1; then
    echo "===== Testing connection to Iran server (${iran_ip}:${control_port}) ====="
    if nc -zv -w5 "${iran_ip}" "${control_port}" 2>&1; then
      ok "Connection successful"
    else
      warn "Connection failed — check the firewall on the Iran side or the network path"
    fi
  fi

  cat > "$INFO_FILE" << EOF
Backhaul Manager - Client (Kharej) Info
Generated: $(date)

Iran Server  : ${iran_ip}:${control_port}
Config       : ${CONFIG_FILE}
Service      : backhaul.service

Useful commands:
  systemctl status backhaul
  journalctl -u backhaul -f
EOF
  chmod 600 "$INFO_FILE"

  echo
  ok "Done. Live log: journalctl -u backhaul -f"
}

uninstall_backhaul() {
  echo
  warn "This will completely remove the backhaul service, binary, and all config files."
  if ! ask_yn "Are you sure?" "n"; then
    info "Cancelled."
    return
  fi

  systemctl stop backhaul.service 2>/dev/null || true
  systemctl disable backhaul.service 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload

  rm -rf "$BACKHAUL_DIR"
  rm -rf "$CONFIG_DIR"

  ok "Backhaul has been completely removed from this server."
}

banner() {
cat << 'BANNER'

  ____             _    _                 _
 | __ )  __ _  ___| | _| |__   __ _ _   _| |
 |  _ \ / _` |/ __| |/ / '_ \ / _` | | | | |
 | |_) | (_| | (__|   <| | | | (_| | |_| | |
 |____/ \__,_|\___|_|\_\_| |_|\__,_|\__,_|_|

              Backhaul Manager
    Reverse Tunnel Setup & Management (wsmux)
        github.com/power0matin/backhaul-manager

BANNER
}

main() {
  require_root
  require_tty
  check_dependencies
  banner

  echo "What would you like to do with this script?"
  echo "  1) Install/configure as the ${C_BOLD}Iran${C_RESET} server (Server side)"
  echo "  2) Install/configure as the ${C_BOLD}foreign${C_RESET} server (Client side)"
  echo "  3) Completely remove Backhaul from this server (Uninstall)"
  echo "  0) Exit"
  local choice
  choice=$(tty_read "Your choice: ")

  case "$choice" in
    1) configure_server ;;
    2) configure_client ;;
    3) uninstall_backhaul ;;
    0) info "Exiting."; exit 0 ;;
    *) err "Invalid option."; exit 1 ;;
  esac

  echo
  info "Full log of this run: $LOG_FILE"
}

main "$@"
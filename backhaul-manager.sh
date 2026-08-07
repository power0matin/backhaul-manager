#!/usr/bin/env bash
#
# Backhaul Manager — safe installer and operations helper for Backhaul.
# Repository: https://github.com/power0matin/backhaul-manager
# License: MIT

set -Eeuo pipefail
umask 077

readonly MANAGER_VERSION="2.0.0"
readonly BACKHAUL_DIR="/opt/backhaul"
readonly BACKHAUL_BIN="${BACKHAUL_DIR}/backhaul"
readonly CONFIG_DIR="/root/backhaul"
readonly CONFIG_FILE="${CONFIG_DIR}/config.toml"
readonly INFO_FILE="${CONFIG_DIR}/backhaul-info.txt"
readonly SERVICE_NAME="backhaul.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly STATE_DIR="/var/lib/backhaul-manager"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly LOG_DIR="/var/log/backhaul-manager"
readonly BACKHAUL_SOURCE_FILE="${STATE_DIR}/backhaul-source"
readonly POWERMATIN_BACKHAUL_REPO="power0matin/Backhaul"
readonly MUSIXAL_BACKHAUL_REPO="Musixal/Backhaul"
readonly DEFAULT_BACKHAUL_SOURCE="$POWERMATIN_BACKHAUL_REPO"

LOG_FILE=""
BINARY_BACKUP=""
BINARY_CHANGED=0
DOWNLOADED_VERSION=""
PARSED_PORTS=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_DIM=""
fi

info() { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

on_interrupt() {
  printf '\n' >&2
  err "Interrupted by user."
  exit 130
}

on_terminate() {
  err "Terminated."
  exit 143
}

on_error() {
  local exit_code=$? line_no="${1:-?}"
  err "Unexpected error at line ${line_no} (exit ${exit_code})."
  [[ -n "$LOG_FILE" ]] && err "Run log: ${LOG_FILE}"
  return "$exit_code"
}

trap on_interrupt INT
trap on_terminate TERM
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<EOF
Backhaul Manager ${MANAGER_VERSION}

Usage:
  sudo ./backhaul-manager.sh                 Interactive manager
  sudo ./backhaul-manager.sh --status        Show installation/service status
  sudo ./backhaul-manager.sh --diagnose      Run health checks
  sudo ./backhaul-manager.sh --restart       Restart Backhaul
  sudo ./backhaul-manager.sh --start         Start Backhaul
  sudo ./backhaul-manager.sh --stop          Stop Backhaul
  sudo ./backhaul-manager.sh --upgrade [ver] Upgrade Backhaul (default: latest)
  sudo ./backhaul-manager.sh --logs [lines]  Show recent journal logs
  sudo ./backhaul-manager.sh --follow-logs   Follow journal logs
       ./backhaul-manager.sh --version       Show manager version
       ./backhaul-manager.sh --help          Show this help

Backhaul versions may be "latest" or an upstream tag such as "v0.7.2".
New interactive installations ask for a Backhaul source; power0matin/Backhaul is recommended.
EOF
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "This operation requires root privileges. Re-run it with sudo."
    exit 1
  fi
}

require_tty() {
  if ! { : < /dev/tty; } 2>/dev/null; then
    err "Interactive mode requires a terminal. Download the script and run it from an SSH/terminal session."
    exit 1
  fi
}

check_platform() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "Only Linux is supported."
    exit 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    err "systemd/systemctl is required."
    exit 1
  fi
  if [[ ! -d /run/systemd/system ]]; then
    err "systemd does not appear to be running as PID 1 on this host."
    exit 1
  fi
}

check_dependencies() {
  local -a missing=()
  local cmd
  for cmd in awk curl grep install journalctl mktemp sed ss stat systemctl tar tee; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    err "Missing required commands: ${missing[*]}"
    info "Debian/Ubuntu: apt update && apt install -y curl tar iproute2 coreutils gawk grep sed"
    exit 1
  fi
  if ! command -v nc >/dev/null 2>&1; then
    warn "netcat (nc) is not installed; remote connectivity checks will be skipped."
  fi
}

setup_logging() {
  install -d -m 0700 "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/run-$(date +%Y%m%d-%H%M%S)-$$.log"
  : > "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

ensure_directories() {
  install -d -m 0755 "$BACKHAUL_DIR"
  install -d -m 0700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR"
}

tty_read() {
  local prompt="$1" value
  if ! IFS= read -r -p "$prompt" value < /dev/tty; then
    printf '\n' >&2
    err "Unable to read from the terminal."
    return 1
  fi
  printf '%s' "$value"
}

tty_read_secret() {
  local prompt="$1" value
  if ! IFS= read -r -s -p "$prompt" value < /dev/tty; then
    printf '\n' >/dev/tty
    err "Unable to read from the terminal."
    return 1
  fi
  printf '\n' >/dev/tty
  printf '%s' "$value"
}

ask() {
  local prompt_text="$1" default_val="${2:-}" input
  if [[ -n "$default_val" ]]; then
    input=$(tty_read "${prompt_text} ${C_DIM}[default: ${default_val}]${C_RESET}: ")
  else
    input=$(tty_read "${prompt_text}: ")
  fi
  printf '%s' "${input:-$default_val}"
}

ask_yn() {
  local prompt_text="$1" default_val="${2:-n}" input hint="y/N"
  [[ "$default_val" == "y" ]] && hint="Y/n"
  while true; do
    input=$(tty_read "${prompt_text} [${hint}]: ")
    input="${input:-$default_val}"
    case "${input,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." >&2 ;;
    esac
  done
}

pause_menu() {
  tty_read "Press Enter to return to the menu..." >/dev/null || true
}

clear_screen() {
  # Write directly to the controlling terminal so screen-control sequences
  # never pollute the persistent run log created by tee.
  printf '\033[H\033[2J' > /dev/tty 2>/dev/null || true
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( ${#value} <= 5 )) || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

ask_port() {
  local prompt_text="$1" default_val="$2" value
  while true; do
    value=$(ask "$prompt_text" "$default_val")
    if validate_port "$value"; then
      printf '%d' "$((10#$value))"
      return 0
    fi
    warn "Port must be an integer from 1 to 65535." >&2
  done
}

validate_version() {
  local value="$1"
  [[ "$value" == "latest" || "$value" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?([+-][0-9A-Za-z.-]+)?$ ]]
}

normalize_version() {
  local value="$1"
  if [[ "$value" == "latest" || "$value" == v* ]]; then
    printf '%s' "$value"
  else
    printf 'v%s' "$value"
  fi
}

ask_version() {
  local value
  while true; do
    value=$(ask "Backhaul version" "latest")
    if validate_version "$value"; then
      normalize_version "$value"
      return 0
    fi
    warn "Use 'latest' or a release tag such as v0.7.2." >&2
  done
}

validate_backhaul_source() {
  case "$1" in
    "$POWERMATIN_BACKHAUL_REPO"|"$MUSIXAL_BACKHAUL_REPO") return 0 ;;
    *) return 1 ;;
  esac
}

backhaul_release_base() {
  local source_repo="$1"
  validate_backhaul_source "$source_repo" || return 1
  printf 'https://github.com/%s/releases' "$source_repo"
}

choose_backhaul_source() {
  local choice
  printf '\nBackhaul source:\n' >&2
  printf '  1) %s %b[recommended]%b\n' "$POWERMATIN_BACKHAUL_REPO" "$C_GREEN" "$C_RESET" >&2
  printf '  2) %s [official upstream]\n' "$MUSIXAL_BACKHAUL_REPO" >&2
  while true; do
    choice=$(tty_read "Source [1]: ")
    case "${choice:-1}" in
      1) printf '%s' "$POWERMATIN_BACKHAUL_REPO"; return ;;
      2) printf '%s' "$MUSIXAL_BACKHAUL_REPO"; return ;;
      *) warn "Choose 1 or 2." >&2 ;;
    esac
  done
}

read_saved_backhaul_source() {
  local source_repo=""
  [[ -r "$BACKHAUL_SOURCE_FILE" ]] || return 1
  IFS= read -r source_repo < "$BACKHAUL_SOURCE_FILE" || true
  validate_backhaul_source "$source_repo" || return 1
  printf '%s' "$source_repo"
}

save_backhaul_source() {
  local source_repo="$1" tmp
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  ensure_directories
  tmp="${BACKHAUL_SOURCE_FILE}.tmp.$$"
  if ! printf '%s\n' "$source_repo" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$BACKHAUL_SOURCE_FILE"
}

validate_host() {
  local value="$1" core
  [[ -n "$value" ]] || return 1
  [[ "$value" != *[$'\n\r\t ']* ]] || return 1
  core="$value"
  if [[ "$core" == \[*\] ]]; then
    core="${core:1:${#core}-2}"
  fi
  [[ -n "$core" && "$core" =~ ^[A-Za-z0-9._:%-]+$ ]]
}

ask_host() {
  local prompt_text="$1" value
  while true; do
    value=$(tty_read "${prompt_text}: ")
    if validate_host "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn "Enter a valid IPv4, IPv6, or hostname without spaces." >&2
  done
}

format_host_port() {
  local host="$1" port="$2"
  if [[ "$host" == \[*\] ]]; then
    printf '%s:%s' "$host" "$port"
  elif [[ "$host" == *:* ]]; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

validate_token() {
  local value="$1"
  [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]]
}

toml_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  elif command -v od >/dev/null 2>&1; then
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  else
    err "Cannot generate a secure token: install openssl or coreutils (od)."
    return 1
  fi
}

ask_server_token() {
  local token
  token=$(tty_read_secret "Shared token (Enter = generate securely): ")
  if [[ -z "$token" ]]; then
    if ! token=$(generate_token); then
      return 1
    fi
    ok "Generated a secure token. It will only be shown in the final terminal summary." >&2
  elif ! validate_token "$token"; then
    err "Token cannot contain line breaks." >&2
    return 1
  elif (( ${#token} < 16 )); then
    warn "The custom token is shorter than 16 characters; a longer token is recommended." >&2
  fi
  printf '%s' "$token"
}

ask_client_token() {
  local token
  while true; do
    token=$(tty_read_secret "Shared token (must match the server): ")
    if validate_token "$token"; then
      printf '%s' "$token"
      return 0
    fi
    warn "Token is required and cannot contain line breaks." >&2
  done
}

parse_ports_csv() {
  local raw="$1" control_port="${2:-}" item normalized
  local -a items=()
  local -A seen=()
  PARSED_PORTS=()
  IFS=',' read -ra items <<< "$raw"
  for item in "${items[@]}"; do
    normalized=$(trim "$item")
    validate_port "$normalized" || return 1
    normalized="$((10#$normalized))"
    [[ -z "$control_port" || "$normalized" != "$control_port" ]] || return 2
    [[ -z "${seen[$normalized]:-}" ]] || continue
    seen[$normalized]=1
    PARSED_PORTS+=("$normalized")
  done
  (( ${#PARSED_PORTS[@]} > 0 ))
}

ask_ports() {
  local control_port="$1" raw rc
  while true; do
    raw=$(ask "Tunnel ports (comma-separated)" "2052,2082,8002,443")
    if parse_ports_csv "$raw" "$control_port"; then
      return 0
    else
      rc=$?
    fi
    if [[ $rc -eq 2 ]]; then
      warn "A tunnel port cannot be the same as the control port (${control_port})." >&2
    else
      warn "Enter one or more unique ports from 1 to 65535, separated by commas." >&2
    fi
  done
}

validate_transport() {
  case "$1" in
    tcp|tcpmux|udp|ws|wss|wsmux|wssmux) return 0 ;;
    *) return 1 ;;
  esac
}

choose_transport() {
  local choice
  printf '\nTransport:\n' >&2
  printf '  1) wsmux   - WebSocket multiplexing %b[recommended]%b\n' "$C_GREEN" "$C_RESET" >&2
  printf '  2) tcpmux  - TCP multiplexing\n' >&2
  printf '  3) tcp     - Plain TCP\n' >&2
  printf '  4) ws      - WebSocket\n' >&2
  printf '  5) wssmux  - TLS WebSocket multiplexing\n' >&2
  printf '  6) wss     - TLS WebSocket\n' >&2
  printf '  7) udp     - UDP transport\n' >&2
  while true; do
    choice=$(tty_read "Transport [1]: ")
    case "${choice:-1}" in
      1) printf 'wsmux'; return ;;
      2) printf 'tcpmux'; return ;;
      3) printf 'tcp'; return ;;
      4) printf 'ws'; return ;;
      5) printf 'wssmux'; return ;;
      6) printf 'wss'; return ;;
      7) printf 'udp'; return ;;
      *) warn "Choose a number from 1 to 7." >&2 ;;
    esac
  done
}

transport_uses_mux() {
  [[ "$1" == "tcpmux" || "$1" == "wsmux" || "$1" == "wssmux" ]]
}

transport_uses_tls() {
  [[ "$1" == "wss" || "$1" == "wssmux" ]]
}

transport_protocol() {
  [[ "$1" == "udp" ]] && printf 'udp' || printf 'tcp'
}

ask_existing_file() {
  local prompt_text="$1" value
  while true; do
    value=$(tty_read "${prompt_text}: ")
    if [[ "$value" == /* && -f "$value" && -r "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    warn "Enter an existing, readable absolute file path." >&2
  done
}

detect_arch_asset() {
  case "$(uname -m)" in
    x86_64|amd64)   printf 'backhaul_linux_amd64.tar.gz' ;;
    aarch64|arm64)  printf 'backhaul_linux_arm64.tar.gz' ;;
    *) err "Unsupported CPU architecture: $(uname -m)"; return 1 ;;
  esac
}

snapshot_file() {
  local source="$1" prefix="$2" output_var="$3" snapshot=""
  if [[ -f "$source" ]]; then
    snapshot="${BACKUP_DIR}/${prefix}.$(date +%Y%m%d-%H%M%S-%N)-$$"
    cp -a -- "$source" "$snapshot"
  fi
  printf -v "$output_var" '%s' "$snapshot"
}

restore_file() {
  local target="$1" snapshot="$2"
  if [[ -n "$snapshot" && -f "$snapshot" ]]; then
    cp -a -- "$snapshot" "$target"
  else
    rm -f -- "$target"
  fi
}

download_backhaul() {
  local requested="$1" source_repo="${2:-$DEFAULT_BACKHAUL_SOURCE}"
  local release_base asset url tmp_dir archive member candidate current_version="" current_source="" candidate_version
  BINARY_BACKUP=""
  BINARY_CHANGED=0
  if ! validate_backhaul_source "$source_repo"; then
    err "Invalid Backhaul source: ${source_repo}"
    return 1
  fi
  requested=$(normalize_version "$requested")
  release_base=$(backhaul_release_base "$source_repo") || return 1
  asset=$(detect_arch_asset) || return 1
  ensure_directories

  if [[ "$requested" == "latest" ]]; then
    url="${release_base}/latest/download/${asset}"
  else
    url="${release_base}/download/${requested}/${asset}"
  fi

  tmp_dir=$(mktemp -d /tmp/backhaul-manager.XXXXXX)
  archive="${tmp_dir}/${asset}"
  info "Downloading Backhaul ${requested} from ${source_repo} for $(uname -m)..."
  if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
      --connect-timeout 10 --max-time 180 -o "$archive" "$url"; then
    rm -rf -- "$tmp_dir"
    err "Download failed: ${url}"
    return 1
  fi
  if ! tar -tzf "$archive" > "${tmp_dir}/members.txt" 2>/dev/null; then
    rm -rf -- "$tmp_dir"
    err "The downloaded release archive is invalid or corrupt."
    return 1
  fi

  member=""
  while IFS= read -r member_candidate; do
    case "$member_candidate" in
      backhaul|./backhaul) member="$member_candidate"; break ;;
    esac
  done < "${tmp_dir}/members.txt"
  if [[ -z "$member" ]]; then
    rm -rf -- "$tmp_dir"
    err "The release archive does not contain the expected 'backhaul' binary."
    return 1
  fi
  if ! tar --no-same-owner -xzf "$archive" -C "$tmp_dir" -- "$member"; then
    rm -rf -- "$tmp_dir"
    err "Could not extract the Backhaul binary."
    return 1
  fi
  candidate="${tmp_dir}/${member#./}"
  if [[ ! -f "$candidate" || -L "$candidate" ]]; then
    rm -rf -- "$tmp_dir"
    err "The expected Backhaul archive member is not a regular file."
    return 1
  fi
  chmod 0755 "$candidate"
  if ! candidate_version=$("$candidate" -v 2>/dev/null); then
    rm -rf -- "$tmp_dir"
    err "The downloaded binary failed its version sanity check."
    return 1
  fi
  if [[ "$requested" != "latest" && "$candidate_version" != "$requested" ]]; then
    rm -rf -- "$tmp_dir"
    err "Requested ${requested}, but the downloaded binary reports ${candidate_version}."
    return 1
  fi

  if [[ -x "$BACKHAUL_BIN" ]]; then
    current_version=$("$BACKHAUL_BIN" -v 2>/dev/null || true)
    if ! current_source=$(read_saved_backhaul_source 2>/dev/null); then
      # Manager versions before source selection always installed Musixal/Backhaul.
      current_source="$MUSIXAL_BACKHAUL_REPO"
    fi
  fi
  if [[ -n "$current_version" && "$current_version" == "$candidate_version" && "$current_source" == "$source_repo" ]]; then
    DOWNLOADED_VERSION="$candidate_version"
    BINARY_CHANGED=0
    rm -rf -- "$tmp_dir"
    ok "Backhaul ${candidate_version} from ${source_repo} is already installed."
    return 0
  fi

  BINARY_BACKUP=""
  snapshot_file "$BACKHAUL_BIN" "backhaul-bin" BINARY_BACKUP
  install -m 0755 "$candidate" "${BACKHAUL_BIN}.new"
  mv -f -- "${BACKHAUL_BIN}.new" "$BACKHAUL_BIN"
  DOWNLOADED_VERSION="$candidate_version"
  BINARY_CHANGED=1
  rm -rf -- "$tmp_dir"
  ok "Installed Backhaul ${candidate_version}."
}

write_service_file() {
  local source_repo="$1" tmp
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  tmp=$(mktemp /etc/systemd/system/.backhaul.service.XXXXXX)
  cat > "$tmp" <<EOF
[Unit]
Description=Backhaul Reverse Tunnel Service
Documentation=https://github.com/${source_repo}
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${BACKHAUL_BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s
LimitNOFILE=1048576
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$SERVICE_FILE"
}

write_server_config() {
  local control_port="$1" transport="$2" token="$3" tls_cert="$4" tls_key="$5" tmp p
  local escaped_token escaped_cert escaped_key
  escaped_token=$(toml_escape "$token")
  escaped_cert=$(toml_escape "$tls_cert")
  escaped_key=$(toml_escape "$tls_key")
  tmp=$(mktemp "${CONFIG_DIR}/.config.toml.XXXXXX")
  {
    printf '[server]\n'
    printf 'bind_addr = "0.0.0.0:%s"\n' "$control_port"
    printf 'transport = "%s"\n' "$transport"
    printf 'token = "%s"\n' "$escaped_token"
    if [[ "$transport" == "udp" ]]; then
      printf 'heartbeat = 20\n'
      printf 'channel_size = 2048\n'
    else
      printf 'keepalive_period = 20\n'
      printf 'heartbeat = 20\n'
      printf 'nodelay = true\n'
      printf 'channel_size = 2048\n'
    fi
    if transport_uses_mux "$transport"; then
      printf 'mux_con = 8\n'
      printf 'mux_version = 1\n'
      printf 'mux_framesize = 32768\n'
      printf 'mux_recievebuffer = 4194304\n'
      printf 'mux_streambuffer = 65536\n'
    fi
    if transport_uses_tls "$transport"; then
      printf 'tls_cert = "%s"\n' "$escaped_cert"
      printf 'tls_key = "%s"\n' "$escaped_key"
    fi
    printf 'sniffer = false\n'
    printf 'web_port = 0\n'
    printf 'log_level = "info"\n\n'
    printf 'ports = [\n'
    for p in "${PARSED_PORTS[@]}"; do
      printf '  "%s",\n' "$p"
    done
    printf ']\n'
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$CONFIG_FILE"
}

write_client_config() {
  local remote_addr="$1" transport="$2" token="$3" edge_ip="$4" tmp
  local escaped_remote escaped_token escaped_edge
  escaped_remote=$(toml_escape "$remote_addr")
  escaped_token=$(toml_escape "$token")
  escaped_edge=$(toml_escape "$edge_ip")
  tmp=$(mktemp "${CONFIG_DIR}/.config.toml.XXXXXX")
  {
    printf '[client]\n'
    printf 'remote_addr = "%s"\n' "$escaped_remote"
    printf 'transport = "%s"\n' "$transport"
    printf 'token = "%s"\n' "$escaped_token"
    printf 'connection_pool = 8\n'
    printf 'aggressive_pool = false\n'
    printf 'retry_interval = 3\n'
    if [[ "$transport" != "udp" ]]; then
      printf 'keepalive_period = 20\n'
      printf 'dial_timeout = 10\n'
      printf 'nodelay = true\n'
    fi
    if transport_uses_mux "$transport"; then
      printf 'mux_version = 1\n'
      printf 'mux_framesize = 32768\n'
      printf 'mux_recievebuffer = 4194304\n'
      printf 'mux_streambuffer = 65536\n'
    fi
    if [[ -n "$edge_ip" ]]; then
      printf 'edge_ip = "%s"\n' "$escaped_edge"
    fi
    printf 'sniffer = false\n'
    printf 'web_port = 0\n'
    printf 'log_level = "info"\n'
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$CONFIG_FILE"
}

service_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

start_and_verify_service() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  if ! systemctl restart "$SERVICE_NAME"; then
    err "systemd could not restart ${SERVICE_NAME}."
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    return 1
  fi
  local _
  for _ in 1 2 3 4 5; do
    if service_is_active; then
      ok "${SERVICE_NAME} is active."
      return 0
    fi
    sleep 1
  done
  err "${SERVICE_NAME} failed to become active."
  journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
  return 1
}

rollback_install() {
  local config_snapshot="$1" service_snapshot="$2" binary_snapshot="$3" was_active="$4" was_enabled="$5"
  warn "Restoring the previous working installation..."
  restore_file "$CONFIG_FILE" "$config_snapshot"
  restore_file "$SERVICE_FILE" "$service_snapshot"
  if [[ -n "$binary_snapshot" && -f "$binary_snapshot" ]]; then
    cp -a -- "$binary_snapshot" "$BACKHAUL_BIN"
  elif [[ -z "$config_snapshot" ]]; then
    rm -f -- "$BACKHAUL_BIN"
  fi
  systemctl daemon-reload || true
  if [[ "$was_enabled" != "yes" ]]; then
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "$was_active" == "yes" && -f "$SERVICE_FILE" ]]; then
    systemctl restart "$SERVICE_NAME" || true
  else
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  ok "Rollback completed."
}

handle_old_services() {
  local keywords='paqet|backhaul|gost|chisel|rathole|wstunnel|frps?|frpc?|v2ray|xray|sing-?box|hysteria|shadowsocks|wireguard|openvpn|nps|ngrok|udp2raw|ligolo'
  local -a running=() candidates=() selected=()
  local svc input item idx
  mapfile -t running < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}')
  for svc in "${running[@]}"; do
    [[ "$svc" == "$SERVICE_NAME" ]] && continue
    if [[ "$svc" =~ $keywords ]]; then
      candidates+=("$svc")
    fi
  done
  (( ${#candidates[@]} > 0 )) || return 0

  printf '\n%bPossible conflicting tunnel services:%b\n' "$C_BOLD" "$C_RESET"
  for idx in "${!candidates[@]}"; do
    printf '  %d) %s\n' "$((idx + 1))" "${candidates[$idx]}"
  done
  input=$(tty_read "Numbers to stop/disable (comma-separated, Enter = skip): ")
  [[ -n "$input" ]] || return 0
  IFS=',' read -ra selected <<< "$input"
  local -a targets=()
  local -A seen=()
  for item in "${selected[@]}"; do
    item=$(trim "$item")
    if [[ "$item" =~ ^[0-9]+$ ]]; then
      idx=$((10#$item - 1))
      if (( idx >= 0 && idx < ${#candidates[@]} )); then
        svc="${candidates[$idx]}"
        [[ -n "${seen[$svc]:-}" ]] || { targets+=("$svc"); seen[$svc]=1; }
      else
        warn "Ignoring invalid service number: ${item}"
      fi
    else
      warn "Ignoring invalid selection: ${item}"
    fi
  done
  (( ${#targets[@]} > 0 )) || return 0
  printf 'Selected: %s\n' "${targets[*]}"
  if ! ask_yn "Stop and disable these services?" "n"; then
    info "Old-service cleanup skipped."
    return 0
  fi
  for svc in "${targets[@]}"; do
    systemctl stop "$svc" || warn "Could not stop ${svc}."
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
}

port_conflict_details() {
  local port="$1" protocol="$2"
  if [[ "$protocol" == "udp" ]]; then
    ss -H -lunp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" && $0 !~ /backhaul/ {print}'
  else
    ss -H -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" && $0 !~ /backhaul/ {print}'
  fi
}

preflight_server_ports() {
  local control_port="$1" protocol="$2" p details conflicts=0
  local -a all_ports=("$control_port" "${PARSED_PORTS[@]}")
  for p in "${all_ports[@]}"; do
    details=$(port_conflict_details "$p" "$protocol")
    if [[ -n "$details" ]]; then
      ((conflicts += 1))
      warn "Port ${p}/${protocol} is already used by another local process:"
      printf '  %s\n' "$details"
    fi
  done
  (( conflicts == 0 )) && return 0
  warn "Backhaul normally cannot bind ports that are already in use."
  ask_yn "Continue despite these conflicts?" "n"
}

check_listening_port() {
  local port="$1" protocol="${2:-tcp}"
  if [[ "$protocol" == "udp" ]]; then
    ss -H -lun 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit !found}'
  else
    ss -H -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit !found}'
  fi
}

firewall_hint() {
  local protocol="$1"; shift
  local p
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    warn "ufw is active. If needed, allow these ports:"
    for p in "$@"; do printf '  ufw allow %s/%s\n' "$p" "$protocol"; done
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "firewalld is active. If needed, allow these ports:"
    for p in "$@"; do printf '  firewall-cmd --add-port=%s/%s --permanent\n' "$p" "$protocol"; done
    printf '  firewall-cmd --reload\n'
  fi
}

write_server_info() {
  local control_port="$1" transport="$2" token="$3" source_repo="$4"
  {
    printf 'Backhaul Manager - Server (Iran)\n'
    printf 'Generated     : %s\n\n' "$(date -Is 2>/dev/null || date)"
    printf 'Backhaul      : %s\n' "$DOWNLOADED_VERSION"
    printf 'Source        : %s\n' "$source_repo"
    printf 'Transport     : %s\n' "$transport"
    printf 'Control port  : %s\n' "$control_port"
    printf 'Tunnel ports  : %s\n' "${PARSED_PORTS[*]}"
    printf 'Token         : %s\n' "$token"
    printf 'Config        : %s\n' "$CONFIG_FILE"
    printf 'Service       : %s\n' "$SERVICE_NAME"
  } > "$INFO_FILE"
  chmod 0600 "$INFO_FILE"
}

write_client_info() {
  local remote_addr="$1" transport="$2" source_repo="$3"
  {
    printf 'Backhaul Manager - Client (Foreign)\n'
    printf 'Generated     : %s\n\n' "$(date -Is 2>/dev/null || date)"
    printf 'Backhaul      : %s\n' "$DOWNLOADED_VERSION"
    printf 'Source        : %s\n' "$source_repo"
    printf 'Transport     : %s\n' "$transport"
    printf 'Iran server   : %s\n' "$remote_addr"
    printf 'Config        : %s\n' "$CONFIG_FILE"
    printf 'Service       : %s\n' "$SERVICE_NAME"
  } > "$INFO_FILE"
  chmod 0600 "$INFO_FILE"
}

print_server_secret_summary() {
  local token="$1" control_port="$2" transport="$3"
  {
    printf '\n%s===== Save these server details =====%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
    printf 'Token        : %s\n' "$token"
    printf 'Control port : %s\n' "$control_port"
    printf 'Transport    : %s\n' "$transport"
    printf 'Tunnel ports : %s\n' "${PARSED_PORTS[*]}"
    printf 'Saved securely in %s (mode 600).\n\n' "$INFO_FILE"
  } > /dev/tty
}

configure_server() {
  printf '\n%b===== Configure Iran / server side =====%b\n' "$C_BOLD" "$C_RESET"
  local control_port transport token source_repo version tls_cert="" tls_key=""
  local config_snapshot="" service_snapshot="" binary_snapshot="" was_active="no" was_enabled="no" protocol p
  control_port=$(ask_port "Backhaul control port" "8080")
  ask_ports "$control_port"
  transport=$(choose_transport)
  token=$(ask_server_token)
  source_repo=$(choose_backhaul_source)
  version=$(ask_version)
  if transport_uses_tls "$transport"; then
    printf '\nTLS transports require a certificate and private key on the server.\n'
    tls_cert=$(ask_existing_file "TLS certificate path")
    tls_key=$(ask_existing_file "TLS private key path")
  fi

  handle_old_services
  protocol=$(transport_protocol "$transport")
  if ! preflight_server_ports "$control_port" "$protocol"; then
    info "Configuration cancelled before making installation changes."
    return 1
  fi
  ensure_directories
  service_is_active && was_active="yes"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && was_enabled="yes"
  snapshot_file "$CONFIG_FILE" "config" config_snapshot
  snapshot_file "$SERVICE_FILE" "service" service_snapshot
  if ! download_backhaul "$version" "$source_repo"; then
    return 1
  fi
  binary_snapshot="$BINARY_BACKUP"
  if ! write_server_config "$control_port" "$transport" "$token" "$tls_cert" "$tls_key"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled"
    return 1
  fi
  if ! write_service_file "$source_repo"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled"
    return 1
  fi
  if ! start_and_verify_service; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled"
    return 1
  fi

  printf '\n%bListening-port check:%b\n' "$C_BOLD" "$C_RESET"
  if check_listening_port "$control_port" "$protocol"; then ok "Control port ${control_port}/${protocol} is listening."; else warn "Control port ${control_port}/${protocol} is not listening yet."; fi
  for p in "${PARSED_PORTS[@]}"; do
    if check_listening_port "$p" "$protocol"; then ok "Tunnel port ${p}/${protocol} is listening."; else warn "Tunnel port ${p}/${protocol} is not listening yet."; fi
  done
  firewall_hint "$protocol" "$control_port" "${PARSED_PORTS[@]}"
  if ! save_backhaul_source "$source_repo"; then
    warn "Configuration succeeded, but the selected Backhaul source could not be saved."
  fi
  write_server_info "$control_port" "$transport" "$token" "$source_repo"
  print_server_secret_summary "$token" "$control_port" "$transport"
  ok "Server configuration completed."
}

configure_client() {
  printf '\n%b===== Configure foreign / client side =====%b\n' "$C_BOLD" "$C_RESET"
  local iran_host control_port remote_addr transport token source_repo version edge_ip=""
  local config_snapshot="" service_snapshot="" binary_snapshot="" was_active="no" was_enabled="no" protocol
  iran_host=$(ask_host "Iran server IP or hostname")
  control_port=$(ask_port "Backhaul control port" "8080")
  remote_addr=$(format_host_port "$iran_host" "$control_port")
  transport=$(choose_transport)
  token=$(ask_client_token)
  if [[ "$transport" == "ws" || "$transport" == "wss" || "$transport" == "wsmux" || "$transport" == "wssmux" ]]; then
    edge_ip=$(tty_read "CDN edge IP/host (optional, Enter = none): ")
    if [[ -n "$edge_ip" ]] && ! validate_host "$edge_ip"; then
      warn "Invalid edge host; continuing without edge_ip."
      edge_ip=""
    fi
  fi
  source_repo=$(choose_backhaul_source)
  version=$(ask_version)

  handle_old_services
  ensure_directories
  service_is_active && was_active="yes"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && was_enabled="yes"
  snapshot_file "$CONFIG_FILE" "config" config_snapshot
  snapshot_file "$SERVICE_FILE" "service" service_snapshot
  if ! download_backhaul "$version" "$source_repo"; then
    return 1
  fi
  binary_snapshot="$BINARY_BACKUP"
  if ! write_client_config "$remote_addr" "$transport" "$token" "$edge_ip"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled"
    return 1
  fi
  if ! write_service_file "$source_repo"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled"
    return 1
  fi
  if ! start_and_verify_service; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled"
    return 1
  fi

  protocol=$(transport_protocol "$transport")
  if command -v nc >/dev/null 2>&1; then
    info "Testing ${remote_addr} (${protocol})..."
    if [[ "$protocol" == "udp" ]]; then
      if nc -z -u -w5 "$iran_host" "$control_port" >/dev/null 2>&1; then
        ok "UDP reachability probe completed."
      else
        warn "UDP reachability probe failed or was inconclusive."
      fi
    else
      if nc -z -w5 "$iran_host" "$control_port" >/dev/null 2>&1; then
        ok "Iran control port is reachable."
      else
        warn "Could not reach the Iran control port; check routing and firewall rules."
      fi
    fi
  fi
  if ! save_backhaul_source "$source_repo"; then
    warn "Configuration succeeded, but the selected Backhaul source could not be saved."
  fi
  write_client_info "$remote_addr" "$transport" "$source_repo"
  ok "Client configuration completed."
}

config_value() {
  local key="$1"
  [[ -f "$CONFIG_FILE" ]] || return 1
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$CONFIG_FILE"
}

config_role() {
  [[ -f "$CONFIG_FILE" ]] || { printf 'not configured'; return; }
  if grep -qE '^\[server\][[:space:]]*$' "$CONFIG_FILE"; then printf 'server (Iran)';
  elif grep -qE '^\[client\][[:space:]]*$' "$CONFIG_FILE"; then printf 'client (foreign)';
  else printf 'unknown'; fi
}

show_status() {
  local version="not installed" active="inactive" enabled="disabled" role transport address source_repo="not selected"
  [[ -x "$BACKHAUL_BIN" ]] && version=$("$BACKHAUL_BIN" -v 2>/dev/null || printf 'unknown')
  if ! source_repo=$(read_saved_backhaul_source 2>/dev/null); then
    if [[ -x "$BACKHAUL_BIN" ]]; then
      source_repo="${MUSIXAL_BACKHAUL_REPO} (legacy)"
    else
      source_repo="not selected"
    fi
  fi
  service_is_active && active="active"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && enabled="enabled"
  role=$(config_role)
  transport=$(config_value transport 2>/dev/null || true)
  if [[ "$role" == server* ]]; then address=$(config_value bind_addr 2>/dev/null || true); else address=$(config_value remote_addr 2>/dev/null || true); fi
  printf '\n%bBackhaul status%b\n' "$C_BOLD" "$C_RESET"
  printf '  Manager    : v%s\n' "$MANAGER_VERSION"
  printf '  Backhaul   : %s\n' "$version"
  printf '  Source     : %s\n' "$source_repo"
  printf '  Role       : %s\n' "$role"
  printf '  Transport  : %s\n' "${transport:-unknown}"
  printf '  Endpoint   : %s\n' "${address:-unknown}"
  printf '  Service    : %s, %s\n' "$active" "$enabled"
  printf '  Config     : %s\n' "$CONFIG_FILE"
  [[ -n "$LOG_FILE" ]] && printf '  Run log    : %s\n' "$LOG_FILE"
}

diagnose() {
  local failures=0 warnings=0 version role transport endpoint protocol port
  printf '\n%b===== Diagnostics =====%b\n' "$C_BOLD" "$C_RESET"
  if [[ -x "$BACKHAUL_BIN" ]] && version=$("$BACKHAUL_BIN" -v 2>/dev/null); then ok "Binary: ${version}"; else err "Backhaul binary is missing or invalid."; ((failures += 1)); fi
  if [[ -f "$CONFIG_FILE" ]]; then
    ok "Config exists: ${CONFIG_FILE}"
    local mode
    mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ "$mode" != "600" ]]; then warn "Config permissions are ${mode:-unknown}; 600 is recommended."; ((warnings += 1)); fi
  else
    err "Config file is missing."
    ((failures += 1))
  fi
  if [[ -f "$SERVICE_FILE" ]]; then ok "systemd unit exists."; else err "systemd unit is missing."; ((failures += 1)); fi
  if service_is_active; then ok "Service is active."; else err "Service is not active."; ((failures += 1)); fi
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then ok "Service is enabled at boot."; else warn "Service is not enabled at boot."; ((warnings += 1)); fi

  role=$(config_role)
  transport=$(config_value transport 2>/dev/null || true)
  protocol=$(transport_protocol "${transport:-tcp}")
  if [[ "$role" == server* ]]; then
    endpoint=$(config_value bind_addr 2>/dev/null || true)
    port="${endpoint##*:}"
    port="${port%\"}"
    if validate_port "$port" && check_listening_port "$port" "$protocol"; then ok "Control port ${port}/${protocol} is listening."; else warn "Configured control port does not appear to be listening."; ((warnings += 1)); fi
  elif [[ "$role" == client* ]]; then
    endpoint=$(config_value remote_addr 2>/dev/null || true)
    if [[ -n "$endpoint" ]]; then ok "Remote endpoint configured: ${endpoint}"; else warn "Remote endpoint could not be read."; ((warnings += 1)); fi
  fi

  if (( failures > 0 )); then
    err "Diagnostics finished with ${failures} failure(s) and ${warnings} warning(s)."
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
    return 1
  fi
  ok "Diagnostics passed with ${warnings} warning(s)."
}

service_action() {
  local action="$1"
  if [[ ! -f "$SERVICE_FILE" ]]; then
    err "Backhaul is not installed as a managed service."
    return 1
  fi
  case "$action" in
    start)
      systemctl start "$SERVICE_NAME"
      systemctl enable "$SERVICE_NAME" >/dev/null
      ;;
    stop) systemctl stop "$SERVICE_NAME" ;;
    restart) systemctl restart "$SERVICE_NAME" ;;
    *) return 2 ;;
  esac
  if [[ "$action" == "stop" ]]; then
    service_is_active && { err "Service is still active."; return 1; }
    ok "Backhaul stopped."
  else
    sleep 1
    if service_is_active; then ok "Backhaul ${action} succeeded."; else err "Backhaul did not become active."; return 1; fi
  fi
}

upgrade_backhaul() {
  local version="${1:-latest}" source_repo="${2:-}" was_active="no" previous_backup
  validate_version "$version" || { err "Invalid Backhaul version: ${version}"; return 1; }
  version=$(normalize_version "$version")
  [[ -f "$CONFIG_FILE" ]] || { err "No managed installation found. Configure Backhaul first."; return 1; }
  if [[ -z "$source_repo" ]]; then
    if ! source_repo=$(read_saved_backhaul_source 2>/dev/null); then
      # Preserve the source used by Manager releases from before source selection existed.
      source_repo="$MUSIXAL_BACKHAUL_REPO"
    fi
  fi
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  service_is_active && was_active="yes"
  if ! download_backhaul "$version" "$source_repo"; then return 1; fi
  previous_backup="$BINARY_BACKUP"
  if (( BINARY_CHANGED == 0 )); then
    save_backhaul_source "$source_repo"
    return 0
  fi
  if [[ "$was_active" == "yes" ]]; then
    if systemctl restart "$SERVICE_NAME" && sleep 1 && service_is_active; then
      save_backhaul_source "$source_repo"
      ok "Upgrade complete: ${DOWNLOADED_VERSION}."
    else
      err "The upgraded binary failed to start; rolling back."
      if [[ -n "$previous_backup" && -f "$previous_backup" ]]; then
        cp -a -- "$previous_backup" "$BACKHAUL_BIN"
        systemctl restart "$SERVICE_NAME" || true
      fi
      return 1
    fi
  else
    save_backhaul_source "$source_repo"
    ok "Upgraded to ${DOWNLOADED_VERSION}; service remains stopped."
  fi
}

show_logs() {
  local lines="${1:-80}"
  if [[ ! "$lines" =~ ^[0-9]+$ ]] || (( 10#$lines < 1 || 10#$lines > 5000 )); then
    err "Log line count must be between 1 and 5000."
    return 1
  fi
  journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager
}

follow_logs() {
  info "Following logs; press Ctrl+C to stop."
  journalctl -u "$SERVICE_NAME" -f
}

uninstall_backhaul() {
  printf '\n%b===== Uninstall Backhaul =====%b\n' "$C_BOLD" "$C_RESET"
  warn "This removes the managed service and Backhaul binary."
  if ! ask_yn "Continue?" "n"; then info "Cancelled."; return 0; fi
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f -- "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf -- "$BACKHAUL_DIR"
  if ask_yn "Also permanently delete config, credentials, and backups?" "n"; then
    rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
    ok "Backhaul, config, credentials, and backups were removed."
    info "Run logs are preserved in ${LOG_DIR}."
  else
    ok "Backhaul was removed; config and backups were preserved."
    info "Preserved: ${CONFIG_DIR} and ${BACKUP_DIR}"
  fi
}

banner() {
  cat <<'BANNER'

  ____             _    _                 _
 | __ )  __ _  ___| | _| |__   __ _ _   _| |
 |  _ \ / _` |/ __| |/ / '_ \ / _` | | | | |
 | |_) | (_| | (__|   <| | | | (_| | |_| | |
 |____/ \__,_|\___|_|\_\_| |_|\__,_|\__,_|_|

              Backhaul Manager
BANNER
  printf '               v%s\n\n' "$MANAGER_VERSION"
}

interactive_menu() {
  local choice first_render=1
  while true; do
    if (( first_render )); then
      first_render=0
    else
      clear_screen
    fi
    banner
    printf '%bActions%b\n' "$C_BOLD" "$C_RESET"
    printf '  1) Configure Iran server\n'
    printf '  2) Configure foreign client\n'
    printf '  3) Status\n'
    printf '  4) Diagnostics\n'
    printf '  5) Restart service\n'
    printf '  6) Start / stop service\n'
    printf '  7) Upgrade Backhaul\n'
    printf '  8) Recent logs\n'
    printf '  9) Follow live logs\n'
    printf ' 10) Uninstall / purge\n'
    printf '  0) Exit\n'
    choice=$(tty_read "Choose: ")
    printf '\n'
    case "$choice" in
      1) configure_server || warn "Server configuration did not complete."; pause_menu ;;
      2) configure_client || warn "Client configuration did not complete."; pause_menu ;;
      3) show_status; pause_menu ;;
      4) diagnose || true; pause_menu ;;
      5) service_action restart || true; pause_menu ;;
      6)
        if service_is_active; then
          ask_yn "Service is active. Stop it?" "n" && service_action stop || true
        else
          ask_yn "Service is stopped. Start it?" "y" && service_action start || true
        fi
        pause_menu
        ;;
      7)
        local version
        version=$(ask_version)
        upgrade_backhaul "$version" || true
        pause_menu
        ;;
      8) show_logs 80 || true; pause_menu ;;
      9) follow_logs || true; pause_menu ;;
      10) uninstall_backhaul; pause_menu ;;
      0) info "Bye."; return 0 ;;
      *) warn "Invalid choice."; pause_menu ;;
    esac
    printf '\n'
  done
}

prepare_runtime() {
  require_root
  check_platform
  check_dependencies
  setup_logging
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    -V|--version) printf 'Backhaul Manager %s\n' "$MANAGER_VERSION"; return 0 ;;
  esac

  prepare_runtime
  case "${1:-}" in
    "") require_tty; interactive_menu ;;
    --status) show_status ;;
    --diagnose) diagnose ;;
    --restart) service_action restart ;;
    --start) service_action start ;;
    --stop) service_action stop ;;
    --upgrade) upgrade_backhaul "${2:-latest}" ;;
    --logs) show_logs "${2:-80}" ;;
    --follow-logs) follow_logs ;;
    *) err "Unknown option: $1"; usage >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi

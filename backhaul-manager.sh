#!/usr/bin/env bash
#
# Backhaul Manager — safe installer and operations helper for Backhaul.
# Repository: https://github.com/power0matin/backhaul-manager
# License: MIT

set -Eeuo pipefail
umask 077

readonly MANAGER_VERSION="3.0.0"
readonly BACKHAUL_DIR="/opt/backhaul"
readonly BACKHAUL_BIN="${BACKHAUL_DIR}/backhaul"
readonly BASE_CONFIG_DIR="/root/backhaul"
readonly PROFILES_DIR="${BASE_CONFIG_DIR}/profiles"
readonly STATE_DIR="/var/lib/backhaul-manager"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly LOG_DIR="/var/log/backhaul-manager"
readonly BACKHAUL_SOURCE_FILE="${STATE_DIR}/backhaul-source"
readonly ACTIVE_PROFILE_FILE="${STATE_DIR}/active-profile"
readonly POWERMATIN_BACKHAUL_REPO="power0matin/Backhaul"
readonly MUSIXAL_BACKHAUL_REPO="Musixal/Backhaul"
readonly DEFAULT_BACKHAUL_SOURCE="$POWERMATIN_BACKHAUL_REPO"
readonly MANAGER_INSTALL_PATH="/usr/local/sbin/backhaul-manager"
readonly MANAGER_RAW_URL="https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh"

ACTIVE_PROFILE="default"
CONFIG_DIR="$BASE_CONFIG_DIR"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
INFO_FILE="${CONFIG_DIR}/backhaul-info.txt"
SERVICE_NAME="backhaul.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

LOG_FILE=""
BINARY_CHANGED=0
DOWNLOADED_VERSION=""
LAST_BACKUP_DIR=""
SELECTED_BACKUP_DIR=""
PARSED_PORTS=()
PORT_RULES=()
PROFILE_NAMES=()
BACKUP_CHOICES=()
COMPAT_UNSUPPORTED_KEYS=()
INCOMPATIBLE_PROFILES=()

# Per-configuration tuning/advanced settings. reset_config_options() restores
# conservative defaults before each interactive configure operation.
CONFIG_MODE="standard"
TUNING_PROFILE="balanced"
TUNE_CHANNEL_SIZE=2048
TUNE_CONNECTION_POOL=8
TUNE_MAX_POOL_SIZE=32
TUNE_MUX_CON=8
TUNE_MUX_RECV_BUFFER=4194304
TUNE_MUX_STREAM_BUFFER=65536
ADV_ACCEPT_UDP="false"
ADV_PROXY_PROTOCOL="false"
ADV_WEB_PORT=0
ADV_WEB_BIND_ADDR="127.0.0.1"
ADV_WEB_USERNAME=""
ADV_WEB_PASSWORD=""
ADV_TLS_VERIFY="true"

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
  sudo ./backhaul-manager.sh --profile NAME --status
  sudo ./backhaul-manager.sh --status        Show installation/service status
  sudo ./backhaul-manager.sh --diagnose      Run health checks
  sudo ./backhaul-manager.sh --metrics       Show systemd and Backhaul metrics
  sudo ./backhaul-manager.sh --restart       Restart Backhaul
  sudo ./backhaul-manager.sh --start         Start Backhaul
  sudo ./backhaul-manager.sh --stop          Stop Backhaul
  sudo ./backhaul-manager.sh --upgrade [ver] Upgrade Backhaul (default: latest)
  sudo ./backhaul-manager.sh --migrate-source REPO [ver]
  sudo ./backhaul-manager.sh --compat [REPO] Check config/source compatibility
  sudo ./backhaul-manager.sh --list-profiles List managed profiles
  sudo ./backhaul-manager.sh --select-profile NAME
  sudo ./backhaul-manager.sh --backup        Create a full local backup
  sudo ./backhaul-manager.sh --export PATH   Export a portable .tar.gz backup
  sudo ./backhaul-manager.sh --import PATH   Import and restore a portable backup
  sudo ./backhaul-manager.sh --restore-backup NAME
  sudo ./backhaul-manager.sh --list-backups  List local/imported backups
  sudo ./backhaul-manager.sh --self-update   Install/update the global manager command
  sudo ./backhaul-manager.sh --logs [lines]  Show recent journal logs
  sudo ./backhaul-manager.sh --follow-logs   Follow journal logs
       ./backhaul-manager.sh --version       Show manager version
       ./backhaul-manager.sh --help          Show this help

Backhaul versions may be "latest" or an upstream tag such as "v0.7.2".
New interactive installations ask for a Backhaul source; power0matin/Backhaul is recommended.
Source migrations reject downgrades and incompatible configs by default; use the interactive manager for confirmed adaptation.
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
  for cmd in awk cp curl find grep install journalctl mktemp sed sha256sum sort ss stat systemctl tar tee; do
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
  install -d -m 0700 "$BASE_CONFIG_DIR" "$PROFILES_DIR" "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR"
}

validate_profile_name() {
  local name="$1"
  [[ "$name" == "default" || "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]
}

apply_profile_context() {
  local name="$1"
  validate_profile_name "$name" || { err "Invalid profile name: ${name}"; return 1; }
  ACTIVE_PROFILE="$name"
  if [[ "$name" == "default" ]]; then
    CONFIG_DIR="$BASE_CONFIG_DIR"
    SERVICE_NAME="backhaul.service"
  else
    CONFIG_DIR="${PROFILES_DIR}/${name}"
    SERVICE_NAME="backhaul-${name}.service"
  fi
  CONFIG_FILE="${CONFIG_DIR}/config.toml"
  INFO_FILE="${CONFIG_DIR}/backhaul-info.txt"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
}

profile_config_path() {
  local name="$1"
  validate_profile_name "$name" || return 1
  if [[ "$name" == "default" ]]; then
    printf '%s/config.toml' "$BASE_CONFIG_DIR"
  else
    printf '%s/%s/config.toml' "$PROFILES_DIR" "$name"
  fi
}

profile_service_name() {
  local name="$1"
  validate_profile_name "$name" || return 1
  if [[ "$name" == "default" ]]; then
    printf 'backhaul.service'
  else
    printf 'backhaul-%s.service' "$name"
  fi
}

profile_from_service_name() {
  local service="$1"
  if [[ "$service" == "backhaul.service" ]]; then
    printf 'default'
  elif [[ "$service" =~ ^backhaul-([A-Za-z0-9][A-Za-z0-9_-]{0,31})\.service$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

profile_exists() {
  local path
  path=$(profile_config_path "$1") || return 1
  [[ -f "$path" ]]
}

refresh_profile_names() {
  local dir name
  PROFILE_NAMES=("default")
  if [[ -d "$PROFILES_DIR" ]]; then
    for dir in "$PROFILES_DIR"/*; do
      [[ -d "$dir" ]] || continue
      name="${dir##*/}"
      validate_profile_name "$name" || continue
      [[ -f "${dir}/config.toml" ]] || continue
      PROFILE_NAMES+=("$name")
    done
  fi
}

save_active_profile() {
  local name="$1" tmp
  validate_profile_name "$name" || return 1
  install -d -m 0700 "$STATE_DIR"
  tmp="${ACTIVE_PROFILE_FILE}.tmp.$$"
  printf '%s\n' "$name" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$ACTIVE_PROFILE_FILE"
}

load_active_profile() {
  local saved="default"
  if [[ -r "$ACTIVE_PROFILE_FILE" ]]; then
    IFS= read -r saved < "$ACTIVE_PROFILE_FILE" || saved="default"
  fi
  if ! validate_profile_name "$saved" || { [[ "$saved" != "default" ]] && ! profile_exists "$saved"; }; then
    saved="default"
  fi
  apply_profile_context "$saved"
}

select_profile() {
  local name="$1"
  validate_profile_name "$name" || { err "Invalid profile name: ${name}"; return 1; }
  profile_exists "$name" || { err "Profile '${name}' is not configured."; return 1; }
  apply_profile_context "$name"
  save_active_profile "$name"
  ok "Active profile: ${name}."
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
  local value="$1" base prerelease identifier
  local -a identifiers=()
  [[ "$value" == "latest" ]] && return 0
  (( ${#value} <= 128 )) || return 1
  [[ "$value" =~ ^v?[0-9]{1,9}\.[0-9]{1,9}(\.[0-9]{1,9})?(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || return 1
  base="${value#v}"
  base="${base%%+*}"
  [[ "$base" == *-* ]] || return 0
  prerelease="${base#*-}"
  IFS='.' read -ra identifiers <<< "$prerelease"
  for identifier in "${identifiers[@]}"; do
    # SemVer forbids leading zeroes in numeric prerelease identifiers.
    if [[ "$identifier" =~ ^[0-9]+$ && ${#identifier} -gt 1 && "$identifier" == 0* ]]; then
      return 1
    fi
  done
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

validate_port_or_range() {
  local value="$1" start end
  if [[ "$value" != *-* ]]; then
    validate_port "$value"
    return
  fi
  [[ "$value" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  start="${BASH_REMATCH[1]}"
  end="${BASH_REMATCH[2]}"
  validate_port "$start" && validate_port "$end" || return 1
  (( 10#$end >= 10#$start ))
}

validate_endpoint() {
  local value="$1" host port
  if [[ "$value" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$value" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  validate_host "$host" && validate_port "$port"
}

validate_port_rule() {
  local rule="$1" local_side remote_side eq_removed
  [[ -n "$rule" && "$rule" != *[$'\n\r\t ']* ]] || return 1
  eq_removed="${rule//=}"
  (( ${#rule} - ${#eq_removed} <= 1 )) || return 1
  if [[ "$rule" != *=* ]]; then
    validate_port_or_range "$rule"
    return
  fi
  local_side="${rule%%=*}"
  remote_side="${rule#*=}"
  [[ -n "$local_side" && -n "$remote_side" ]] || return 1
  if [[ "$local_side" == *-* || "$local_side" =~ ^[0-9]+$ ]]; then
    validate_port_or_range "$local_side" || return 1
  else
    validate_endpoint "$local_side" || return 1
  fi
  if [[ "$remote_side" =~ ^[0-9]+$ ]]; then
    validate_port "$remote_side"
  else
    validate_endpoint "$remote_side"
  fi
}

port_rule_conflicts_control() {
  local rule="$1" control_port="$2" local_side port start end
  local_side="${rule%%=*}"
  if [[ "$local_side" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    (( 10#$control_port >= 10#$start && 10#$control_port <= 10#$end ))
    return
  fi
  if [[ "$local_side" =~ ^[0-9]+$ ]]; then
    (( 10#$local_side == 10#$control_port ))
    return
  fi
  port="${local_side##*:}"
  (( 10#$port == 10#$control_port ))
}

parse_port_rules_csv() {
  local raw="$1" control_port="${2:-}" item normalized
  local -a items=()
  local -A seen=()
  PORT_RULES=()
  IFS=',' read -ra items <<< "$raw"
  for item in "${items[@]}"; do
    normalized=$(trim "$item")
    validate_port_rule "$normalized" || return 1
    if [[ -n "$control_port" ]] && port_rule_conflicts_control "$normalized" "$control_port"; then
      return 2
    fi
    [[ -n "${seen[$normalized]:-}" ]] && continue
    seen[$normalized]=1
    PORT_RULES+=("$normalized")
  done
  (( ${#PORT_RULES[@]} > 0 ))
}

ask_port_rules() {
  local control_port="$1" raw rc
  while true; do
    raw=$(ask "Port rules (comma-separated)" "2052,2082,8002,443")
    if parse_port_rules_csv "$raw" "$control_port"; then
      return 0
    else
      rc=$?
    fi
    if [[ $rc -eq 2 ]]; then
      warn "A port rule cannot bind the control port (${control_port})." >&2
    else
      warn "Invalid rules. Examples: 443, 443-500, 4000=5000, 443=127.0.0.1:8443." >&2
    fi
  done
}

validate_int_range() {
  local value="$1" min="$2" max="$3"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( ${#value} <= 10 )) || return 1
  (( 10#$value >= min && 10#$value <= max ))
}

ask_int_range() {
  local prompt_text="$1" default_val="$2" min="$3" max="$4" value
  while true; do
    value=$(ask "$prompt_text" "$default_val")
    if validate_int_range "$value" "$min" "$max"; then
      printf '%d' "$((10#$value))"
      return 0
    fi
    warn "Enter an integer from ${min} to ${max}." >&2
  done
}

reset_config_options() {
  PARSED_PORTS=()
  PORT_RULES=()
  CONFIG_MODE="standard"
  TUNING_PROFILE="balanced"
  TUNE_CHANNEL_SIZE=2048
  TUNE_CONNECTION_POOL=8
  TUNE_MAX_POOL_SIZE=32
  TUNE_MUX_CON=8
  TUNE_MUX_RECV_BUFFER=4194304
  TUNE_MUX_STREAM_BUFFER=65536
  ADV_ACCEPT_UDP="false"
  ADV_PROXY_PROTOCOL="false"
  ADV_WEB_PORT=0
  ADV_WEB_BIND_ADDR="127.0.0.1"
  ADV_WEB_USERNAME=""
  ADV_WEB_PASSWORD=""
  ADV_TLS_VERIFY="true"
}

recommend_tuning_profile() {
  local cpu_count="${1:-}" mem_mib="${2:-}"
  if [[ -z "$cpu_count" ]]; then cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1'); fi
  if [[ -z "$mem_mib" ]]; then mem_mib=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf '0'); fi
  [[ "$cpu_count" =~ ^[0-9]+$ ]] || cpu_count=1
  [[ "$mem_mib" =~ ^[0-9]+$ ]] || mem_mib=0
  if (( cpu_count <= 1 || (mem_mib > 0 && mem_mib < 768) )); then
    printf 'safe'
  elif (( cpu_count >= 4 && mem_mib >= 4096 )); then
    printf 'throughput'
  else
    printf 'balanced'
  fi
}

apply_tuning_profile() {
  local profile="$1"
  case "$profile" in
    safe)
      TUNE_CHANNEL_SIZE=1024; TUNE_CONNECTION_POOL=4; TUNE_MAX_POOL_SIZE=16
      TUNE_MUX_CON=4; TUNE_MUX_RECV_BUFFER=2097152; TUNE_MUX_STREAM_BUFFER=65536
      ;;
    balanced)
      TUNE_CHANNEL_SIZE=2048; TUNE_CONNECTION_POOL=8; TUNE_MAX_POOL_SIZE=32
      TUNE_MUX_CON=8; TUNE_MUX_RECV_BUFFER=4194304; TUNE_MUX_STREAM_BUFFER=65536
      ;;
    throughput)
      TUNE_CHANNEL_SIZE=4096; TUNE_CONNECTION_POOL=16; TUNE_MAX_POOL_SIZE=64
      TUNE_MUX_CON=12; TUNE_MUX_RECV_BUFFER=8388608; TUNE_MUX_STREAM_BUFFER=262144
      ;;
    *) return 1 ;;
  esac
  TUNING_PROFILE="$profile"
}

choose_config_mode() {
  local choice
  printf '\nConfiguration mode:\n' >&2
  printf '  1) Standard %b[recommended]%b\n' "$C_GREEN" "$C_RESET" >&2
  printf '  2) Advanced\n' >&2
  while true; do
    choice=$(tty_read "Mode [1]: ")
    case "${choice:-1}" in
      1) printf 'standard'; return ;;
      2) printf 'advanced'; return ;;
      *) warn "Choose 1 or 2." >&2 ;;
    esac
  done
}

choose_tuning_profile() {
  local choice recommended
  recommended=$(recommend_tuning_profile)
  printf '\nTuning profile:\n' >&2
  printf '  1) Auto (%s) %b[recommended]%b\n' "$recommended" "$C_GREEN" "$C_RESET" >&2
  printf '  2) Safe       - low resource usage\n' >&2
  printf '  3) Balanced   - general workloads\n' >&2
  printf '  4) Throughput - high concurrency\n' >&2
  while true; do
    choice=$(tty_read "Tuning [1]: ")
    case "${choice:-1}" in
      1) printf '%s' "$recommended"; return ;;
      2) printf 'safe'; return ;;
      3) printf 'balanced'; return ;;
      4) printf 'throughput'; return ;;
      *) warn "Choose a number from 1 to 4." >&2 ;;
    esac
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

transport_supports_proxy_protocol() {
  [[ "$1" == "tcp" || "$1" == "tcpmux" || "$1" == "wsmux" || "$1" == "wssmux" ]]
}

validate_web_username() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

validate_web_password() {
  [[ ${#1} -ge 12 && ${#1} -le 128 && "$1" =~ ^[A-Za-z0-9._:@%+=,-]+$ ]]
}

configure_web_monitor() {
  local source_repo="$1" username password
  [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" ]] || {
    warn "The Musixal v0.7.2 web monitor cannot be safely bound to loopback by config; keeping it disabled."
    return 0
  }
  ask_yn "Enable loopback-only web metrics?" "n" || return 0
  ADV_WEB_PORT=$(ask_port "Web metrics port" "2060")
  while true; do
    username=$(ask "Web metrics username" "backhaul")
    validate_web_username "$username" && break
    warn "Username may contain letters, numbers, dot, underscore, and dash only." >&2
  done
  password=$(tty_read_secret "Web metrics password (Enter = generate securely): ")
  if [[ -z "$password" ]]; then
    password=$(generate_token) || return 1
    ok "Generated a web metrics password; it is stored only in root-readable config/info files." >&2
  elif ! validate_web_password "$password"; then
    err "Web metrics password must be 12-128 characters using letters, numbers, or ._:@%+=,-" >&2
    return 1
  fi
  ADV_WEB_BIND_ADDR="127.0.0.1"
  ADV_WEB_USERNAME="$username"
  ADV_WEB_PASSWORD="$password"
}

configure_advanced_options() {
  local role="$1" transport="$2" source_repo="$3" selected_tuning
  selected_tuning=$(choose_tuning_profile)
  apply_tuning_profile "$selected_tuning" || return 1
  if [[ "$role" == "server" ]]; then
    if [[ "$transport" == "tcp" ]] && ask_yn "Accept UDP flows over the TCP tunnel?" "n"; then
      ADV_ACCEPT_UDP="true"
    fi
    if transport_supports_proxy_protocol "$transport" && ask_yn "Enable PROXY protocol forwarding?" "n"; then
      ADV_PROXY_PROTOCOL="true"
    fi
  elif [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" ]] && transport_uses_tls "$transport"; then
    if ! ask_yn "Verify the server TLS certificate?" "y"; then
      ADV_TLS_VERIFY="false"
      warn "TLS certificate verification is disabled for this profile."
    fi
  fi
  configure_web_monitor "$source_repo"
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

current_backhaul_source() {
  local source_repo
  if source_repo=$(read_saved_backhaul_source 2>/dev/null); then
    printf '%s' "$source_repo"
  elif [[ -x "$BACKHAUL_BIN" ]]; then
    # Every Manager release before source tracking downloaded Musixal.
    printf '%s' "$MUSIXAL_BACKHAUL_REPO"
  else
    printf '%s' "$DEFAULT_BACKHAUL_SOURCE"
  fi
}

manifest_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  sed -nE "s/^${key}=//p" "$file" | head -n 1
}

backup_checksum_file() {
  local dir="$1" file
  (
    cd "$dir"
    : > CHECKSUMS
    while IFS= read -r file; do
      [[ "$file" == "./CHECKSUMS" ]] && continue
      sha256sum "$file" >> CHECKSUMS
    done < <(find . -type f -print | LC_ALL=C sort)
    chmod 0600 CHECKSUMS
  )
}

backup_payload_present() {
  local copied_profiles="$1" binary_path="$2"
  (( copied_profiles > 0 )) || [[ -x "$binary_path" ]]
}

create_backup() {
  local label="${1:-manual}" safe_label stamp dir profile cfg_dir backup_profile svc source_repo version="unknown"
  local tls_cert tls_key active enabled copied_profiles=0
  safe_label="${label//[^A-Za-z0-9_-]/-}"
  safe_label="${safe_label:0:32}"
  [[ -n "$safe_label" ]] || safe_label="manual"
  ensure_directories
  refresh_profile_names
  if [[ ! -x "$BACKHAUL_BIN" ]]; then
    local found_config=0
    for profile in "${PROFILE_NAMES[@]}"; do profile_exists "$profile" && found_config=1; done
    (( found_config )) || { err "Nothing is installed or configured to back up."; return 1; }
  fi
  stamp=$(date +%Y%m%d-%H%M%S)
  dir="${BACKUP_DIR}/backup-${stamp}-${safe_label}-$$"
  install -d -m 0700 "$dir" "$dir/profiles" "$dir/state" "$dir/services"
  source_repo=$(current_backhaul_source)
  [[ -x "$BACKHAUL_BIN" ]] && version=$("$BACKHAUL_BIN" -v 2>/dev/null || printf 'unknown')
  if [[ -x "$BACKHAUL_BIN" ]]; then install -m 0755 "$BACKHAUL_BIN" "$dir/backhaul"; fi
  printf '%s\n' "$source_repo" > "$dir/state/backhaul-source"
  printf '%s\n' "$ACTIVE_PROFILE" > "$dir/state/active-profile"
  : > "$dir/services.state"
  chmod 0600 "$dir/state/backhaul-source" "$dir/state/active-profile" "$dir/services.state"

  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    cfg_dir="$(dirname "$(profile_config_path "$profile")")"
    backup_profile="${dir}/profiles/${profile}"
    install -d -m 0700 "$backup_profile"
    install -m 0600 "${cfg_dir}/config.toml" "$backup_profile/config.toml"
    [[ -f "${cfg_dir}/backhaul-info.txt" ]] && install -m 0600 "${cfg_dir}/backhaul-info.txt" "$backup_profile/backhaul-info.txt"
    tls_cert=$(config_value_from_file "${cfg_dir}/config.toml" tls_cert 2>/dev/null || true)
    tls_key=$(config_value_from_file "${cfg_dir}/config.toml" tls_key 2>/dev/null || true)
    if [[ -n "$tls_cert" || -n "$tls_key" ]]; then
      if [[ -r "$tls_cert" && -r "$tls_key" ]]; then
        install -m 0600 "$tls_cert" "$backup_profile/tls-cert.pem"
        install -m 0600 "$tls_key" "$backup_profile/tls-key.pem"
      else
        warn "Profile '${profile}' references TLS files that could not be included in the backup."
      fi
    fi
    svc=$(profile_service_name "$profile")
    if [[ -f "/etc/systemd/system/${svc}" ]]; then
      install -m 0644 "/etc/systemd/system/${svc}" "$dir/services/${svc}"
    fi
    active="no"; enabled="no"
    systemctl is-active --quiet "$svc" 2>/dev/null && active="yes"
    systemctl is-enabled --quiet "$svc" 2>/dev/null && enabled="yes"
    printf '%s %s %s\n' "$svc" "$active" "$enabled" >> "$dir/services.state"
    ((copied_profiles += 1))
  done
  if ! backup_payload_present "$copied_profiles" "$BACKHAUL_BIN"; then
    rm -rf -- "$dir"
    return 1
  fi
  {
    printf 'schema=1\n'
    printf 'created=%s\n' "$(date -Is 2>/dev/null || date)"
    printf 'manager_version=%s\n' "$MANAGER_VERSION"
    printf 'backhaul_version=%s\n' "$version"
    printf 'source=%s\n' "$source_repo"
    printf 'active_profile=%s\n' "$ACTIVE_PROFILE"
  } > "$dir/MANIFEST"
  chmod 0600 "$dir/MANIFEST"
  backup_checksum_file "$dir"
  LAST_BACKUP_DIR="$dir"
  ok "Backup created: ${dir}"
}

validate_backup_tree() {
  local dir="$1" schema source_repo profile_dir profile name
  [[ -d "$dir" && -f "$dir/MANIFEST" && -f "$dir/CHECKSUMS" && -f "$dir/services.state" ]] || return 1
  schema=$(manifest_value "$dir/MANIFEST" schema 2>/dev/null || true)
  [[ "$schema" == "1" ]] || return 1
  source_repo=$(manifest_value "$dir/MANIFEST" source 2>/dev/null || true)
  validate_backhaul_source "$source_repo" || return 1
  (
    cd "$dir"
    sha256sum -c CHECKSUMS >/dev/null 2>&1
  ) || return 1
  if [[ -d "$dir/profiles" ]]; then
    for profile_dir in "$dir/profiles"/*; do
      [[ -d "$profile_dir" ]] || continue
      name="${profile_dir##*/}"
      validate_profile_name "$name" || return 1
      [[ -f "$profile_dir/config.toml" ]] || return 1
      check_config_compatibility_file "$source_repo" "$profile_dir/config.toml" || return 1
    done
  fi
  profile=$(manifest_value "$dir/MANIFEST" active_profile 2>/dev/null || printf 'default')
  validate_profile_name "$profile"
}

replace_config_string_value() {
  local file="$1" key="$2" value="$3" tmp line replaced=0 escaped
  escaped=$(toml_escape "$value")
  tmp="${file}.tmp.$$"
  : > "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
      printf '%s = "%s"\n' "$key" "$escaped" >> "$tmp"
      replaced=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  (( replaced )) || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$file"
}

stop_all_managed_services() {
  local profile svc
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    svc=$(profile_service_name "$profile")
    systemctl stop "$svc" 2>/dev/null || true
  done
}

managed_installation_exists() {
  local profile
  [[ -x "$BACKHAUL_BIN" ]] && return 0
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" && return 0
  done
  return 1
}

cleanup_failed_empty_restore() {
  local profile svc
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    svc=$(profile_service_name "$profile")
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
    rm -f -- "/etc/systemd/system/${svc}"
  done
  rm -f -- "$BACKHAUL_BIN" "${BASE_CONFIG_DIR}/config.toml" "${BASE_CONFIG_DIR}/backhaul-info.txt"
  rm -rf -- "$PROFILES_DIR"
  rm -f -- "$BACKHAUL_SOURCE_FILE" "$ACTIVE_PROFILE_FILE"
  install -d -m 0700 "$PROFILES_DIR"
  apply_profile_context "default"
  systemctl daemon-reload || true
}

apply_backup_tree() {
  local dir="$1" source_repo profile_dir profile target_dir svc active enabled restored_active first_profile=""
  validate_backup_tree "$dir" || { err "Backup validation failed: ${dir}"; return 1; }
  source_repo=$(manifest_value "$dir/MANIFEST" source)
  restored_active=$(manifest_value "$dir/MANIFEST" active_profile 2>/dev/null || printf 'default')

  stop_all_managed_services
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    svc=$(profile_service_name "$profile")
    systemctl disable "$svc" >/dev/null 2>&1 || true
    rm -f -- "/etc/systemd/system/${svc}"
  done
  rm -f -- "${BASE_CONFIG_DIR}/config.toml" "${BASE_CONFIG_DIR}/backhaul-info.txt"
  rm -rf -- "$PROFILES_DIR"
  install -d -m 0700 "$BASE_CONFIG_DIR" "$PROFILES_DIR" "$STATE_DIR" "$BACKUP_DIR"
  # Reset the mutable profile context before helpers that call
  # ensure_directories(), or a previously selected named profile can be
  # recreated as an empty stale directory during restore.
  apply_profile_context "default"
  if [[ -f "$dir/backhaul" ]]; then
    install -d -m 0755 "$BACKHAUL_DIR"
    install -m 0755 "$dir/backhaul" "${BACKHAUL_BIN}.restore"
    mv -f -- "${BACKHAUL_BIN}.restore" "$BACKHAUL_BIN"
  else
    rm -f -- "$BACKHAUL_BIN"
  fi

  for profile_dir in "$dir/profiles"/*; do
    [[ -d "$profile_dir" ]] || continue
    profile="${profile_dir##*/}"
    validate_profile_name "$profile" || return 1
    [[ -z "$first_profile" ]] && first_profile="$profile"
    if [[ "$profile" == "default" ]]; then target_dir="$BASE_CONFIG_DIR"; else target_dir="${PROFILES_DIR}/${profile}"; fi
    install -d -m 0700 "$target_dir"
    install -m 0600 "$profile_dir/config.toml" "$target_dir/config.toml"
    [[ -f "$profile_dir/backhaul-info.txt" ]] && install -m 0600 "$profile_dir/backhaul-info.txt" "$target_dir/backhaul-info.txt"
    if [[ -f "$profile_dir/tls-cert.pem" && -f "$profile_dir/tls-key.pem" ]]; then
      install -d -m 0700 "$target_dir/tls"
      install -m 0600 "$profile_dir/tls-cert.pem" "$target_dir/tls/cert.pem"
      install -m 0600 "$profile_dir/tls-key.pem" "$target_dir/tls/key.pem"
      replace_config_string_value "$target_dir/config.toml" tls_cert "$target_dir/tls/cert.pem"
      replace_config_string_value "$target_dir/config.toml" tls_key "$target_dir/tls/key.pem"
    fi
  done
  save_backhaul_source "$source_repo"
  if ! validate_profile_name "$restored_active" || ! profile_exists "$restored_active"; then
    restored_active="${first_profile:-default}"
  fi

  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    apply_profile_context "$profile"
    write_service_file "$source_repo" || return 1
  done
  systemctl daemon-reload || return 1
  while read -r svc active enabled; do
    [[ -n "$svc" ]] || continue
    if [[ "$svc" == "backhaul.service" ]]; then profile="default";
    elif [[ "$svc" =~ ^backhaul-([A-Za-z0-9][A-Za-z0-9_-]{0,31})\.service$ ]]; then profile="${BASH_REMATCH[1]}";
    else continue; fi
    profile_exists "$profile" || continue
    if [[ "$enabled" == "yes" ]]; then systemctl enable "$svc" >/dev/null || return 1; else systemctl disable "$svc" >/dev/null 2>&1 || true; fi
    if [[ "$active" == "yes" ]]; then
      systemctl start "$svc" || return 1
      sleep 1
      systemctl is-active --quiet "$svc" || return 1
    fi
  done < "$dir/services.state"
  apply_profile_context "$restored_active"
  save_active_profile "$restored_active"
  ok "Backup restored. Active profile: ${restored_active}."
}

restore_backup_dir() {
  local dir="$1" safety=""
  validate_backup_tree "$dir" || { err "Selected backup is invalid or corrupted."; return 1; }
  if managed_installation_exists; then
    create_backup "pre-restore" || return 1
    safety="$LAST_BACKUP_DIR"
  fi
  if apply_backup_tree "$dir"; then
    return 0
  fi
  if [[ -n "$safety" ]]; then
    err "Restore failed; rolling back to the pre-restore snapshot."
    apply_backup_tree "$safety" || err "Automatic rollback also failed; recovery backup: ${safety}"
  else
    err "Restore failed on a previously empty host."
    cleanup_failed_empty_restore
  fi
  return 1
}

refresh_backup_choices() {
  local dir
  BACKUP_CHOICES=()
  [[ -d "$BACKUP_DIR" ]] || return 0
  for dir in "$BACKUP_DIR"/backup-* "$BACKUP_DIR"/import-*; do
    [[ -d "$dir" && -f "$dir/MANIFEST" ]] || continue
    BACKUP_CHOICES+=("$dir")
  done
}

list_backups() {
  local idx dir created source version
  refresh_backup_choices
  printf '\n%bBackups%b\n' "$C_BOLD" "$C_RESET"
  if (( ${#BACKUP_CHOICES[@]} == 0 )); then
    printf '  No backups found.\n'
    return 0
  fi
  for idx in "${!BACKUP_CHOICES[@]}"; do
    dir="${BACKUP_CHOICES[$idx]}"
    created=$(manifest_value "$dir/MANIFEST" created 2>/dev/null || printf '?')
    source=$(manifest_value "$dir/MANIFEST" source 2>/dev/null || printf '?')
    version=$(manifest_value "$dir/MANIFEST" backhaul_version 2>/dev/null || printf '?')
    printf '  %d) %s | %s | %s | %s\n' "$((idx + 1))" "${dir##*/}" "$version" "$source" "$created"
  done
}

validate_backup_archive() {
  local archive="$1" size member listing count=0 type member_size unpacked_size=0
  [[ -f "$archive" ]] || return 1
  size=$(stat -c '%s' "$archive" 2>/dev/null || printf '0')
  (( size > 0 && size <= 536870912 )) || return 1
  # A failing process substitution does not reliably make the surrounding
  # while command fail. Validate the archive stream independently first.
  tar -tzf "$archive" >/dev/null 2>&1 || return 1
  while IFS= read -r member; do
    ((count += 1))
    (( count <= 256 )) || return 1
    case "$member" in
      /*|..|../*|*/../*|*/..) return 1 ;;
    esac
  done < <(tar -tzf "$archive" 2>/dev/null) || return 1
  (( count > 0 )) || return 1
  while IFS= read -r listing; do
    type="${listing:0:1}"
    [[ "$type" == "-" || "$type" == "d" ]] || return 1
    # GNU tar's verbose listing starts with: mode owner/group size date time.
    # Cap both individual members and total expanded data to contain archive
    # bombs before extracting anything as root.
    member_size=$(awk '{print $3}' <<< "$listing")
    [[ "$member_size" =~ ^[0-9]+$ ]] || return 1
    (( member_size <= 536870912 )) || return 1
    (( unpacked_size <= 1073741824 - member_size )) || return 1
    (( unpacked_size += member_size ))
  done < <(tar -tvzf "$archive" 2>/dev/null) || return 1
}

export_backup_bundle() {
  local output="$1"
  [[ "$output" == /* && "$output" == *.tar.gz ]] || { err "Export path must be an absolute .tar.gz path."; return 1; }
  if [[ -e "$output" ]]; then err "Refusing to overwrite existing file: ${output}"; return 1; fi
  create_backup "export" || return 1
  if ! tar -czf "$output" -C "$LAST_BACKUP_DIR" .; then
    rm -f -- "$output"
    err "Could not create the portable backup archive."
    return 1
  fi
  chmod 0600 "$output"
  validate_backup_archive "$output" || { rm -f -- "$output"; err "Export archive validation failed."; return 1; }
  ok "Portable backup exported: ${output}"
  warn "The archive can contain tokens and TLS private keys; transfer and store it securely."
}

import_backup_bundle() {
  local archive="$1" tmp imported
  validate_backup_archive "$archive" || { err "Backup archive is invalid or unsafe."; return 1; }
  tmp=$(mktemp -d /tmp/backhaul-import.XXXXXX)
  if ! tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmp"; then
    rm -rf -- "$tmp"
    return 1
  fi
  validate_backup_tree "$tmp" || { rm -rf -- "$tmp"; err "Imported backup failed integrity or compatibility checks."; return 1; }
  ensure_directories
  imported="${BACKUP_DIR}/import-$(date +%Y%m%d-%H%M%S)-$$"
  if ! cp -a -- "$tmp" "$imported" || ! chmod -R go-rwx "$imported"; then
    rm -rf -- "$tmp" "$imported"
    err "Could not stage the imported backup safely."
    return 1
  fi
  rm -rf -- "$tmp"
  if ! restore_backup_dir "$imported"; then
    return 1
  fi
  ok "Import completed successfully."
}

choose_backup_dir() {
  local choice idx
  SELECTED_BACKUP_DIR=""
  list_backups
  (( ${#BACKUP_CHOICES[@]} > 0 )) || return 1
  choice=$(tty_read "Backup number (Enter = cancel): ")
  [[ -n "$choice" ]] || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid backup number."; return 1; }
  idx=$((10#$choice - 1))
  (( idx >= 0 && idx < ${#BACKUP_CHOICES[@]} )) || { warn "Invalid backup number."; return 1; }
  SELECTED_BACKUP_DIR="${BACKUP_CHOICES[$idx]}"
}

restore_backup_interactive() {
  choose_backup_dir || return 0
  ask_yn "Restore '${SELECTED_BACKUP_DIR##*/}'? Current managed state will be snapshotted first." "n" || return 0
  restore_backup_dir "$SELECTED_BACKUP_DIR"
}

delete_backup_interactive() {
  choose_backup_dir || return 0
  ask_yn "Permanently delete backup '${SELECTED_BACKUP_DIR##*/}'?" "n" || return 0
  case "$SELECTED_BACKUP_DIR" in
    "$BACKUP_DIR"/backup-*|"$BACKUP_DIR"/import-*) rm -rf -- "$SELECTED_BACKUP_DIR" ;;
    *) err "Refusing to delete an unexpected path."; return 1 ;;
  esac
  ok "Backup deleted."
}

export_backup_interactive() {
  local output default_output
  default_output="/root/backhaul-manager-$(date +%Y%m%d-%H%M%S).tar.gz"
  output=$(ask "Export path" "$default_output")
  export_backup_bundle "$output"
}

import_backup_interactive() {
  local archive
  archive=$(ask_existing_file "Backup .tar.gz path")
  [[ "$archive" == *.tar.gz ]] || { err "Expected a .tar.gz backup bundle."; return 1; }
  ask_yn "Import and restore this bundle?" "n" || return 0
  import_backup_bundle "$archive"
}

validate_ssh_target() {
  local target="$1"
  [[ "$target" != -* ]] || return 1
  [[ "$target" =~ ^([A-Za-z0-9._-]+@)?([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\])$ ]]
}

remote_migration_interactive() {
  local target bundle remote_file remote_cmd
  if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
    err "Remote migration requires OpenSSH client tools (ssh and scp)."
    return 1
  fi
  while true; do
    target=$(tty_read "SSH target (user@host): ")
    validate_ssh_target "$target" && break
    warn "Use a plain user@host target; configure custom ports/keys in ~/.ssh/config." >&2
  done
  bundle="/tmp/backhaul-manager-migration-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  export_backup_bundle "$bundle" || return 1
  remote_file="/tmp/backhaul-manager-migration-$$.tar.gz"
  info "Transferring the encrypted-in-transit SSH bundle to ${target}..."
  if ! scp -- "$bundle" "${target}:${remote_file}"; then
    rm -f -- "$bundle"
    err "SCP transfer failed."
    return 1
  fi
  if ! ssh -- "$target" "chmod 600 -- '${remote_file}'"; then
    ssh -- "$target" "rm -f -- '${remote_file}'" >/dev/null 2>&1 || true
    rm -f -- "$bundle"
    err "The remote backup could not be secured with mode 600; migration stopped."
    return 1
  fi
  rm -f -- "$bundle"
  ok "Bundle transferred to ${target}:${remote_file}."
  if ! ask_yn "Run the remote import now over SSH?" "y"; then
    info "On the target host, run Backhaul Manager with --import ${remote_file}."
    return 0
  fi
  remote_cmd="if [ \"\$(id -u)\" -eq 0 ]; then curl --proto '=https' --tlsv1.2 -fsSL --max-filesize 2097152 '${MANAGER_RAW_URL}' | bash -s -- --import '${remote_file}'; else curl --proto '=https' --tlsv1.2 -fsSL --max-filesize 2097152 '${MANAGER_RAW_URL}' | sudo bash -s -- --import '${remote_file}'; fi && rm -f -- '${remote_file}'"
  if ssh -t -- "$target" "$remote_cmd"; then
    ok "Remote migration completed and the transferred bundle was removed."
  else
    err "Remote import failed. The bundle remains at ${target}:${remote_file} for recovery."
    return 1
  fi
}

backup_migration_menu() {
  local choice
  printf '\n%bBackup & migration%b\n' "$C_BOLD" "$C_RESET"
  printf '  1) Create full backup\n'
  printf '  2) List backups\n'
  printf '  3) Restore backup\n'
  printf '  4) Export portable bundle\n'
  printf '  5) Import portable bundle\n'
  printf '  6) Migrate/clone to another server over SSH\n'
  printf '  7) Delete backup\n'
  printf '  0) Back\n'
  choice=$(tty_read "Choose: ")
  case "$choice" in
    1) create_backup "manual" ;;
    2) list_backups ;;
    3) restore_backup_interactive ;;
    4) export_backup_interactive ;;
    5) import_backup_interactive ;;
    6) remote_migration_interactive ;;
    7) delete_backup_interactive ;;
    0|"") return 0 ;;
    *) warn "Invalid choice."; return 1 ;;
  esac
}

manager_candidate_version() {
  local script="$1" version count
  [[ -f "$script" ]] || return 1
  version=$(sed -nE 's/^readonly MANAGER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$script")
  count=$(grep -cE '^readonly MANAGER_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$script" || true)
  [[ "$count" == "1" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s' "$version"
}

update_manager_command() {
  local tmp candidate_version installed_version="not installed"
  tmp=$(mktemp /tmp/backhaul-manager-update.XXXXXX)
  if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
      --max-filesize 2097152 -o "$tmp" "$MANAGER_RAW_URL"; then
    rm -f -- "$tmp"
    err "Could not download the latest Backhaul Manager."
    return 1
  fi
  if ! bash -n "$tmp" || ! candidate_version=$(manager_candidate_version "$tmp"); then
    rm -f -- "$tmp"
    err "Downloaded Manager failed syntax/version validation."
    return 1
  fi
  if [[ -x "$MANAGER_INSTALL_PATH" ]]; then installed_version=$(manager_candidate_version "$MANAGER_INSTALL_PATH" 2>/dev/null || printf 'unknown'); fi
  if [[ "$installed_version" != "not installed" && "$installed_version" != "unknown" ]] && version_is_older "$candidate_version" "$installed_version"; then
    rm -f -- "$tmp"
    err "Refusing Manager downgrade: ${installed_version} -> ${candidate_version}."
    return 1
  fi
  install -d -m 0755 "$(dirname "$MANAGER_INSTALL_PATH")"
  install -m 0755 "$tmp" "${MANAGER_INSTALL_PATH}.new"
  mv -f -- "${MANAGER_INSTALL_PATH}.new" "$MANAGER_INSTALL_PATH"
  rm -f -- "$tmp"
  ok "Backhaul Manager ${candidate_version} installed at ${MANAGER_INSTALL_PATH}."
  info "You can now run: backhaul-manager"
}

manager_menu() {
  local choice installed="not installed"
  [[ -x "$MANAGER_INSTALL_PATH" ]] && installed=$(manager_candidate_version "$MANAGER_INSTALL_PATH" 2>/dev/null || printf 'unknown')
  printf '\n%bManager%b\n' "$C_BOLD" "$C_RESET"
  printf '  Running   : v%s\n' "$MANAGER_VERSION"
  printf '  Installed : %s\n\n' "$installed"
  printf '  1) Install / update global command\n'
  printf '  0) Back\n'
  choice=$(tty_read "Choose: ")
  case "$choice" in
    1) update_manager_command ;;
    0|"") return 0 ;;
    *) warn "Invalid choice."; return 1 ;;
  esac
}

download_backhaul() {
  local requested="$1" source_repo="${2:-$DEFAULT_BACKHAUL_SOURCE}"
  local release_base asset url tmp_dir archive member candidate current_version="" current_source="" candidate_version
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
      --connect-timeout 10 --max-time 180 --max-filesize 536870912 -o "$archive" "$url"; then
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

  install -m 0755 "$candidate" "${BACKHAUL_BIN}.new"
  mv -f -- "${BACKHAUL_BIN}.new" "$BACKHAUL_BIN"
  DOWNLOADED_VERSION="$candidate_version"
  BINARY_CHANGED=1
  rm -rf -- "$tmp_dir"
  ok "Installed Backhaul ${candidate_version}."
}

write_service_file() {
  local source_repo="$1" tmp unit_dir
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  unit_dir=$(dirname "$SERVICE_FILE")
  [[ -d "$unit_dir" ]] || { err "systemd unit directory does not exist: ${unit_dir}"; return 1; }
  tmp=$(mktemp "${unit_dir}/.backhaul.service.XXXXXX")
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
  local control_port="$1" transport="$2" token="$3" tls_cert="$4" tls_key="$5" source_repo="$6" tmp rule
  local escaped_token escaped_cert escaped_key escaped_web_user escaped_web_password
  escaped_token=$(toml_escape "$token")
  escaped_cert=$(toml_escape "$tls_cert")
  escaped_key=$(toml_escape "$tls_key")
  escaped_web_user=$(toml_escape "$ADV_WEB_USERNAME")
  escaped_web_password=$(toml_escape "$ADV_WEB_PASSWORD")
  tmp=$(mktemp "${CONFIG_DIR}/.config.toml.XXXXXX")
  {
    printf '[server]\n'
    printf 'bind_addr = "0.0.0.0:%s"\n' "$control_port"
    printf 'transport = "%s"\n' "$transport"
    printf 'token = "%s"\n' "$escaped_token"
    if [[ "$transport" == "udp" ]]; then
      printf 'heartbeat = 20\n'
      printf 'channel_size = %s\n' "$TUNE_CHANNEL_SIZE"
    else
      printf 'keepalive_period = 20\n'
      printf 'heartbeat = 20\n'
      printf 'nodelay = true\n'
      printf 'channel_size = %s\n' "$TUNE_CHANNEL_SIZE"
    fi
    if transport_uses_mux "$transport"; then
      printf 'mux_con = %s\n' "$TUNE_MUX_CON"
      printf 'mux_version = 1\n'
      printf 'mux_framesize = 32768\n'
      printf 'mux_recievebuffer = %s\n' "$TUNE_MUX_RECV_BUFFER"
      printf 'mux_streambuffer = %s\n' "$TUNE_MUX_STREAM_BUFFER"
    fi
    if transport_uses_tls "$transport"; then
      printf 'tls_cert = "%s"\n' "$escaped_cert"
      printf 'tls_key = "%s"\n' "$escaped_key"
    fi
    if [[ "$CONFIG_MODE" == "advanced" ]]; then
      [[ "$transport" == "tcp" ]] && printf 'accept_udp = %s\n' "$ADV_ACCEPT_UDP"
      transport_supports_proxy_protocol "$transport" && printf 'proxy_protocol = %s\n' "$ADV_PROXY_PROTOCOL"
      if [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" && ( "$transport" == "tcp" || "$transport" == "udp" ) ]]; then
        printf 'udp_queue_size = 64\n'
        printf 'udp_queue_limit = 4096\n'
        printf 'udp_max_flows = 2048\n'
      fi
    fi
    printf 'sniffer = false\n'
    printf 'web_port = %s\n' "$ADV_WEB_PORT"
    if [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" && "$ADV_WEB_PORT" -gt 0 ]]; then
      printf 'web_bind_addr = "%s"\n' "$ADV_WEB_BIND_ADDR"
      printf 'web_username = "%s"\n' "$escaped_web_user"
      printf 'web_password = "%s"\n' "$escaped_web_password"
    fi
    printf 'log_level = "info"\n\n'
    printf 'ports = [\n'
    for rule in "${PORT_RULES[@]}"; do
      printf '  "%s",\n' "$rule"
    done
    printf ']\n'
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$CONFIG_FILE"
}

write_client_config() {
  local remote_addr="$1" transport="$2" token="$3" edge_ip="$4" source_repo="$5" tmp
  local escaped_remote escaped_token escaped_edge escaped_web_user escaped_web_password
  escaped_remote=$(toml_escape "$remote_addr")
  escaped_token=$(toml_escape "$token")
  escaped_edge=$(toml_escape "$edge_ip")
  escaped_web_user=$(toml_escape "$ADV_WEB_USERNAME")
  escaped_web_password=$(toml_escape "$ADV_WEB_PASSWORD")
  tmp=$(mktemp "${CONFIG_DIR}/.config.toml.XXXXXX")
  {
    printf '[client]\n'
    printf 'remote_addr = "%s"\n' "$escaped_remote"
    printf 'transport = "%s"\n' "$transport"
    printf 'token = "%s"\n' "$escaped_token"
    printf 'connection_pool = %s\n' "$TUNE_CONNECTION_POOL"
    if [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" && "$CONFIG_MODE" == "advanced" ]]; then
      printf 'max_pool_size = %s\n' "$TUNE_MAX_POOL_SIZE"
    fi
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
      printf 'mux_recievebuffer = %s\n' "$TUNE_MUX_RECV_BUFFER"
      printf 'mux_streambuffer = %s\n' "$TUNE_MUX_STREAM_BUFFER"
    fi
    if [[ -n "$edge_ip" ]]; then
      printf 'edge_ip = "%s"\n' "$escaped_edge"
    fi
    if [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" && "$CONFIG_MODE" == "advanced" ]] && transport_uses_tls "$transport"; then
      printf 'tls_verify = %s\n' "$ADV_TLS_VERIFY"
    fi
    printf 'sniffer = false\n'
    printf 'web_port = %s\n' "$ADV_WEB_PORT"
    if [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" && "$ADV_WEB_PORT" -gt 0 ]]; then
      printf 'web_bind_addr = "%s"\n' "$ADV_WEB_BIND_ADDR"
      printf 'web_username = "%s"\n' "$escaped_web_user"
      printf 'web_password = "%s"\n' "$escaped_web_password"
    fi
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
  local config_snapshot="$1" service_snapshot="$2" binary_snapshot="$3" was_active="$4" was_enabled="$5" source_snapshot="${6:-}"
  warn "Restoring the previous working installation..."
  restore_file "$CONFIG_FILE" "$config_snapshot"
  restore_file "$SERVICE_FILE" "$service_snapshot"
  restore_file "$BACKHAUL_SOURCE_FILE" "$source_snapshot"
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
  local svc input item idx managed_profile
  mapfile -t running < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}')
  for svc in "${running[@]}"; do
    [[ "$svc" == "$SERVICE_NAME" ]] && continue
    if managed_profile=$(profile_from_service_name "$svc" 2>/dev/null) && profile_exists "$managed_profile"; then
      continue
    fi
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
  local port="$1" protocol="$2" current_pid
  current_pid=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || printf '0')
  [[ "$current_pid" =~ ^[0-9]+$ ]] || current_pid=0
  if [[ "$protocol" == "udp" ]]; then
    ss -H -lunp 2>/dev/null | awk -v p=":${port}" -v own="pid=${current_pid}," '$4 ~ p"$" && (own == "pid=0," || index($0, own) == 0) {print}'
  else
    ss -H -ltnp 2>/dev/null | awk -v p=":${port}" -v own="pid=${current_pid}," '$4 ~ p"$" && (own == "pid=0," || index($0, own) == 0) {print}'
  fi
}

port_rule_matches_port() {
  local rule="$1" port="$2" local_side start end local_port
  validate_port "$port" || return 1
  local_side="${rule%%=*}"
  if [[ "$local_side" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    (( 10#$port >= 10#$start && 10#$port <= 10#$end ))
    return
  fi
  if [[ "$local_side" =~ ^[0-9]+$ ]]; then
    (( 10#$port == 10#$local_side ))
    return
  fi
  local_port="${local_side##*:}"
  (( 10#$port == 10#$local_port ))
}

preflight_server_ports() {
  local control_port="$1" protocol="$2" p details conflicts=0 line local_addr rule current_pid
  current_pid=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || printf '0')
  [[ "$current_pid" =~ ^[0-9]+$ ]] || current_pid=0
  details=$(port_conflict_details "$control_port" "$protocol")
  if [[ -n "$details" ]]; then
    ((conflicts += 1))
    warn "Control port ${control_port}/${protocol} is already used by another local process:"
    printf '  %s\n' "$details"
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if (( current_pid > 0 )) && [[ "$line" == *"pid=${current_pid},"* ]]; then continue; fi
    local_addr=$(awk '{print $4}' <<< "$line")
    p="${local_addr##*:}"
    validate_port "$p" || continue
    for rule in "${PORT_RULES[@]}"; do
      if port_rule_matches_port "$rule" "$p"; then
        ((conflicts += 1))
        warn "Port rule '${rule}' conflicts with an existing ${protocol} listener on port ${p}:"
        printf '  %s\n' "$line"
        break
      fi
    done
  done < <(if [[ "$protocol" == "udp" ]]; then ss -H -lunp 2>/dev/null; else ss -H -ltnp 2>/dev/null; fi)
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
    printf 'Profile       : %s\n' "$ACTIVE_PROFILE"
    printf 'Transport     : %s\n' "$transport"
    printf 'Control port  : %s\n' "$control_port"
    printf 'Port rules    : %s\n' "${PORT_RULES[*]}"
    printf 'Config mode   : %s\n' "$CONFIG_MODE"
    printf 'Tuning        : %s\n' "$TUNING_PROFILE"
    printf 'Token         : %s\n' "$token"
    if (( ADV_WEB_PORT > 0 )); then
      printf 'Metrics       : http://%s:%s/stats\n' "$ADV_WEB_BIND_ADDR" "$ADV_WEB_PORT"
      printf 'Metrics user  : %s\n' "$ADV_WEB_USERNAME"
      printf 'Metrics pass  : %s\n' "$ADV_WEB_PASSWORD"
    fi
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
    printf 'Profile       : %s\n' "$ACTIVE_PROFILE"
    printf 'Transport     : %s\n' "$transport"
    printf 'Iran server   : %s\n' "$remote_addr"
    printf 'Config mode   : %s\n' "$CONFIG_MODE"
    printf 'Tuning        : %s\n' "$TUNING_PROFILE"
    if (( ADV_WEB_PORT > 0 )); then
      printf 'Metrics       : http://%s:%s/stats\n' "$ADV_WEB_BIND_ADDR" "$ADV_WEB_PORT"
      printf 'Metrics user  : %s\n' "$ADV_WEB_USERNAME"
      printf 'Metrics pass  : %s\n' "$ADV_WEB_PASSWORD"
    fi
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
    printf 'Port rules   : %s\n' "${PORT_RULES[*]}"
    printf 'Saved securely in %s (mode 600).\n\n' "$INFO_FILE"
  } > /dev/tty
}

configure_server() {
  printf '\n%b===== Configure Iran / server side =====%b\n' "$C_BOLD" "$C_RESET"
  local control_port transport token source_repo version tls_cert="" tls_key=""
  local config_snapshot="" service_snapshot="" binary_snapshot="" source_snapshot="" was_active="no" was_enabled="no" protocol p
  reset_config_options
  if [[ -x "$BACKHAUL_BIN" ]]; then
    source_repo=$(current_backhaul_source)
    version=$("$BACKHAUL_BIN" -v 2>/dev/null || printf 'latest')
    info "Shared Backhaul binary: ${source_repo} ${version}. Use Source migration/Upgrade to change it."
  else
    source_repo=$(choose_backhaul_source)
    version=$(ask_version)
  fi
  control_port=$(ask_port "Backhaul control port" "8080")
  transport=$(choose_transport)
  CONFIG_MODE=$(choose_config_mode)
  if [[ "$CONFIG_MODE" == "advanced" ]]; then
    ask_port_rules "$control_port"
  else
    ask_ports "$control_port"
    PORT_RULES=("${PARSED_PORTS[@]}")
  fi
  token=$(ask_server_token)
  if transport_uses_tls "$transport"; then
    printf '\nTLS transports require a certificate and private key on the server.\n'
    tls_cert=$(ask_existing_file "TLS certificate path")
    tls_key=$(ask_existing_file "TLS private key path")
  fi
  if [[ "$CONFIG_MODE" == "advanced" ]]; then
    configure_advanced_options "server" "$transport" "$source_repo" || return 1
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
  snapshot_file "$BACKHAUL_BIN" "backhaul-bin" binary_snapshot
  snapshot_file "$BACKHAUL_SOURCE_FILE" "source" source_snapshot
  if ! download_backhaul "$version" "$source_repo"; then
    return 1
  fi
  if ! write_server_config "$control_port" "$transport" "$token" "$tls_cert" "$tls_key" "$source_repo"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
    return 1
  fi
  if ! write_service_file "$source_repo"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
    return 1
  fi
  if ! start_and_verify_service; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
    return 1
  fi

  printf '\n%bListening-port check:%b\n' "$C_BOLD" "$C_RESET"
  if check_listening_port "$control_port" "$protocol"; then ok "Control port ${control_port}/${protocol} is listening."; else warn "Control port ${control_port}/${protocol} is not listening yet."; fi
  if [[ "$CONFIG_MODE" == "standard" ]]; then
    for p in "${PARSED_PORTS[@]}"; do
      if check_listening_port "$p" "$protocol"; then ok "Tunnel port ${p}/${protocol} is listening."; else warn "Tunnel port ${p}/${protocol} is not listening yet."; fi
    done
    firewall_hint "$protocol" "$control_port" "${PARSED_PORTS[@]}"
  else
    info "Advanced port rules are active; use Diagnostics for post-start rule checks."
    firewall_hint "$protocol" "$control_port"
  fi
  if ! save_backhaul_source "$source_repo"; then
    err "Configuration succeeded but source state could not be persisted; rolling back for consistency."
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
    return 1
  fi
  write_server_info "$control_port" "$transport" "$token" "$source_repo"
  print_server_secret_summary "$token" "$control_port" "$transport"
  ok "Server configuration completed."
}

configure_client() {
  printf '\n%b===== Configure foreign / client side =====%b\n' "$C_BOLD" "$C_RESET"
  local iran_host control_port remote_addr transport token source_repo version edge_ip=""
  local config_snapshot="" service_snapshot="" binary_snapshot="" source_snapshot="" was_active="no" was_enabled="no" protocol
  reset_config_options
  if [[ -x "$BACKHAUL_BIN" ]]; then
    source_repo=$(current_backhaul_source)
    version=$("$BACKHAUL_BIN" -v 2>/dev/null || printf 'latest')
    info "Shared Backhaul binary: ${source_repo} ${version}. Use Source migration/Upgrade to change it."
  else
    source_repo=$(choose_backhaul_source)
    version=$(ask_version)
  fi
  iran_host=$(ask_host "Iran server IP or hostname")
  control_port=$(ask_port "Backhaul control port" "8080")
  remote_addr=$(format_host_port "$iran_host" "$control_port")
  transport=$(choose_transport)
  CONFIG_MODE=$(choose_config_mode)
  token=$(ask_client_token)
  if [[ "$transport" == "ws" || "$transport" == "wss" || "$transport" == "wsmux" || "$transport" == "wssmux" ]]; then
    edge_ip=$(tty_read "CDN edge IP/host (optional, Enter = none): ")
    if [[ -n "$edge_ip" ]] && ! validate_host "$edge_ip"; then
      warn "Invalid edge host; continuing without edge_ip."
      edge_ip=""
    fi
  fi
  if [[ "$CONFIG_MODE" == "advanced" ]]; then
    configure_advanced_options "client" "$transport" "$source_repo" || return 1
  fi

  handle_old_services
  ensure_directories
  service_is_active && was_active="yes"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && was_enabled="yes"
  snapshot_file "$CONFIG_FILE" "config" config_snapshot
  snapshot_file "$SERVICE_FILE" "service" service_snapshot
  snapshot_file "$BACKHAUL_BIN" "backhaul-bin" binary_snapshot
  snapshot_file "$BACKHAUL_SOURCE_FILE" "source" source_snapshot
  if ! download_backhaul "$version" "$source_repo"; then
    return 1
  fi
  if ! write_client_config "$remote_addr" "$transport" "$token" "$edge_ip" "$source_repo"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
    return 1
  fi
  if ! write_service_file "$source_repo"; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
    return 1
  fi
  if ! start_and_verify_service; then
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
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
    err "Configuration succeeded but source state could not be persisted; rolling back for consistency."
    rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot"
    return 1
  fi
  write_client_info "$remote_addr" "$transport" "$source_repo"
  ok "Client configuration completed."
}

ask_profile_name() {
  local prompt_text="$1" name
  while true; do
    name=$(tty_read "${prompt_text}: ")
    if validate_profile_name "$name" && [[ "$name" != "default" ]]; then
      printf '%s' "$name"
      return 0
    fi
    warn "Use 1-32 letters, numbers, '_' or '-'; 'default' is reserved." >&2
  done
}

list_profiles() {
  local idx profile file role transport endpoint svc state marker
  refresh_profile_names
  printf '\n%bProfiles%b\n' "$C_BOLD" "$C_RESET"
  for idx in "${!PROFILE_NAMES[@]}"; do
    profile="${PROFILE_NAMES[$idx]}"
    marker=" "
    [[ "$profile" == "$ACTIVE_PROFILE" ]] && marker="*"
    if profile_exists "$profile"; then
      file=$(profile_config_path "$profile")
      role=$(config_role_from_file "$file")
      transport=$(config_value_from_file "$file" transport 2>/dev/null || printf '?')
      if [[ "$role" == "server" ]]; then endpoint=$(config_value_from_file "$file" bind_addr 2>/dev/null || printf '?'); else endpoint=$(config_value_from_file "$file" remote_addr 2>/dev/null || printf '?'); fi
      svc=$(profile_service_name "$profile")
      state="stopped"; systemctl is-active --quiet "$svc" 2>/dev/null && state="active"
      printf ' %s%d) %-16s %-7s %-7s %-8s %s\n' "$marker" "$((idx + 1))" "$profile" "$role" "$transport" "$state" "$endpoint"
    else
      printf ' %s%d) %-16s not configured\n' "$marker" "$((idx + 1))" "$profile"
    fi
  done
}

select_profile_interactive() {
  local choice idx
  list_profiles
  choice=$(tty_read "Profile number (Enter = cancel): ")
  [[ -n "$choice" ]] || return 0
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid profile number."; return 1; }
  idx=$((10#$choice - 1))
  (( idx >= 0 && idx < ${#PROFILE_NAMES[@]} )) || { warn "Invalid profile number."; return 1; }
  select_profile "${PROFILE_NAMES[$idx]}"
}

create_profile_interactive() {
  local name old_profile="$ACTIVE_PROFILE" role_choice rc=0
  name=$(ask_profile_name "New profile name")
  profile_exists "$name" && { err "Profile '${name}' already exists."; return 1; }
  printf '\nRole:\n  1) Iran server\n  2) Foreign client\n'
  role_choice=$(tty_read "Role [1]: ")
  apply_profile_context "$name" || return 1
  ensure_directories
  case "${role_choice:-1}" in
    1) configure_server || rc=$? ;;
    2) configure_client || rc=$? ;;
    *) err "Invalid role."; rc=1 ;;
  esac
  if (( rc != 0 )); then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$SERVICE_FILE"
    rm -rf -- "$CONFIG_DIR"
    apply_profile_context "$old_profile"
    save_active_profile "$old_profile"
    systemctl daemon-reload || true
    return "$rc"
  fi
  save_active_profile "$name"
  ok "Profile '${name}' created and selected."
}

clone_active_profile() {
  local name target_dir source_repo tls_cert tls_key old_profile="$ACTIVE_PROFILE"
  profile_exists "$ACTIVE_PROFILE" || { err "The active profile is not configured."; return 1; }
  name=$(ask_profile_name "Clone name")
  profile_exists "$name" && { err "Profile '${name}' already exists."; return 1; }
  target_dir="${PROFILES_DIR}/${name}"
  install -d -m 0700 "$target_dir"
  install -m 0600 "$CONFIG_FILE" "$target_dir/config.toml"
  [[ -f "$INFO_FILE" ]] && install -m 0600 "$INFO_FILE" "$target_dir/backhaul-info.txt"
  tls_cert=$(config_value_from_file "$CONFIG_FILE" tls_cert 2>/dev/null || true)
  tls_key=$(config_value_from_file "$CONFIG_FILE" tls_key 2>/dev/null || true)
  if [[ -n "$tls_cert" || -n "$tls_key" ]]; then
    if [[ ! -r "$tls_cert" || ! -r "$tls_key" ]]; then
      rm -rf -- "$target_dir"
      err "The source profile references unreadable TLS files; clone cancelled."
      return 1
    fi
    install -d -m 0700 "$target_dir/tls"
    install -m 0600 "$tls_cert" "$target_dir/tls/cert.pem"
    install -m 0600 "$tls_key" "$target_dir/tls/key.pem"
    if ! replace_config_string_value "$target_dir/config.toml" tls_cert "$target_dir/tls/cert.pem" ||
       ! replace_config_string_value "$target_dir/config.toml" tls_key "$target_dir/tls/key.pem"; then
      rm -rf -- "$target_dir"
      err "Could not make the cloned TLS configuration self-contained."
      return 1
    fi
  fi
  source_repo=$(current_backhaul_source)
  apply_profile_context "$name"
  if ! write_service_file "$source_repo" || ! systemctl daemon-reload || ! save_active_profile "$name"; then
    rm -f -- "$SERVICE_FILE"
    rm -rf -- "$target_dir"
    apply_profile_context "$old_profile"
    systemctl daemon-reload || true
    err "Clone failed; the partial profile was removed."
    return 1
  fi
  if [[ -f "$INFO_FILE" ]]; then
    sed -i -E \
      -e "s|^Profile[[:space:]]*:.*$|Profile       : ${name}|" \
      -e "s|^Config[[:space:]]*:.*$|Config        : ${CONFIG_FILE}|" \
      -e "s|^Service[[:space:]]*:.*$|Service       : ${SERVICE_NAME}|" \
      "$INFO_FILE"
  fi
  ok "Cloned profile as '${name}'. It is stopped by default."
  if ask_yn "Start and enable the cloned profile now?" "n"; then service_action start; fi
}

delete_profile_interactive() {
  local choice idx profile svc fallback="" candidate
  refresh_profile_names
  list_profiles
  choice=$(tty_read "Profile number to delete (Enter = cancel): ")
  [[ -n "$choice" ]] || return 0
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid profile number."; return 1; }
  idx=$((10#$choice - 1))
  (( idx >= 0 && idx < ${#PROFILE_NAMES[@]} )) || { warn "Invalid profile number."; return 1; }
  profile="${PROFILE_NAMES[$idx]}"
  [[ "$profile" != "default" ]] || { err "The default profile cannot be deleted here; use Uninstall for the complete installation."; return 1; }
  ask_yn "Permanently delete profile '${profile}' and its service?" "n" || return 0
  svc=$(profile_service_name "$profile")
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" >/dev/null 2>&1 || true
  rm -f -- "/etc/systemd/system/${svc}"
  rm -rf -- "${PROFILES_DIR:?}/${profile}"
  systemctl daemon-reload || true
  if [[ "$ACTIVE_PROFILE" == "$profile" ]]; then
    refresh_profile_names
    for candidate in "${PROFILE_NAMES[@]}"; do
      if profile_exists "$candidate"; then fallback="$candidate"; break; fi
    done
    fallback="${fallback:-default}"
    apply_profile_context "$fallback"
    save_active_profile "$fallback"
  fi
  ok "Profile '${profile}' deleted."
}

profiles_menu() {
  local choice
  list_profiles
  printf '\n  1) Select active profile\n'
  printf '  2) Create profile\n'
  printf '  3) Clone active profile\n'
  printf '  4) Delete profile\n'
  printf '  0) Back\n'
  choice=$(tty_read "Choose: ")
  case "$choice" in
    1) select_profile_interactive ;;
    2) create_profile_interactive ;;
    3) clone_active_profile ;;
    4) delete_profile_interactive ;;
    0|"") return 0 ;;
    *) warn "Invalid choice."; return 1 ;;
  esac
}

config_value_from_file() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$file" | head -n 1
}

config_value() {
  config_value_from_file "$CONFIG_FILE" "$1"
}

config_role_from_file() {
  local file="$1"
  [[ -f "$file" ]] || { printf 'not configured'; return; }
  if grep -qE '^\[server\][[:space:]]*$' "$file"; then printf 'server';
  elif grep -qE '^\[client\][[:space:]]*$' "$file"; then printf 'client';
  else printf 'unknown'; fi
}

config_role() {
  local role
  role=$(config_role_from_file "$CONFIG_FILE")
  case "$role" in
    server) printf 'server (Iran)' ;;
    client) printf 'client (foreign)' ;;
    *) printf '%s' "$role" ;;
  esac
}

config_key_allowed() {
  local source_repo="$1" role="$2" key="$3"
  local common_server=' bind_addr transport token nodelay keepalive_period channel_size log_level ports pprof mux_session mux_version mux_framesize mux_recievebuffer mux_streambuffer sniffer web_port sniffer_log tls_cert tls_key heartbeat mux_con accept_udp skip_optz mss so_rcvbuf so_sndbuf proxy_protocol '
  local common_client=' remote_addr transport token connection_pool retry_interval nodelay keepalive_period log_level pprof mux_session mux_version mux_framesize mux_recievebuffer mux_streambuffer sniffer web_port sniffer_log dial_timeout aggressive_pool edge_ip skip_optz mss so_rcvbuf so_sndbuf '
  local power_server=' web_bind_addr web_username web_password udp_queue_size udp_queue_limit udp_max_flows '
  local power_client=' max_pool_size web_bind_addr web_username web_password tls_verify '
  validate_backhaul_source "$source_repo" || return 1
  case "$role" in
    server)
      [[ "$common_server" == *" ${key} "* ]] && return 0
      [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" && "$power_server" == *" ${key} "* ]]
      ;;
    client)
      [[ "$common_client" == *" ${key} "* ]] && return 0
      [[ "$source_repo" == "$POWERMATIN_BACKHAUL_REPO" && "$power_client" == *" ${key} "* ]]
      ;;
    *) return 1 ;;
  esac
}

check_config_compatibility_file() {
  local source_repo="$1" file="$2" role key transport
  COMPAT_UNSUPPORTED_KEYS=()
  validate_backhaul_source "$source_repo" || return 1
  [[ -f "$file" ]] || { COMPAT_UNSUPPORTED_KEYS+=("missing-config"); return 1; }
  role=$(config_role_from_file "$file")
  [[ "$role" == "server" || "$role" == "client" ]] || { COMPAT_UNSUPPORTED_KEYS+=("invalid-section"); return 1; }
  transport=$(config_value_from_file "$file" transport 2>/dev/null || true)
  validate_transport "$transport" || COMPAT_UNSUPPORTED_KEYS+=("transport=${transport:-missing}")
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! config_key_allowed "$source_repo" "$role" "$key"; then
      COMPAT_UNSUPPORTED_KEYS+=("$key")
    fi
  done < <(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\1/p' "$file")
  (( ${#COMPAT_UNSUPPORTED_KEYS[@]} == 0 ))
}

show_compatibility() {
  local source_repo="${1:-}" file="${2:-$CONFIG_FILE}"
  if [[ -z "$source_repo" ]]; then source_repo=$(read_saved_backhaul_source 2>/dev/null || printf '%s' "$MUSIXAL_BACKHAUL_REPO"); fi
  printf '\n%bCompatibility check%b\n' "$C_BOLD" "$C_RESET"
  printf '  Target     : %s\n' "$source_repo"
  printf '  Config     : %s\n' "$file"
  if check_config_compatibility_file "$source_repo" "$file"; then
    ok "Configuration is compatible with ${source_repo}."
    return 0
  fi
  err "Configuration is not compatible with ${source_repo}."
  printf '  Unsupported: %s\n' "${COMPAT_UNSUPPORTED_KEYS[*]}"
  return 1
}

sanitize_config_for_source() {
  local source_repo="$1" input="$2" output="$3" tmp key had_power_web=0
  validate_backhaul_source "$source_repo" || return 1
  [[ -f "$input" ]] || return 1
  tmp="${output}.tmp.$$"
  cp -a -- "$input" "$tmp"
  if check_config_compatibility_file "$source_repo" "$input"; then
    mv -f -- "$tmp" "$output"
    return 0
  fi
  for key in "${COMPAT_UNSUPPORTED_KEYS[@]}"; do
    case "$key" in
      web_bind_addr|web_username|web_password)
        had_power_web=1
        sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"
        ;;
      max_pool_size|tls_verify|udp_queue_size|udp_queue_limit|udp_max_flows)
        sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"
        ;;
      *) rm -f -- "$tmp"; return 1 ;;
    esac
  done
  if (( had_power_web )) && [[ "$source_repo" == "$MUSIXAL_BACKHAUL_REPO" ]]; then
    sed -i -E 's/^[[:space:]]*web_port[[:space:]]*=.*/web_port = 0/' "$tmp"
  fi
  if ! check_config_compatibility_file "$source_repo" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$output"
}

show_status() {
  local version="not installed" active="inactive" enabled="disabled" role transport address source_repo="not selected" profile_count=0 profile
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
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do profile_exists "$profile" && ((profile_count += 1)); done
  if [[ "$role" == server* ]]; then address=$(config_value bind_addr 2>/dev/null || true); else address=$(config_value remote_addr 2>/dev/null || true); fi
  printf '\n%bBackhaul status%b\n' "$C_BOLD" "$C_RESET"
  printf '  Manager    : v%s\n' "$MANAGER_VERSION"
  printf '  Backhaul   : %s\n' "$version"
  printf '  Source     : %s\n' "$source_repo"
  printf '  Profile    : %s (%s managed)\n' "$ACTIVE_PROFILE" "$profile_count"
  printf '  Role       : %s\n' "$role"
  printf '  Transport  : %s\n' "${transport:-unknown}"
  printf '  Endpoint   : %s\n' "${address:-unknown}"
  printf '  Service    : %s, %s\n' "$active" "$enabled"
  printf '  Config     : %s\n' "$CONFIG_FILE"
  [[ -n "$LOG_FILE" ]] && printf '  Run log    : %s\n' "$LOG_FILE"
}

diagnose() {
  local failures=0 warnings=0 version role transport endpoint protocol port source_repo
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

  source_repo=$(current_backhaul_source)
  if check_config_compatibility_file "$source_repo" "$CONFIG_FILE"; then
    ok "Config is compatible with ${source_repo}."
  else
    err "Config contains unsupported settings for ${source_repo}: ${COMPAT_UNSUPPORTED_KEYS[*]}"
    ((failures += 1))
  fi

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

curl_config_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/}
  value=${value//$'\r'/}
  printf '%s' "$value"
}

show_metrics() {
  local pid memory tasks restarts cpu_mem web_port username password stats auth_file="" auth_value service_state
  printf '\n%b===== Health & metrics: %s =====%b\n' "$C_BOLD" "$ACTIVE_PROFILE" "$C_RESET"
  if ! profile_exists "$ACTIVE_PROFILE"; then err "Active profile is not configured."; return 1; fi
  pid=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || printf '0')
  memory=$(systemctl show "$SERVICE_NAME" -p MemoryCurrent --value 2>/dev/null || printf '?')
  tasks=$(systemctl show "$SERVICE_NAME" -p TasksCurrent --value 2>/dev/null || printf '?')
  restarts=$(systemctl show "$SERVICE_NAME" -p NRestarts --value 2>/dev/null || printf '?')
  service_state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
  printf '  Service    : %s\n' "${service_state:-unknown}"
  printf '  PID        : %s\n' "$pid"
  printf '  Memory     : %s bytes\n' "$memory"
  printf '  Tasks      : %s\n' "$tasks"
  printf '  Restarts   : %s\n' "$restarts"
  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] && command -v ps >/dev/null 2>&1; then
    cpu_mem=$(ps -p "$pid" -o %cpu=,%mem=,etimes= 2>/dev/null | awk '{$1=$1;print}' || true)
    [[ -n "$cpu_mem" ]] && printf '  CPU/MEM/age: %s\n' "$cpu_mem"
  fi
  web_port=$(config_value web_port 2>/dev/null || printf '0')
  validate_port "$web_port" || {
    info "Backhaul web metrics are disabled; systemd metrics above are still available."
    return 0
  }
  username=$(config_value web_username 2>/dev/null || true)
  password=$(config_value web_password 2>/dev/null || true)
  if [[ -n "$username" && -n "$password" ]]; then
    auth_file=$(mktemp /tmp/backhaul-curl.XXXXXX)
    chmod 0600 "$auth_file"
    auth_value=$(curl_config_escape "${username}:${password}")
    printf 'user = "%s"\n' "$auth_value" > "$auth_file"
    stats=$(curl -fsS --connect-timeout 3 --max-time 5 --config "$auth_file" "http://127.0.0.1:${web_port}/stats" 2>/dev/null || true)
    rm -f -- "$auth_file"
  else
    stats=$(curl -fsS --connect-timeout 3 --max-time 5 "http://127.0.0.1:${web_port}/stats" 2>/dev/null || true)
  fi
  if [[ -z "$stats" ]]; then
    warn "Backhaul /stats did not respond on loopback port ${web_port}."
    return 0
  fi
  printf '\n%bBackhaul /stats%b\n' "$C_BOLD" "$C_RESET"
  if command -v jq >/dev/null 2>&1; then
    jq . <<< "$stats" 2>/dev/null || printf '%s\n' "$stats"
  else
    printf '%s\n' "$stats" | sed 's/^{//;s/}$//;s/,/\n/g;s/^/  /'
  fi
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

resolve_release_version() {
  local source_repo="$1" requested="${2:-latest}" release_base location version
  validate_backhaul_source "$source_repo" || return 1
  validate_version "$requested" || return 1
  requested=$(normalize_version "$requested")
  if [[ "$requested" != "latest" ]]; then
    printf '%s' "$requested"
    return 0
  fi
  release_base=$(backhaul_release_base "$source_repo") || return 1
  location=$(curl --proto '=https' --tlsv1.2 -fsSI --connect-timeout 10 --max-time 30 "${release_base}/latest" \
    | sed -nE 's/^[Ll]ocation:[[:space:]]*([^[:space:]\r]+).*/\1/p' | head -n 1)
  version="${location##*/}"
  validate_version "$version" || { err "Could not resolve the latest release for ${source_repo}."; return 1; }
  normalize_version "$version"
}

version_is_older() {
  local candidate="${1#v}" current="${2#v}" candidate_base current_base candidate_core current_core
  local candidate_pre="" current_pre="" idx left right
  local -a candidate_parts=() current_parts=() candidate_ids=() current_ids=()
  validate_version "$candidate" && validate_version "$current" || return 2

  # Build metadata has no effect on SemVer precedence.
  candidate_base="${candidate%%+*}"
  current_base="${current%%+*}"
  if [[ "$candidate_base" == *-* ]]; then
    candidate_pre="${candidate_base#*-}"
    candidate_core="${candidate_base%%-*}"
  else
    candidate_core="$candidate_base"
  fi
  if [[ "$current_base" == *-* ]]; then
    current_pre="${current_base#*-}"
    current_core="${current_base%%-*}"
  else
    current_core="$current_base"
  fi

  IFS='.' read -ra candidate_parts <<< "$candidate_core"
  IFS='.' read -ra current_parts <<< "$current_core"
  for idx in 0 1 2; do
    left="${candidate_parts[$idx]:-0}"
    right="${current_parts[$idx]:-0}"
    if (( 10#$left < 10#$right )); then return 0; fi
    if (( 10#$left > 10#$right )); then return 1; fi
  done

  # A prerelease has lower precedence than the corresponding stable release.
  [[ -n "$candidate_pre" && -z "$current_pre" ]] && return 0
  [[ -z "$candidate_pre" && -n "$current_pre" ]] && return 1
  [[ -z "$candidate_pre" && -z "$current_pre" ]] && return 1

  IFS='.' read -ra candidate_ids <<< "$candidate_pre"
  IFS='.' read -ra current_ids <<< "$current_pre"
  for ((idx = 0; idx < ${#candidate_ids[@]} || idx < ${#current_ids[@]}; idx++)); do
    if (( idx >= ${#candidate_ids[@]} )); then return 0; fi
    if (( idx >= ${#current_ids[@]} )); then return 1; fi
    left="${candidate_ids[$idx]}"
    right="${current_ids[$idx]}"
    [[ "$left" == "$right" ]] && continue
    if [[ "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ ]]; then
      if (( ${#left} < ${#right} )); then return 0; fi
      if (( ${#left} > ${#right} )); then return 1; fi
      [[ "$left" < "$right" ]] && return 0 || return 1
    fi
    [[ "$left" =~ ^[0-9]+$ ]] && return 0
    [[ "$right" =~ ^[0-9]+$ ]] && return 1
    [[ "$left" < "$right" ]] && return 0 || return 1
  done
  return 1
}

check_all_profiles_compatibility() {
  local source_repo="$1" profile file
  INCOMPATIBLE_PROFILES=()
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    file=$(profile_config_path "$profile")
    if ! check_config_compatibility_file "$source_repo" "$file"; then
      INCOMPATIBLE_PROFILES+=("${profile}: ${COMPAT_UNSUPPORTED_KEYS[*]}")
    fi
  done
  (( ${#INCOMPATIBLE_PROFILES[@]} == 0 ))
}

print_incompatible_profiles() {
  local item
  for item in "${INCOMPATIBLE_PROFILES[@]}"; do printf '  - %s\n' "$item"; done
}

sanitize_all_profiles_for_source() {
  local source_repo="$1" profile file migrated
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    file=$(profile_config_path "$profile")
    migrated="${file}.migrated.$$"
    if ! sanitize_config_for_source "$source_repo" "$file" "$migrated"; then
      rm -f -- "$migrated"
      err "Could not safely adapt profile '${profile}' for ${source_repo}."
      return 1
    fi
    mv -f -- "$migrated" "$file"
  done
}

migrate_backhaul_source() {
  local target_source="$1" requested="${2:-latest}" allow_downgrade="${3:-no}" allow_sanitize="${4:-no}"
  local current_source current_version target_version safety original_profile profile svc active enabled
  validate_backhaul_source "$target_source" || { err "Invalid migration target: ${target_source}"; return 1; }
  managed_installation_exists || { err "No managed installation found."; return 1; }
  [[ -x "$BACKHAUL_BIN" ]] || { err "Backhaul binary is missing."; return 1; }
  current_source=$(current_backhaul_source)
  [[ "$current_source" != "$target_source" ]] || { warn "Backhaul already uses ${target_source}."; return 2; }
  current_version=$("$BACKHAUL_BIN" -v 2>/dev/null || true)
  target_version=$(resolve_release_version "$target_source" "$requested") || return 1
  if [[ -n "$current_version" ]] && version_is_older "$target_version" "$current_version" && [[ "$allow_downgrade" != "yes" ]]; then
    warn "Migration would downgrade Backhaul: ${current_version} -> ${target_version}."
    return 3
  fi
  if ! check_all_profiles_compatibility "$target_source"; then
    warn "Some profiles contain settings unsupported by ${target_source}:"
    print_incompatible_profiles
    if [[ "$allow_sanitize" != "yes" ]]; then return 4; fi
  fi

  create_backup "source-migration" || return 1
  safety="$LAST_BACKUP_DIR"
  original_profile="$ACTIVE_PROFILE"
  if [[ "$allow_sanitize" == "yes" ]]; then
    if ! sanitize_all_profiles_for_source "$target_source"; then
      apply_backup_tree "$safety" || true
      return 1
    fi
  fi
  if ! download_backhaul "$target_version" "$target_source"; then
    apply_backup_tree "$safety" || true
    return 1
  fi
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    apply_profile_context "$profile"
    if ! write_service_file "$target_source"; then
      apply_backup_tree "$safety" || true
      return 1
    fi
  done
  if ! systemctl daemon-reload; then
    apply_backup_tree "$safety" || true
    return 1
  fi
  while read -r svc active enabled; do
    [[ "$active" == "yes" ]] || continue
    if ! systemctl restart "$svc" || ! sleep 1 || ! systemctl is-active --quiet "$svc"; then
      err "${svc} failed after source migration; restoring the previous installation."
      apply_backup_tree "$safety" || err "Automatic migration rollback failed: ${safety}"
      return 1
    fi
  done < "$safety/services.state"
  save_backhaul_source "$target_source" || { apply_backup_tree "$safety" || true; return 1; }
  if profile_exists "$original_profile" || [[ "$original_profile" == "default" ]]; then apply_profile_context "$original_profile"; fi
  save_active_profile "$ACTIVE_PROFILE"
  ok "Migration complete: ${current_source} ${current_version} -> ${target_source} ${target_version}."
}

migrate_source_interactive() {
  local target_source version rc downgrade="no" sanitize="no"
  printf '\n%b===== Migrate Backhaul source =====%b\n' "$C_BOLD" "$C_RESET"
  printf 'Current source: %s\n' "$(current_backhaul_source)"
  target_source=$(choose_backhaul_source)
  if [[ "$target_source" == "$(current_backhaul_source)" ]]; then
    info "Source unchanged; migration cancelled."
    return 0
  fi
  version=$(ask_version)
  while true; do
    if migrate_backhaul_source "$target_source" "$version" "$downgrade" "$sanitize"; then return 0; else rc=$?; fi
    case "$rc" in
      3)
        ask_yn "Continue with this explicit downgrade?" "n" || { info "Migration cancelled."; return 0; }
        downgrade="yes"
        ;;
      4)
        warn "Safe adaptation removes target-unsupported fork-only keys; web metrics are disabled when moving to Musixal."
        ask_yn "Create a backup and adapt incompatible profiles automatically?" "n" || { info "Migration cancelled."; return 0; }
        sanitize="yes"
        ;;
      *) return "$rc" ;;
    esac
  done
}

upgrade_backhaul() {
  local version="${1:-latest}" source_repo="${2:-}" safety svc active enabled restarted=0
  validate_version "$version" || { err "Invalid Backhaul version: ${version}"; return 1; }
  version=$(normalize_version "$version")
  managed_installation_exists || { err "No managed installation found. Configure Backhaul first."; return 1; }
  if [[ -z "$source_repo" ]]; then
    source_repo=$(current_backhaul_source)
  fi
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  check_all_profiles_compatibility "$source_repo" || {
    err "One or more profiles are incompatible with the selected source; run Compatibility check first."
    print_incompatible_profiles
    return 1
  }
  create_backup "upgrade" || return 1
  safety="$LAST_BACKUP_DIR"
  if ! download_backhaul "$version" "$source_repo"; then return 1; fi
  if (( BINARY_CHANGED == 0 )); then
    save_backhaul_source "$source_repo"
    return 0
  fi
  while read -r svc active enabled; do
    [[ "$active" == "yes" ]] || continue
    if ! systemctl restart "$svc" || ! sleep 1 || ! systemctl is-active --quiet "$svc"; then
      err "${svc} failed after upgrade; restoring the complete pre-upgrade state."
      apply_backup_tree "$safety" || err "Automatic rollback failed; recovery backup: ${safety}"
      return 1
    fi
    ((restarted += 1))
  done < "$safety/services.state"
  save_backhaul_source "$source_repo"
  if (( restarted > 0 )); then ok "Upgrade complete: ${DOWNLOADED_VERSION}; ${restarted} active profile(s) verified.";
  else ok "Upgraded to ${DOWNLOADED_VERSION}; all profiles remain stopped."; fi
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
  local profile svc
  printf '\n%b===== Uninstall Backhaul =====%b\n' "$C_BOLD" "$C_RESET"
  warn "This removes all managed Backhaul services and the shared binary."
  if ! ask_yn "Continue?" "n"; then info "Cancelled."; return 0; fi
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    svc=$(profile_service_name "$profile")
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
    rm -f -- "/etc/systemd/system/${svc}"
  done
  systemctl daemon-reload
  rm -rf -- "$BACKHAUL_DIR"
  if ask_yn "Also permanently delete config, credentials, and backups?" "n"; then
    rm -rf -- "$BASE_CONFIG_DIR" "$STATE_DIR"
    apply_profile_context "default"
    ok "Backhaul, config, credentials, and backups were removed."
    info "Run logs are preserved in ${LOG_DIR}."
  else
    ok "Backhaul was removed; config and backups were preserved."
    info "Preserved: ${BASE_CONFIG_DIR} and ${BACKUP_DIR}"
  fi
}

backhaul_maintenance_menu() {
  local choice version source_repo
  printf '\n%bBackhaul maintenance%b\n' "$C_BOLD" "$C_RESET"
  printf '  1) Upgrade current source\n'
  printf '  2) Migrate source\n'
  printf '  3) Check current compatibility\n'
  printf '  4) Check power0matin compatibility\n'
  printf '  5) Check Musixal compatibility\n'
  printf '  0) Back\n'
  choice=$(tty_read "Choose: ")
  case "$choice" in
    1) version=$(ask_version); upgrade_backhaul "$version" ;;
    2) migrate_source_interactive ;;
    3) source_repo=$(current_backhaul_source); show_compatibility "$source_repo" ;;
    4) show_compatibility "$POWERMATIN_BACKHAUL_REPO" ;;
    5) show_compatibility "$MUSIXAL_BACKHAUL_REPO" ;;
    0|"") return 0 ;;
    *) warn "Invalid choice."; return 1 ;;
  esac
}

health_logs_menu() {
  local choice
  printf '\n%bHealth & logs%b\n' "$C_BOLD" "$C_RESET"
  printf '  1) Health / metrics\n'
  printf '  2) Recent logs\n'
  printf '  3) Follow live logs\n'
  printf '  0) Back\n'
  choice=$(tty_read "Choose: ")
  case "$choice" in
    1) show_metrics ;;
    2) show_logs 80 ;;
    3) follow_logs ;;
    0|"") return 0 ;;
    *) warn "Invalid choice."; return 1 ;;
  esac
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
    printf '  7) Backhaul maintenance\n'
    printf '  8) Profiles\n'
    printf '  9) Backup & migration\n'
    printf ' 10) Health & logs\n'
    printf ' 11) Manager install / update\n'
    printf ' 12) Uninstall / purge\n'
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
      7) backhaul_maintenance_menu || true; pause_menu ;;
      8) profiles_menu || true; pause_menu ;;
      9) backup_migration_menu || true; pause_menu ;;
      10) health_logs_menu || true; pause_menu ;;
      11) manager_menu || true; pause_menu ;;
      12) uninstall_backhaul; pause_menu ;;
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
  load_active_profile
  setup_logging
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    -V|--version) printf 'Backhaul Manager %s\n' "$MANAGER_VERSION"; return 0 ;;
  esac

  prepare_runtime
  if [[ "${1:-}" == "--profile" ]]; then
    [[ -n "${2:-}" ]] || { err "--profile requires a profile name."; return 2; }
    profile_exists "$2" || { err "Profile '$2' is not configured."; return 1; }
    apply_profile_context "$2" || return 1
    shift 2
  fi
  case "${1:-}" in
    "") require_tty; interactive_menu ;;
    --status) show_status ;;
    --diagnose) diagnose ;;
    --metrics) show_metrics ;;
    --restart) service_action restart ;;
    --start) service_action start ;;
    --stop) service_action stop ;;
    --upgrade) upgrade_backhaul "${2:-latest}" ;;
    --migrate-source)
      [[ -n "${2:-}" ]] || { err "--migrate-source requires power0matin/Backhaul or Musixal/Backhaul."; return 2; }
      migrate_backhaul_source "$2" "${3:-latest}" "no" "no"
      ;;
    --compat) show_compatibility "${2:-$(current_backhaul_source)}" ;;
    --list-profiles) list_profiles ;;
    --select-profile)
      [[ -n "${2:-}" ]] || { err "--select-profile requires a profile name."; return 2; }
      select_profile "$2"
      ;;
    --backup) create_backup "cli" ;;
    --export)
      [[ -n "${2:-}" ]] || { err "--export requires an absolute .tar.gz path."; return 2; }
      export_backup_bundle "$2"
      ;;
    --import)
      [[ -n "${2:-}" ]] || { err "--import requires a backup .tar.gz path."; return 2; }
      import_backup_bundle "$2"
      ;;
    --restore-backup)
      [[ "${2:-}" =~ ^(backup|import)-[A-Za-z0-9._-]+$ ]] || { err "--restore-backup requires a backup name from --list-backups."; return 2; }
      restore_backup_dir "${BACKUP_DIR}/${2}"
      ;;
    --list-backups) list_backups ;;
    --self-update) update_manager_command ;;
    --logs) show_logs "${2:-80}" ;;
    --follow-logs) follow_logs ;;
    *) err "Unknown option: $1"; usage >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi

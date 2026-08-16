#!/usr/bin/env bash
#
# Backhaul Manager — safe installer and operations helper for Backhaul.
# Repository: https://github.com/power0matin/backhaul-manager
# License: MIT

set -Eeuo pipefail
umask 077

readonly MANAGER_VERSION="3.1.2"
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
readonly OPERATION_LOCK_FILE="/run/lock/backhaul-manager.lock"
readonly UNKNOWN_BACKHAUL_SOURCE="unknown"

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
LEGACY_CONFIG_FILES=()
BACKUP_CHOICES=()
COMPAT_UNSUPPORTED_KEYS=()
INCOMPATIBLE_PROFILES=()
TRANSACTION_ACTIVE=0
TRANSACTION_ROLLBACK_FUNC=""
TRANSACTION_ROLLBACK_ARGS=()
TRANSACTION_ROLLBACK_RUNNING=0
OPERATION_LOCK_HELD=0
STARTED_SERVICE_COUNT=0

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
  rollback_active_transaction "interrupt" || true
  exit 130
}

on_terminate() {
  err "Terminated."
  rollback_active_transaction "termination" || true
  exit 143
}

begin_transaction() {
  local rollback_func="$1"
  shift
  (( TRANSACTION_ACTIVE == 0 )) || { err "An internal transaction is already active."; return 1; }
  declare -F "$rollback_func" >/dev/null || { err "Invalid rollback handler: ${rollback_func}"; return 1; }
  TRANSACTION_ROLLBACK_FUNC="$rollback_func"
  TRANSACTION_ROLLBACK_ARGS=("$@")
  TRANSACTION_ACTIVE=1
}

commit_transaction() {
  TRANSACTION_ACTIVE=0
  TRANSACTION_ROLLBACK_FUNC=""
  TRANSACTION_ROLLBACK_ARGS=()
}

rollback_active_transaction() {
  local reason="${1:-failure}" rollback_func rc=0
  (( TRANSACTION_ACTIVE == 1 )) || return 0
  (( TRANSACTION_ROLLBACK_RUNNING == 0 )) || return 0
  rollback_func="$TRANSACTION_ROLLBACK_FUNC"
  TRANSACTION_ACTIVE=0
  TRANSACTION_ROLLBACK_RUNNING=1
  trap '' INT TERM
  warn "Rolling back the active operation after ${reason}..."
  if "$rollback_func" "${TRANSACTION_ROLLBACK_ARGS[@]}"; then
    :
  else
    rc=$?
    err "Automatic rollback did not complete cleanly; inspect the run log and latest backup before making more changes."
  fi
  TRANSACTION_ROLLBACK_RUNNING=0
  TRANSACTION_ROLLBACK_FUNC=""
  TRANSACTION_ROLLBACK_ARGS=()
  trap on_interrupt INT
  trap on_terminate TERM
  return "$rc"
}

trap on_interrupt INT
trap on_terminate TERM

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
  sudo ./backhaul-manager.sh --adopt-legacy [REPO]
  sudo ./backhaul-manager.sh --set-source REPO
  sudo ./backhaul-manager.sh --compat [REPO] Check config/source compatibility
  sudo ./backhaul-manager.sh --list-profiles List managed profiles and detected legacy tunnels
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
  for cmd in awk basename cmp cp curl find flock grep install journalctl mktemp sed sha256sum sort ss stat systemctl tar tee timeout tr; do
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

operation_requires_lock() {
  local operation="${1:-}"
  if [[ "$operation" == "--profile" ]]; then
    [[ -n "${2:-}" ]] || return 0
    operation="${3:-}"
  fi
  case "$operation" in
    -h|--help|-V|--version|--status|--diagnose|--metrics|--compat|--list-profiles|--list-backups|--logs|--follow-logs)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

acquire_operation_lock() {
  (( OPERATION_LOCK_HELD == 0 )) || return 0
  if ! install -d -m 0755 "$(dirname "$OPERATION_LOCK_FILE")"; then
    err "Could not prepare the Manager lock directory."
    return 1
  fi
  if ! { exec 9>"$OPERATION_LOCK_FILE"; }; then
    err "Could not open the Manager operation lock."
    return 1
  fi
  if ! flock -n 9; then
    err "Another Backhaul Manager operation is already running."
    info "Finish or exit the other Manager session before making changes."
    return 1
  fi
  OPERATION_LOCK_HELD=1
}

setup_logging() {
  install -d -m 0700 "$LOG_DIR" || { err "Could not create ${LOG_DIR}."; return 1; }
  LOG_FILE="${LOG_DIR}/run-$(date +%Y%m%d-%H%M%S)-$$.log"
  : > "$LOG_FILE" || return 1
  chmod 0600 "$LOG_FILE" || return 1
  exec > >(tee -a "$LOG_FILE") 2>&1
}

ensure_directories() {
  install -d -m 0755 "$BACKHAUL_DIR" || return 1
  install -d -m 0700 "$BASE_CONFIG_DIR" "$PROFILES_DIR" "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" || return 1
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

matching_managed_profile_for_config() {
  local legacy_file="$1" dir name default_config="${BASE_CONFIG_DIR}/config.toml"
  [[ -f "$legacy_file" ]] || return 1
  if [[ "$legacy_file" != "$default_config" && -f "$default_config" ]] && cmp -s -- "$legacy_file" "$default_config"; then
    printf 'default'
    return 0
  fi
  [[ -d "$PROFILES_DIR" ]] || return 1
  for dir in "$PROFILES_DIR"/*; do
    [[ -f "${dir}/config.toml" ]] || continue
    if cmp -s -- "$legacy_file" "${dir}/config.toml"; then
      name="${dir##*/}"
      validate_profile_name "$name" || continue
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

refresh_legacy_configs_from_root() {
  local root="$1" file role transport endpoint
  LEGACY_CONFIG_FILES=()
  [[ -d "$root" ]] || return 0
  for file in "$root"/*.toml; do
    [[ -f "$file" ]] || continue
    [[ ! -L "$file" ]] || continue
    [[ "$file" != "$root/config.toml" ]] || continue
    validate_legacy_config_basename "${file##*/}" || continue
    role=$(config_role_from_file "$file")
    [[ "$role" == "server" || "$role" == "client" ]] || continue
    transport=$(config_value_from_file "$file" transport 2>/dev/null || true)
    validate_transport "$transport" || continue
    if [[ "$role" == "server" ]]; then
      endpoint=$(config_value_from_file "$file" bind_addr 2>/dev/null || true)
    else
      endpoint=$(config_value_from_file "$file" remote_addr 2>/dev/null || true)
    fi
    validate_endpoint "$endpoint" || continue
    LEGACY_CONFIG_FILES+=("$file")
  done
}

validate_legacy_config_basename() {
  local name="$1"
  [[ "$name" != "config.toml" && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,122}\.toml$ ]]
}

validate_service_unit_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9@_.:-]{0,127}\.service$ ]]
}

refresh_legacy_configs() {
  refresh_legacy_configs_from_root "$BASE_CONFIG_DIR"
}

legacy_profile_suggestion() {
  local file="$1" stem name
  stem="$(basename "$file" .toml)"
  name="$stem"
  [[ "$name" == config-* ]] && name="${name#config-}"
  name="${name//[^A-Za-z0-9_-]/-}"
  name="${name:0:32}"
  if [[ -z "$name" || "$name" == "default" || "$name" == -* ]]; then
    name="legacy-${name#-}"
    name="${name:0:32}"
  fi
  validate_profile_name "$name" && [[ "$name" != "default" ]] || return 1
  printf '%s' "$name"
}

find_services_for_config_file() {
  local config_file="$1" requested_dir="${2:-}" unit_dir unit_file service
  local -a unit_dirs=()
  local -A seen=()
  [[ -f "$config_file" ]] || return 1
  if [[ -n "$requested_dir" ]]; then
    unit_dirs=("$requested_dir")
  else
    unit_dirs=(
      /etc/systemd/system
      /run/systemd/system
      /usr/local/lib/systemd/system
      /usr/lib/systemd/system
      /lib/systemd/system
    )
  fi
  for unit_dir in "${unit_dirs[@]}"; do
    [[ -d "$unit_dir" ]] || continue
    for unit_file in "$unit_dir"/*.service; do
      [[ -f "$unit_file" ]] || continue
      service=$(basename "$unit_file")
      [[ -n "${seen[$service]:-}" ]] && continue
      seen[$service]=1
      if service_references_config_file "$service" "$unit_file" "$config_file"; then
        printf '%s\n' "$service"
      fi
    done
  done
}

service_fragment_path() {
  local service="$1" fallback="${2:-}" fragment=""
  [[ -n "$service" ]] || return 1
  fragment=$(systemctl show "$service" -p FragmentPath --value 2>/dev/null || true)
  if [[ "$fragment" == /* && "$fragment" == *.service && "$fragment" != *$'\n'* && -f "$fragment" ]]; then
    printf '%s' "$fragment"
    return 0
  fi
  if [[ -n "$fallback" && -f "$fallback" ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  return 1
}

service_exec_binary_path() {
  local service="$1" unit_file="$2" exec_start line command path=""
  [[ -n "$service" ]] || return 1
  exec_start=$(systemctl show "$service" -p ExecStart --value 2>/dev/null || true)
  # A structured systemd ExecStart record is authoritative over a stale unit
  # file and also exposes legacy binaries outside /opt/backhaul.
  if [[ "$exec_start" == *"path="* || "$exec_start" == *"argv[]="* ]]; then
    if [[ "$exec_start" =~ path=([^[:space:];}]+) ]]; then
      path="${BASH_REMATCH[1]}"
      [[ "$path" == /* ]] || return 1
      printf '%s' "$path"
      return 0
    fi
    return 1
  fi
  [[ -f "$unit_file" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*ExecStart= ]] || continue
    command="${line#*=}"
    command="${command#"${command%%[![:space:]]*}"}"
    [[ "$command" == -* ]] && command="${command#-}"
    command="${command#"${command%%[![:space:]]*}"}"
    path="${command%%[[:space:]]*}"
    [[ "$path" == /* ]] || return 1
    [[ "$path" != *\"* && "$path" != *"'"* ]] || return 1
    printf '%s' "$path"
    return 0
  done < "$unit_file"
  return 1
}

service_references_config_file() {
  local service="$1" unit_file="$2" config_file="$3" exec_start
  [[ -n "$service" && -n "$config_file" ]] || return 1
  exec_start=$(systemctl show "$service" -p ExecStart --value 2>/dev/null || true)
  if [[ "$exec_start" == *"path="* || "$exec_start" == *"argv[]="* ]]; then
    case " $exec_start " in
      *" -c ${config_file} "*|*" --config ${config_file} "*|*" --config=${config_file} "*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  unit_file_uses_config_file "$unit_file" "$config_file"
}

service_uses_config_file() {
  local service="$1" unit_file="$2" config_file="$3" executable
  service_references_config_file "$service" "$unit_file" "$config_file" || return 1
  executable=$(service_exec_binary_path "$service" "$unit_file" 2>/dev/null || true)
  [[ "$executable" == "$BACKHAUL_BIN" ]]
}

service_effective_uses_backhaul_binary() {
  local service="$1" executable
  executable=$(service_exec_binary_path "$service" "/etc/systemd/system/${service}" 2>/dev/null || true)
  [[ "$executable" == "$BACKHAUL_BIN" ]]
}

find_service_for_config_file() {
  local config_file="$1" requested_dir="${2:-}" service
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    printf '%s' "$service"
    return 0
  done < <(find_services_for_config_file "$config_file" "$requested_dir")
  return 1
}

unit_file_uses_config_file() {
  local unit_file="$1" config_file="$2" line needle suffix
  local -a needles=()
  [[ -f "$unit_file" && -n "$config_file" ]] || return 1
  needles=(
    " -c ${config_file}"
    " -c \"${config_file}\""
    " -c '${config_file}'"
    " --config ${config_file}"
    " --config=\"${config_file}\""
    " --config='${config_file}'"
    " --config=${config_file}"
  )
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*ExecStart= ]] || continue
    for needle in "${needles[@]}"; do
      [[ "$line" == *"$needle"* ]] || continue
      suffix="${line#*"$needle"}"
      if [[ -z "$suffix" || "$suffix" == [[:space:]]* ]]; then
        return 0
      fi
    done
  done < "$unit_file"
  return 1
}

unit_file_uses_backhaul_binary() {
  local unit_file="$1" line command
  [[ -f "$unit_file" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*ExecStart= ]] || continue
    command="${line#*=}"
    command="${command#"${command%%[![:space:]]*}"}"
    case "$command" in
      "${BACKHAUL_BIN}"|"${BACKHAUL_BIN} "*) return 0 ;;
    esac
  done < "$unit_file"
  return 1
}

unit_file_safe_for_restore() {
  local unit_file="$1" config_file="$2" exec_count
  unit_file_uses_backhaul_binary "$unit_file" || return 1
  unit_file_uses_config_file "$unit_file" "$config_file" || return 1
  exec_count=$(grep -cE '^[[:space:]]*ExecStart=' "$unit_file" 2>/dev/null || true)
  [[ "$exec_count" == "1" ]] || return 1
  # Portable backups are restored as root. Do not accept additional command
  # hooks or environment injection that could turn a crafted unit into code
  # execution during restore.
  if grep -qE '^[[:space:]]*(Exec(StartPre|StartPost|Reload|Stop|StopPost|Condition)|Environment|EnvironmentFile|PassEnvironment|SetCredential|LoadCredential|StandardOutput|StandardError|RootDirectory|RootImage|RootHash|RootVerity|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|MountImages|ExtensionImages)=' "$unit_file" 2>/dev/null; then
    return 1
  fi
}

unit_file_mentions_backhaul_binary() {
  local unit_file="$1"
  [[ -f "$unit_file" ]] || return 1
  awk -v bin="$BACKHAUL_BIN" '/^[[:space:]]*Exec[A-Za-z]*=/ && index($0, bin) {found=1} END {exit !found}' "$unit_file"
}

profile_service_references_config_file() {
  local profile="$1" config_file="$2" service unit_file fallback
  service=$(profile_service_name "$profile") || return 1
  fallback="/etc/systemd/system/${service}"
  unit_file=$(service_fragment_path "$service" "$fallback" 2>/dev/null || true)
  [[ -n "$unit_file" ]] || return 1
  service_references_config_file "$service" "$unit_file" "$config_file"
}

profile_service_uses_config_file() {
  local profile="$1" config_file="$2" service unit_file fallback
  service=$(profile_service_name "$profile") || return 1
  fallback="/etc/systemd/system/${service}"
  unit_file=$(service_fragment_path "$service" "$fallback" 2>/dev/null || true)
  [[ -n "$unit_file" ]] || return 1
  service_uses_config_file "$service" "$unit_file" "$config_file"
}

selected_service_binary_path() {
  local unit_file
  [[ -f "$CONFIG_FILE" ]] || return 1
  unit_file=$(service_fragment_path "$SERVICE_NAME" "$SERVICE_FILE" 2>/dev/null || true)
  [[ -n "$unit_file" ]] || return 1
  service_references_config_file "$SERVICE_NAME" "$unit_file" "$CONFIG_FILE" || return 1
  service_exec_binary_path "$SERVICE_NAME" "$unit_file"
}

selected_legacy_binary_path() {
  local executable
  executable=$(selected_service_binary_path 2>/dev/null || true)
  [[ -n "$executable" && "$executable" != "$BACKHAUL_BIN" && -x "$executable" && ! -L "$executable" ]] || return 1
  [[ "${executable##*/}" == "backhaul" ]] || return 1
  printf '%s' "$executable"
}

guard_selected_service_mapping() {
  local executable unit_file
  unit_file=$(service_fragment_path "$SERVICE_NAME" "$SERVICE_FILE" 2>/dev/null || true)
  [[ -n "$unit_file" ]] || return 0
  if service_uses_config_file "$SERVICE_NAME" "$unit_file" "$CONFIG_FILE"; then
    return 0
  fi
  if service_references_config_file "$SERVICE_NAME" "$unit_file" "$CONFIG_FILE"; then
    executable=$(service_exec_binary_path "$SERVICE_NAME" "$unit_file" 2>/dev/null || printf 'unknown')
    err "Legacy/unmanaged service detected: ${SERVICE_NAME} uses ${CONFIG_FILE} via ${executable}."
    info "Use Backhaul maintenance -> Adopt legacy installation, or Migrate source, before changing this profile."
    return 1
  fi
  err "Service/config mismatch: ${SERVICE_NAME} does not point at ${CONFIG_FILE}."
  info "Open Profiles first; another tunnel may currently own this service name."
  return 1
}

guard_shared_binary_consumers() {
  local operation="$1" unit_dir unit_file svc profile file recognized found=0
  local -a unit_dirs=(/etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system)
  local -A seen=()
  refresh_profile_names
  refresh_legacy_configs
  for unit_dir in "${unit_dirs[@]}"; do
    [[ -d "$unit_dir" ]] || continue
    for unit_file in "$unit_dir"/*.service; do
      [[ -f "$unit_file" ]] || continue
      svc="${unit_file##*/}"
      [[ -z "${seen[$svc]:-}" ]] || continue
      seen[$svc]=1
      if ! service_effective_uses_backhaul_binary "$svc" && ! unit_file_mentions_backhaul_binary "$unit_file"; then
        continue
      fi
      recognized=0
      for profile in "${PROFILE_NAMES[@]}"; do
        profile_exists "$profile" || continue
        file=$(profile_config_path "$profile")
        if service_uses_config_file "$svc" "$unit_file" "$file"; then recognized=1; break; fi
      done
      if (( recognized == 0 )); then
        for file in "${LEGACY_CONFIG_FILES[@]}"; do
          if service_uses_config_file "$svc" "$unit_file" "$file"; then recognized=1; break; fi
        done
      fi
      if (( recognized == 0 )); then
        (( found == 0 )) && err "Cannot ${operation}; untracked services also use the shared Backhaul binary:"
        printf '  - %s\n' "$svc"
        found=1
      fi
    done
  done
  (( found == 0 )) || {
    info "Move these services into Profiles or point them at a separate binary before continuing."
    return 1
  }
}

guard_active_legacy_tunnels() {
  local operation="$1" file svc state found=0 service_count
  refresh_legacy_configs
  for file in "${LEGACY_CONFIG_FILES[@]}"; do
    if (( found == 0 )); then
      err "Cannot ${operation} while legacy tunnels remain outside profile management:"
    fi
    service_count=0
    while IFS= read -r svc; do
      [[ -n "$svc" ]] || continue
      service_count=$((service_count + 1))
      state="stopped"
      systemctl is-active --quiet "$svc" 2>/dev/null && state="active"
      printf '  - %s [%s, %s]\n' "$file" "$svc" "$state"
    done < <(find_services_for_config_file "$file" 2>/dev/null)
    (( service_count > 0 )) || printf '  - %s [no service detected]\n' "$file"
    found=1
  done
  (( found == 0 )) || {
    info "Adopt these tunnels from Profiles first so compatibility, source changes, and rollback cover every tunnel."
    return 1
  }
}

save_active_profile() {
  local name="$1" tmp
  validate_profile_name "$name" || return 1
  install -d -m 0700 "$STATE_DIR" || return 1
  tmp="${ACTIVE_PROFILE_FILE}.tmp.$$"
  if ! printf '%s\n' "$name" > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$ACTIVE_PROFILE_FILE"; then
    rm -f -- "$tmp"
    err "Could not persist the active profile selection."
    return 1
  fi
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
  apply_profile_context "$name" || return 1
  save_active_profile "$name" || return 1
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

source_repo_from_state_file() {
  local state_file="$1" first="" source_repo=""
  [[ -r "$state_file" ]] || return 1
  IFS= read -r first < "$state_file" || true
  if [[ "$first" == source=* ]]; then
    if ! awk '
      /^source=/ {sources++; next}
      /^sha256=[0-9A-Fa-f]{64}$/ {hashes++; next}
      /^[[:space:]]*$/ {next}
      {bad++}
      END {exit !(sources == 1 && hashes <= 1 && bad == 0)}
    ' "$state_file"; then
      return 1
    fi
    source_repo="${first#source=}"
  else
    if ! awk 'NF {count++} END {exit !(count == 1)}' "$state_file"; then
      return 1
    fi
    source_repo="$first"
  fi
  validate_backhaul_source "$source_repo" || return 1
  printf '%s' "$source_repo"
}

source_state_matches_binary() {
  local state_file="$1" binary="$2" source_repo expected_hash actual_hash
  source_repo=$(source_repo_from_state_file "$state_file") || return 1
  [[ -x "$binary" && ! -L "$binary" ]] || return 1
  expected_hash=$(awk '/^sha256=[0-9A-Fa-f]{64}$/ {value=substr($0,8); count++} END {if (count == 1) print value; else exit 1}' "$state_file") || return 1
  [[ "$expected_hash" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  actual_hash=$(sha256sum "$binary" | awk '{print $1}')
  [[ "${actual_hash,,}" == "${expected_hash,,}" ]] || return 1
  printf '%s' "$source_repo"
}

read_saved_backhaul_source_unverified() {
  source_repo_from_state_file "$BACKHAUL_SOURCE_FILE"
}

read_saved_backhaul_source() {
  source_state_matches_binary "$BACKHAUL_SOURCE_FILE" "$BACKHAUL_BIN"
}

save_backhaul_source() {
  local source_repo="$1" tmp binary_hash
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  [[ -x "$BACKHAUL_BIN" && ! -L "$BACKHAUL_BIN" ]] || { err "Cannot persist source provenance without a managed Backhaul binary."; return 1; }
  binary_hash=$(sha256sum "$BACKHAUL_BIN" | awk '{print $1}')
  [[ "$binary_hash" =~ ^[0-9a-fA-F]{64}$ ]] || { err "Could not hash the managed Backhaul binary."; return 1; }
  ensure_directories || return 1
  tmp="${BACKHAUL_SOURCE_FILE}.tmp.$$"
  if ! printf 'source=%s\nsha256=%s\n' "$source_repo" "${binary_hash,,}" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$BACKHAUL_SOURCE_FILE"; then
    rm -f -- "$tmp"
    err "Could not persist Backhaul source metadata."
    return 1
  fi
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

recommend_tuning_profile_for_resources() {
  local cpu_count="$1" mem_mib="$2"
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

recommend_tuning_profile() {
  local cpu_count mem_mib
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
  mem_mib=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')
  recommend_tuning_profile_for_resources "$cpu_count" "$mem_mib"
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
    if ! cp -a -- "$source" "$snapshot"; then
      err "Could not snapshot ${source}; the operation was stopped before mutation."
      return 1
    fi
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

installation_footprint_exists() {
  local profile
  [[ -x "$BACKHAUL_BIN" || -f "${BASE_CONFIG_DIR}/config.toml" || -f "/etc/systemd/system/backhaul.service" ]] && return 0
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" && return 0
  done
  refresh_legacy_configs
  (( ${#LEGACY_CONFIG_FILES[@]} > 0 )) && return 0
  return 1
}

current_backhaul_source() {
  local source_repo
  if source_repo=$(read_saved_backhaul_source 2>/dev/null); then
    printf '%s' "$source_repo"
  elif installation_footprint_exists; then
    # Existing binaries/configs/services may predate this Manager or may have
    # been replaced manually. Never turn the recommended default into claimed
    # provenance for an installation that already exists.
    printf '%s' "$UNKNOWN_BACKHAUL_SOURCE"
  else
    printf '%s' "$DEFAULT_BACKHAUL_SOURCE"
  fi
}

backhaul_binary_version() {
  local binary="$1" version
  [[ -x "$binary" && ! -L "$binary" ]] || return 1
  version=$(timeout 5 "$binary" -v </dev/null 2>/dev/null) || return 1
  validate_version "$version" || return 1
  [[ "$version" != "latest" ]] || return 1
  normalize_version "$version"
}

installed_backhaul_version() {
  backhaul_binary_version "$BACKHAUL_BIN"
}

validate_backhaul_source_or_unknown() {
  [[ "$1" == "$UNKNOWN_BACKHAUL_SOURCE" ]] || validate_backhaul_source "$1"
}

persist_backhaul_source_state() {
  local source_repo="$1"
  if [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
    rm -f -- "$BACKHAUL_SOURCE_FILE" || return 1
    return
  fi
  save_backhaul_source "$source_repo"
}

binary_matches_release_source() {
  local binary="$1" source_repo="$2" version="$3" candidate rc=1
  local old_changed="$BINARY_CHANGED" old_downloaded="$DOWNLOADED_VERSION"
  [[ -x "$binary" && ! -L "$binary" ]] || return 1
  validate_backhaul_source "$source_repo" || return 1
  validate_version "$version" || return 1
  version=$(normalize_version "$version")
  [[ "$version" != "latest" ]] || return 1
  ensure_directories || return 1
  candidate="${STATE_DIR}/.source-identity.$$.$RANDOM"
  if download_backhaul "$version" "$source_repo" "$candidate" >/dev/null 2>&1 \
      && cmp -s -- "$binary" "$candidate"; then
    rc=0
  fi
  rm -f -- "$candidate"
  BINARY_CHANGED="$old_changed"
  DOWNLOADED_VERSION="$old_downloaded"
  return "$rc"
}

detect_backhaul_source_for_binary() {
  local binary="$1" version source matches=0 matched=""
  version=$(backhaul_binary_version "$binary") || return 1
  for source in "$POWERMATIN_BACKHAUL_REPO" "$MUSIXAL_BACKHAUL_REPO"; do
    if binary_matches_release_source "$binary" "$source" "$version"; then
      matched="$source"
      matches=$((matches + 1))
    fi
  done
  (( matches == 1 )) || return 1
  printf '%s' "$matched"
}

claim_backhaul_source() {
  local source_repo="$1" version
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  [[ -x "$BACKHAUL_BIN" ]] || { err "No managed Backhaul binary is installed to identify."; return 1; }
  if ! version=$(installed_backhaul_version); then
    err "The installed Backhaul binary did not report a valid version."
    return 1
  fi
  info "Verifying the installed binary byte-for-byte against ${source_repo} ${version}..."
  if ! binary_matches_release_source "$BACKHAUL_BIN" "$source_repo" "$version"; then
    err "The installed binary does not match ${source_repo} ${version} for this architecture."
    info "No source metadata was changed. Use source migration or legacy adoption instead of claiming unverified provenance."
    return 1
  fi
  save_backhaul_source "$source_repo" || return 1
  ok "Recorded verified Backhaul source: ${source_repo} (${version})."
}

claim_backhaul_source_interactive() {
  local source_repo current
  [[ -x "$BACKHAUL_BIN" ]] || { err "Backhaul is not installed; there is no existing binary to identify."; return 1; }
  current=$(current_backhaul_source)
  printf '\n%bRecord current Backhaul source%b\n' "$C_BOLD" "$C_RESET"
  printf '  Current metadata: %s\n' "$current"
  warn "Choose the repository that supplied the binary currently installed at ${BACKHAUL_BIN}."
  source_repo=$(choose_backhaul_source)
  claim_backhaul_source "$source_repo"
}

require_known_backhaul_source() {
  local source_repo legacy_source version bound_hash=""
  source_repo=$(current_backhaul_source)
  if [[ "$source_repo" != "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
    printf '%s' "$source_repo"
    return 0
  fi
  if [[ -x "$BACKHAUL_BIN" ]] && legacy_source=$(read_saved_backhaul_source_unverified 2>/dev/null); then
    bound_hash=$(awk '/^sha256=[0-9A-Fa-f]{64}$/ {value=substr($0,8); count++} END {if (count == 1) print value; else exit 1}' "$BACKHAUL_SOURCE_FILE" 2>/dev/null || true)
    if [[ "$bound_hash" =~ ^[0-9A-Fa-f]{64}$ ]]; then
      # A v3.1.1 state file binds the intended repository to the previously
      # installed binary hash. If the live binary changed, keep provenance
      # unknown in Status but allow Upgrade to use that bound repository only
      # as a repair target; the downloaded replacement is checksum-verified.
      warn "Managed Backhaul binary hash changed; using the previously bound source ${legacy_source} only as a repair target." >&2
      printf '%s' "$legacy_source"
      return 0
    fi
    # v3.1.0 stored only a repository name. Upgrade that legacy metadata lazily
    # by verifying the current binary against the exact published release.
    if version=$(installed_backhaul_version 2>/dev/null); then
      info "Verifying legacy source metadata for ${legacy_source} ${version}..." >&2
      if binary_matches_release_source "$BACKHAUL_BIN" "$legacy_source" "$version"; then
        save_backhaul_source "$legacy_source" || return 1
        printf '%s' "$legacy_source"
        return 0
      fi
      warn "Stored source metadata did not match the installed binary; it was not trusted." >&2
    fi
  fi
  err "The installed Backhaul source is unknown; refusing a source-dependent operation."
  info "Use Backhaul maintenance -> Record current source, or: backhaul-manager --set-source REPO"
  return 1
}

manifest_value() {
  local file="$1" key="$2"
  [[ -f "$file" && "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  awk -v prefix="${key}=" '
    index($0, prefix) == 1 {value=substr($0, length(prefix) + 1); count++}
    END {if (count == 1) print value; else exit 1}
  ' "$file"
}

backup_checksum_file() {
  local dir="$1" file
  (
    cd "$dir" || exit 1
    : > CHECKSUMS || exit 1
    while IFS= read -r file; do
      [[ "$file" == "./CHECKSUMS" ]] && continue
      sha256sum "$file" >> CHECKSUMS || exit 1
    done < <(find . -type f -print | LC_ALL=C sort)
    chmod 0600 CHECKSUMS || exit 1
  )
}

backup_payload_present() {
  local copied_profiles="$1" binary_path="$2" copied_legacy="${3:-0}"
  (( copied_profiles > 0 || copied_legacy > 0 )) || [[ -x "$binary_path" ]]
}

create_backup() {
  local label="${1:-manual}" safe_label stamp dir profile cfg_dir backup_profile svc source_repo version="unknown"
  local tls_cert tls_key active enabled copied_profiles=0 copied_legacy=0 legacy_file legacy_name legacy_tls_dir
  local -a legacy_services=()
  local -A legacy_service_seen=()
  safe_label="${label//[^A-Za-z0-9_-]/-}"
  safe_label="${safe_label:0:32}"
  [[ -n "$safe_label" ]] || safe_label="manual"
  ensure_directories || return 1
  guard_selected_service_mapping || return 1
  refresh_profile_names
  refresh_legacy_configs
  if [[ ! -x "$BACKHAUL_BIN" ]]; then
    local found_config=0
    for profile in "${PROFILE_NAMES[@]}"; do profile_exists "$profile" && found_config=1; done
    (( ${#LEGACY_CONFIG_FILES[@]} > 0 )) && found_config=1
    (( found_config )) || { err "Nothing is installed or configured to back up."; return 1; }
  fi
  stamp=$(date +%Y%m%d-%H%M%S)
  dir="${BACKUP_DIR}/backup-${stamp}-${safe_label}-$$"
  if ! install -d -m 0700 "$dir" "$dir/profiles" "$dir/state" "$dir/services" "$dir/legacy" "$dir/legacy-services" "$dir/legacy-tls"; then
    err "Could not create the backup staging directory."
    return 1
  fi
  source_repo=$(current_backhaul_source)
  [[ -x "$BACKHAUL_BIN" ]] && version=$(installed_backhaul_version 2>/dev/null || printf 'unknown')
  if [[ -x "$BACKHAUL_BIN" ]] && ! install -m 0755 "$BACKHAUL_BIN" "$dir/backhaul"; then
    rm -rf -- "$dir"
    err "Could not include the Backhaul binary in the backup."
    return 1
  fi
  if ! printf '%s\n' "$source_repo" > "$dir/state/backhaul-source" \
      || ! printf '%s\n' "$ACTIVE_PROFILE" > "$dir/state/active-profile" \
      || ! : > "$dir/services.state" \
      || ! : > "$dir/legacy-services.state" \
      || ! chmod 0600 "$dir/state/backhaul-source" "$dir/state/active-profile" "$dir/services.state" "$dir/legacy-services.state"; then
    rm -rf -- "$dir"
    err "Could not initialize the backup metadata."
    return 1
  fi

  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    cfg_dir="$(dirname "$(profile_config_path "$profile")")"
    backup_profile="${dir}/profiles/${profile}"
    if ! install -d -m 0700 "$backup_profile" \
        || ! install -m 0600 "${cfg_dir}/config.toml" "$backup_profile/config.toml"; then
      rm -rf -- "$dir"
      err "Could not back up profile '${profile}'."
      return 1
    fi
    if [[ -f "${cfg_dir}/backhaul-info.txt" ]] && ! install -m 0600 "${cfg_dir}/backhaul-info.txt" "$backup_profile/backhaul-info.txt"; then
      rm -rf -- "$dir"
      err "Could not back up profile metadata for '${profile}'."
      return 1
    fi
    tls_cert=$(config_value_from_file "${cfg_dir}/config.toml" tls_cert 2>/dev/null || true)
    tls_key=$(config_value_from_file "${cfg_dir}/config.toml" tls_key 2>/dev/null || true)
    if [[ -n "$tls_cert" || -n "$tls_key" ]]; then
      if [[ -r "$tls_cert" && -r "$tls_key" ]]; then
        if ! install -m 0600 "$tls_cert" "$backup_profile/tls-cert.pem" \
            || ! install -m 0600 "$tls_key" "$backup_profile/tls-key.pem"; then
          rm -rf -- "$dir"
          err "Could not back up TLS material for profile '${profile}'."
          return 1
        fi
      else
        rm -rf -- "$dir"
        err "Profile '${profile}' references TLS files that cannot be backed up safely."
        return 1
      fi
    fi
    svc=$(profile_service_name "$profile")
    if [[ -f "/etc/systemd/system/${svc}" ]]; then
      if ! install -m 0644 "/etc/systemd/system/${svc}" "$dir/services/${svc}"; then
        rm -rf -- "$dir"
        err "Could not back up systemd unit '${svc}'."
        return 1
      fi
    fi
    active="no"; enabled="no"
    systemctl is-active --quiet "$svc" 2>/dev/null && active="yes"
    systemctl is-enabled --quiet "$svc" 2>/dev/null && enabled="yes"
    if ! printf '%s %s %s\n' "$svc" "$active" "$enabled" >> "$dir/services.state"; then
      rm -rf -- "$dir"
      return 1
    fi
    ((copied_profiles += 1))
  done

  for legacy_file in "${LEGACY_CONFIG_FILES[@]}"; do
    legacy_name="${legacy_file##*/}"
    validate_legacy_config_basename "$legacy_name" || continue
    if ! install -m 0600 "$legacy_file" "$dir/legacy/$legacy_name"; then
      rm -rf -- "$dir"
      err "Could not include legacy config '${legacy_name}' in the full backup."
      return 1
    fi
    tls_cert=$(config_value_from_file "$legacy_file" tls_cert 2>/dev/null || true)
    tls_key=$(config_value_from_file "$legacy_file" tls_key 2>/dev/null || true)
    if [[ -n "$tls_cert" || -n "$tls_key" ]]; then
      if [[ -r "$tls_cert" && -r "$tls_key" ]]; then
        legacy_tls_dir="$dir/legacy-tls/$legacy_name"
        if ! install -d -m 0700 "$legacy_tls_dir" \
            || ! install -m 0600 "$tls_cert" "$legacy_tls_dir/cert.pem" \
            || ! install -m 0600 "$tls_key" "$legacy_tls_dir/key.pem"; then
          rm -rf -- "$dir"
          err "Could not back up TLS material for legacy config '${legacy_name}'."
          return 1
        fi
      else
        rm -rf -- "$dir"
        err "Legacy config '${legacy_name}' references TLS material that cannot be backed up safely."
        return 1
      fi
    fi
    legacy_services=()
    mapfile -t legacy_services < <(find_services_for_config_file "$legacy_file" 2>/dev/null)
    for svc in "${legacy_services[@]}"; do
      validate_service_unit_name "$svc" || continue
      [[ -n "${legacy_service_seen[$svc]:-}" ]] && continue
      legacy_service_seen[$svc]=1
      if ! service_uses_config_file "$svc" "/etc/systemd/system/${svc}" "$legacy_file"; then
        rm -rf -- "$dir"
        err "Legacy service '${svc}' uses ${legacy_file} through an unmanaged executable."
        info "Adopt that tunnel into Profiles before creating a portable full backup."
        return 1
      fi
      active="no"; enabled="no"
      systemctl is-active --quiet "$svc" 2>/dev/null && active="yes"
      systemctl is-enabled --quiet "$svc" 2>/dev/null && enabled="yes"
      if [[ -f "/etc/systemd/system/${svc}" ]]; then
        if ! install -m 0644 "/etc/systemd/system/${svc}" "$dir/legacy-services/${svc}"; then
          rm -rf -- "$dir"
          return 1
        fi
      else
        err "Legacy service '${svc}' has no restorable unit in /etc/systemd/system."
        rm -rf -- "$dir"
        return 1
      fi
      if ! printf '%s %s %s %s\n' "$svc" "$active" "$enabled" "$legacy_name" >> "$dir/legacy-services.state"; then
        rm -rf -- "$dir"
        return 1
      fi
    done
    ((copied_legacy += 1))
  done

  if ! backup_payload_present "$copied_profiles" "$BACKHAUL_BIN" "$copied_legacy"; then
    rm -rf -- "$dir"
    return 1
  fi
  {
    printf 'schema=2\n'
    printf 'created=%s\n' "$(date -Is 2>/dev/null || date)"
    printf 'manager_version=%s\n' "$MANAGER_VERSION"
    printf 'backhaul_version=%s\n' "$version"
    printf 'source=%s\n' "$source_repo"
    printf 'active_profile=%s\n' "$ACTIVE_PROFILE"
  } > "$dir/MANIFEST" || { rm -rf -- "$dir"; return 1; }
  chmod 0600 "$dir/MANIFEST" || { rm -rf -- "$dir"; return 1; }
  if ! backup_checksum_file "$dir"; then
    rm -rf -- "$dir"
    err "Could not generate backup checksums."
    return 1
  fi
  if ! validate_backup_tree "$dir"; then
    rm -rf -- "$dir"
    err "Backup integrity validation failed; the incomplete snapshot was removed."
    return 1
  fi
  LAST_BACKUP_DIR="$dir"
  ok "Backup created: ${dir}"
}

validate_backup_tree() {
  local dir="$1" schema source_repo profile_dir profile name role transport legacy_file svc active enabled legacy_name config_path needs_binary=0
  [[ -d "$dir" && -f "$dir/MANIFEST" && -f "$dir/CHECKSUMS" && -f "$dir/services.state" ]] || return 1
  schema=$(manifest_value "$dir/MANIFEST" schema 2>/dev/null || true)
  [[ "$schema" == "1" || "$schema" == "2" ]] || return 1
  source_repo=$(manifest_value "$dir/MANIFEST" source 2>/dev/null || true)
  validate_backhaul_source_or_unknown "$source_repo" || return 1
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
      # Rollback snapshots preserve the installation exactly as it was,
      # including legacy keys that a running Backhaul decoder may ignore.
      # Source compatibility belongs to migration checks, not integrity.
      role=$(config_role_from_file "$profile_dir/config.toml")
      [[ "$role" == "server" || "$role" == "client" ]] || return 1
      transport=$(config_value_from_file "$profile_dir/config.toml" transport 2>/dev/null || true)
      validate_transport "$transport" || return 1
      svc=$(profile_service_name "$name") || return 1
      if [[ -f "$dir/services/$svc" ]]; then
        config_path=$(profile_config_path "$name") || return 1
        unit_file_safe_for_restore "$dir/services/$svc" "$config_path" || return 1
      elif [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
        # With unknown provenance the Manager must restore the exact saved
        # service definition instead of inventing source-specific metadata.
        return 1
      fi
    done
  fi
  while read -r svc active enabled; do
    [[ -n "$svc" ]] || continue
    validate_service_unit_name "$svc" || return 1
    [[ "$active" == "yes" || "$active" == "no" ]] || return 1
    [[ "$enabled" == "yes" || "$enabled" == "no" ]] || return 1
    [[ "$active" != "yes" ]] || needs_binary=1
    profile=$(profile_from_service_name "$svc") || return 1
    [[ -f "$dir/profiles/$profile/config.toml" ]] || return 1
  done < "$dir/services.state"
  if [[ "$schema" == "2" ]]; then
    [[ -d "$dir/legacy" && -d "$dir/legacy-services" && -f "$dir/legacy-services.state" ]] || return 1
    for legacy_file in "$dir/legacy"/*.toml; do
      [[ -f "$legacy_file" ]] || continue
      name="${legacy_file##*/}"
      validate_legacy_config_basename "$name" || return 1
      role=$(config_role_from_file "$legacy_file")
      [[ "$role" == "server" || "$role" == "client" ]] || return 1
      transport=$(config_value_from_file "$legacy_file" transport 2>/dev/null || true)
      validate_transport "$transport" || return 1
      if [[ -d "$dir/legacy-tls/$name" ]]; then
        [[ -f "$dir/legacy-tls/$name/cert.pem" && -f "$dir/legacy-tls/$name/key.pem" ]] || return 1
      fi
    done
    while read -r svc active enabled legacy_name; do
      [[ -n "$svc" ]] || continue
      validate_service_unit_name "$svc" || return 1
      [[ "$active" == "yes" || "$active" == "no" ]] || return 1
      [[ "$enabled" == "yes" || "$enabled" == "no" ]] || return 1
      [[ "$active" != "yes" ]] || needs_binary=1
      validate_legacy_config_basename "$legacy_name" || return 1
      [[ -f "$dir/legacy/$legacy_name" && -f "$dir/legacy-services/$svc" ]] || return 1
      unit_file_safe_for_restore "$dir/legacy-services/$svc" "${BASE_CONFIG_DIR}/${legacy_name}" || return 1
    done < "$dir/legacy-services.state"
  fi
  (( needs_binary == 0 )) || [[ -f "$dir/backhaul" && ! -L "$dir/backhaul" ]] || return 1
  profile=$(manifest_value "$dir/MANIFEST" active_profile 2>/dev/null || printf 'default')
  validate_profile_name "$profile"
}

backup_schema() {
  manifest_value "$1/MANIFEST" schema 2>/dev/null || true
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
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

service_is_active_name() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

service_main_pid() {
  local pid
  pid=$(systemctl show "$1" -p MainPID --value 2>/dev/null || printf '0')
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  printf '%s' "$pid"
}

client_control_channel_healthy() {
  awk '
    /control channel established successfully/ {healthy=1; next}
    /attempting to establish a new .*control channel/ {healthy=0; next}
    /control channel has been closed/ {healthy=0; next}
    /failed to .*channel/ {healthy=0; next}
    /restarting client/ {healthy=0; next}
    /dial (tcp|udp).*: (i\/o timeout|connection refused|network is unreachable|no route to host)/ {healthy=0; next}
    END {exit !healthy}
  '
}

service_health_probe() {
  local svc="$1" config_file="$2" role endpoint port protocol transport pid
  service_is_active_name "$svc" || return 1
  pid=$(service_main_pid "$svc") || return 1
  role=$(config_role_from_file "$config_file")
  transport=$(config_value_from_file "$config_file" transport 2>/dev/null || true)
  validate_transport "$transport" || return 1
  if [[ "$role" == "server" ]]; then
    endpoint=$(config_value_from_file "$config_file" bind_addr 2>/dev/null || true)
    validate_endpoint "$endpoint" || return 1
    port="${endpoint##*:}"; port="${port%]}"
    protocol=$(transport_protocol "$transport")
    check_listening_port_for_pid "$port" "$protocol" "$pid"
  elif [[ "$role" == "client" ]]; then
    endpoint=$(config_value_from_file "$config_file" remote_addr 2>/dev/null || true)
    validate_endpoint "$endpoint" || return 1
    port="${endpoint##*:}"; port="${port%]}"
    protocol=$(transport_protocol "$transport")
    if check_connected_peer_for_pid "$port" "$protocol" "$pid"; then
      return 0
    fi
    journalctl -u "$svc" "_PID=${pid}" -n 1000 --no-pager -o cat 2>/dev/null \
      | client_control_channel_healthy
  else
    return 1
  fi
}

verify_service_health() {
  local svc="$1" config_file="$2" timeout_seconds="${3:-15}" waited=0 first_pid second_pid
  while (( waited < timeout_seconds )); do
    if service_health_probe "$svc" "$config_file"; then
      first_pid=$(service_main_pid "$svc") || return 1
      sleep 2
      if service_health_probe "$svc" "$config_file"; then
        second_pid=$(service_main_pid "$svc") || return 1
        [[ "$first_pid" == "$second_pid" ]] || { err "${svc} restarted during health verification."; return 1; }
        return 0
      fi
    fi
    sleep 1
    ((waited += 1))
  done
  err "${svc} did not reach a healthy tunnel state within ${timeout_seconds}s."
  journalctl -u "$svc" -n 40 --no-pager 2>/dev/null || true
  return 1
}

stop_service_verified() {
  local svc="$1" waited=0
  service_is_active_name "$svc" || return 0
  if ! systemctl stop "$svc"; then
    err "Could not stop ${svc}; no files will be removed for this service."
    return 1
  fi
  while (( waited < 20 )); do
    service_is_active_name "$svc" || return 0
    sleep 1
    ((waited += 1))
  done
  err "${svc} is still active after the stop timeout."
  return 1
}

disable_service_verified() {
  local svc="$1"
  systemctl is-enabled --quiet "$svc" 2>/dev/null || return 0
  if ! systemctl disable "$svc" >/dev/null; then
    err "Could not disable ${svc}."
    return 1
  fi
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    err "${svc} is still enabled after disable."
    return 1
  fi
}

stop_all_managed_services() {
  local profile svc failed=0
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    svc=$(profile_service_name "$profile")
    stop_service_verified "$svc" || failed=1
  done
  (( failed == 0 ))
}

stop_all_legacy_services() {
  local file svc failed=0
  local -A seen=()
  refresh_legacy_configs
  for file in "${LEGACY_CONFIG_FILES[@]}"; do
    while IFS= read -r svc; do
      [[ -n "$svc" && -z "${seen[$svc]:-}" ]] || continue
      seen[$svc]=1
      stop_service_verified "$svc" || failed=1
    done < <(find_services_for_config_file "$file" 2>/dev/null)
  done
  (( failed == 0 ))
}

managed_installation_exists() {
  local profile
  [[ -x "$BACKHAUL_BIN" ]] && return 0
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" && return 0
  done
  refresh_legacy_configs
  (( ${#LEGACY_CONFIG_FILES[@]} > 0 )) && return 0
  return 1
}

cleanup_failed_empty_restore() {
  local profile svc file
  stop_all_managed_services || return 1
  stop_all_legacy_services || return 1
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    svc=$(profile_service_name "$profile")
    disable_service_verified "$svc" || return 1
    rm -f -- "/etc/systemd/system/${svc}" || return 1
  done
  refresh_legacy_configs
  for file in "${LEGACY_CONFIG_FILES[@]}"; do
    while IFS= read -r svc; do
      [[ -n "$svc" ]] || continue
      disable_service_verified "$svc" || return 1
      rm -f -- "/etc/systemd/system/${svc}" || return 1
    done < <(find_services_for_config_file "$file" 2>/dev/null)
    rm -f -- "$file" || return 1
  done
  rm -f -- "$BACKHAUL_BIN" "${BASE_CONFIG_DIR}/config.toml" "${BASE_CONFIG_DIR}/backhaul-info.txt" || return 1
  rm -rf -- "$PROFILES_DIR" "${BASE_CONFIG_DIR}/legacy-tls" || return 1
  rm -f -- "$BACKHAUL_SOURCE_FILE" "$ACTIVE_PROFILE_FILE" || return 1
  install -d -m 0700 "$PROFILES_DIR" || return 1
  apply_profile_context "default" || return 1
  systemctl daemon-reload || return 1
}

apply_backup_tree() {
  local dir="$1" source_repo schema profile_dir profile target_dir svc active enabled restored_active first_profile=""
  local legacy_file legacy_name legacy_target legacy_tls_dir
  validate_backup_tree "$dir" || { err "Backup validation failed: ${dir}"; return 1; }
  schema=$(backup_schema "$dir")
  source_repo=$(manifest_value "$dir/MANIFEST" source)
  restored_active=$(manifest_value "$dir/MANIFEST" active_profile 2>/dev/null || printf 'default')

  if ! stop_all_managed_services || ! stop_all_legacy_services; then
    err "Restore aborted because one or more existing Backhaul services could not be stopped safely."
    return 1
  fi
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    svc=$(profile_service_name "$profile")
    disable_service_verified "$svc" || return 1
    rm -f -- "/etc/systemd/system/${svc}" || return 1
  done
  refresh_legacy_configs
  for legacy_file in "${LEGACY_CONFIG_FILES[@]}"; do
    while IFS= read -r svc; do
      [[ -n "$svc" ]] || continue
      disable_service_verified "$svc" || return 1
      rm -f -- "/etc/systemd/system/${svc}" || return 1
    done < <(find_services_for_config_file "$legacy_file" 2>/dev/null)
    rm -f -- "$legacy_file" || return 1
  done
  rm -f -- "${BASE_CONFIG_DIR}/config.toml" "${BASE_CONFIG_DIR}/backhaul-info.txt" || return 1
  rm -rf -- "$PROFILES_DIR" "${BASE_CONFIG_DIR}/legacy-tls" || return 1
  install -d -m 0700 "$BASE_CONFIG_DIR" "$PROFILES_DIR" "$STATE_DIR" "$BACKUP_DIR" || return 1
  # Reset the mutable profile context before helpers that call
  # ensure_directories(), or a previously selected named profile can be
  # recreated as an empty stale directory during restore.
  apply_profile_context "default" || return 1
  if [[ -f "$dir/backhaul" ]]; then
    install -d -m 0755 "$BACKHAUL_DIR" || return 1
    install -m 0755 "$dir/backhaul" "${BACKHAUL_BIN}.restore" || return 1
    mv -f -- "${BACKHAUL_BIN}.restore" "$BACKHAUL_BIN" || return 1
  else
    rm -f -- "$BACKHAUL_BIN" || return 1
  fi

  for profile_dir in "$dir/profiles"/*; do
    [[ -d "$profile_dir" ]] || continue
    profile="${profile_dir##*/}"
    validate_profile_name "$profile" || return 1
    [[ -z "$first_profile" ]] && first_profile="$profile"
    if [[ "$profile" == "default" ]]; then target_dir="$BASE_CONFIG_DIR"; else target_dir="${PROFILES_DIR}/${profile}"; fi
    install -d -m 0700 "$target_dir" || return 1
    install -m 0600 "$profile_dir/config.toml" "$target_dir/config.toml" || return 1
    if [[ -f "$profile_dir/backhaul-info.txt" ]]; then
      install -m 0600 "$profile_dir/backhaul-info.txt" "$target_dir/backhaul-info.txt" || return 1
    fi
    if [[ -f "$profile_dir/tls-cert.pem" && -f "$profile_dir/tls-key.pem" ]]; then
      install -d -m 0700 "$target_dir/tls" || return 1
      install -m 0600 "$profile_dir/tls-cert.pem" "$target_dir/tls/cert.pem" || return 1
      install -m 0600 "$profile_dir/tls-key.pem" "$target_dir/tls/key.pem" || return 1
      replace_config_string_value "$target_dir/config.toml" tls_cert "$target_dir/tls/cert.pem" || return 1
      replace_config_string_value "$target_dir/config.toml" tls_key "$target_dir/tls/key.pem" || return 1
    fi
  done
  persist_backhaul_source_state "$source_repo" || return 1
  if ! validate_profile_name "$restored_active" || ! profile_exists "$restored_active"; then
    restored_active="${first_profile:-default}"
  fi

  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    apply_profile_context "$profile" || return 1
    svc=$(profile_service_name "$profile")
    if [[ -f "$dir/services/$svc" ]]; then
      unit_file_safe_for_restore "$dir/services/$svc" "$CONFIG_FILE" || return 1
      install -m 0644 "$dir/services/$svc" "$SERVICE_FILE" || return 1
    elif [[ "$source_repo" != "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
      write_service_file "$source_repo" || return 1
    else
      err "Backup has unknown source metadata and no saved unit for ${svc}; refusing to invent one."
      return 1
    fi
  done

  if [[ "$schema" == "2" ]]; then
    for legacy_file in "$dir/legacy"/*.toml; do
      [[ -f "$legacy_file" ]] || continue
      legacy_name="${legacy_file##*/}"
      legacy_target="${BASE_CONFIG_DIR}/${legacy_name}"
      install -m 0600 "$legacy_file" "$legacy_target" || return 1
      legacy_tls_dir="$dir/legacy-tls/$legacy_name"
      if [[ -f "$legacy_tls_dir/cert.pem" && -f "$legacy_tls_dir/key.pem" ]]; then
        install -d -m 0700 "${BASE_CONFIG_DIR}/legacy-tls/${legacy_name}" || return 1
        install -m 0600 "$legacy_tls_dir/cert.pem" "${BASE_CONFIG_DIR}/legacy-tls/${legacy_name}/cert.pem" || return 1
        install -m 0600 "$legacy_tls_dir/key.pem" "${BASE_CONFIG_DIR}/legacy-tls/${legacy_name}/key.pem" || return 1
        replace_config_string_value "$legacy_target" tls_cert "${BASE_CONFIG_DIR}/legacy-tls/${legacy_name}/cert.pem" || return 1
        replace_config_string_value "$legacy_target" tls_key "${BASE_CONFIG_DIR}/legacy-tls/${legacy_name}/key.pem" || return 1
      fi
    done
    while read -r svc active enabled legacy_name; do
      [[ -n "$svc" ]] || continue
      install -m 0644 "$dir/legacy-services/$svc" "/etc/systemd/system/$svc" || return 1
    done < "$dir/legacy-services.state"
  fi
  systemctl daemon-reload || return 1
  while read -r svc active enabled; do
    [[ -n "$svc" ]] || continue
    if [[ "$svc" == "backhaul.service" ]]; then profile="default";
    elif [[ "$svc" =~ ^backhaul-([A-Za-z0-9][A-Za-z0-9_-]{0,31})\.service$ ]]; then profile="${BASH_REMATCH[1]}";
    else continue; fi
    profile_exists "$profile" || continue
    if [[ "$enabled" == "yes" ]]; then systemctl enable "$svc" >/dev/null || return 1; else disable_service_verified "$svc" || return 1; fi
    if [[ "$active" == "yes" ]]; then
      systemctl start "$svc" || return 1
      verify_service_health "$svc" "$(profile_config_path "$profile")" || return 1
    fi
  done < "$dir/services.state"
  if [[ "$schema" == "2" ]]; then
    while read -r svc active enabled legacy_name; do
      [[ -n "$svc" ]] || continue
      legacy_target="${BASE_CONFIG_DIR}/${legacy_name}"
      if [[ "$enabled" == "yes" ]]; then systemctl enable "$svc" >/dev/null || return 1; else disable_service_verified "$svc" || return 1; fi
      if [[ "$active" == "yes" ]]; then
        systemctl start "$svc" || return 1
        verify_service_health "$svc" "$legacy_target" || return 1
      fi
    done < "$dir/legacy-services.state"
  fi
  apply_profile_context "$restored_active" || return 1
  save_active_profile "$restored_active" || return 1
  ok "Backup restored. Active profile: ${restored_active}."
}

restore_backup_dir() {
  local dir="$1" safety="" schema
  validate_backup_tree "$dir" || { err "Selected backup is invalid or corrupted."; return 1; }
  guard_shared_binary_consumers "restore the installation" || return 1
  schema=$(backup_schema "$dir")
  refresh_legacy_configs
  if [[ "$schema" == "1" && ${#LEGACY_CONFIG_FILES[@]} -gt 0 ]]; then
    err "This v3.0 backup does not contain legacy tunnels detected on the current host."
    info "Create a new schema-2 full backup first; restore was blocked before changing any service or file."
    return 1
  fi
  if managed_installation_exists; then
    create_backup "pre-restore" || return 1
    safety="$LAST_BACKUP_DIR"
  fi
  if [[ -n "$safety" ]]; then
    begin_transaction apply_backup_tree "$safety" || return 1
  else
    begin_transaction cleanup_failed_empty_restore || return 1
  fi
  if apply_backup_tree "$dir"; then
    commit_transaction
    return 0
  fi
  rollback_active_transaction "restore failure" || true
  [[ -n "$safety" ]] && err "Restore failed; recovery snapshot: ${safety}"
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
  local archive="$1" size member canonical listing count=0 type member_size unpacked_size=0
  local -A seen_members=()
  [[ -f "$archive" ]] || return 1
  size=$(stat -c '%s' "$archive" 2>/dev/null || printf '0')
  (( size > 0 && size <= 536870912 )) || return 1
  # A failing process substitution does not reliably make the surrounding
  # while command fail. Validate the archive stream independently first.
  tar -tzf "$archive" >/dev/null 2>&1 || return 1
  while IFS= read -r member; do
    ((count += 1))
    (( count <= 2048 )) || return 1
    case "$member" in
      /*|..|../*|*/../*|*/..) return 1 ;;
    esac
    canonical="${member#./}"
    canonical="${canonical%/}"
    [[ -n "$canonical" ]] || canonical="."
    [[ -z "${seen_members[$canonical]:-}" ]] || return 1
    seen_members[$canonical]=1
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

verify_portable_backup_binary_provenance() {
  local dir="$1" source_repo version candidate=""
  [[ -d "$dir" ]] || return 1
  [[ -f "$dir/backhaul" ]] || return 0
  source_repo=$(manifest_value "$dir/MANIFEST" source 2>/dev/null || true)
  version=$(manifest_value "$dir/MANIFEST" backhaul_version 2>/dev/null || true)
  if ! validate_backhaul_source "$source_repo" || ! validate_version "$version" || [[ "$version" == "latest" ]]; then
    err "Portable backup contains an executable but lacks verifiable source/version provenance."
    info "Adopt/migrate the installation to a verified source before exporting a portable executable backup."
    return 1
  fi
  version=$(normalize_version "$version")
  candidate=$(mktemp /tmp/backhaul-portable-provenance.XXXXXX) || return 1
  rm -f -- "$candidate"
  if ! download_backhaul "$version" "$source_repo" "$candidate" >/dev/null; then
    rm -f -- "$candidate"
    err "Could not obtain the checksum-verified release needed to verify the portable backup binary."
    return 1
  fi
  if ! cmp -s -- "$dir/backhaul" "$candidate"; then
    rm -f -- "$candidate"
    err "Portable backup binary does not match the published ${source_repo} ${version} release."
    return 1
  fi
  rm -f -- "$candidate"
}

import_backup_bundle() {
  local archive="$1" tmp imported private_archive
  [[ -f "$archive" ]] || { err "Backup archive does not exist: ${archive}"; return 1; }
  tmp=$(mktemp -d /tmp/backhaul-import.XXXXXX)
  private_archive="${tmp}/input.tar.gz"
  if ! install -m 0600 "$archive" "$private_archive"; then
    rm -rf -- "$tmp"
    err "Could not copy the backup into a private staging area."
    return 1
  fi
  validate_backup_archive "$private_archive" || { rm -rf -- "$tmp"; err "Backup archive is invalid or unsafe."; return 1; }
  install -d -m 0700 "$tmp/tree"
  if ! tar --no-same-owner --no-same-permissions -xzf "$private_archive" -C "$tmp/tree"; then
    rm -rf -- "$tmp"
    return 1
  fi
  validate_backup_tree "$tmp/tree" || { rm -rf -- "$tmp"; err "Imported backup failed integrity validation."; return 1; }
  ensure_directories || { rm -rf -- "$tmp"; return 1; }
  if ! verify_portable_backup_binary_provenance "$tmp/tree"; then
    rm -rf -- "$tmp"
    return 1
  fi
  imported="${BACKUP_DIR}/import-$(date +%Y%m%d-%H%M%S)-$$"
  if ! cp -a -- "$tmp/tree" "$imported" || ! chmod -R go-rwx "$imported"; then
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
  remote_file=$(ssh -- "$target" "umask 077; mktemp /tmp/backhaul-manager-migration.XXXXXXXX.tar.gz") || {
    rm -f -- "$bundle"
    err "Could not allocate a private temporary file on the target host."
    return 1
  }
  if [[ ! "$remote_file" =~ ^/tmp/backhaul-manager-migration\.[A-Za-z0-9]+\.tar\.gz$ ]]; then
    rm -f -- "$bundle"
    err "The target returned an unexpected temporary path; migration stopped."
    return 1
  fi
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
  if ! install -d -m 0755 "$(dirname "$MANAGER_INSTALL_PATH")" \
      || ! install -m 0755 "$tmp" "${MANAGER_INSTALL_PATH}.new" \
      || ! mv -f -- "${MANAGER_INSTALL_PATH}.new" "$MANAGER_INSTALL_PATH"; then
    rm -f -- "$tmp" "${MANAGER_INSTALL_PATH}.new"
    err "Could not atomically install the Manager command."
    return 1
  fi
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

release_checksum_for_asset() {
  local checksums_file="$1" asset="$2" hash="" count=0 line candidate name
  [[ -f "$checksums_file" && -n "$asset" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Accept the common `sha256  file` / `sha256 *file` formats only. Match
    # the exact architecture asset so a crafted prefix/suffix cannot verify.
    [[ "$line" =~ ^([0-9A-Fa-f]{64})[[:space:]]+(.+)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    name="${name#\*}"
    name="${name#./}"
    name="${name%$'\r'}"
    [[ "$name" == "$asset" ]] || continue
    hash="${candidate,,}"
    count=$((count + 1))
  done < "$checksums_file"
  (( count == 1 )) || return 1
  printf '%s' "$hash"
}

release_candidate_matches_installation() {
  local installed_binary="$1" candidate="$2" current_version="$3" candidate_version="$4" current_source="$5" source_repo="$6"
  [[ -x "$installed_binary" && -f "$candidate" && ! -L "$candidate" ]] || return 1
  [[ -n "$current_version" && "$current_version" == "$candidate_version" && "$current_source" == "$source_repo" ]] || return 1
  cmp -s -- "$installed_binary" "$candidate"
}

download_backhaul() {
  local requested="$1" source_repo="${2:-$DEFAULT_BACKHAUL_SOURCE}" stage_path="${3:-}"
  local release_base asset url checksums_url tmp_dir archive checksums_file expected_checksum actual_checksum
  local member candidate current_version="" current_source="" candidate_version
  BINARY_CHANGED=0
  if ! validate_backhaul_source "$source_repo"; then
    err "Invalid Backhaul source: ${source_repo}"
    return 1
  fi
  requested=$(normalize_version "$requested")
  release_base=$(backhaul_release_base "$source_repo") || return 1
  asset=$(detect_arch_asset) || return 1
  ensure_directories || return 1

  if [[ "$requested" == "latest" ]]; then
    url="${release_base}/latest/download/${asset}"
    checksums_url="${release_base}/latest/download/checksums.txt"
  else
    url="${release_base}/download/${requested}/${asset}"
    checksums_url="${release_base}/download/${requested}/checksums.txt"
  fi

  tmp_dir=$(mktemp -d /tmp/backhaul-manager.XXXXXX)
  archive="${tmp_dir}/${asset}"
  checksums_file="${tmp_dir}/checksums.txt"
  info "Downloading Backhaul ${requested} from ${source_repo} for $(uname -m)..."
  if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
      --connect-timeout 10 --max-time 180 --max-filesize 536870912 -o "$archive" "$url"; then
    rm -rf -- "$tmp_dir"
    err "Download failed: ${url}"
    return 1
  fi
  if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
      --connect-timeout 10 --max-time 60 --max-filesize 1048576 -o "$checksums_file" "$checksums_url"; then
    rm -rf -- "$tmp_dir"
    err "Release checksum download failed; refusing to execute an unverified binary."
    return 1
  fi
  if ! expected_checksum=$(release_checksum_for_asset "$checksums_file" "$asset"); then
    rm -rf -- "$tmp_dir"
    err "Release checksums do not contain exactly one valid entry for ${asset}."
    return 1
  fi
  actual_checksum=$(sha256sum "$archive" | awk '{print $1}')
  if [[ "${actual_checksum,,}" != "$expected_checksum" ]]; then
    rm -rf -- "$tmp_dir"
    err "Release checksum verification failed for ${asset}."
    return 1
  fi
  if ! tar -tzf "$archive" > "${tmp_dir}/members.txt" 2>/dev/null; then
    rm -rf -- "$tmp_dir"
    err "The downloaded release archive is invalid or corrupt."
    return 1
  fi

  member=""
  local member_count=0 member_candidate
  while IFS= read -r member_candidate; do
    case "$member_candidate" in
      backhaul|./backhaul)
        member="$member_candidate"
        member_count=$((member_count + 1))
        ;;
    esac
  done < "${tmp_dir}/members.txt"
  if (( member_count != 1 )); then
    rm -rf -- "$tmp_dir"
    err "The release archive must contain exactly one top-level 'backhaul' binary."
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
  if ! chmod 0755 "$candidate" || ! candidate_version=$(timeout 5 "$candidate" -v </dev/null 2>/dev/null) \
      || ! validate_version "$candidate_version" || [[ "$candidate_version" == "latest" ]]; then
    rm -rf -- "$tmp_dir"
    err "The downloaded binary failed its version sanity check."
    return 1
  fi
  candidate_version=$(normalize_version "$candidate_version")
  if [[ "$requested" != "latest" && "$candidate_version" != "$requested" ]]; then
    rm -rf -- "$tmp_dir"
    err "Requested ${requested}, but the downloaded binary reports ${candidate_version}."
    return 1
  fi

  if [[ -x "$BACKHAUL_BIN" ]]; then
    current_version=$(installed_backhaul_version 2>/dev/null || true)
    if ! current_source=$(read_saved_backhaul_source 2>/dev/null); then
      current_source="$UNKNOWN_BACKHAUL_SOURCE"
    fi
  fi
  if release_candidate_matches_installation "$BACKHAUL_BIN" "$candidate" "$current_version" "$candidate_version" "$current_source" "$source_repo"; then
    DOWNLOADED_VERSION="$candidate_version"
    BINARY_CHANGED=0
    if [[ -n "$stage_path" ]]; then
      install -m 0755 "$candidate" "$stage_path" || { rm -rf -- "$tmp_dir"; return 1; }
    fi
    rm -rf -- "$tmp_dir"
    ok "Backhaul ${candidate_version} from ${source_repo} is already installed."
    return 0
  fi

  if [[ -n "$current_version" && "$current_version" == "$candidate_version" && "$current_source" == "$source_repo" \
      && -x "$BACKHAUL_BIN" ]] \
      && ! release_candidate_matches_installation "$BACKHAUL_BIN" "$candidate" "$current_version" "$candidate_version" "$current_source" "$source_repo"; then
    warn "Installed ${candidate_version} bytes differ from the verified ${source_repo} release; preparing a repair reinstall."
  fi

  if [[ -n "$stage_path" ]]; then
    if ! install -m 0755 "$candidate" "$stage_path"; then
      rm -rf -- "$tmp_dir"
      err "Could not stage the downloaded Backhaul binary."
      return 1
    fi
    DOWNLOADED_VERSION="$candidate_version"
    BINARY_CHANGED=1
    rm -rf -- "$tmp_dir"
    ok "Prepared Backhaul ${candidate_version}; the running installation is unchanged."
    return 0
  fi

  if ! install -m 0755 "$candidate" "${BACKHAUL_BIN}.new" \
      || ! mv -f -- "${BACKHAUL_BIN}.new" "$BACKHAUL_BIN"; then
    rm -f -- "${BACKHAUL_BIN}.new"
    rm -rf -- "$tmp_dir"
    err "Could not atomically install the Backhaul binary."
    return 1
  fi
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
  tmp=$(mktemp "${unit_dir}/.backhaul.service.XXXXXX") || return 1
  if ! {
    printf '[Unit]\n'
    printf 'Description=Backhaul Reverse Tunnel Service\n'
    printf 'Documentation=https://github.com/%s\n' "$source_repo"
    printf 'Wants=network-online.target\n'
    printf 'After=network-online.target\n\n'
    printf '[Service]\n'
    printf 'Type=simple\n'
    printf 'ExecStart=%s -c %s\n' "$BACKHAUL_BIN" "$CONFIG_FILE"
    printf 'Restart=on-failure\n'
    printf 'RestartSec=3s\n'
    printf 'TimeoutStopSec=20s\n'
    printf 'LimitNOFILE=1048576\n'
    printf 'UMask=0077\n\n'
    printf '[Install]\n'
    printf 'WantedBy=multi-user.target\n'
  } > "$tmp"; then
    rm -f -- "$tmp"
    err "Could not write the systemd unit staging file."
    return 1
  fi
  if ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$SERVICE_FILE"; then
    rm -f -- "$tmp"
    err "Could not atomically install ${SERVICE_NAME}."
    return 1
  fi
}

write_server_config() {
  local control_port="$1" transport="$2" token="$3" tls_cert="$4" tls_key="$5" source_repo="$6" tmp rule
  local escaped_token escaped_cert escaped_key escaped_web_user escaped_web_password
  escaped_token=$(toml_escape "$token")
  escaped_cert=$(toml_escape "$tls_cert")
  escaped_key=$(toml_escape "$tls_key")
  escaped_web_user=$(toml_escape "$ADV_WEB_USERNAME")
  escaped_web_password=$(toml_escape "$ADV_WEB_PASSWORD")
  tmp=$(mktemp "${CONFIG_DIR}/.config.toml.XXXXXX") || return 1
  if ! {
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
  } > "$tmp"; then
    rm -f -- "$tmp"
    err "Could not write the server configuration staging file."
    return 1
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$CONFIG_FILE"; then
    rm -f -- "$tmp"
    err "Could not atomically install the server configuration."
    return 1
  fi
}

write_client_config() {
  local remote_addr="$1" transport="$2" token="$3" edge_ip="$4" source_repo="$5" tmp
  local escaped_remote escaped_token escaped_edge escaped_web_user escaped_web_password
  escaped_remote=$(toml_escape "$remote_addr")
  escaped_token=$(toml_escape "$token")
  escaped_edge=$(toml_escape "$edge_ip")
  escaped_web_user=$(toml_escape "$ADV_WEB_USERNAME")
  escaped_web_password=$(toml_escape "$ADV_WEB_PASSWORD")
  tmp=$(mktemp "${CONFIG_DIR}/.config.toml.XXXXXX") || return 1
  if ! {
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
  } > "$tmp"; then
    rm -f -- "$tmp"
    err "Could not write the client configuration staging file."
    return 1
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$CONFIG_FILE"; then
    rm -f -- "$tmp"
    err "Could not atomically install the client configuration."
    return 1
  fi
}

service_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

start_and_verify_service() {
  if ! systemctl daemon-reload; then
    err "systemd daemon-reload failed; ${SERVICE_NAME} was not restarted."
    return 1
  fi
  if ! systemctl enable "$SERVICE_NAME" >/dev/null; then
    err "Could not enable ${SERVICE_NAME} at boot."
    return 1
  fi
  if ! systemctl restart "$SERVICE_NAME"; then
    err "systemd could not restart ${SERVICE_NAME}."
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    return 1
  fi
  if ! verify_service_health "$SERVICE_NAME" "$CONFIG_FILE" 20; then
    err "${SERVICE_NAME} started but the tunnel did not become healthy."
    return 1
  fi
  ok "${SERVICE_NAME} is active and tunnel health is verified."
}

rollback_install() {
  local config_snapshot="$1" service_snapshot="$2" binary_snapshot="$3" was_active="$4" was_enabled="$5" source_snapshot="${6:-}"
  local failed=0
  warn "Restoring the previous working installation..."
  restore_file "$CONFIG_FILE" "$config_snapshot" || failed=1
  restore_file "$SERVICE_FILE" "$service_snapshot" || failed=1
  restore_file "$BACKHAUL_SOURCE_FILE" "$source_snapshot" || failed=1
  restore_file "$BACKHAUL_BIN" "$binary_snapshot" || failed=1
  systemctl daemon-reload || failed=1
  if [[ "$was_enabled" == "yes" && -f "$SERVICE_FILE" ]]; then
    systemctl enable "$SERVICE_NAME" >/dev/null || failed=1
  else
    disable_service_verified "$SERVICE_NAME" || failed=1
  fi
  if [[ "$was_active" == "yes" && -f "$SERVICE_FILE" ]]; then
    if ! systemctl restart "$SERVICE_NAME" || ! verify_service_health "$SERVICE_NAME" "$CONFIG_FILE" 20; then failed=1; fi
  else
    stop_service_verified "$SERVICE_NAME" || failed=1
  fi
  if (( failed == 0 )); then
    ok "Rollback completed."
    return 0
  fi
  err "Rollback restored as much state as possible but one or more recovery steps failed."
  return 1
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

check_listening_port_for_pid() {
  local port="$1" protocol="${2:-tcp}" pid="$3"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  if [[ "$protocol" == "udp" ]]; then
    ss -H -lunp 2>/dev/null | awk -v p=":${port}" -v marker="pid=${pid}," \
      '$4 ~ p"$" && index($0, marker) {found=1} END {exit !found}'
  else
    ss -H -ltnp 2>/dev/null | awk -v p=":${port}" -v marker="pid=${pid}," \
      '$4 ~ p"$" && index($0, marker) {found=1} END {exit !found}'
  fi
}

check_connected_peer_for_pid() {
  local port="$1" protocol="${2:-tcp}" pid="$3"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  if [[ "$protocol" == "udp" ]]; then
    ss -H -unp 2>/dev/null | awk -v p=":${port}" -v marker="pid=${pid}," \
      '($5 ~ p"$" || $6 ~ p"$") && index($0, marker) {found=1} END {exit !found}'
  else
    ss -H -ntp state established 2>/dev/null | awk -v p=":${port}" -v marker="pid=${pid}," \
      '($4 ~ p"$" || $5 ~ p"$") && index($0, marker) {found=1} END {exit !found}'
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
  local control_port="$1" transport="$2" token="$3" source_repo="$4" tmp="${INFO_FILE}.tmp.$$"
  if ! {
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
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$INFO_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

write_client_info() {
  local remote_addr="$1" transport="$2" source_repo="$3" tmp="${INFO_FILE}.tmp.$$"
  if ! {
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
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$INFO_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
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
  guard_selected_service_mapping || return 1
  reset_config_options
  if [[ -x "$BACKHAUL_BIN" ]]; then
    source_repo=$(current_backhaul_source)
    if [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
      warn "The existing Backhaul binary has no trustworthy source metadata."
      info "Select the repository that actually supplied the currently installed binary."
      source_repo=$(choose_backhaul_source)
      claim_backhaul_source "$source_repo" || return 1
    fi
    if ! version=$(installed_backhaul_version); then
      err "The managed Backhaul binary did not report a valid version within the safety timeout."
      return 1
    fi
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

  protocol=$(transport_protocol "$transport")
  if ! preflight_server_ports "$control_port" "$protocol"; then
    info "Configuration cancelled before making installation changes."
    return 1
  fi
  ensure_directories || return 1
  service_is_active && was_active="yes"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && was_enabled="yes"
  if ! snapshot_file "$CONFIG_FILE" "config" config_snapshot \
      || ! snapshot_file "$SERVICE_FILE" "service" service_snapshot \
      || ! snapshot_file "$BACKHAUL_BIN" "backhaul-bin" binary_snapshot \
      || ! snapshot_file "$BACKHAUL_SOURCE_FILE" "source" source_snapshot; then
    return 1
  fi
  begin_transaction rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot" || return 1
  if ! download_backhaul "$version" "$source_repo"; then
    rollback_active_transaction "server binary preparation failure" || true
    return 1
  fi
  if ! write_server_config "$control_port" "$transport" "$token" "$tls_cert" "$tls_key" "$source_repo"; then
    rollback_active_transaction "server config write failure" || true
    return 1
  fi
  if ! write_service_file "$source_repo"; then
    rollback_active_transaction "server unit write failure" || true
    return 1
  fi
  if ! start_and_verify_service; then
    rollback_active_transaction "server health failure" || true
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
    rollback_active_transaction "source-state failure" || true
    return 1
  fi
  if ! write_server_info "$control_port" "$transport" "$token" "$source_repo"; then
    rollback_active_transaction "server metadata write failure" || true
    return 1
  fi
  commit_transaction
  print_server_secret_summary "$token" "$control_port" "$transport"
  ok "Server configuration completed."
}

configure_client() {
  printf '\n%b===== Configure foreign / client side =====%b\n' "$C_BOLD" "$C_RESET"
  local iran_host control_port remote_addr transport token source_repo version edge_ip=""
  local config_snapshot="" service_snapshot="" binary_snapshot="" source_snapshot="" was_active="no" was_enabled="no" protocol
  guard_selected_service_mapping || return 1
  reset_config_options
  if [[ -x "$BACKHAUL_BIN" ]]; then
    source_repo=$(current_backhaul_source)
    if [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
      warn "The existing Backhaul binary has no trustworthy source metadata."
      info "Select the repository that actually supplied the currently installed binary."
      source_repo=$(choose_backhaul_source)
      claim_backhaul_source "$source_repo" || return 1
    fi
    if ! version=$(installed_backhaul_version); then
      err "The managed Backhaul binary did not report a valid version within the safety timeout."
      return 1
    fi
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

  ensure_directories || return 1
  service_is_active && was_active="yes"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && was_enabled="yes"
  if ! snapshot_file "$CONFIG_FILE" "config" config_snapshot \
      || ! snapshot_file "$SERVICE_FILE" "service" service_snapshot \
      || ! snapshot_file "$BACKHAUL_BIN" "backhaul-bin" binary_snapshot \
      || ! snapshot_file "$BACKHAUL_SOURCE_FILE" "source" source_snapshot; then
    return 1
  fi
  begin_transaction rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot" || return 1
  if ! download_backhaul "$version" "$source_repo"; then
    rollback_active_transaction "client binary preparation failure" || true
    return 1
  fi
  if ! write_client_config "$remote_addr" "$transport" "$token" "$edge_ip" "$source_repo"; then
    rollback_active_transaction "client config write failure" || true
    return 1
  fi
  if ! write_service_file "$source_repo"; then
    rollback_active_transaction "client unit write failure" || true
    return 1
  fi
  if ! start_and_verify_service; then
    rollback_active_transaction "client health failure" || true
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
    rollback_active_transaction "source-state failure" || true
    return 1
  fi
  if ! write_client_info "$remote_addr" "$transport" "$source_repo"; then
    rollback_active_transaction "client metadata write failure" || true
    return 1
  fi
  commit_transaction
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

ask_profile_name_default() {
  local prompt_text="$1" default_name="$2" name
  while true; do
    name=$(tty_read "${prompt_text} [${default_name}]: ")
    name="${name:-$default_name}"
    if validate_profile_name "$name" && [[ "$name" != "default" ]] && ! profile_exists "$name"; then
      printf '%s' "$name"
      return 0
    fi
    warn "Choose a new 1-32 character profile name using letters, numbers, '_' or '-'." >&2
  done
}

list_legacy_tunnels() {
  local idx file role transport endpoint svc duplicate state="unmanaged"
  local -a services=()
  refresh_legacy_configs
  (( ${#LEGACY_CONFIG_FILES[@]} > 0 )) || return 0
  printf '\n%bDetected legacy tunnels (not managed yet)%b\n' "$C_BOLD" "$C_RESET"
  for idx in "${!LEGACY_CONFIG_FILES[@]}"; do
    file="${LEGACY_CONFIG_FILES[$idx]}"
    role=$(config_role_from_file "$file")
    transport=$(config_value_from_file "$file" transport 2>/dev/null || printf '?')
    if [[ "$role" == "server" ]]; then
      endpoint=$(config_value_from_file "$file" bind_addr 2>/dev/null || printf '?')
    else
      endpoint=$(config_value_from_file "$file" remote_addr 2>/dev/null || printf '?')
    fi
    services=()
    mapfile -t services < <(find_services_for_config_file "$file" 2>/dev/null)
    state="unmanaged"
    if (( ${#services[@]} > 0 )); then
      state="stopped"
      for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
          state="active"
          break
        fi
      done
    fi
    printf '  L%d) %-22s %-7s %-7s %-9s %s' \
      "$((idx + 1))" "${file##*/}" "$role" "$transport" "$state" "$endpoint"
    (( ${#services[@]} > 0 )) && printf '  [services: %s]' "${services[*]}"
    duplicate=$(matching_managed_profile_for_config "$file" 2>/dev/null || true)
    [[ -n "$duplicate" ]] && printf '  [same config as: %s]' "$duplicate"
    printf '\n'
  done
  printf '  Use "Adopt legacy tunnel" to convert one safely into a managed profile.\n'
}

list_profiles() {
  local idx profile file role transport endpoint svc unit_file state marker
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
      unit_file="/etc/systemd/system/${svc}"
      if [[ ! -f "$unit_file" ]]; then
        state="no-unit"
      elif profile_service_uses_config_file "$profile" "$file"; then
        state="stopped"
        systemctl is-active --quiet "$svc" 2>/dev/null && state="active"
      elif profile_service_references_config_file "$profile" "$file"; then
        state="legacy"
        systemctl is-active --quiet "$svc" 2>/dev/null && state="legacy-active"
      else
        state="mismatch"
      fi
      printf ' %s%d) %-16s %-7s %-7s %-8s %s\n' "$marker" "$((idx + 1))" "$profile" "$role" "$transport" "$state" "$endpoint"
    else
      printf ' %s%d) %-16s not configured\n' "$marker" "$((idx + 1))" "$profile"
    fi
  done
  printf '  %b* = selected profile for Manager actions; each row has its own service state.%b\n' "$C_DIM" "$C_RESET"
  list_legacy_tunnels
}

rollback_legacy_adoption() {
  local target_service="$1" target_snapshot="$2" legacy_service="$3" was_active="$4" was_enabled="$5"
  local old_profile="$6" target_dir="$7" legacy_config="$8" target_unit="/etc/systemd/system/${target_service}"
  local failed=0
  stop_service_verified "$target_service" || failed=1
  restore_file "$target_unit" "$target_snapshot" || failed=1
  systemctl daemon-reload || failed=1
  if [[ -n "$legacy_service" ]]; then
    if [[ "$was_enabled" == "yes" ]]; then systemctl enable "$legacy_service" >/dev/null || failed=1;
    else disable_service_verified "$legacy_service" || failed=1; fi
    if [[ "$was_active" == "yes" ]]; then
      if ! systemctl restart "$legacy_service" >/dev/null || ! verify_service_health "$legacy_service" "$legacy_config" 20; then failed=1; fi
    else
      stop_service_verified "$legacy_service" || failed=1
    fi
  fi
  rm -rf -- "$target_dir" || failed=1
  apply_profile_context "$old_profile" || failed=1
  save_active_profile "$old_profile" || failed=1
  (( failed == 0 ))
}

adopt_legacy_config() {
  local legacy_file="$1" name="$2" source_repo candidate duplicate found=0 legacy_service="" target_service target_unit
  local old_profile="$ACTIVE_PROFILE" was_active="no" was_enabled="no" target_snapshot="" target_dir archived
  local -a legacy_services=()
  if ! validate_profile_name "$name" || [[ "$name" == "default" ]]; then
    err "Invalid target profile name: ${name}"
    return 1
  fi
  profile_exists "$name" && { err "Profile '${name}' already exists."; return 1; }
  refresh_legacy_configs
  for candidate in "${LEGACY_CONFIG_FILES[@]}"; do
    [[ "$candidate" == "$legacy_file" ]] && { found=1; break; }
  done
  (( found )) || { err "Not a detected legacy Backhaul config: ${legacy_file}"; return 1; }
  duplicate=$(matching_managed_profile_for_config "$legacy_file" 2>/dev/null || true)
  if [[ -n "$duplicate" ]]; then
    err "This legacy file is already byte-identical to managed profile '${duplicate}'."
    info "It stays visible so no tunnel file is hidden; remove the duplicate only after confirming no service still references it."
    return 1
  fi
  [[ -x "$BACKHAUL_BIN" ]] || { err "Backhaul binary is missing; install/configure Backhaul before adopting legacy tunnels."; return 1; }
  source_repo=$(current_backhaul_source)
  if [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
    err "Cannot adopt a legacy tunnel until the shared binary source is identified."
    info "Use Backhaul maintenance -> Record current source first."
    return 1
  fi
  if ! check_config_compatibility_file "$source_repo" "$legacy_file"; then
    err "Legacy config is incompatible with ${source_repo}: ${COMPAT_UNSUPPORTED_KEYS[*]}"
    return 1
  fi

  ensure_directories || return 1
  mapfile -t legacy_services < <(find_services_for_config_file "$legacy_file" 2>/dev/null)
  if (( ${#legacy_services[@]} > 1 )); then
    err "Cannot auto-adopt: multiple systemd services reference this legacy config: ${legacy_services[*]}"
    info "Resolve the duplicate service ownership first; no files or services were changed."
    return 1
  fi
  if (( ${#legacy_services[@]} == 1 )); then
    legacy_service="${legacy_services[0]}"
  fi
  if [[ "$legacy_service" == "backhaul.service" ]] && profile_exists default; then
    err "Cannot auto-adopt: backhaul.service references the legacy config while the default profile also exists."
    info "Keep both tunnels running and inspect 'systemctl cat backhaul.service' before changing this ambiguous legacy layout."
    return 1
  fi
  target_service=$(profile_service_name "$name") || return 1
  target_unit="/etc/systemd/system/${target_service}"
  if [[ -e "$target_unit" && "$legacy_service" != "$target_service" ]]; then
    err "Target service already exists and belongs to another layout: ${target_service}"
    return 1
  fi
  [[ -n "$legacy_service" ]] && systemctl is-active --quiet "$legacy_service" 2>/dev/null && was_active="yes"
  [[ -n "$legacy_service" ]] && systemctl is-enabled --quiet "$legacy_service" 2>/dev/null && was_enabled="yes"
  snapshot_file "$target_unit" "legacy-adopt-unit" target_snapshot || return 1

  target_dir="${PROFILES_DIR}/${name}"
  begin_transaction rollback_legacy_adoption "$target_service" "$target_snapshot" "$legacy_service" "$was_active" "$was_enabled" "$old_profile" "$target_dir" "$legacy_file" || return 1
  install -d -m 0700 "$target_dir"
  if ! install -m 0600 "$legacy_file" "$target_dir/config.toml"; then
    rollback_active_transaction "legacy config copy failure" || true
    return 1
  fi
  if ! apply_profile_context "$name"; then
    rollback_active_transaction "profile context failure" || true
    return 1
  fi
  if ! write_service_file "$source_repo" || ! systemctl daemon-reload; then
    rollback_active_transaction "legacy adoption unit failure" || true
    return 1
  fi

  if [[ -n "$legacy_service" && "$legacy_service" != "$target_service" && "$was_active" == "yes" ]]; then
    if ! stop_service_verified "$legacy_service"; then
      rollback_active_transaction "legacy service stop failure" || true
      err "Could not stop the legacy service; adoption rolled back."
      return 1
    fi
  fi
  if [[ "$was_enabled" == "yes" ]]; then
    if ! systemctl enable "$target_service" >/dev/null; then
      rollback_active_transaction "managed service enable failure" || true
      return 1
    fi
  else
    if ! disable_service_verified "$target_service"; then
      rollback_active_transaction "managed service disable failure" || true
      return 1
    fi
  fi
  if [[ "$was_active" == "yes" ]]; then
    if ! systemctl restart "$target_service" || ! verify_service_health "$target_service" "$target_dir/config.toml" 20; then
      rollback_active_transaction "managed replacement health failure" || true
      err "Managed replacement did not become active; adoption rolled back."
      return 1
    fi
  fi
  if [[ -n "$legacy_service" && "$legacy_service" != "$target_service" && "$was_enabled" == "yes" ]]; then
    if ! systemctl disable "$legacy_service" >/dev/null; then
      rollback_active_transaction "legacy disable failure" || true
      err "Could not disable the old legacy service; adoption rolled back."
      return 1
    fi
  fi
  if ! save_active_profile "$name"; then
    rollback_active_transaction "active-profile state failure" || true
    return 1
  fi

  # The new service and selected-profile state are now healthy and durable.
  # Commit before archiving the legacy file so SIGINT can never leave the
  # rollback service pointing at a path that has already been moved away.
  commit_transaction
  if [[ -n "$legacy_service" ]]; then
    archived="${legacy_file}.adopted.$(date +%Y%m%d-%H%M%S)"
    if mv -- "$legacy_file" "$archived"; then
      info "Legacy config archived: ${archived}"
    else
      warn "Profile is adopted, but the original legacy config could not be archived: ${legacy_file}"
    fi
  else
    warn "No systemd service referenced this legacy config; the original file was retained for safety."
    info "The new managed profile is stopped/disabled until you start it explicitly."
  fi
  ok "Legacy tunnel adopted as profile '${name}'."
}

adopt_legacy_config_interactive() {
  local choice idx file suggestion name
  refresh_legacy_configs
  if (( ${#LEGACY_CONFIG_FILES[@]} == 0 )); then
    info "No unadopted legacy Backhaul configs were detected in ${BASE_CONFIG_DIR}."
    return 0
  fi
  list_legacy_tunnels
  choice=$(tty_read "Legacy tunnel number (Enter = cancel): ")
  [[ -n "$choice" ]] || return 0
  [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid legacy tunnel number."; return 1; }
  idx=$((10#$choice - 1))
  (( idx >= 0 && idx < ${#LEGACY_CONFIG_FILES[@]} )) || { warn "Invalid legacy tunnel number."; return 1; }
  file="${LEGACY_CONFIG_FILES[$idx]}"
  suggestion=$(legacy_profile_suggestion "$file") || suggestion="legacy-$((idx + 1))"
  name=$(ask_profile_name_default "Managed profile name" "$suggestion")
  printf 'Legacy config : %s\n' "$file"
  printf 'New profile   : %s\n' "$name"
  ask_yn "Adopt this tunnel without changing its Backhaul settings?" "n" || return 0
  adopt_legacy_config "$file" "$name" || return 1
  if ! service_is_active && ask_yn "Profile is stopped. Start and enable it now?" "n"; then
    service_action start
  fi
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
  local name old_profile="$ACTIVE_PROFILE" role_choice rc=0 candidate_service candidate_unit effective_unit=""
  name=$(ask_profile_name "New profile name")
  profile_exists "$name" && { err "Profile '${name}' already exists."; return 1; }
  candidate_service=$(profile_service_name "$name") || return 1
  candidate_unit="/etc/systemd/system/${candidate_service}"
  effective_unit=$(service_fragment_path "$candidate_service" "$candidate_unit" 2>/dev/null || true)
  if [[ -n "$effective_unit" ]]; then
    err "Cannot create profile '${name}': ${candidate_service} already exists at ${effective_unit}."
    info "Inspect/adopt the existing tunnel instead of overwriting its systemd unit."
    return 1
  fi
  printf '\nRole:\n  1) Iran server\n  2) Foreign client\n'
  role_choice=$(tty_read "Role [1]: ")
  apply_profile_context "$name" || return 1
  ensure_directories || { apply_profile_context "$old_profile"; return 1; }
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
  save_active_profile "$name" || return 1
  ok "Profile '${name}' created and selected."
}

clone_active_profile() {
  local name target_dir source_repo tls_cert tls_key old_profile="$ACTIVE_PROFILE" target_service target_unit effective_unit=""
  profile_exists "$ACTIVE_PROFILE" || { err "The active profile is not configured."; return 1; }
  [[ -x "$BACKHAUL_BIN" ]] || { err "Cannot clone an unmanaged legacy installation; adopt or migrate it first."; return 1; }
  guard_selected_service_mapping || return 1
  source_repo=$(require_known_backhaul_source) || return 1
  name=$(ask_profile_name "Clone name")
  profile_exists "$name" && { err "Profile '${name}' already exists."; return 1; }
  target_service=$(profile_service_name "$name") || return 1
  target_unit="/etc/systemd/system/${target_service}"
  effective_unit=$(service_fragment_path "$target_service" "$target_unit" 2>/dev/null || true)
  if [[ -n "$effective_unit" ]]; then
    err "Cannot clone to '${name}': ${target_service} already exists at ${effective_unit}."
    return 1
  fi
  target_dir="${PROFILES_DIR}/${name}"
  if ! install -d -m 0700 "$target_dir" || ! install -m 0600 "$CONFIG_FILE" "$target_dir/config.toml"; then
    rm -rf -- "$target_dir"
    err "Could not create the clone staging profile."
    return 1
  fi
  if [[ -f "$INFO_FILE" ]] && ! install -m 0600 "$INFO_FILE" "$target_dir/backhaul-info.txt"; then
    rm -rf -- "$target_dir"
    err "Could not clone the profile metadata."
    return 1
  fi
  tls_cert=$(config_value_from_file "$CONFIG_FILE" tls_cert 2>/dev/null || true)
  tls_key=$(config_value_from_file "$CONFIG_FILE" tls_key 2>/dev/null || true)
  if [[ -n "$tls_cert" || -n "$tls_key" ]]; then
    if [[ ! -r "$tls_cert" || ! -r "$tls_key" ]]; then
      rm -rf -- "$target_dir"
      err "The source profile references unreadable TLS files; clone cancelled."
      return 1
    fi
    if ! install -d -m 0700 "$target_dir/tls" \
        || ! install -m 0600 "$tls_cert" "$target_dir/tls/cert.pem" \
        || ! install -m 0600 "$tls_key" "$target_dir/tls/key.pem"; then
      rm -rf -- "$target_dir"
      err "Could not copy TLS material into the cloned profile."
      return 1
    fi
    if ! replace_config_string_value "$target_dir/config.toml" tls_cert "$target_dir/tls/cert.pem" ||
       ! replace_config_string_value "$target_dir/config.toml" tls_key "$target_dir/tls/key.pem"; then
      rm -rf -- "$target_dir"
      err "Could not make the cloned TLS configuration self-contained."
      return 1
    fi
  fi
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
  local choice idx profile svc fallback="" candidate safety unit_file effective_unit="" config_file
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
  unit_file="/etc/systemd/system/${svc}"
  config_file=$(profile_config_path "$profile") || return 1
  effective_unit=$(service_fragment_path "$svc" "$unit_file" 2>/dev/null || true)
  if [[ -n "$effective_unit" && "$effective_unit" != "$unit_file" ]]; then
    err "Refusing to delete profile '${profile}': ${svc} is owned by ${effective_unit}, not by the Manager unit path."
    info "Adopt or remove the external unit explicitly first; nothing was changed."
    return 1
  fi
  if [[ -n "$effective_unit" ]] && ! service_uses_config_file "$svc" "$effective_unit" "$config_file"; then
    err "Refusing to delete ${svc}: its effective ExecStart does not use ${config_file}."
    info "Resolve the service/profile ownership mismatch first; nothing was changed."
    return 1
  fi
  create_backup "pre-delete-${profile}" || return 1
  safety="$LAST_BACKUP_DIR"
  begin_transaction apply_backup_tree "$safety" || return 1
  if ! stop_service_verified "$svc" || ! disable_service_verified "$svc"; then
    rollback_active_transaction "profile delete stop/disable failure" || true
    return 1
  fi
  if ! rm -f -- "/etc/systemd/system/${svc}" || ! rm -rf -- "${PROFILES_DIR:?}/${profile}" || ! systemctl daemon-reload; then
    rollback_active_transaction "profile delete filesystem failure" || true
    return 1
  fi
  if [[ "$ACTIVE_PROFILE" == "$profile" ]]; then
    refresh_profile_names
    for candidate in "${PROFILE_NAMES[@]}"; do
      if profile_exists "$candidate"; then fallback="$candidate"; break; fi
    done
    fallback="${fallback:-default}"
    if ! apply_profile_context "$fallback" || ! save_active_profile "$fallback"; then
      rollback_active_transaction "profile selection update failure" || true
      return 1
    fi
  fi
  commit_transaction
  ok "Profile '${profile}' deleted."
  info "Recovery snapshot: ${safety}"
}

profiles_menu() {
  local choice
  list_profiles
  printf '\n  1) Select profile\n'
  printf '  2) Create profile\n'
  printf '  3) Clone selected profile\n'
  printf '  4) Delete profile\n'
  printf '  5) Adopt legacy tunnel\n'
  printf '  0) Back\n'
  choice=$(tty_read "Choose: ")
  case "$choice" in
    1) select_profile_interactive ;;
    2) create_profile_interactive ;;
    3) clone_active_profile ;;
    4) delete_profile_interactive ;;
    5) adopt_legacy_config_interactive ;;
    0|"") return 0 ;;
    *) warn "Invalid choice."; return 1 ;;
  esac
}

config_value_from_file() {
  local file="$1" key="$2" role
  [[ -f "$file" ]] || return 1
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  role=$(config_role_from_file "$file")
  [[ "$role" == "server" || "$role" == "client" ]] || return 1
  awk -v wanted="$key" -v wanted_section="$role" '
    function trim(s) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    /^[ \t]*\[/ {
      section=$0
      sub(/^[ \t]*\[[ \t]*/, "", section)
      sub(/[ \t]*\].*$/, "", section)
      active=(section == wanted_section)
      next
    }
    active && /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ {
      line=$0
      eq=index(line, "=")
      lhs=trim(substr(line, 1, eq - 1))
      if (lhs != wanted) next
      value=substr(line, eq + 1)
      out=""; in_double=0; in_single=0; escaped=0
      for (i=1; i<=length(value); i++) {
        ch=substr(value, i, 1)
        if (escaped) { out=out ch; escaped=0; continue }
        if (in_double && ch == "\\") { out=out ch; escaped=1; continue }
        if (!in_single && ch == "\"") { in_double=!in_double; out=out ch; continue }
        if (!in_double && ch == sprintf("%c", 39)) { in_single=!in_single; out=out ch; continue }
        if (!in_double && !in_single && ch == "#") break
        out=out ch
      }
      value=trim(out)
      single=sprintf("%c", 39)
      if (length(value) >= 2 && ((substr(value,1,1) == "\"" && substr(value,length(value),1) == "\"") ||
          (substr(value,1,1) == single && substr(value,length(value),1) == single))) {
        value=substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$file"
}

config_value() {
  config_value_from_file "$CONFIG_FILE" "$1"
}

config_role_from_file() {
  local file="$1"
  [[ -f "$file" ]] || { printf 'not configured'; return; }
  awk '
    /^[ \t]*\[[ \t]*server[ \t]*\][ \t]*(#.*)?$/ {server++; next}
    /^[ \t]*\[[ \t]*client[ \t]*\][ \t]*(#.*)?$/ {client++; next}
    /^[ \t]*\[[^]]+\][ \t]*(#.*)?$/ {other++}
    END {
      if (server == 1 && client == 0 && other == 0) print "server"
      else if (client == 1 && server == 0 && other == 0) print "client"
      else print "unknown"
    }
  ' "$file"
}

config_duplicate_keys_from_file() {
  local file="$1" role
  [[ -f "$file" ]] || return 1
  role=$(config_role_from_file "$file")
  [[ "$role" == "server" || "$role" == "client" ]] || return 1
  awk -v wanted_section="$role" '
    function trim(s) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    /^[ \t]*\[/ {
      section=$0
      sub(/^[ \t]*\[[ \t]*/, "", section)
      sub(/[ \t]*\].*$/, "", section)
      active=(section == wanted_section)
      next
    }
    active && /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ {
      line=$0
      eq=index(line, "=")
      key=trim(substr(line, 1, eq - 1))
      seen[key]++
      if (seen[key] == 2) print key
    }
  ' "$file"
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
    COMPAT_UNSUPPORTED_KEYS+=("duplicate-key=${key}")
  done < <(config_duplicate_keys_from_file "$file" 2>/dev/null || true)
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! config_key_allowed "$source_repo" "$role" "$key"; then
      COMPAT_UNSUPPORTED_KEYS+=("$key")
    fi
  done < <(awk -v wanted_section="$role" '
    /^[[:space:]]*\[/ {
      section=$0
      sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
      sub(/[[:space:]]*\].*$/, "", section)
      active=(section == wanted_section)
      next
    }
    active && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*=.*/, "", line)
      print line
    }
  ' "$file")
  (( ${#COMPAT_UNSUPPORTED_KEYS[@]} == 0 ))
}

show_compatibility() {
  local source_repo="${1:-}" file="${2:-$CONFIG_FILE}"
  if [[ -z "$source_repo" ]]; then source_repo=$(current_backhaul_source); fi
  printf '\n%bCompatibility check%b\n' "$C_BOLD" "$C_RESET"
  printf '  Target     : %s\n' "$source_repo"
  printf '  Config     : %s\n' "$file"
  if [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
    err "Installed Backhaul source is unknown, so current-source compatibility cannot be claimed."
    info "Record it first with Backhaul maintenance -> Record current source, or --set-source REPO."
    return 1
  fi
  validate_backhaul_source "$source_repo" || { err "Invalid compatibility target: ${source_repo}"; return 1; }
  if check_config_compatibility_file "$source_repo" "$file"; then
    ok "Configuration is compatible with ${source_repo}."
    return 0
  fi
  err "Configuration is not compatible with ${source_repo}."
  printf '  Unsupported: %s\n' "${COMPAT_UNSUPPORTED_KEYS[*]}"
  return 1
}

sanitize_config_for_source() {
  local source_repo="$1" input="$2" output="$3" tmp key role had_power_web=0
  validate_backhaul_source "$source_repo" || return 1
  [[ -f "$input" ]] || return 1
  role=$(config_role_from_file "$input")
  [[ "$role" == "server" || "$role" == "client" ]] || return 1
  tmp="${output}.tmp.$$"
  cp -a -- "$input" "$tmp" || return 1
  if check_config_compatibility_file "$source_repo" "$input"; then
    mv -f -- "$tmp" "$output" || { rm -f -- "$tmp"; return 1; }
    return
  fi
  for key in "${COMPAT_UNSUPPORTED_KEYS[@]}"; do
    case "$key" in
      web_bind_addr|web_username|web_password)
        if [[ "$source_repo" == "$MUSIXAL_BACKHAUL_REPO" ]]; then
          had_power_web=1
          if ! sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"; then rm -f -- "$tmp"; return 1; fi
        else
          rm -f -- "$tmp"
          return 1
        fi
        ;;
      max_pool_size|tls_verify|udp_queue_size|udp_queue_limit|udp_max_flows)
        if [[ "$role" == "server" && ( "$key" == "max_pool_size" || "$key" == "tls_verify" ) ]]; then
          if ! sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"; then rm -f -- "$tmp"; return 1; fi
        elif [[ "$role" == "client" && "$key" == udp_* ]]; then
          if ! sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"; then rm -f -- "$tmp"; return 1; fi
        elif [[ "$source_repo" == "$MUSIXAL_BACKHAUL_REPO" ]]; then
          if ! sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"; then rm -f -- "$tmp"; return 1; fi
        else
          rm -f -- "$tmp"
          return 1
        fi
        ;;
      heartbeat|bind_addr|channel_size|ports|tls_cert|tls_key|mux_con|accept_udp|proxy_protocol)
        if [[ "$role" == "client" ]]; then
          if ! sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"; then rm -f -- "$tmp"; return 1; fi
        else
          rm -f -- "$tmp"
          return 1
        fi
        ;;
      remote_addr|connection_pool|retry_interval|dial_timeout|aggressive_pool|edge_ip)
        if [[ "$role" == "server" ]]; then
          if ! sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"; then rm -f -- "$tmp"; return 1; fi
        else
          rm -f -- "$tmp"
          return 1
        fi
        ;;
      *) rm -f -- "$tmp"; return 1 ;;
    esac
  done
  if (( had_power_web )) && [[ "$source_repo" == "$MUSIXAL_BACKHAUL_REPO" ]]; then
    if ! sed -i -E 's/^[[:space:]]*web_port[[:space:]]*=.*/web_port = 0/' "$tmp"; then rm -f -- "$tmp"; return 1; fi
  fi
  if ! check_config_compatibility_file "$source_repo" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
}

show_status() {
  local version="not installed" active="inactive" enabled="disabled" tunnel="down" role transport address
  local source_repo="not selected" service_binary="" binary_display="not installed" profile_count=0 legacy_count=0 profile
  if [[ -x "$BACKHAUL_BIN" ]]; then
    version=$(backhaul_binary_version "$BACKHAUL_BIN" 2>/dev/null || printf 'unknown')
    source_repo=$(current_backhaul_source)
    [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]] && source_repo="unknown (verify source before maintenance)"
    binary_display="$BACKHAUL_BIN (installed)"
  elif installation_footprint_exists; then
    source_repo="unknown (existing installation footprint)"
  fi

  service_binary=$(selected_service_binary_path 2>/dev/null || true)
  if [[ -n "$service_binary" ]]; then
    binary_display="$service_binary"
    if [[ "$service_binary" != "$BACKHAUL_BIN" ]]; then
      version=$(backhaul_binary_version "$service_binary" 2>/dev/null || printf 'unknown')
      source_repo="unknown (selected service is legacy/unmanaged; adopt or migrate first)"
    fi
  fi

  if service_is_active; then
    if profile_service_references_config_file "$ACTIVE_PROFILE" "$CONFIG_FILE"; then
      if [[ "$service_binary" == "$BACKHAUL_BIN" ]]; then
        active="active"
      else
        active="active (legacy/unmanaged)"
      fi
      if service_health_probe "$SERVICE_NAME" "$CONFIG_FILE"; then tunnel="healthy"; else tunnel="degraded/disconnected"; fi
    else
      active="active (config mismatch)"
      tunnel="unknown (config mismatch)"
    fi
  fi
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && enabled="enabled"
  role=$(config_role)
  transport=$(config_value transport 2>/dev/null || true)
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do profile_exists "$profile" && ((profile_count += 1)); done
  refresh_legacy_configs
  legacy_count=${#LEGACY_CONFIG_FILES[@]}
  if [[ "$role" == server* ]]; then address=$(config_value bind_addr 2>/dev/null || true); else address=$(config_value remote_addr 2>/dev/null || true); fi
  printf '\n%bBackhaul status%b\n' "$C_BOLD" "$C_RESET"
  printf '  Manager    : v%s\n' "$MANAGER_VERSION"
  printf '  Backhaul   : %s\n' "$version"
  printf '  Binary     : %s\n' "$binary_display"
  printf '  Source     : %s\n' "$source_repo"
  printf '  Profile    : %s selected (%s configured, %s extra legacy detected)\n' "$ACTIVE_PROFILE" "$profile_count" "$legacy_count"
  printf '  Role       : %s\n' "$role"
  printf '  Transport  : %s\n' "${transport:-unknown}"
  printf '  Endpoint   : %s\n' "${address:-unknown}"
  printf '  Service    : %s, %s\n' "$active" "$enabled"
  printf '  Tunnel     : %s\n' "$tunnel"
  printf '  Config     : %s\n' "$CONFIG_FILE"
  [[ -n "$LOG_FILE" ]] && printf '  Run log    : %s\n' "$LOG_FILE"
}

diagnose() {
  local failures=0 warnings=0 version role transport endpoint protocol port source_repo service_binary="" managed_version="" unit_file=""
  printf '\n%b===== Diagnostics =====%b\n' "$C_BOLD" "$C_RESET"
  service_binary=$(selected_service_binary_path 2>/dev/null || true)
  if [[ -x "$BACKHAUL_BIN" ]] && managed_version=$(backhaul_binary_version "$BACKHAUL_BIN" 2>/dev/null); then
    ok "Managed binary installed: ${BACKHAUL_BIN} (${managed_version})"
  elif [[ ! -n "$service_binary" ]]; then
    err "Backhaul binary is missing or invalid for the selected service."
    ((failures += 1))
  fi
  if [[ -n "$service_binary" && "$service_binary" != "$BACKHAUL_BIN" ]]; then
    version=$(backhaul_binary_version "$service_binary" 2>/dev/null || printf 'unknown')
    warn "Selected service uses a legacy/unmanaged executable: ${service_binary} (${version})."
    info "Adopt or migrate it before source-dependent maintenance."
    ((warnings += 1))
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    ok "Config exists: ${CONFIG_FILE}"
    local mode
    mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ "$mode" != "600" ]]; then warn "Config permissions are ${mode:-unknown}; 600 is recommended."; ((warnings += 1)); fi
  else
    err "Config file is missing."
    ((failures += 1))
  fi
  unit_file=$(service_fragment_path "$SERVICE_NAME" "$SERVICE_FILE" 2>/dev/null || true)
  if [[ -n "$unit_file" ]]; then
    ok "systemd unit exists: ${unit_file}"
    if service_references_config_file "$SERVICE_NAME" "$unit_file" "$CONFIG_FILE"; then
      if [[ "$service_binary" == "$BACKHAUL_BIN" ]]; then
        ok "Service uses the managed binary and selected profile config."
      else
        warn "Service uses the selected config but an unmanaged executable: ${service_binary:-unknown}."
        ((warnings += 1))
      fi
    else
      err "Service/config mismatch: ${SERVICE_NAME} does not point at ${CONFIG_FILE}."
      ((failures += 1))
    fi
  else
    err "systemd unit is missing."
    ((failures += 1))
  fi
  if service_is_active; then
    ok "Service is active."
    if [[ -f "$CONFIG_FILE" ]] && profile_service_references_config_file "$ACTIVE_PROFILE" "$CONFIG_FILE" \
        && service_health_probe "$SERVICE_NAME" "$CONFIG_FILE"; then
      ok "Tunnel health is verified for the running service PID."
    else
      err "Service is active, but the tunnel health check failed for its current PID."
      ((failures += 1))
    fi
  else
    err "Service is not active."
    ((failures += 1))
  fi
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then ok "Service is enabled at boot."; else warn "Service is not enabled at boot."; ((warnings += 1)); fi

  if [[ -n "$service_binary" && "$service_binary" != "$BACKHAUL_BIN" ]]; then
    source_repo="$UNKNOWN_BACKHAUL_SOURCE"
  else
    source_repo=$(current_backhaul_source)
  fi
  if [[ "$source_repo" == "$UNKNOWN_BACKHAUL_SOURCE" ]]; then
    warn "Backhaul source provenance is unknown; it was not guessed from the default repository."
    ((warnings += 1))
  elif [[ -f "$CONFIG_FILE" ]] && check_config_compatibility_file "$source_repo" "$CONFIG_FILE"; then
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
  if ! profile_exists "$ACTIVE_PROFILE"; then err "Selected profile is not configured."; return 1; fi
  if ! profile_service_references_config_file "$ACTIVE_PROFILE" "$CONFIG_FILE"; then
    err "Refusing mismatched metrics: ${SERVICE_NAME} does not point at ${CONFIG_FILE}."
    return 1
  fi
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

restore_service_activation_state() {
  local svc="$1" was_active="$2" was_enabled="$3" failed=0
  if [[ "$was_active" == "yes" ]]; then
    systemctl start "$svc" >/dev/null 2>&1 || failed=1
  else
    stop_service_verified "$svc" >/dev/null 2>&1 || failed=1
  fi
  if [[ "$was_enabled" == "yes" ]]; then
    systemctl enable "$svc" >/dev/null 2>&1 || failed=1
  else
    disable_service_verified "$svc" >/dev/null 2>&1 || failed=1
  fi
  (( failed == 0 ))
}

service_action() {
  local action="$1" unit_file="" was_active="no" was_enabled="no"
  unit_file=$(service_fragment_path "$SERVICE_NAME" "$SERVICE_FILE" 2>/dev/null || true)
  if [[ -z "$unit_file" ]]; then
    err "Backhaul is not installed as a service for the selected profile."
    return 1
  fi
  if ! service_uses_config_file "$SERVICE_NAME" "$unit_file" "$CONFIG_FILE"; then
    err "Refusing service action: ${SERVICE_NAME} does not use the managed binary and selected config ${CONFIG_FILE}."
    info "Open Profiles to inspect detected legacy tunnels or adopt the correct config first."
    return 1
  fi
  service_is_active && was_active="yes"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && was_enabled="yes"
  case "$action" in
    start)
      if ! systemctl daemon-reload; then err "systemd daemon-reload failed."; return 1; fi
      if ! systemctl enable "$SERVICE_NAME" >/dev/null; then
        err "Could not enable ${SERVICE_NAME}."
        restore_service_activation_state "$SERVICE_NAME" "$was_active" "$was_enabled" || true
        return 1
      fi
      if ! systemctl start "$SERVICE_NAME"; then
        err "Could not start ${SERVICE_NAME}."
        restore_service_activation_state "$SERVICE_NAME" "$was_active" "$was_enabled" || true
        return 1
      fi
      ;;
    stop)
      stop_service_verified "$SERVICE_NAME" || return 1
      ;;
    restart)
      if ! systemctl restart "$SERVICE_NAME"; then err "Could not restart ${SERVICE_NAME}."; return 1; fi
      ;;
    *) return 2 ;;
  esac
  if [[ "$action" == "stop" ]]; then
    ok "Backhaul stopped."
  else
    if verify_service_health "$SERVICE_NAME" "$CONFIG_FILE" 20; then
      ok "Backhaul ${action} succeeded and tunnel health is verified."
    else
      err "Backhaul ${action} did not reach a healthy tunnel state."
      if [[ "$action" == "start" ]]; then
        warn "Restoring the service activation state from before the failed start..."
        restore_service_activation_state "$SERVICE_NAME" "$was_active" "$was_enabled" || warn "Could not fully restore the previous activation state."
      fi
      return 1
    fi
  fi
}

resolve_release_version() {
  local source_repo="$1" requested="${2:-latest}" release_base headers location version
  validate_backhaul_source "$source_repo" || return 1
  validate_version "$requested" || return 1
  requested=$(normalize_version "$requested")
  if [[ "$requested" != "latest" ]]; then
    printf '%s' "$requested"
    return 0
  fi
  release_base=$(backhaul_release_base "$source_repo") || return 1
  headers=$(curl --proto '=https' --tlsv1.2 -fsSI --connect-timeout 10 --max-time 30 "${release_base}/latest") || {
    err "Could not query the latest release for ${source_repo}."
    return 1
  }
  location=$(awk '
    BEGIN {IGNORECASE=1}
    /^location:[[:space:]]*/ {
      sub(/^[^:]+:[[:space:]]*/, "")
      sub(/\r$/, "")
      if (!found++) print
    }
  ' <<< "$headers")
  [[ "$location" != *$'\n'* ]] || { err "Ambiguous latest-release redirect for ${source_repo}."; return 1; }
  version="${location##*/}"
  validate_version "$version" || { err "Could not resolve the latest release for ${source_repo}."; return 1; }
  normalize_version "$version"
}

version_is_older() {
  local LC_ALL=C
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

stage_all_profiles_for_source() {
  local source_repo="$1" stage_dir="$2" profile file staged
  install -d -m 0700 "$stage_dir" || return 1
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    file=$(profile_config_path "$profile")
    install -d -m 0700 "$stage_dir/$profile" || return 1
    staged="$stage_dir/$profile/config.toml"
    if ! sanitize_config_for_source "$source_repo" "$file" "$staged"; then
      err "Could not safely adapt profile '${profile}' for ${source_repo}."
      return 1
    fi
  done
}

commit_staged_profiles() {
  local stage_dir="$1" profile_dir profile target tmp
  for profile_dir in "$stage_dir"/*; do
    [[ -d "$profile_dir" && -f "$profile_dir/config.toml" ]] || continue
    profile="${profile_dir##*/}"
    validate_profile_name "$profile" || return 1
    target=$(profile_config_path "$profile") || return 1
    tmp="${target}.migration.$$"
    if ! install -m 0600 "$profile_dir/config.toml" "$tmp" || ! mv -f -- "$tmp" "$target"; then
      rm -f -- "$tmp"
      err "Could not atomically commit profile '${profile}'."
      return 1
    fi
  done
}

commit_staged_binary() {
  local candidate="$1" tmp="${BACKHAUL_BIN}.new"
  [[ -f "$candidate" && -x "$candidate" ]] || { err "Staged Backhaul binary is missing or not executable."; return 1; }
  install -m 0755 "$candidate" "$tmp" || return 1
  mv -f -- "$tmp" "$BACKHAUL_BIN"
}

start_managed_services_from_state() {
  local state_file="$1" svc active enabled profile config_file started=0
  while read -r svc active enabled; do
    [[ -n "$svc" && "$active" == "yes" ]] || continue
    if [[ "$svc" == "backhaul.service" ]]; then
      profile="default"
    elif [[ "$svc" =~ ^backhaul-([A-Za-z0-9][A-Za-z0-9_-]{0,31})\.service$ ]]; then
      profile="${BASH_REMATCH[1]}"
    else
      err "Unexpected managed service in saved state: ${svc}"
      return 1
    fi
    config_file=$(profile_config_path "$profile") || return 1
    systemctl start "$svc" || return 1
    verify_service_health "$svc" "$config_file" || return 1
    started=$((started + 1))
  done < "$state_file"
  STARTED_SERVICE_COUNT="$started"
}

migrate_selected_legacy_installation() {
  local target_source="$1" requested="${2:-latest}" allow_downgrade="${3:-no}" allow_sanitize="${4:-no}" current_source_hint="${5:-}"
  local legacy_binary current_version current_source="$UNKNOWN_BACKHAUL_SOURCE" target_version candidate staged_config=""
  local config_snapshot="" service_snapshot="" binary_snapshot="" source_snapshot="" was_active="no" was_enabled="no"
  validate_backhaul_source "$target_source" || { err "Invalid migration target: ${target_source}"; return 1; }
  legacy_binary=$(selected_legacy_binary_path 2>/dev/null) || { err "No adoptable legacy installation is selected."; return 1; }
  current_version=$(backhaul_binary_version "$legacy_binary") || { err "Legacy Backhaul binary did not report a valid version."; return 1; }
  if validate_backhaul_source "$current_source_hint" 2>/dev/null; then current_source="$current_source_hint"; fi
  target_version=$(resolve_release_version "$target_source" "$requested") || return 1
  if version_is_older "$target_version" "$current_version" && [[ "$allow_downgrade" != "yes" ]]; then
    warn "Migration would downgrade Backhaul: ${current_version} -> ${target_version}."
    return 3
  fi
  if ! check_config_compatibility_file "$target_source" "$CONFIG_FILE"; then
    warn "Selected legacy config contains settings unsupported by ${target_source}: ${COMPAT_UNSUPPORTED_KEYS[*]}"
    [[ "$allow_sanitize" == "yes" ]] || return 4
  fi

  ensure_directories || return 1
  candidate="${STATE_DIR}/.legacy-migration-binary.$$"
  if [[ "$allow_sanitize" == "yes" ]]; then
    staged_config="${STATE_DIR}/.legacy-migration-config.$$"
    sanitize_config_for_source "$target_source" "$CONFIG_FILE" "$staged_config" || { rm -f -- "$staged_config"; return 1; }
  fi
  download_backhaul "$target_version" "$target_source" "$candidate" || { rm -f -- "$candidate" "$staged_config"; return 1; }
  service_is_active && was_active="yes"
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && was_enabled="yes"
  if ! snapshot_file "$CONFIG_FILE" "legacy-config" config_snapshot \
      || ! snapshot_file "$SERVICE_FILE" "legacy-service" service_snapshot \
      || ! snapshot_file "$BACKHAUL_BIN" "legacy-managed-bin" binary_snapshot \
      || ! snapshot_file "$BACKHAUL_SOURCE_FILE" "legacy-source" source_snapshot; then
    rm -f -- "$candidate" "$staged_config"
    return 1
  fi
  begin_transaction rollback_install "$config_snapshot" "$service_snapshot" "$binary_snapshot" "$was_active" "$was_enabled" "$source_snapshot" || {
    rm -f -- "$candidate" "$staged_config"; return 1;
  }
  if [[ "$was_active" == "yes" ]] && ! stop_service_verified "$SERVICE_NAME"; then
    rollback_active_transaction "legacy migration stop failure" || true
    rm -f -- "$candidate" "$staged_config"
    return 1
  fi
  if [[ -n "$staged_config" ]]; then
    if ! install -m 0600 "$staged_config" "${CONFIG_FILE}.migration" || ! mv -f -- "${CONFIG_FILE}.migration" "$CONFIG_FILE"; then
      rm -f -- "${CONFIG_FILE}.migration"
      rollback_active_transaction "legacy migration config failure" || true
      rm -f -- "$candidate" "$staged_config"
      return 1
    fi
  elif ! chmod 0600 "$CONFIG_FILE"; then
    rollback_active_transaction "legacy migration config-permission failure" || true
    rm -f -- "$candidate" "$staged_config"
    return 1
  fi
  if ! commit_staged_binary "$candidate" || ! write_service_file "$target_source" || ! systemctl daemon-reload; then
    rollback_active_transaction "legacy migration install failure" || true
    rm -f -- "$candidate" "$staged_config"
    return 1
  fi
  if [[ "$was_enabled" == "yes" ]]; then
    if ! systemctl enable "$SERVICE_NAME" >/dev/null; then
      rollback_active_transaction "legacy migration enable failure" || true
      rm -f -- "$candidate" "$staged_config"
      return 1
    fi
  elif ! disable_service_verified "$SERVICE_NAME"; then
    rollback_active_transaction "legacy migration disable failure" || true
    rm -f -- "$candidate" "$staged_config"
    return 1
  fi
  if [[ "$was_active" == "yes" ]]; then
    if ! systemctl start "$SERVICE_NAME" || ! verify_service_health "$SERVICE_NAME" "$CONFIG_FILE" 20; then
      rollback_active_transaction "legacy migration health failure" || true
      rm -f -- "$candidate" "$staged_config"
      return 1
    fi
  fi
  if ! save_backhaul_source "$target_source"; then
    rollback_active_transaction "legacy migration source-state failure" || true
    rm -f -- "$candidate" "$staged_config"
    return 1
  fi
  commit_transaction
  rm -f -- "$candidate" "$staged_config"
  ok "Legacy installation migrated safely: ${current_source} ${current_version} -> ${target_source} ${target_version}."
  info "The old executable was retained at ${legacy_binary}; the service now uses ${BACKHAUL_BIN}."
}

adopt_legacy_installation() {
  local requested_source="${1:-}" legacy_binary version source_repo
  legacy_binary=$(selected_legacy_binary_path 2>/dev/null) || {
    err "No legacy installation is selected. The service must reference ${CONFIG_FILE} through a non-managed executable."
    return 1
  }
  version=$(backhaul_binary_version "$legacy_binary") || { err "Legacy Backhaul binary is invalid."; return 1; }
  if [[ -n "$requested_source" ]]; then
    validate_backhaul_source "$requested_source" || { err "Invalid Backhaul source: ${requested_source}"; return 1; }
    if ! binary_matches_release_source "$legacy_binary" "$requested_source" "$version"; then
      err "Legacy binary does not match ${requested_source} ${version}; refusing to record false provenance."
      return 1
    fi
    source_repo="$requested_source"
  else
    source_repo=$(detect_backhaul_source_for_binary "$legacy_binary" 2>/dev/null || true)
    if [[ -z "$source_repo" ]]; then
      err "Could not uniquely identify the legacy binary from supported release assets."
      info "Run --adopt-legacy REPO with the repository that supplied this exact binary, or use Migrate source to replace it."
      return 1
    fi
  fi
  migrate_selected_legacy_installation "$source_repo" "$version" "no" "no" "$source_repo"
}

adopt_legacy_installation_interactive() {
  local legacy_binary version source_repo
  legacy_binary=$(selected_legacy_binary_path 2>/dev/null) || {
    info "No adoptable legacy installation is selected."
    return 0
  }
  version=$(backhaul_binary_version "$legacy_binary" 2>/dev/null || printf 'unknown')
  printf '\n%b===== Adopt legacy installation =====%b\n' "$C_BOLD" "$C_RESET"
  printf 'Legacy binary : %s\n' "$legacy_binary"
  printf 'Version       : %s\n' "$version"
  printf 'Config        : %s\n' "$CONFIG_FILE"
  printf 'Service       : %s\n' "$SERVICE_NAME"
  info "Trying exact release-binary provenance detection..."
  source_repo=$(detect_backhaul_source_for_binary "$legacy_binary" 2>/dev/null || true)
  if [[ -n "$source_repo" ]]; then
    ok "Verified source: ${source_repo}"
  else
    warn "Automatic provenance was not unique. Choose a source; the binary will still be verified byte-for-byte before adoption."
    source_repo=$(choose_backhaul_source)
  fi
  ask_yn "Adopt this installation without changing its Backhaul version/settings?" "n" || return 0
  adopt_legacy_installation "$source_repo"
}

migrate_backhaul_source() {
  local target_source="$1" requested="${2:-latest}" allow_downgrade="${3:-no}" allow_sanitize="${4:-no}"
  local current_source current_version target_version safety original_profile profile
  local stage_dir candidate started
  validate_backhaul_source "$target_source" || { err "Invalid migration target: ${target_source}"; return 1; }
  if [[ ! -x "$BACKHAUL_BIN" ]] && selected_legacy_binary_path >/dev/null 2>&1; then
    migrate_selected_legacy_installation "$target_source" "$requested" "$allow_downgrade" "$allow_sanitize"
    return $?
  fi
  managed_installation_exists || { err "No managed installation found."; return 1; }
  [[ -x "$BACKHAUL_BIN" ]] || { err "Managed Backhaul binary is missing. Adopt the legacy installation first."; return 1; }
  guard_selected_service_mapping || return 1
  guard_active_legacy_tunnels "migrate the shared Backhaul source" || return 1
  guard_shared_binary_consumers "migrate the shared Backhaul source" || return 1
  current_source=$(current_backhaul_source)
  [[ "$current_source" != "$target_source" ]] || { warn "Backhaul already uses ${target_source}."; return 2; }
  if ! current_version=$(installed_backhaul_version); then
    err "The installed Backhaul binary did not report a valid version; refusing source migration."
    return 1
  fi
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
  stage_dir="${STATE_DIR}/.source-migration-stage.$$"
  candidate="${STATE_DIR}/.backhaul-candidate.$$"
  install -d -m 0700 "$stage_dir" || return 1
  if [[ "$allow_sanitize" == "yes" ]]; then
    if ! stage_all_profiles_for_source "$target_source" "$stage_dir/profiles"; then
      rm -rf -- "$stage_dir"
      return 1
    fi
  fi
  if ! download_backhaul "$target_version" "$target_source" "$candidate"; then
    rm -rf -- "$stage_dir"
    return 1
  fi

  begin_transaction apply_backup_tree "$safety" || { rm -rf -- "$stage_dir"; rm -f -- "$candidate"; return 1; }
  if ! stop_all_managed_services; then
    rollback_active_transaction "source migration stop failure" || true
    rm -rf -- "$stage_dir"; rm -f -- "$candidate"
    return 1
  fi
  if [[ "$allow_sanitize" == "yes" ]] && ! commit_staged_profiles "$stage_dir/profiles"; then
    rollback_active_transaction "source migration config commit failure" || true
    rm -rf -- "$stage_dir"; rm -f -- "$candidate"
    return 1
  fi
  if ! commit_staged_binary "$candidate"; then
    rollback_active_transaction "source migration binary commit failure" || true
    rm -rf -- "$stage_dir"; rm -f -- "$candidate"
    return 1
  fi
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    profile_exists "$profile" || continue
    apply_profile_context "$profile"
    if ! write_service_file "$target_source"; then
      rollback_active_transaction "source migration unit update failure" || true
      rm -rf -- "$stage_dir"; rm -f -- "$candidate"
      return 1
    fi
  done
  if ! systemctl daemon-reload; then
    rollback_active_transaction "source migration daemon-reload failure" || true
    rm -rf -- "$stage_dir"; rm -f -- "$candidate"
    return 1
  fi
  if ! start_managed_services_from_state "$safety/services.state"; then
    err "A managed tunnel failed health verification after source migration."
    rollback_active_transaction "source migration health failure" || true
    rm -rf -- "$stage_dir"; rm -f -- "$candidate"
    return 1
  fi
  started="$STARTED_SERVICE_COUNT"
  if ! save_backhaul_source "$target_source"; then
    rollback_active_transaction "source metadata persistence failure" || true
    rm -rf -- "$stage_dir"; rm -f -- "$candidate"
    return 1
  fi
  if profile_exists "$original_profile" || [[ "$original_profile" == "default" ]]; then apply_profile_context "$original_profile"; fi
  if ! save_active_profile "$ACTIVE_PROFILE"; then
    rollback_active_transaction "active-profile state failure" || true
    rm -rf -- "$stage_dir"; rm -f -- "$candidate"
    return 1
  fi
  commit_transaction
  rm -rf -- "$stage_dir"; rm -f -- "$candidate"
  ok "Migration complete: ${current_source} ${current_version} -> ${target_source} ${target_version}; ${started} active tunnel(s) verified."
}

migrate_source_interactive() {
  local target_source version rc downgrade="no" sanitize="no"
  printf '\n%b===== Migrate Backhaul source =====%b\n' "$C_BOLD" "$C_RESET"
  printf 'Current source: %s\n' "$(current_backhaul_source)"
  target_source=$(choose_backhaul_source)
  if [[ "$target_source" == "$(current_backhaul_source)" ]]; then
    info "Backhaul already uses ${target_source}. Use 'Upgrade current source' to verify/repair or update it."
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
        if [[ "$target_source" == "$MUSIXAL_BACKHAUL_REPO" ]]; then
          warn "Safe adaptation removes PowerMatin-only keys and disables the Musixal web monitor where secure loopback/auth settings are unavailable."
        else
          warn "Safe adaptation removes only known role-mismatched legacy keys that the target does not use."
        fi
        ask_yn "Create a backup and adapt incompatible profiles automatically?" "n" || { info "Migration cancelled."; return 0; }
        sanitize="yes"
        ;;
      *) return "$rc" ;;
    esac
  done
}

upgrade_backhaul() {
  local version="${1:-latest}" source_repo="${2:-}" allow_downgrade="${3:-no}"
  local safety current_version target_version candidate restarted=0 legacy_binary=""
  validate_version "$version" || { err "Invalid Backhaul version: ${version}"; return 1; }
  version=$(normalize_version "$version")
  if [[ ! -x "$BACKHAUL_BIN" ]] && legacy_binary=$(selected_legacy_binary_path 2>/dev/null); then
    if [[ -z "$source_repo" ]]; then
      source_repo=$(detect_backhaul_source_for_binary "$legacy_binary" 2>/dev/null || true)
      if [[ -z "$source_repo" ]]; then
        err "Legacy binary source could not be uniquely verified; use Migrate source or Adopt legacy installation first."
        return 1
      fi
    fi
    migrate_selected_legacy_installation "$source_repo" "$version" "$allow_downgrade" "no" "$source_repo"
    return $?
  fi
  managed_installation_exists || { err "No managed installation found. Configure Backhaul first."; return 1; }
  guard_selected_service_mapping || return 1
  guard_active_legacy_tunnels "upgrade the shared Backhaul binary" || return 1
  guard_shared_binary_consumers "upgrade the shared Backhaul binary" || return 1
  if [[ -z "$source_repo" ]]; then
    source_repo=$(require_known_backhaul_source) || return 1
  fi
  validate_backhaul_source "$source_repo" || { err "Invalid Backhaul source: ${source_repo}"; return 1; }
  if ! current_version=$(installed_backhaul_version); then
    err "The installed Backhaul binary is missing or did not report a valid version."
    return 1
  fi
  target_version=$(resolve_release_version "$source_repo" "$version") || return 1
  if [[ -n "$current_version" ]] && version_is_older "$target_version" "$current_version" && [[ "$allow_downgrade" != "yes" ]]; then
    warn "Upgrade request would downgrade Backhaul: ${current_version} -> ${target_version}."
    return 3
  fi
  check_all_profiles_compatibility "$source_repo" || {
    err "One or more profiles are incompatible with the selected source; run Compatibility check first."
    print_incompatible_profiles
    return 1
  }
  create_backup "upgrade" || return 1
  safety="$LAST_BACKUP_DIR"
  candidate="${STATE_DIR}/.backhaul-upgrade-candidate.$$"
  if ! download_backhaul "$target_version" "$source_repo" "$candidate"; then return 1; fi
  if (( BINARY_CHANGED == 0 )); then
    rm -f -- "$candidate"
    save_backhaul_source "$source_repo" || return 1
    return 0
  fi
  begin_transaction apply_backup_tree "$safety" || { rm -f -- "$candidate"; return 1; }
  if ! stop_all_managed_services; then
    rollback_active_transaction "upgrade stop failure" || true
    rm -f -- "$candidate"
    return 1
  fi
  if ! commit_staged_binary "$candidate"; then
    rollback_active_transaction "upgrade binary commit failure" || true
    rm -f -- "$candidate"
    return 1
  fi
  if ! start_managed_services_from_state "$safety/services.state"; then
    rollback_active_transaction "upgrade health failure" || true
    rm -f -- "$candidate"
    return 1
  fi
  restarted="$STARTED_SERVICE_COUNT"
  if ! save_backhaul_source "$source_repo"; then
    rollback_active_transaction "upgrade source-state failure" || true
    rm -f -- "$candidate"
    return 1
  fi
  commit_transaction
  rm -f -- "$candidate"
  if (( restarted > 0 )); then ok "Upgrade complete: ${DOWNLOADED_VERSION}; ${restarted} active profile(s) verified.";
  else ok "Upgraded to ${DOWNLOADED_VERSION}; all profiles remain stopped."; fi
}

upgrade_backhaul_interactive() {
  local version rc downgrade="no"
  version=$(ask_version)
  while true; do
    if upgrade_backhaul "$version" "" "$downgrade"; then
      return 0
    else
      rc=$?
    fi
    if [[ "$rc" -ne 3 ]]; then
      return "$rc"
    fi
    if ! ask_yn "This is a downgrade. Continue only if you explicitly need the older release?" "n"; then
      info "Upgrade/downgrade cancelled before changing the running binary."
      return 0
    fi
    downgrade="yes"
  done
}

show_logs() {
  local lines="${1:-80}"
  if [[ ! "$lines" =~ ^[0-9]+$ ]] || (( 10#$lines < 1 || 10#$lines > 5000 )); then
    err "Log line count must be between 1 and 5000."
    return 1
  fi
  if ! profile_service_references_config_file "$ACTIVE_PROFILE" "$CONFIG_FILE"; then
    err "Refusing mismatched logs: ${SERVICE_NAME} does not point at ${CONFIG_FILE}."
    return 1
  fi
  journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager
}

follow_logs() {
  local rc=0 interrupted=0
  if ! profile_service_references_config_file "$ACTIVE_PROFILE" "$CONFIG_FILE"; then
    err "Refusing mismatched logs: ${SERVICE_NAME} does not point at ${CONFIG_FILE}."
    return 1
  fi
  info "Following logs; press Ctrl+C to return."
  trap 'interrupted=1' INT
  journalctl -u "$SERVICE_NAME" -f || rc=$?
  trap on_interrupt INT
  if (( interrupted )) || (( rc == 130 )); then
    info "Stopped following logs."
    return 0
  fi
  return "$rc"
}

rollback_uninstall_transaction() {
  local reason="$1" rollback_dir="${2:-}"
  if rollback_active_transaction "$reason"; then
    [[ -z "$rollback_dir" ]] || rm -rf -- "$rollback_dir" || warn "Could not remove temporary rollback data: ${rollback_dir}"
    return 0
  fi
  if [[ -n "$rollback_dir" && -d "$rollback_dir" ]]; then
    err "Emergency rollback snapshot preserved at: ${rollback_dir}"
  fi
  return 1
}

uninstall_backhaul() {
  local profile svc safety rollback_dir="" purge="no" legacy_binary=""
  if [[ ! -x "$BACKHAUL_BIN" ]] && legacy_binary=$(selected_legacy_binary_path 2>/dev/null); then
    err "Selected service is a legacy/unmanaged installation (${legacy_binary})."
    info "Adopt or migrate it first so uninstall can be transactional and restorable."
    return 1
  fi
  printf '\n%b===== Uninstall Backhaul =====%b\n' "$C_BOLD" "$C_RESET"
  guard_selected_service_mapping || return 1
  guard_active_legacy_tunnels "uninstall the shared Backhaul binary" || return 1
  guard_shared_binary_consumers "uninstall the shared Backhaul binary" || return 1
  warn "This removes all managed Backhaul services and the shared binary."
  if ! ask_yn "Continue?" "n"; then info "Cancelled."; return 0; fi
  if ask_yn "Also permanently delete config, credentials, and backups?" "n"; then purge="yes"; fi
  create_backup "pre-uninstall" || return 1
  safety="$LAST_BACKUP_DIR"
  if [[ "$purge" == "yes" ]]; then
    rollback_dir=$(mktemp -d /tmp/backhaul-uninstall-rollback.XXXXXX)
    chmod 0700 "$rollback_dir"
    if ! cp -a -- "$safety/." "$rollback_dir/"; then
      rm -rf -- "$rollback_dir"
      err "Could not prepare an out-of-tree uninstall rollback snapshot."
      return 1
    fi
    begin_transaction apply_backup_tree "$rollback_dir" || { rm -rf -- "$rollback_dir"; return 1; }
  else
    begin_transaction apply_backup_tree "$safety" || return 1
  fi
  refresh_profile_names
  for profile in "${PROFILE_NAMES[@]}"; do
    svc=$(profile_service_name "$profile")
    if profile_exists "$profile" && service_uses_config_file "$svc" "/etc/systemd/system/${svc}" "$(profile_config_path "$profile")"; then
      if ! stop_service_verified "$svc" || ! disable_service_verified "$svc"; then
        rollback_uninstall_transaction "uninstall service stop failure" "$rollback_dir" || true
        return 1
      fi
    elif [[ -e "/etc/systemd/system/${svc}" ]]; then
      warn "Preserving ${svc}: its ExecStart does not use the managed '${profile}' config."
    fi
  done
  for profile in "${PROFILE_NAMES[@]}"; do
    svc=$(profile_service_name "$profile")
    if profile_exists "$profile" && service_uses_config_file "$svc" "/etc/systemd/system/${svc}" "$(profile_config_path "$profile")"; then
      rm -f -- "/etc/systemd/system/${svc}" || { rollback_uninstall_transaction "uninstall unit removal failure" "$rollback_dir" || true; return 1; }
    fi
  done
  if ! systemctl daemon-reload || ! rm -rf -- "$BACKHAUL_DIR"; then
    rollback_uninstall_transaction "uninstall filesystem failure" "$rollback_dir" || true
    return 1
  fi
  if [[ "$purge" == "yes" ]]; then
    if ! rm -rf -- "$BASE_CONFIG_DIR" "$STATE_DIR"; then
      rollback_uninstall_transaction "uninstall purge failure" "$rollback_dir" || true
      return 1
    fi
    apply_profile_context "default"
    commit_transaction
    rm -rf -- "$rollback_dir"
    ok "Backhaul, config, credentials, and backups were removed."
    info "Run logs are preserved in ${LOG_DIR}."
  else
    commit_transaction
    ok "Backhaul was removed; config and backups were preserved."
    info "Preserved: ${BASE_CONFIG_DIR} and ${BACKUP_DIR}"
    info "Recovery snapshot: ${safety}"
  fi
}

backhaul_maintenance_menu() {
  local choice source_repo
  printf '\n%bBackhaul maintenance%b\n' "$C_BOLD" "$C_RESET"
  printf '  1) Upgrade current source\n'
  printf '  2) Migrate source\n'
  printf '  3) Check current compatibility\n'
  printf '  4) Check power0matin compatibility\n'
  printf '  5) Check Musixal compatibility\n'
  printf '  6) Record current source\n'
  printf '  7) Adopt legacy installation\n'
  printf '  0) Back\n'
  choice=$(tty_read "Choose: ")
  case "$choice" in
    1) upgrade_backhaul_interactive ;;
    2) migrate_source_interactive ;;
    3) source_repo=$(current_backhaul_source); show_compatibility "$source_repo" ;;
    4) show_compatibility "$POWERMATIN_BACKHAUL_REPO" ;;
    5) show_compatibility "$MUSIXAL_BACKHAUL_REPO" ;;
    6) claim_backhaul_source_interactive ;;
    7) adopt_legacy_installation_interactive ;;
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
          if ask_yn "Service is active. Stop it?" "n"; then
            service_action stop || true
          fi
        else
          if ask_yn "Service is stopped. Start it?" "y"; then
            service_action start || true
          fi
        fi
        pause_menu
        ;;
      7) backhaul_maintenance_menu || true; pause_menu ;;
      8) profiles_menu || true; pause_menu ;;
      9) backup_migration_menu || true; pause_menu ;;
      10) health_logs_menu || true; pause_menu ;;
      11) manager_menu || true; pause_menu ;;
      12) uninstall_backhaul || true; pause_menu ;;
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
  if operation_requires_lock "$@"; then
    acquire_operation_lock || return 1
  fi
  load_active_profile
  setup_logging
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    -V|--version) printf 'Backhaul Manager %s\n' "$MANAGER_VERSION"; return 0 ;;
  esac

  prepare_runtime "$@" || return 1
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
    --adopt-legacy)
      adopt_legacy_installation "${2:-}"
      ;;
    --set-source)
      [[ -n "${2:-}" ]] || { err "--set-source requires power0matin/Backhaul or Musixal/Backhaul."; return 2; }
      claim_backhaul_source "$2"
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

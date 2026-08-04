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
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh)

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

BACKHAUL_DIR="/opt/backhaul"
CONFIG_DIR="/root/backhaul"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/backhaul.service"
INFO_FILE="${CONFIG_DIR}/backhaul-info.txt"
LOG_FILE="/var/log/backhaul-manager-$(date +%Y%m%d%H%M%S).log"

mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'err "اسکریپت در خط $LINENO با خطا متوقف شد. جزئیات کامل: $LOG_FILE"' ERR

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
    input=$(tty_read "${prompt_text} ${C_YELLOW}[پیش‌فرض: ${default_val}]${C_RESET}: ")
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
    warn "این مقدار الزامی است، دوباره وارد کنید." >&2
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
    err "این اسکریپت تعاملی است و به یک ترمینال نیاز دارد. مستقیم روی SSH اجرا کنید."
    exit 1
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "این اسکریپت باید با دسترسی root اجرا شود. لطفاً با sudo اجرا کنید."
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
    err "دستورهای زیر روی سیستم یافت نشد: ${missing[*]}"
    info "نصب روی Debian/Ubuntu: apt update && apt install -y iproute2 curl tar gawk grep sed"
    exit 1
  fi
  if ! command -v nc >/dev/null 2>&1; then
    warn "دستور nc پیدا نشد؛ تست اتصال کلاینت در پایان انجام نخواهد شد (نصب: apt install -y netcat-openbsd)"
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
    *) err "معماری پشتیبانی‌نشده: $arch"; exit 1 ;;
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

  info "دانلود Backhaul (${version:-latest}) از: $url"
  curl -fsSL --retry 3 --retry-delay 2 -o backhaul.tar.gz "$url"
  tar -tzf backhaul.tar.gz >/dev/null 2>&1 || { err "فایل دانلودشده معتبر نیست (tar corrupt)."; exit 1; }
  tar -xzf backhaul.tar.gz
  chmod +x backhaul
  rm -f backhaul.tar.gz
  ok "باینری Backhaul در ${BACKHAUL_DIR}/backhaul نصب شد"
}

backup_config_if_exists() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local bkp
    bkp="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG_FILE" "$bkp"
    info "کانفیگ قبلی بکاپ گرفته شد: $bkp"
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
  echo "${C_BOLD}===== سرویس‌های در حال اجرا روی این سرور =====${C_RESET}"

  local -a RUNNING=()
  mapfile -t RUNNING < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}')

  if [[ ${#RUNNING[@]} -eq 0 ]]; then
    info "هیچ سرویس در حال اجرایی یافت نشد."
    return
  fi

  local keywords="paqet|backhaul|gost|chisel|rathole|wstunnel|frps?|frpc?|v2ray|xray|sing-?box|hysteria|shadowsocks|ssr-|wireguard|openvpn|nps|ngrok|udp2raw|ligolo"

  local i svc
  for i in "${!RUNNING[@]}"; do
    svc="${RUNNING[$i]}"
    if echo "$svc" | grep -qiE "$keywords"; then
      printf "  %2d) %s   ${C_YELLOW}<-- احتمالاً مرتبط با تونل${C_RESET}\n" "$((i + 1))" "$svc"
    else
      printf "  %2d) %s\n" "$((i + 1))" "$svc"
    fi
  done

  echo
  echo "اگر سرویس(های) قدیمی (مثلاً تونل قبلی) را می‌خواهید متوقف و غیرفعال کنید،"
  echo "شماره یا نام دقیق سرویس را وارد کنید. برای چند مورد از ',' استفاده کنید"
  echo "(مثال: 2,paqet-client.service,5). برای رد شدن، فقط Enter بزنید."
  local sel
  sel=$(tty_read "سرویس(های) موردنظر برای توقف: ")

  if [[ -z "$sel" ]]; then
    info "هیچ سرویسی حذف نشد."
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
        warn "شماره '$item' نامعتبر است، رد شد."
        continue
      fi
    else
      name="$item"
      [[ "$name" != *.service ]] && name="${name}.service"
    fi

    info "در حال متوقف و غیرفعال‌سازی: $name"
    systemctl stop "$name" 2>/dev/null || warn "توقف $name ناموفق بود (شاید قبلاً متوقف بوده)"
    systemctl disable "$name" 2>/dev/null || true
    ok "پردازش شد: $name"
  done
}

# warns about open ports needed; never modifies firewall rules itself
firewall_hint() {
  local ports_list="$1"
  local p
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
    warn "فایروال ufw فعال است. مطمئن شوید پورت‌های زیر باز هستند:"
    for p in $ports_list; do
      echo "    ufw allow ${p}/tcp"
    done
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "فایروال firewalld فعال است. مطمئن شوید پورت‌های زیر باز هستند:"
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

  echo "===== وضعیت سرویس ====="
  if systemctl is-active --quiet backhaul.service; then
    ok "سرویس backhaul فعال است"
  else
    err "سرویس backhaul بالا نیامد!"
    journalctl -u backhaul -n 30 --no-pager || true
    exit 1
  fi
}

configure_server() {
  echo
  echo "${C_BOLD}===== پیکربندی سرور ایران (Server side) =====${C_RESET}"

  local control_port ports_raw version token token_input

  control_port=$(ask "پورت کنترل بک‌هال" "8080")
  ports_raw=$(ask "پورت‌های تونل (با , جدا کنید)" "2052,2082,8002,443")

  echo
  echo "برای توکن مشترک بین سرور و کلاینت می‌توانید یک مقدار دلخواه"
  echo "وارد کنید، یا Enter بزنید تا یک توکن امن به‌صورت خودکار ساخته شود."
  token_input=$(tty_read "توکن (Enter = تولید خودکار): ")
  if [[ -z "$token_input" ]]; then
    token="$(generate_token)"
    ok "توکن امن تولید شد (در خلاصه‌ی پایانی نمایش داده می‌شود)"
  else
    token="$token_input"
  fi

  version=$(ask "نسخه Backhaul (یا latest)" "latest")

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
  ok "کانفیگ نوشته شد: $CONFIG_FILE"

  write_service_file
  start_and_verify_service

  echo "===== بررسی پورت‌ها ====="
  local p
  for p in "${ports_arr[@]}" "${control_port}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
      ok "پورت $p در حال گوش دادن است"
    else
      warn "پورت $p هنوز باز نیست (ممکن است چند ثانیه طول بکشد)"
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

این مقادیر (به‌خصوص Token و IP این سرور) برای پیکربندی سمت
کلاینت (سرور خارج) لازم است.

دستورات مفید:
  systemctl status backhaul
  journalctl -u backhaul -f
EOF
  chmod 600 "$INFO_FILE"

  echo
  echo "${C_BOLD}${C_GREEN}===== خلاصه پیکربندی =====${C_RESET}"
  echo "  توکن          : ${token}"
  echo "  پورت کنترل     : ${control_port}"
  echo "  پورت‌های تونل   : ${ports_arr[*]}"
  echo
  warn "این توکن را برای سمت کلاینت (سرور خارج) کپی کنید — در ${INFO_FILE} هم ذخیره شد."
  echo
  ok "تمام شد. لاگ زنده: journalctl -u backhaul -f"
}

configure_client() {
  echo
  echo "${C_BOLD}===== پیکربندی سرور خارج (Client side) =====${C_RESET}"

  local iran_ip control_port token version

  iran_ip=$(ask_required "آی‌پی سرور ایران")
  control_port=$(ask "پورت کنترل بک‌هال" "8080")
  token=$(ask_required "توکن مشترک (دقیقاً مثل سمت سرور)")
  version=$(ask "نسخه Backhaul (یا latest)" "latest")

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
  ok "کانفیگ نوشته شد: $CONFIG_FILE"

  write_service_file
  start_and_verify_service

  if command -v nc >/dev/null 2>&1; then
    echo "===== تست اتصال به سرور ایران (${iran_ip}:${control_port}) ====="
    if nc -zv -w5 "${iran_ip}" "${control_port}" 2>&1; then
      ok "اتصال برقرار است"
    else
      warn "اتصال برقرار نشد — فایروال سمت ایران یا مسیر شبکه را بررسی کنید"
    fi
  fi

  cat > "$INFO_FILE" << EOF
Backhaul Manager - Client (Kharej) Info
Generated: $(date)

Iran Server  : ${iran_ip}:${control_port}
Config       : ${CONFIG_FILE}
Service      : backhaul.service

دستورات مفید:
  systemctl status backhaul
  journalctl -u backhaul -f
EOF
  chmod 600 "$INFO_FILE"

  echo
  ok "تمام شد. لاگ زنده: journalctl -u backhaul -f"
}

uninstall_backhaul() {
  echo
  warn "این کار سرویس backhaul، باینری و تمام فایل‌های کانفیگ را کاملاً حذف می‌کند."
  if ! ask_yn "آیا مطمئن هستید؟" "n"; then
    info "لغو شد."
    return
  fi

  systemctl stop backhaul.service 2>/dev/null || true
  systemctl disable backhaul.service 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload

  rm -rf "$BACKHAUL_DIR"
  rm -rf "$CONFIG_DIR"

  ok "Backhaul به‌طور کامل از این سرور حذف شد."
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

  echo "این اسکریپت را برای چه کاری اجرا می‌کنید؟"
  echo "  1) نصب/پیکربندی به عنوان سرور ${C_BOLD}ایران${C_RESET} (Server side)"
  echo "  2) نصب/پیکربندی به عنوان سرور ${C_BOLD}خارج${C_RESET} (Client side)"
  echo "  3) حذف کامل Backhaul از این سرور (Uninstall)"
  echo "  0) خروج"
  local choice
  choice=$(tty_read "انتخاب شما: ")

  case "$choice" in
    1) configure_server ;;
    2) configure_client ;;
    3) uninstall_backhaul ;;
    0) info "خروج."; exit 0 ;;
    *) err "گزینه نامعتبر."; exit 1 ;;
  esac

  echo
  info "لاگ کامل این اجرا: $LOG_FILE"
}

main "$@"

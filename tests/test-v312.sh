#!/usr/bin/env bash
# shellcheck disable=SC2317
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT_DIR}/backhaul-manager.sh"

checks=0
pass(){ checks=$((checks+1)); }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_success(){ local l="$1"; shift; if "$@"; then pass; else fail "$l"; fi; }
assert_failure(){ local l="$1"; shift; if "$@"; then fail "$l (unexpected success)"; else pass; fi; }
assert_eq(){ local l="$1" e="$2" a="$3"; [[ "$e" == "$a" ]] || fail "$l: expected <$e>, got <$a>"; pass; }
assert_contains(){ local l="$1" hay="$2" needle="$3"; [[ "$hay" == *"$needle"* ]] || fail "$l: missing <$needle>"; pass; }

tmp=$(mktemp -d /tmp/backhaul-manager-v312-tests.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

# Effective systemd fragment must be honored even outside /etc/systemd/system.
fragment_path="$tmp/vendor.service"
printf '[Service]\nExecStart=/root/backhaul/backhaul -c /root/backhaul/config.toml\n' > "$fragment_path"
fragment_path_from_systemd() (
  systemctl(){ [[ "${1:-}" == show ]] && { printf '%s\n' "$fragment_path"; return 0; }; return 1; }
  [[ "$(service_fragment_path backhaul.service /missing)" == "$fragment_path" ]]
)
assert_success "effective FragmentPath is honored" fragment_path_from_systemd

fragment_fallback_works() (
  systemctl(){ return 1; }
  [[ "$(service_fragment_path backhaul.service "$fragment_path")" == "$fragment_path" ]]
)
assert_success "static unit path remains a safe fallback" fragment_fallback_works

# A vendor unit using the selected config via a legacy executable must not become managed
# merely because a managed binary also exists elsewhere.
selected_legacy_effective_path() (
  local cfg="$tmp/effective.toml"
  printf '[client]\nremote_addr="192.0.2.1:443"\ntransport="wsmux"\n' > "$cfg"
  CONFIG_FILE="$cfg"; SERVICE_FILE="$tmp/missing.service"; SERVICE_NAME=backhaul.service; ACTIVE_PROFILE=default
  service_fragment_path(){ printf '%s' "$fragment_path"; }
  service_references_config_file(){ return 0; }
  service_exec_binary_path(){ printf '/root/backhaul/backhaul'; }
  [[ "$(selected_service_binary_path)" == /root/backhaul/backhaul ]]
)
assert_success "selected service reports effective legacy executable" selected_legacy_effective_path

# Restore validation must reject unit directives capable of changing the filesystem root.
safe_unit="$tmp/safe.service"
cat > "$safe_unit" <<'UNIT'
[Service]
ExecStart=/opt/backhaul/backhaul -c /root/backhaul/config.toml
UNIT
assert_success "minimal restore unit accepted" unit_file_safe_for_restore "$safe_unit" /root/backhaul/config.toml
for directive in RootDirectory RootImage BindPaths BindReadOnlyPaths TemporaryFileSystem MountImages ExtensionImages; do
  bad="$tmp/${directive}.service"
  cp "$safe_unit" "$bad"
  printf '%s=/tmp/evil\n' "$directive" >> "$bad"
  assert_failure "restore rejects ${directive}" unit_file_safe_for_restore "$bad" /root/backhaul/config.toml
done

# Portable backups containing executable code require exact published-release provenance.
portable="$tmp/portable"
mkdir -p "$portable"
printf 'official-bytes\n' > "$portable/backhaul"
cat > "$portable/MANIFEST" <<'MAN'
schema=2
source=power0matin/Backhaul
backhaul_version=v9.9.9
active_profile=default
MAN
portable_match() (
  download_backhaul(){ printf 'official-bytes\n' > "$3"; chmod +x "$3"; }
  verify_portable_backup_binary_provenance "$portable"
)
assert_success "portable binary accepts exact verified release bytes" portable_match
portable_mismatch() (
  download_backhaul(){ printf 'different-release\n' > "$3"; chmod +x "$3"; }
  verify_portable_backup_binary_provenance "$portable" >/dev/null 2>&1
)
assert_failure "portable binary rejects self-consistent but non-release bytes" portable_mismatch
sed -i 's/source=power0matin\/Backhaul/source=unknown/' "$portable/MANIFEST"
portable_unknown_source() { verify_portable_backup_binary_provenance "$portable" >/dev/null 2>&1; }
assert_failure "portable executable with unknown source is rejected" portable_unknown_source

# Failed start must restore the previous stopped/disabled state.
failed_start_restores_activation() (
  local stopped=0 disabled=0
  SERVICE_NAME=backhaul-test.service; SERVICE_FILE="$safe_unit"; CONFIG_FILE=/root/backhaul/config.toml; ACTIVE_PROFILE=default
  service_fragment_path(){ printf '%s' "$safe_unit"; }
  service_uses_config_file(){ return 0; }
  service_is_active(){ return 1; }
  stop_service_verified(){ stopped=1; return 0; }
  disable_service_verified(){ disabled=1; return 0; }
  verify_service_health(){ return 1; }
  systemctl(){
    case "${1:-}" in
      daemon-reload|enable|start) return 0 ;;
      is-enabled) return 1 ;;
      *) return 0 ;;
    esac
  }
  service_action start >/dev/null 2>&1 && return 1
  (( stopped == 1 && disabled == 1 ))
)
assert_success "failed service start restores stopped/disabled state" failed_start_restores_activation

# Existing managed binaries are always version-read through the hardened timeout helper.
server_fn=$(declare -f configure_server)
client_fn=$(declare -f configure_client)
assert_contains "server config uses hardened installed version helper" "$server_fn" "version=\$(installed_backhaul_version)"
assert_contains "client config uses hardened installed version helper" "$client_fn" "version=\$(installed_backhaul_version)"
if grep -Fq "version=\$(\"\$BACKHAUL_BIN\" -v" <<<"$server_fn$client_fn"; then fail "raw unbounded -v call remains in configure path"; else pass; fi

# CLI dispatch: every documented option routes to the intended operation.
cli_route() (
  local expected="$1"; shift
  local marker=""
  prepare_runtime(){ :; }
  profile_exists(){ return 0; }
  apply_profile_context(){ ACTIVE_PROFILE="$1"; }
  show_status(){ marker=status; }
  diagnose(){ marker=diagnose; }
  show_metrics(){ marker=metrics; }
  service_action(){ marker="service:$1"; }
  upgrade_backhaul(){ marker="upgrade:$1"; }
  migrate_backhaul_source(){ marker="migrate:$1:$2"; }
  adopt_legacy_installation(){ marker="adopt:${1:-}"; }
  claim_backhaul_source(){ marker="source:$1"; }
  show_compatibility(){ marker="compat:$1"; }
  list_profiles(){ marker=list-profiles; }
  select_profile(){ marker="select:$1"; }
  create_backup(){ marker="backup:$1"; }
  export_backup_bundle(){ marker="export:$1"; }
  import_backup_bundle(){ marker="import:$1"; }
  restore_backup_dir(){ marker="restore:${1##*/}"; }
  list_backups(){ marker=list-backups; }
  update_manager_command(){ marker=self-update; }
  show_logs(){ marker="logs:$1"; }
  follow_logs(){ marker=follow-logs; }
  main "$@" >/dev/null
  [[ "$marker" == "$expected" ]]
)
assert_success "CLI status route" cli_route status --status
assert_success "CLI diagnose route" cli_route diagnose --diagnose
assert_success "CLI metrics route" cli_route metrics --metrics
assert_success "CLI restart route" cli_route service:restart --restart
assert_success "CLI start route" cli_route service:start --start
assert_success "CLI stop route" cli_route service:stop --stop
assert_success "CLI upgrade route" cli_route upgrade:v1.2.3 --upgrade v1.2.3
assert_success "CLI migrate route" cli_route migrate:Musixal/Backhaul:v0.7.2 --migrate-source Musixal/Backhaul v0.7.2
assert_success "CLI adopt route" cli_route adopt:power0matin/Backhaul --adopt-legacy power0matin/Backhaul
assert_success "CLI source route" cli_route source:power0matin/Backhaul --set-source power0matin/Backhaul
assert_success "CLI compatibility route" cli_route compat:Musixal/Backhaul --compat Musixal/Backhaul
assert_success "CLI profile list route" cli_route list-profiles --list-profiles
assert_success "CLI profile select route" cli_route select:edge --select-profile edge
assert_success "CLI backup route" cli_route backup:cli --backup
assert_success "CLI export route" cli_route export:/tmp/a.tar.gz --export /tmp/a.tar.gz
assert_success "CLI import route" cli_route import:/tmp/a.tar.gz --import /tmp/a.tar.gz
assert_success "CLI restore route" cli_route restore:backup-abc --restore-backup backup-abc
assert_success "CLI backup list route" cli_route list-backups --list-backups
assert_success "CLI self-update route" cli_route self-update --self-update
assert_success "CLI logs route" cli_route logs:123 --logs 123
assert_success "CLI follow logs route" cli_route follow-logs --follow-logs
assert_success "profile-prefixed CLI route" cli_route status --profile edge --status

# Required argument errors and unknown option must be deterministic exit code 2.
cli_rc() (
  prepare_runtime(){ :; }
  main "$@" >/dev/null 2>&1
)
for args in '--migrate-source' '--set-source' '--select-profile' '--export' '--import' '--restore-backup' '--profile'; do
  # shellcheck disable=SC2086
  if cli_rc $args; then fail "missing argument accepted for $args"; else rc=$?; [[ $rc -eq 2 ]] || fail "wrong rc=$rc for $args"; pass; fi
done
if cli_rc --definitely-unknown; then fail "unknown CLI option accepted"; else rc=$?; [[ $rc -eq 2 ]] || fail "unknown option rc=$rc"; pass; fi

# Interactive submenu dispatch coverage without a TTY: each menu choice reaches its action.
submenu_route() (
  local menu="$1" expected="$3" marker=""
  TEST_MENU_CHOICE="$2"
  tty_read(){ printf '%s' "$TEST_MENU_CHOICE"; }
  list_profiles(){ :; }
  upgrade_backhaul_interactive(){ marker=upgrade; }
  migrate_source_interactive(){ marker=migrate; }
  current_backhaul_source(){ printf power0matin/Backhaul; }
  show_compatibility(){ marker="compat:$1"; }
  claim_backhaul_source_interactive(){ marker=claim; }
  adopt_legacy_installation_interactive(){ marker=adopt-install; }
  select_profile_interactive(){ marker=select; }
  create_profile_interactive(){ marker=create; }
  clone_active_profile(){ marker=clone; }
  delete_profile_interactive(){ marker=delete; }
  adopt_legacy_config_interactive(){ marker=adopt-config; }
  create_backup(){ marker=backup; }
  list_backups(){ marker=list-backup; }
  restore_backup_interactive(){ marker=restore; }
  export_backup_interactive(){ marker='export'; }
  import_backup_interactive(){ marker=import; }
  remote_migration_interactive(){ marker=remote; }
  delete_backup_interactive(){ marker=delete-backup; }
  show_metrics(){ marker=metrics; }
  show_logs(){ marker=logs; }
  follow_logs(){ marker=follow; }
  update_manager_command(){ marker=manager-update; }
  case "$menu" in
    maintenance) backhaul_maintenance_menu >/dev/null ;;
    profiles) profiles_menu >/dev/null ;;
    backup) backup_migration_menu >/dev/null ;;
    health) health_logs_menu >/dev/null ;;
    manager) manager_menu >/dev/null ;;
  esac
  [[ "$marker" == "$expected" ]]
)
for spec in \
 'maintenance 1 upgrade' 'maintenance 2 migrate' 'maintenance 3 compat:power0matin/Backhaul' \
 'maintenance 4 compat:power0matin/Backhaul' 'maintenance 5 compat:Musixal/Backhaul' 'maintenance 6 claim' 'maintenance 7 adopt-install' \
 'profiles 1 select' 'profiles 2 create' 'profiles 3 clone' 'profiles 4 delete' 'profiles 5 adopt-config' \
 'backup 1 backup' 'backup 2 list-backup' 'backup 3 restore' 'backup 4 export' 'backup 5 import' 'backup 6 remote' 'backup 7 delete-backup' \
 'health 1 metrics' 'health 2 logs' 'health 3 follow' 'manager 1 manager-update'; do
  read -r m c e <<< "$spec"
  assert_success "submenu route $m/$c" submenu_route "$m" "$c" "$e"
done

# Main menu dispatch coverage for all 12 actions; nested menus are stubbed here because
# each nested option is exhaustively covered above.
main_menu_route() (
  local expected="$2" marker="" counter_file="$tmp/main-menu-counter.$$"
  TEST_MAIN_CHOICE="$1"; printf '0\n' > "$counter_file"
  tty_read(){ local n; n=$(cat "$counter_file"); n=$((n+1)); printf '%s\n' "$n" > "$counter_file"; if (( n == 1 )); then printf '%s' "$TEST_MAIN_CHOICE"; else printf '0'; fi; }
  clear_screen(){ :; }; banner(){ :; }; pause_menu(){ :; }; ask_yn(){ return 0; }
  configure_server(){ marker=server; }
  configure_client(){ marker=client; }
  show_status(){ marker=status; }
  diagnose(){ marker=diag; }
  service_action(){ marker="service:$1"; }
  service_is_active(){ return 0; }
  backhaul_maintenance_menu(){ marker=maintenance; }
  profiles_menu(){ marker=profiles; }
  backup_migration_menu(){ marker=backup; }
  health_logs_menu(){ marker=health; }
  manager_menu(){ marker=manager; }
  uninstall_backhaul(){ marker=uninstall; }
  interactive_menu >/dev/null
  [[ "$marker" == "$expected" ]]
)
assert_success "main menu configure server" main_menu_route 1 server
assert_success "main menu configure client" main_menu_route 2 client
assert_success "main menu status" main_menu_route 3 status
assert_success "main menu diagnostics" main_menu_route 4 diag
assert_success "main menu restart" main_menu_route 5 service:restart
assert_success "main menu start/stop" main_menu_route 6 service:stop
assert_success "main menu maintenance" main_menu_route 7 maintenance
assert_success "main menu profiles" main_menu_route 8 profiles
assert_success "main menu backup" main_menu_route 9 backup
assert_success "main menu health" main_menu_route 10 health
assert_success "main menu manager" main_menu_route 11 manager
assert_success "main menu uninstall" main_menu_route 12 uninstall


# Source-state corruption/ambiguity must fail closed.
state="$tmp/source-state"
printf 'source=power0matin/Backhaul\nsha256=%064d\n' 0 > "$state"
assert_eq "strict source state accepts one source and one hash" power0matin/Backhaul "$(source_repo_from_state_file "$state")"
printf 'source=power0matin/Backhaul\nsource=Musixal/Backhaul\n' > "$state"
assert_failure "duplicate source metadata rejected" source_repo_from_state_file "$state"
printf 'source=power0matin/Backhaul\nunknown_field=x\n' > "$state"
assert_failure "unknown source metadata field rejected" source_repo_from_state_file "$state"
printf 'Musixal/Backhaul\nextra\n' > "$state"
assert_failure "legacy source state rejects extra records" source_repo_from_state_file "$state"

# TOML role/value parsing is scoped to exactly one Backhaul role table.
parser_good="$tmp/parser-good.toml"
cat > "$parser_good" <<'TOML'
[client]
remote_addr = "192.0.2.10:443"
transport = "wsmux"
token = "abc"
connection_pool = 8
TOML
assert_eq "single client section recognized" client "$(config_role_from_file "$parser_good")"
assert_eq "value parser is role-scoped" wsmux "$(config_value_from_file "$parser_good" transport)"
parser_repeat="$tmp/parser-repeat.toml"
cat > "$parser_repeat" <<'TOML'
[client]
remote_addr = "192.0.2.10:443"
[client]
transport = "wsmux"
TOML
assert_eq "repeated client table rejected" unknown "$(config_role_from_file "$parser_repeat")"
parser_extra="$tmp/parser-extra.toml"
cat > "$parser_extra" <<'TOML'
[metadata]
transport = "udp"
[client]
remote_addr = "192.0.2.10:443"
transport = "wsmux"
TOML
assert_eq "unexpected TOML table rejected" unknown "$(config_role_from_file "$parser_extra")"
parser_dup="$tmp/parser-dup.toml"
cat > "$parser_dup" <<'TOML'
[client]
remote_addr = "192.0.2.10:443"
transport = "wsmux"
transport = "tcp"
token = "abc"
connection_pool = 8
TOML
assert_eq "duplicate assignment is detected" transport "$(config_duplicate_keys_from_file "$parser_dup")"
assert_failure "duplicate assignment fails compatibility" check_config_compatibility_file power0matin/Backhaul "$parser_dup"

# Writer + sanitizer smoke tests against the hardened parser.
gen="$tmp/generated"
mkdir -p "$gen"
CONFIG_DIR="$gen"; CONFIG_FILE="$gen/config.toml"; INFO_FILE="$gen/info.txt"
reset_config_options
CONFIG_MODE=standard
PORT_RULES=("2052" "443")
assert_success "generated Power server remains compatible" write_server_config 8080 wsmux test-token '' '' power0matin/Backhaul
assert_success "generated Power server passes hardened parser" check_config_compatibility_file power0matin/Backhaul "$CONFIG_FILE"
reset_config_options
CONFIG_MODE=standard
assert_success "generated Power client remains compatible" write_client_config 192.0.2.10:8080 wsmux test-token '' power0matin/Backhaul
assert_success "generated Power client passes hardened parser" check_config_compatibility_file power0matin/Backhaul "$CONFIG_FILE"
legacy_hb="$tmp/legacy-heartbeat.toml"; sanitized_hb="$tmp/sanitized-heartbeat.toml"
cat > "$legacy_hb" <<'TOML'
[client]
remote_addr = "192.0.2.10:443"
transport = "wsmux"
token = "abc"
connection_pool = 8
heartbeat = 40
retry_interval = 3
TOML
assert_failure "legacy client heartbeat is flagged" check_config_compatibility_file power0matin/Backhaul "$legacy_hb"
assert_success "legacy client heartbeat is safely sanitized" sanitize_config_for_source power0matin/Backhaul "$legacy_hb" "$sanitized_hb"
assert_success "sanitized legacy client passes compatibility" check_config_compatibility_file power0matin/Backhaul "$sanitized_hb"


# Full source/role/transport configuration matrix (7 transports x 2 roles x 2 sources).
matrix="$tmp/matrix"; mkdir -p "$matrix"
printf 'dummy cert\n' > "$matrix/cert.pem"; printf 'dummy key\n' > "$matrix/key.pem"
for src in power0matin/Backhaul Musixal/Backhaul; do
  for transport_name in tcp tcpmux ws wss wsmux wssmux udp; do
    CONFIG_DIR="$matrix"; CONFIG_FILE="$matrix/server-${src%%/*}-${transport_name}.toml"; INFO_FILE="$matrix/info.txt"
    reset_config_options; CONFIG_MODE=standard; PORT_RULES=("2052")
    cert=''; key=''
    if [[ "$transport_name" == wss || "$transport_name" == wssmux ]]; then cert="$matrix/cert.pem"; key="$matrix/key.pem"; fi
    assert_success "matrix server writer $src/$transport_name" write_server_config 18080 "$transport_name" token "$cert" "$key" "$src"
    assert_success "matrix server compatibility $src/$transport_name" check_config_compatibility_file "$src" "$CONFIG_FILE"

    CONFIG_FILE="$matrix/client-${src%%/*}-${transport_name}.toml"
    reset_config_options; CONFIG_MODE=standard
    assert_success "matrix client writer $src/$transport_name" write_client_config 192.0.2.20:18080 "$transport_name" token '' "$src"
    assert_success "matrix client compatibility $src/$transport_name" check_config_compatibility_file "$src" "$CONFIG_FILE"
  done
done

# Advanced fork-only options remain confined to the fork schema.
CONFIG_DIR="$matrix"; CONFIG_FILE="$matrix/power-advanced-server.toml"; INFO_FILE="$matrix/info.txt"
reset_config_options; CONFIG_MODE=advanced; apply_tuning_profile throughput; PORT_RULES=("2052" "3000-3010")
ADV_ACCEPT_UDP=true; ADV_PROXY_PROTOCOL=true; ADV_WEB_PORT=2060; ADV_WEB_USERNAME=backhaul; ADV_WEB_PASSWORD=safe-password_123
assert_success "advanced Power server writer" write_server_config 18081 tcp token '' '' power0matin/Backhaul
assert_success "advanced Power server compatibility" check_config_compatibility_file power0matin/Backhaul "$CONFIG_FILE"
assert_failure "advanced Power server rejected by upstream schema" check_config_compatibility_file Musixal/Backhaul "$CONFIG_FILE"
CONFIG_FILE="$matrix/power-advanced-client.toml"
reset_config_options; CONFIG_MODE=advanced; apply_tuning_profile throughput; ADV_TLS_VERIFY=false; ADV_WEB_PORT=2061; ADV_WEB_USERNAME=backhaul; ADV_WEB_PASSWORD=safe-password_123
assert_success "advanced Power client writer" write_client_config 192.0.2.20:18081 wss token '' power0matin/Backhaul
assert_success "advanced Power client compatibility" check_config_compatibility_file power0matin/Backhaul "$CONFIG_FILE"
assert_failure "advanced Power client rejected by upstream schema" check_config_compatibility_file Musixal/Backhaul "$CONFIG_FILE"


# Duplicate archive paths are ambiguous and must be rejected before extraction.
dupdir="$tmp/duplicate-archive"; mkdir -p "$dupdir"; printf 'one\n' > "$dupdir/data"
tar -cf "$tmp/duplicate.tar" -C "$dupdir" data
tar -rf "$tmp/duplicate.tar" -C "$dupdir" data
gzip -c "$tmp/duplicate.tar" > "$tmp/duplicate.tar.gz"
assert_failure "portable archive rejects duplicate member paths" validate_backup_archive "$tmp/duplicate.tar.gz"

# Release archives must contain exactly one top-level Backhaul executable.
duplicate_release_member_rejected() (
  local fixture="$tmp/duplicate-release" raw archive checksums stage
  mkdir -p "$fixture/pkg"
  cat > "$fixture/pkg/backhaul" <<'BIN'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && { printf 'v9.9.9\n'; exit 0; }
exit 0
BIN
  chmod +x "$fixture/pkg/backhaul"
  raw="$fixture/release.tar"
  tar -cf "$raw" -C "$fixture/pkg" backhaul
  tar -rf "$raw" -C "$fixture/pkg" backhaul
  archive="$fixture/backhaul_linux_amd64.tar.gz"
  gzip -c "$raw" > "$archive"
  checksums="$fixture/checksums.txt"
  printf '%s  backhaul_linux_amd64.tar.gz\n' "$(sha256sum "$archive" | awk '{print $1}')" > "$checksums"
  DUP_ARCHIVE="$archive"; DUP_CHECKSUMS="$checksums"
  detect_arch_asset(){ printf 'backhaul_linux_amd64.tar.gz'; }
  backhaul_release_base(){ printf 'https://example.invalid/releases'; }
  curl(){
    local out='' arg url=''
    while (($#)); do arg="$1"; shift; case "$arg" in -o) out="$1"; shift ;; http*) url="$arg" ;; esac; done
    case "$url" in */checksums.txt) cp "$DUP_CHECKSUMS" "$out" ;; */backhaul_linux_amd64.tar.gz) cp "$DUP_ARCHIVE" "$out" ;; *) return 1 ;; esac
  }
  stage="$fixture/stage"
  download_backhaul v9.9.9 power0matin/Backhaul "$stage" >/dev/null 2>&1
)
assert_failure "release download rejects duplicate Backhaul members" duplicate_release_member_rejected


# Service action success paths remain intact after rollback hardening.
service_action_success() (
  local requested="$1" stopped=0
  SERVICE_NAME=backhaul-test.service; SERVICE_FILE="$safe_unit"; CONFIG_FILE=/root/backhaul/config.toml; ACTIVE_PROFILE=default
  service_fragment_path(){ printf '%s' "$safe_unit"; }
  service_uses_config_file(){ return 0; }
  service_is_active(){ [[ "$requested" == restart || "$requested" == stop ]]; }
  stop_service_verified(){ stopped=1; return 0; }
  verify_service_health(){ return 0; }
  systemctl(){ case "${1:-}" in daemon-reload|enable|start|restart) return 0 ;; is-enabled) return 0 ;; *) return 0 ;; esac; }
  service_action "$requested" >/dev/null
  [[ "$requested" != stop || "$stopped" == 1 ]]
)
assert_success "service start success path" service_action_success start
assert_success "service restart success path" service_action_success restart
assert_success "service stop success path" service_action_success stop

# Destructive/profile operations must consult effective unit ownership, not only /etc files.
for fn in create_profile_interactive clone_active_profile delete_profile_interactive create_backup upgrade_backhaul migrate_backhaul_source uninstall_backhaul; do
  body=$(declare -f "$fn")
  case "$fn" in
    create_profile_interactive|clone_active_profile|delete_profile_interactive)
      assert_contains "$fn checks effective FragmentPath" "$body" 'service_fragment_path'
      ;;
    *)
      assert_contains "$fn guards selected service ownership" "$body" 'guard_selected_service_mapping'
      ;;
  esac
done

# Main menu option 6 also dispatches start when service is inactive.
main_menu_start_route() (
  local marker='' counter_file="$tmp/main-menu-start-counter.$$"; printf '0\n' > "$counter_file"
  tty_read(){ local n; n=$(cat "$counter_file"); n=$((n+1)); printf '%s\n' "$n" > "$counter_file"; if ((n==1)); then printf '6'; else printf '0'; fi; }
  clear_screen(){ :; }; banner(){ :; }; pause_menu(){ :; }; ask_yn(){ return 0; }
  service_is_active(){ return 1; }
  service_action(){ marker="service:$1"; }
  interactive_menu >/dev/null
  [[ "$marker" == service:start ]]
)
assert_success "main menu start/stop chooses start when inactive" main_menu_start_route

printf 'PASS: %d v3.1.2 audit/regression checks\n' "$checks"

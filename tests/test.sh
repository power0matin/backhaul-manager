#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT_DIR}/backhaul-manager.sh"

tests=0
skipped=0

pass() {
  tests=$((tests + 1))
}

skip() {
  local label="$1"
  tests=$((tests + 1))
  skipped=$((skipped + 1))
  printf 'SKIP: %s\n' "$label" >&2
}

assert_success() {
  local label="$1"; shift
  if "$@"; then
    pass
  else
    printf 'FAIL: %s\n' "$label" >&2
    exit 1
  fi
}

assert_failure() {
  local label="$1"; shift
  if "$@"; then
    printf 'FAIL: %s (unexpected success)\n' "$label" >&2
    exit 1
  else
    pass
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass
  else
    printf 'FAIL: %s\n  expected: <%s>\n  actual:   <%s>\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

is_hex_token() {
  [[ "$1" =~ ^[0-9a-f]{48}$ ]]
}

assert_success "lowest valid port" validate_port 1
assert_success "highest valid port" validate_port 65535
assert_failure "port zero" validate_port 0
assert_failure "port above range" validate_port 65536
assert_failure "non-numeric port" validate_port 443/tcp
assert_failure "oversized numeric port" validate_port 999999999999999999999999

assert_success "valid release tag" validate_version v0.7.2
assert_success "valid release without v" validate_version 0.7.2
assert_success "valid SemVer prerelease and build" validate_version v0.8.0-rc.1+build.7
assert_success "latest release alias" validate_version latest
assert_failure "unsafe version" validate_version '../../latest'
assert_failure "oversized version component" validate_version v999999999999999999999.1.0
assert_failure "SemVer numeric prerelease leading zero" validate_version v0.8.0-rc.01
assert_eq "normalize release tag" v0.7.2 "$(normalize_version 0.7.2)"

assert_success "power0matin source accepted" validate_backhaul_source power0matin/Backhaul
assert_success "Musixal source accepted" validate_backhaul_source Musixal/Backhaul
assert_failure "unknown source rejected" validate_backhaul_source attacker/Backhaul
assert_failure "source path injection rejected" validate_backhaul_source '../../releases'
assert_eq "recommended source" power0matin/Backhaul "$DEFAULT_BACKHAUL_SOURCE"
assert_eq "power0matin release base" 'https://github.com/power0matin/Backhaul/releases' "$(backhaul_release_base power0matin/Backhaul)"
assert_eq "Musixal release base" 'https://github.com/Musixal/Backhaul/releases' "$(backhaul_release_base Musixal/Backhaul)"
assert_failure "release base rejects unknown source" backhaul_release_base attacker/Backhaul
assert_success "older release detected" version_is_older v0.7.2 v0.8.0
assert_failure "newer release is not a downgrade" version_is_older v0.8.0 v0.7.2
assert_failure "same release is not a downgrade" version_is_older v0.8.0 v0.8.0
assert_success "prerelease is older than stable" version_is_older v0.8.0-beta.1 v0.8.0
assert_failure "stable is newer than prerelease" version_is_older v0.8.0 v0.8.0-beta.1
assert_success "numeric prerelease identifier has lower precedence" version_is_older v0.8.0-alpha.1 v0.8.0-alpha.beta
assert_failure "build metadata does not change precedence" version_is_older v0.8.0+build.1 v0.8.0+build.2

source_choice_input=""
tty_read() { printf '%s' "$source_choice_input"; }
assert_eq "source menu defaults to recommended" power0matin/Backhaul "$(choose_backhaul_source 2>/dev/null)"
source_choice_input="2"
assert_eq "source menu option two selects upstream" Musixal/Backhaul "$(choose_backhaul_source 2>/dev/null)"

assert_success "IPv4 accepted" validate_host 192.0.2.10
assert_success "hostname accepted" validate_host iran.example.com
assert_success "IPv6 accepted" validate_host 2001:db8::1
assert_success "bracketed IPv6 accepted" validate_host '[2001:db8::1]'
assert_failure "host with whitespace rejected" validate_host 'bad host'
assert_failure "host with TOML injection rejected" validate_host 'host".example'
assert_eq "IPv4 endpoint" 192.0.2.10:8080 "$(format_host_port 192.0.2.10 8080)"
assert_eq "IPv6 endpoint" '[2001:db8::1]:8080' "$(format_host_port 2001:db8::1 8080)"
assert_eq "bracketed IPv6 endpoint" '[2001:db8::1]:8080' "$(format_host_port '[2001:db8::1]' 8080)"

assert_success "printable custom token accepted" validate_token 'safe token"with\\symbols'
assert_failure "control character in token rejected" validate_token $'unsafe\ttoken'

assert_success "port list parsed" parse_ports_csv '443, 8080,443' 9000
assert_eq "duplicate ports removed" '443 8080' "${PARSED_PORTS[*]}"
assert_failure "control/tunnel conflict rejected" parse_ports_csv '443,9000' 9000
assert_failure "invalid port list rejected" parse_ports_csv '443,70000' 9000

assert_success "simple advanced port rule" validate_port_rule 443
assert_success "port range rule" validate_port_rule 4000-4100
assert_success "port remap rule" validate_port_rule 4000=5000
assert_success "host remap rule" validate_port_rule 443=127.0.0.1:8443
assert_success "IPv6 remote remap rule" validate_port_rule '443=[2001:db8::1]:8443'
assert_failure "descending port range rejected" validate_port_rule 5000-4000
assert_failure "multiple mapping separators rejected" validate_port_rule 443=5000=6000
assert_failure "port-rule injection rejected" validate_port_rule '443;touch /tmp/x'
assert_success "advanced port list parsed" parse_port_rules_csv '443, 4000-4010,443=8443' 9000
assert_eq "advanced port list count" 3 "${#PORT_RULES[@]}"
assert_failure "advanced rule/control collision rejected" parse_port_rules_csv '8000-9000' 8080
assert_success "range contains listener" port_rule_matches_port '8000-9000' 8443
assert_failure "range excludes listener" port_rule_matches_port '8000-8100' 8443

assert_success "valid profile name" validate_profile_name iran-main
assert_failure "profile traversal rejected" validate_profile_name '../iran'
assert_failure "profile option injection rejected" validate_profile_name '-danger'
apply_profile_context edge-1
assert_eq "named profile config path" '/root/backhaul/profiles/edge-1/config.toml' "$CONFIG_FILE"
assert_eq "named profile service" 'backhaul-edge-1.service' "$SERVICE_NAME"
apply_profile_context default
assert_eq "default profile service" 'backhaul.service' "$SERVICE_NAME"
assert_eq "default service maps to profile" default "$(profile_from_service_name backhaul.service)"
assert_eq "named service maps to profile" edge-1 "$(profile_from_service_name backhaul-edge-1.service)"
assert_failure "unmanaged service name rejected" profile_from_service_name 'backhaul-edge-1.service;id'

assert_eq "low-resource auto tuning" safe "$(recommend_tuning_profile 1 512)"
assert_eq "general auto tuning" balanced "$(recommend_tuning_profile 2 2048)"
assert_eq "large-host auto tuning" throughput "$(recommend_tuning_profile 4 4096)"
assert_success "throughput tuning applied" apply_tuning_profile throughput
assert_eq "throughput connection pool" 16 "$TUNE_CONNECTION_POOL"
assert_eq "throughput max pool" 64 "$TUNE_MAX_POOL_SIZE"
reset_config_options
assert_eq "reset tuning profile" balanced "$TUNING_PROFILE"

assert_success "Musixal common server key" config_key_allowed Musixal/Backhaul server mux_con
assert_failure "Musixal rejects fork-only client key" config_key_allowed Musixal/Backhaul client max_pool_size
assert_success "power fork client key" config_key_allowed power0matin/Backhaul client max_pool_size
assert_success "power fork web binding key" config_key_allowed power0matin/Backhaul server web_bind_addr
assert_failure "unknown config key rejected" config_key_allowed power0matin/Backhaul server shell_command

assert_success "wsmux transport" validate_transport wsmux
assert_success "udp transport" validate_transport udp
assert_failure "unknown transport" validate_transport quic
assert_eq "UDP protocol" udp "$(transport_protocol udp)"
assert_eq "wsmux protocol" tcp "$(transport_protocol wsmux)"
assert_success "proxy protocol supported on wsmux" transport_supports_proxy_protocol wsmux
assert_failure "proxy protocol not offered on udp" transport_supports_proxy_protocol udp

assert_success "safe web username" validate_web_username backhaul.metrics
assert_failure "unsafe web username" validate_web_username 'bad user'
assert_success "safe web password" validate_web_password 'safe-password_123'
assert_failure "short web password" validate_web_password short
assert_success "backup accepts configured-profile payload" backup_payload_present 1 /definitely/missing/backhaul
assert_failure "backup rejects empty payload" backup_payload_present 0 /definitely/missing/backhaul

escaped=$(toml_escape $'a"b\\c\t')
assert_eq "TOML escaping" 'a\"b\\c\t' "$escaped"

token=$(generate_token)
assert_eq "generated token length" 48 "${#token}"
assert_success "generated token alphabet" is_hex_token "$token"

test_tmp=$(mktemp -d /tmp/backhaul-manager-tests.XXXXXX)
trap 'rm -rf -- "$test_tmp"' EXIT
power_config="$test_tmp/power.toml"
sanitized_config="$test_tmp/musixal.toml"
cat > "$power_config" <<'EOF'
[client]
remote_addr = "127.0.0.1:8080"
transport = "wsmux"
token = "test-token"
connection_pool = 8
max_pool_size = 32
web_port = 2061
web_bind_addr = "127.0.0.1"
web_username = "backhaul"
web_password = "safe-password_123"
tls_verify = true
EOF
assert_success "power config compatibility" check_config_compatibility_file power0matin/Backhaul "$power_config"
assert_failure "fork config rejected by Musixal schema" check_config_compatibility_file Musixal/Backhaul "$power_config"
assert_success "fork config safely sanitized" sanitize_config_for_source Musixal/Backhaul "$power_config" "$sanitized_config"
assert_success "sanitized config passes Musixal schema" check_config_compatibility_file Musixal/Backhaul "$sanitized_config"
assert_eq "sanitizer disables unsafe Musixal web monitor" 0 "$(config_value_from_file "$sanitized_config" web_port)"
assert_failure "sanitizer removes adaptive pool key" grep -q '^max_pool_size[[:space:]]*=' "$sanitized_config"
assert_failure "sanitizer removes fork web auth key" grep -q '^web_username[[:space:]]*=' "$sanitized_config"

# Exercise the actual config writers against the release-specific schema
# matrix, not only their individual validation helpers.
generated_dir="$test_tmp/generated"
mkdir -p "$generated_dir"
CONFIG_DIR="$generated_dir"
CONFIG_FILE="$generated_dir/config.toml"
INFO_FILE="$generated_dir/backhaul-info.txt"

reset_config_options
CONFIG_MODE="advanced"
apply_tuning_profile throughput
PORT_RULES=("443" "4000-4010" "8443=127.0.0.1:9443")
ADV_ACCEPT_UDP="true"
ADV_PROXY_PROTOCOL="true"
ADV_WEB_PORT=2060
ADV_WEB_USERNAME="backhaul"
ADV_WEB_PASSWORD="safe-password_123"
assert_success "generate advanced power server config" write_server_config 8080 tcp test-token '' '' power0matin/Backhaul
assert_success "generated power server schema" check_config_compatibility_file power0matin/Backhaul "$CONFIG_FILE"
assert_success "power server emits UDP queue limits" grep -q '^udp_queue_limit[[:space:]]*=[[:space:]]*4096$' "$CONFIG_FILE"
assert_success "power server emits loopback metrics bind" grep -q '^web_bind_addr[[:space:]]*=[[:space:]]*"127\.0\.0\.1"$' "$CONFIG_FILE"
assert_success "power server preserves advanced mapping" grep -q '^  "8443=127\.0\.0\.1:9443",$' "$CONFIG_FILE"

reset_config_options
CONFIG_MODE="standard"
PORT_RULES=("2052" "443")
assert_success "generate Musixal server config" write_server_config 8080 wsmux test-token '' '' Musixal/Backhaul
assert_success "generated Musixal server schema" check_config_compatibility_file Musixal/Backhaul "$CONFIG_FILE"
assert_failure "Musixal server omits fork keys" grep -qE '^(web_bind_addr|udp_queue_limit)[[:space:]]*=' "$CONFIG_FILE"

reset_config_options
CONFIG_MODE="advanced"
apply_tuning_profile balanced
ADV_TLS_VERIFY="false"
assert_success "generate advanced power TLS client config" write_client_config example.com:8080 wss test-token '' power0matin/Backhaul
assert_success "generated power TLS client schema" check_config_compatibility_file power0matin/Backhaul "$CONFIG_FILE"
assert_success "power client emits bounded adaptive pool" grep -q '^max_pool_size[[:space:]]*=[[:space:]]*32$' "$CONFIG_FILE"
assert_success "power TLS client writes verification policy" grep -q '^tls_verify[[:space:]]*=[[:space:]]*false$' "$CONFIG_FILE"

reset_config_options
CONFIG_MODE="standard"
assert_success "generate Musixal client config" write_client_config example.com:8080 wsmux test-token '' Musixal/Backhaul
assert_success "generated Musixal client schema" check_config_compatibility_file Musixal/Backhaul "$CONFIG_FILE"
assert_failure "Musixal client omits fork-only pool limit" grep -q '^max_pool_size[[:space:]]*=' "$CONFIG_FILE"

SERVICE_FILE="$generated_dir/backhaul-test.service"
SERVICE_NAME="backhaul-test.service"
assert_success "generate systemd unit in isolated test path" write_service_file power0matin/Backhaul
assert_success "unit waits for network-online" grep -q '^After=network-online.target$' "$SERVICE_FILE"
assert_success "unit uses on-failure restart policy" grep -q '^Restart=on-failure$' "$SERVICE_FILE"
assert_success "unit protects created files with UMask" grep -q '^UMask=0077$' "$SERVICE_FILE"
assert_success "unit points at selected config" grep -Fq "ExecStart=${BACKHAUL_BIN} -c ${CONFIG_FILE}" "$SERVICE_FILE"
assert_success "unit documents selected source" grep -q '^Documentation=https://github.com/power0matin/Backhaul$' "$SERVICE_FILE"
apply_profile_context default

archive_dir="$test_tmp/archive"
mkdir -p "$archive_dir"
printf 'safe\n' > "$archive_dir/data"
tar -czf "$test_tmp/safe.tar.gz" -C "$archive_dir" .
assert_success "safe archive structure" validate_backup_archive "$test_tmp/safe.tar.gz"
printf 'not a gzip archive\n' > "$test_tmp/corrupt.tar.gz"
assert_failure "corrupt archive rejected" validate_backup_archive "$test_tmp/corrupt.tar.gz"
tar -czf "$test_tmp/traversal.tar.gz" --transform='s|^\./|../|' -C "$archive_dir" .
assert_failure "archive traversal rejected" validate_backup_archive "$test_tmp/traversal.tar.gz"
if ln -s data "$archive_dir/link" 2>/dev/null && [[ -L "$archive_dir/link" ]]; then
  tar -czf "$test_tmp/symlink.tar.gz" -C "$archive_dir" .
  assert_failure "archive symlink rejected" validate_backup_archive "$test_tmp/symlink.tar.gz"
else
  rm -f -- "$archive_dir/link"
  skip "archive symlink rejection (host filesystem cannot create a real symlink)"
fi

assert_success "valid SSH migration target" validate_ssh_target root@example.com
assert_success "valid IPv6 SSH migration target" validate_ssh_target 'root@[2001:db8::1]'
assert_failure "SSH option injection rejected" validate_ssh_target '-oProxyCommand=bad'
assert_failure "SSH shell injection rejected" validate_ssh_target 'root@example.com;id'

assert_eq "manager candidate version" "$MANAGER_VERSION" "$(manager_candidate_version "${ROOT_DIR}/backhaul-manager.sh")"

stdin_version=$(bash -s -- --version < "${ROOT_DIR}/backhaul-manager.sh")
assert_eq "stdin/curl-pipe execution" "Backhaul Manager ${MANAGER_VERSION}" "$stdin_version"

process_substitution_version=$(bash <(cat "${ROOT_DIR}/backhaul-manager.sh") --version)
assert_eq "process-substitution execution" "Backhaul Manager ${MANAGER_VERSION}" "$process_substitution_version"

if (( skipped > 0 )); then
  printf 'PASS: %d helper checks (%d skipped)\n' "$tests" "$skipped"
else
  printf 'PASS: %d helper tests\n' "$tests"
fi

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${ROOT_DIR}/backhaul-manager.sh"

tests=0

pass() {
  tests=$((tests + 1))
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
assert_success "latest release alias" validate_version latest
assert_failure "unsafe version" validate_version '../../latest'
assert_eq "normalize release tag" v0.7.2 "$(normalize_version 0.7.2)"

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

assert_success "wsmux transport" validate_transport wsmux
assert_success "udp transport" validate_transport udp
assert_failure "unknown transport" validate_transport quic
assert_eq "UDP protocol" udp "$(transport_protocol udp)"
assert_eq "wsmux protocol" tcp "$(transport_protocol wsmux)"

escaped=$(toml_escape $'a"b\\c\t')
assert_eq "TOML escaping" 'a\"b\\c\t' "$escaped"

token=$(generate_token)
assert_eq "generated token length" 48 "${#token}"
assert_success "generated token alphabet" is_hex_token "$token"

printf 'PASS: %d helper tests\n' "$tests"

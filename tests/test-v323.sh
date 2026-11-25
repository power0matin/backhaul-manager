#!/usr/bin/env bash
# shellcheck disable=SC2317
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT_DIR}/backhaul-manager.sh"

checks=0
pass() { checks=$((checks + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_success() { local label="$1"; shift; if "$@"; then pass; else fail "$label"; fi; }
assert_failure() { local label="$1"; shift; if "$@"; then fail "$label (unexpected success)"; else pass; fi; }
assert_eq() { local label="$1" expected="$2" actual="$3"; [[ "$expected" == "$actual" ]] || fail "$label: expected <$expected>, got <$actual>"; pass; }

tmp=$(mktemp -d /tmp/backhaul-manager-v323-tests.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

assert_eq "Manager version is bumped for the server health fix" 3.2.3 "$MANAGER_VERSION"

server_handshake_is_healthy() (
  local log="$1"
  journalctl() { printf '%s\n' "$log"; }
  server_control_channel_healthy backhaul.service 4242
)
server_handshake_is_not_healthy() (
  local log="$1"
  journalctl() { printf '%s\n' "$log"; }
  ! server_control_channel_healthy backhaul.service 4242
)
assert_success "server without a client has no connected control channel" server_handshake_is_not_healthy "server started successfully, listening on address: [::]:8005"
assert_success "TCPMux authenticated control channel is recognized" server_handshake_is_healthy "control channel successfully established."
assert_success "WebSocket authenticated control channel is recognized" server_handshake_is_healthy "control channel established successfully"
assert_success "closed server control channel is no longer healthy" server_handshake_is_not_healthy $'control channel successfully established.\ncontrol channel has been closed by the client'
assert_success "server restart clears the previous connected state" server_handshake_is_not_healthy $'control channel established successfully\nrestarting server...'
assert_success "a new handshake restores connected state after restart" server_handshake_is_healthy $'restarting server...\ncontrol channel established successfully'

server_config="$tmp/server.toml"
cat > "$server_config" <<'EOF_CONFIG'
[server]
bind_addr = "0.0.0.0:8005"
transport = "tcpmux"
ports = ["8080"]
EOF_CONFIG

probe_server_health() (
  local log="$1" forward_ready="$2" calls_file="$3" config_file="$4"
  service_is_active_name() { [[ "$1" == "backhaul.service" ]]; }
  service_main_pid() { [[ "$1" == "backhaul.service" ]] && printf '4242'; }
  journalctl() { printf '%s\n' "$log"; }
  control_protocol() { printf 'tcp'; }
  check_listening_port_for_pid() {
    printf '%s/%s\n' "$1" "$2" >> "$calls_file"
    if [[ "$1" == "8005" && "$2" == "tcp" && "$3" == "4242" ]]; then return 0; fi
    [[ "$1" == "8080" && "$2" == "tcp" && "$3" == "4242" && "$forward_ready" == "yes" ]]
  }
  service_health_probe backhaul.service "$config_file" >/dev/null 2>&1
)

calls="$tmp/listener-calls"
: > "$calls"
assert_success "fresh server passes health without forwarding listeners before client pairing" \
  probe_server_health "server started successfully, listening on address: [::]:8005" no "$calls" "$server_config"
assert_eq "fresh server health checks only its control listener" "8005/tcp" "$(cat "$calls")"

: > "$calls"
assert_failure "connected server still rejects a missing forwarding listener" \
  probe_server_health "control channel successfully established." no "$calls" "$server_config"
assert_eq "connected server checks the configured forwarding listener" $'8005/tcp\n8080/tcp' "$(cat "$calls")"

: > "$calls"
assert_success "connected server passes when its forwarding listener belongs to Backhaul" \
  probe_server_health "control channel successfully established." yes "$calls" "$server_config"
assert_eq "connected server validates control and forwarding listeners" $'8005/tcp\n8080/tcp' "$(cat "$calls")"

: > "$calls"
assert_success "disconnected server returns to waiting-for-client health state" \
  probe_server_health $'control channel successfully established.\ncontrol channel has been closed by the client\nrestarting server...' no "$calls" "$server_config"
assert_eq "disconnected server checks only its control listener" "8005/tcp" "$(cat "$calls")"

printf 'PASS: %d server health regression checks\n' "$checks"

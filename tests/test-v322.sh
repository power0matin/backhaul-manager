#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT_DIR}/backhaul-manager.sh"

checks=0
pass() { checks=$((checks + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_success() { local label="$1"; shift; if "$@"; then pass; else fail "$label"; fi; }
assert_failure() { local label="$1"; shift; if "$@"; then fail "$label (unexpected success)"; else pass; fi; }

tmp=$(mktemp -d /tmp/backhaul-manager-v322-tests.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

make_socket_fd() {
  local proc_root="$1" pid="$2" inode="$3" fd="${4:-8}"
  mkdir -p "${proc_root}/${pid}/fd"
  ln -s "socket:[${inode}]" "${proc_root}/${pid}/fd/${fd}"
}

# The process must own the exact socket inode reported by ss.
proc_root="${tmp}/proc-match"
make_socket_fd "$proc_root" 4242 98765
assert_success "process owns matching socket inode" process_owns_socket_inode 4242 98765 "$proc_root"
assert_failure "process does not own a different inode" process_owns_socket_inode 4242 98766 "$proc_root"
assert_failure "invalid PID is rejected" process_owns_socket_inode 0 98765 "$proc_root"
assert_failure "invalid inode is rejected" process_owns_socket_inode 4242 invalid "$proc_root"

# ss process metadata remains the fast path when it identifies the exact PID.
check_listener_uses_ss_pid_metadata() (
  ss() {
    [[ "$*" == *"-ltnpe"* && "$*" == *"sport = :8080"* ]] || return 90
    printf '%s\n' 'LISTEN 0 4096 *:8080 *:* users:(("backhaul",pid=4242,fd=8)) ino:98765'
  }
  check_listening_port_for_pid 8080 tcp 4242
)
assert_success "TCP listener accepts exact ss PID metadata" check_listener_uses_ss_pid_metadata

# If ss omits process metadata, the socket inode must match /proc/<pid>/fd.
check_listener_uses_tcp_inode_fallback() (
  local fake_proc="${tmp}/proc-tcp"
  make_socket_fd "$fake_proc" 4242 98765
  ss() {
    [[ "$*" == *"-ltnpe"* && "$*" == *"sport = :8080"* ]] || return 90
    printf '%s\n' 'LISTEN 0 4096 *:8080 *:* ino:98765 sk:abcdef'
  }
  check_listening_port_for_pid 8080 tcp 4242 "$fake_proc"
)
assert_success "TCP listener falls back to matching socket inode" check_listener_uses_tcp_inode_fallback

check_listener_uses_udp_inode_fallback() (
  local fake_proc="${tmp}/proc-udp"
  make_socket_fd "$fake_proc" 5252 12345
  ss() {
    [[ "$*" == *"-lunpe"* && "$*" == *"sport = :5353"* ]] || return 90
    printf '%s\n' 'UNCONN 0 0 *:5353 *:* ino:12345 sk:fedcba'
  }
  check_listening_port_for_pid 5353 udp 5252 "$fake_proc"
)
assert_success "UDP listener falls back to matching socket inode" check_listener_uses_udp_inode_fallback

check_listener_rejects_wrong_inode_owner() (
  local fake_proc="${tmp}/proc-wrong"
  make_socket_fd "$fake_proc" 4242 11111
  ss() {
    [[ "$*" == *"sport = :8080"* ]] || return 90
    printf '%s\n' 'LISTEN 0 4096 *:8080 *:* ino:22222 sk:abcdef'
  }
  check_listening_port_for_pid 8080 tcp 4242 "$fake_proc" >/dev/null 2>&1 && return 1
  return 0
)
assert_success "listener rejects an inode owned by another process" check_listener_rejects_wrong_inode_owner

check_listener_rejects_pid_prefix_collision() (
  ss() {
    printf '%s\n' 'LISTEN 0 4096 *:8080 *:* users:(("other",pid=42420,fd=8))'
  }
  check_listening_port_for_pid 8080 tcp 4242 >/dev/null 2>&1 && return 1
  return 0
)
assert_success "listener rejects PID prefix collisions" check_listener_rejects_pid_prefix_collision

check_listener_rejects_empty_or_failed_ss() (
  ss() { return 0; }
  check_listening_port_for_pid 8080 tcp 4242 >/dev/null 2>&1 && return 1
  ss() { return 1; }
  check_listening_port_for_pid 8080 tcp 4242 >/dev/null 2>&1 && return 1
  return 0
)
assert_success "listener rejects empty and failed ss output" check_listener_rejects_empty_or_failed_ss

check_listener_rejects_invalid_port_and_pid() (
  ss() { return 90; }
  check_listening_port_for_pid 0 tcp 4242 >/dev/null 2>&1 && return 1
  check_listening_port_for_pid 65536 tcp 4242 >/dev/null 2>&1 && return 1
  check_listening_port_for_pid 8080 tcp 0 >/dev/null 2>&1 && return 1
  return 0
)
assert_success "listener rejects invalid port and PID values" check_listener_rejects_invalid_port_and_pid

printf 'PASS: %s socket ownership regression checks\n' "$checks"

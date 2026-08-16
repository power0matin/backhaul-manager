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

tmp=$(mktemp -d /tmp/backhaul-manager-v311-tests.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

# Read-only operations must remain lock-free even when --profile precedes them.
assert_failure "profile status is lock-free" operation_requires_lock --profile edge-1 --status
assert_failure "profile diagnostics are lock-free" operation_requires_lock --profile edge-1 --diagnose
assert_failure "profile live logs are lock-free" operation_requires_lock --profile edge-1 --follow-logs
assert_success "profile restart still requires lock" operation_requires_lock --profile edge-1 --restart

# The recommended repository is only a pristine-install default, never provenance.
existing_install_source_is_unknown() (
  read_saved_backhaul_source() { return 1; }
  installation_footprint_exists() { return 0; }
  [[ "$(current_backhaul_source)" == "$UNKNOWN_BACKHAUL_SOURCE" ]]
)
pristine_install_uses_recommendation() (
  read_saved_backhaul_source() { return 1; }
  installation_footprint_exists() { return 1; }
  [[ "$(current_backhaul_source)" == "$DEFAULT_BACKHAUL_SOURCE" ]]
)
assert_success "existing footprint never inherits recommended source" existing_install_source_is_unknown
assert_success "pristine install keeps recommended source" pristine_install_uses_recommendation

# Persisted provenance is bound to the exact managed binary hash; legacy v3.1.0
# repo-only state is readable for migration but is not trusted as verified state.
state_binary="$tmp/state-binary"
state_file="$tmp/backhaul-source"
printf '#!/usr/bin/env bash\nexit 0\n' > "$state_binary"; chmod +x "$state_binary"
state_hash=$(sha256sum "$state_binary" | awk '{print $1}')
printf 'source=Musixal/Backhaul\nsha256=%s\n' "$state_hash" > "$state_file"
assert_eq "hash-bound source state accepted" Musixal/Backhaul "$(source_state_matches_binary "$state_file" "$state_binary")"
printf '# tamper\n' >> "$state_binary"
assert_failure "source state rejected after binary replacement" source_state_matches_binary "$state_file" "$state_binary"
printf 'Musixal/Backhaul\n' > "$state_file"
assert_eq "legacy repo-only source remains recoverable for re-verification" Musixal/Backhaul "$(source_repo_from_state_file "$state_file")"
assert_failure "legacy repo-only source is not trusted without hash" source_state_matches_binary "$state_file" "$state_binary"

# Exact live-systemd parsing must recognize a legacy executable while preserving
# the config association independently from managed ownership.
legacy_exec_path_from_systemd() (
  systemctl() {
    if [[ "${1:-}" == show ]]; then
      printf '{ path=/root/backhaul/backhaul ; argv[]=/root/backhaul/backhaul -c /root/backhaul/config.toml ; }\n'
      return 0
    fi
    return 1
  }
  [[ "$(service_exec_binary_path backhaul.service /missing/unit)" == /root/backhaul/backhaul ]]
)
legacy_config_association_from_systemd() (
  systemctl() {
    if [[ "${1:-}" == show ]]; then
      printf '{ path=/root/backhaul/backhaul ; argv[]=/root/backhaul/backhaul -c /root/backhaul/config.toml ; }\n'
      return 0
    fi
    return 1
  }
  service_references_config_file backhaul.service /missing/unit /root/backhaul/config.toml \
    && ! service_uses_config_file backhaul.service /missing/unit /root/backhaul/config.toml
)
assert_success "effective ExecStart exposes legacy binary path" legacy_exec_path_from_systemd
assert_success "legacy service owns config but is not managed ownership" legacy_config_association_from_systemd

# Static legacy discovery must not require /opt/backhaul/backhaul ownership.
legacy_cfg="$tmp/config-2087.toml"
legacy_units="$tmp/units"
mkdir -p "$legacy_units"
printf '[server]\ntransport = "wsmux"\nbind_addr = "0.0.0.0:2087"\n' > "$legacy_cfg"
cat > "$legacy_units/backhaul-2087.service" <<EOF_UNIT
[Service]
ExecStart=/root/backhaul/backhaul -c $legacy_cfg
EOF_UNIT
cat > "$legacy_units/not-this-one.service" <<EOF_UNIT
[Service]
ExecStart=/root/backhaul/backhaul -c ${legacy_cfg}.old
EOF_UNIT
assert_eq "legacy service discovery accepts non-managed executable" backhaul-2087.service "$(find_service_for_config_file "$legacy_cfg" "$legacy_units")"

# Release checksum parsing is exact, duplicate-safe and supports sha256sum '*file'.
checksums="$tmp/checksums.txt"
hash_a='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
hash_b='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
printf '%s  backhaul_linux_amd64.tar.gz\n%s *backhaul_linux_arm64.tar.gz\n' "$hash_a" "$hash_b" > "$checksums"
assert_eq "exact checksum entry" "$hash_a" "$(release_checksum_for_asset "$checksums" backhaul_linux_amd64.tar.gz)"
assert_eq "star checksum entry" "$hash_b" "$(release_checksum_for_asset "$checksums" backhaul_linux_arm64.tar.gz)"
printf '%s  backhaul_linux_amd64.tar.gz\n' "$hash_a" >> "$checksums"
assert_failure "duplicate checksum entry is rejected" release_checksum_for_asset "$checksums" backhaul_linux_amd64.tar.gz

# Byte equality, not version/source labels alone, decides whether an install is current.
installed="$tmp/installed"
candidate="$tmp/candidate"
printf 'same\n' > "$installed"; chmod +x "$installed"; cp "$installed" "$candidate"
assert_success "same release bytes are current" release_candidate_matches_installation "$installed" "$candidate" v1.2.3 v1.2.3 Musixal/Backhaul Musixal/Backhaul
printf 'tampered\n' > "$installed"; chmod +x "$installed"
assert_failure "same version with different bytes requires repair" release_candidate_matches_installation "$installed" "$candidate" v1.2.3 v1.2.3 Musixal/Backhaul Musixal/Backhaul

# Checksum verification in download_backhaul must fail closed before extraction.
download_fixture_test() (
  local fixture="$tmp/download-fixture" archive fixture_checksums stage
  mkdir -p "$fixture/pkg"
  cat > "$fixture/pkg/backhaul" <<'EOF_BIN'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && { printf 'v9.9.9\n'; exit 0; }
exit 0
EOF_BIN
  chmod +x "$fixture/pkg/backhaul"
  archive="$fixture/backhaul_linux_amd64.tar.gz"
  tar -czf "$archive" -C "$fixture/pkg" backhaul
  FIXTURE_ARCHIVE="$archive"
  fixture_checksums="$fixture/checksums.txt"
  FIXTURE_CHECKSUMS="$fixture_checksums"
  printf '%s  backhaul_linux_amd64.tar.gz\n' "$(sha256sum "$FIXTURE_ARCHIVE" | awk '{print $1}')" > "$FIXTURE_CHECKSUMS"
  stage="$fixture/staged"
  detect_arch_asset() { printf 'backhaul_linux_amd64.tar.gz'; }
  backhaul_release_base() { printf 'https://example.invalid/releases'; }
  # Staged downloads must not prepare or mutate production installation paths.
  # Returning failure here makes the regression deterministic even when tests run as root.
  ensure_directories() { return 99; }
  curl() {
    local out="" arg url=""
    while (($#)); do
      arg="$1"; shift
      case "$arg" in
        -o) out="$1"; shift ;;
        http*) url="$arg" ;;
      esac
    done
    [[ -n "$out" && -n "$url" ]] || return 1
    case "$url" in
      */checksums.txt) cp "$FIXTURE_CHECKSUMS" "$out" ;;
      */backhaul_linux_amd64.tar.gz) cp "$FIXTURE_ARCHIVE" "$out" ;;
      *) return 1 ;;
    esac
  }
  download_backhaul v9.9.9 Musixal/Backhaul "$stage" >/dev/null
  [[ -x "$stage" && "$($stage -v)" == v9.9.9 ]] || return 1
  printf 'corruption' >> "$FIXTURE_ARCHIVE"
  if download_backhaul v9.9.9 Musixal/Backhaul "$fixture/should-not-stage" >/dev/null 2>&1; then
    return 1
  fi
  [[ ! -e "$fixture/should-not-stage" ]]
)
assert_success "release download verifies checksum before execution" download_fixture_test

# Exact provenance detection succeeds only for one matching supported source.
unique_source_detection() (
  backhaul_binary_version() { printf 'v0.7.2'; }
  binary_matches_release_source() { [[ "$2" == "$MUSIXAL_BACKHAUL_REPO" ]]; }
  [[ "$(detect_backhaul_source_for_binary /tmp/fake)" == "$MUSIXAL_BACKHAUL_REPO" ]]
)
ambiguous_source_detection() (
  backhaul_binary_version() { printf 'v0.7.2'; }
  binary_matches_release_source() { return 0; }
  detect_backhaul_source_for_binary /tmp/fake >/dev/null
)
assert_success "unique binary provenance is detected" unique_source_detection
assert_failure "ambiguous binary provenance is not guessed" ambiguous_source_detection

# Rollback must restore the *absence* of a pre-existing managed binary. This is
# essential when converting /root/backhaul/backhaul into /opt/backhaul/backhaul.
rollback_restores_missing_managed_binary() (
  local saw_binary_restore=0
  restore_file() {
    local target="$1" snapshot="$2"
    if [[ "$target" == "$BACKHAUL_BIN" && -z "$snapshot" ]]; then saw_binary_restore=1; fi
    return 0
  }
  systemctl() { return 0; }
  disable_service_verified() { return 0; }
  stop_service_verified() { return 0; }
  verify_service_health() { return 0; }
  rollback_install cfg-snapshot svc-snapshot "" no no source-snapshot >/dev/null
  (( saw_binary_restore == 1 ))
)
assert_success "rollback removes newly-created managed binary when none existed" rollback_restores_missing_managed_binary

# Legacy migration is dispatched before the managed-installation guard, which
# is the regression for /root/backhaul/backhaul + /root/backhaul/config.toml.
legacy_migration_dispatch() (
  [[ ! -x "$BACKHAUL_BIN" ]] || return 0
  selected_legacy_binary_path() { printf '/root/backhaul/backhaul'; }
  migrate_selected_legacy_installation() {
    [[ "$1" == power0matin/Backhaul && "$2" == latest && "$3" == no && "$4" == no ]]
  }
  migrate_backhaul_source power0matin/Backhaul latest no no
)
assert_success "migration dispatches legacy installation before managed guard" legacy_migration_dispatch

# Ctrl+C/130 from journalctl must return to the Manager instead of terminating it.
follow_logs_interrupt_is_local() (
  profile_service_references_config_file() { return 0; }
  journalctl() { return 130; }
  follow_logs >/dev/null
  trap -p INT | grep -q 'on_interrupt'
)
assert_success "live-log interrupt returns to Manager" follow_logs_interrupt_is_local

# Manifest parsing rejects ambiguity instead of silently choosing the first key.
manifest="$tmp/MANIFEST"
printf 'schema=2\nsource=Musixal/Backhaul\n' > "$manifest"
assert_eq "single manifest key" 2 "$(manifest_value "$manifest" schema)"
printf 'schema=2\n' >> "$manifest"
assert_failure "duplicate manifest key rejected" manifest_value "$manifest" schema

printf 'PASS: %d v3.1.1 regression checks\n' "$checks"

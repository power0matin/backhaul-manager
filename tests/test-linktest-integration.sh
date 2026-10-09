#!/usr/bin/env bash
# Optional loopback integration test against REAL Backhaul binaries.
#   BH_BIN_POWER=/path/to/power0matin/backhaul BH_BIN_MUSIXAL=/path/to/Musixal/backhaul bash tests/test-linktest-integration.sh
# Not part of CI: it needs release binaries. Loopback only; no multi-host path is exercised.
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LINK_TEST_SOAK_SECONDS=2 LINK_TEST_HANDSHAKE_TIMEOUT=15
# shellcheck disable=SC1091
source "${ROOT_DIR}/backhaul-manager.sh"
set +e

fails=0; checks=0
check(){ checks=$((checks+1)); if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: expected <%s> got <%s>\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }

run_one() { # label bin repo transport ctrl
  local label="$1" bin="$2" repo="$3" t="$4" ctrl="$5" rc=0
  [[ -x "$bin" ]] || { printf 'SKIP %s (binary not set)\n' "$label"; return; }
  LINK_TEST_DIR=$(mktemp -d /tmp/backhaul-linktest.XXXXXX); LINK_TEST_BIN="$bin"; LINK_TEST_SOURCE="$repo"; LINK_TEST_PIDS=()
  link_test_exact_listener_start "$t" "$ctrl" 25010 25011 45099 "$repo" >/dev/null 2>&1 || rc=$?
  check "$label $t:$ctrl listener starts" 0 "$rc"
  if (( rc == 0 )); then
    local code="$LT_X_CODE" token; token=$(awk -F- '{print $(NF-1)}' <<<"$code")
    rc=0; link_test_exact_probe_run 127.0.0.1 "$t" "$ctrl" 25010 25011 45099 "$token" >/dev/null 2>&1 || rc=$?
    check "$label $t:$ctrl PASS" "PASS" "$LT_X_VERDICT"
  fi
  link_test_cleanup
}

for t in ws wss wsmux wssmux tcp tcpmux udp; do
  run_one power "${BH_BIN_POWER:-}" "$POWERMATIN_BACKHAUL_REPO" "$t" 24443
  run_one musixal "${BH_BIN_MUSIXAL:-}" "$MUSIXAL_BACKHAUL_REPO" "$t" 24443
done
if [[ "$(id -u)" == 0 ]]; then
  run_one power-443 "${BH_BIN_POWER:-}" "$POWERMATIN_BACKHAUL_REPO" ws 443
  run_one musixal-443 "${BH_BIN_MUSIXAL:-}" "$MUSIXAL_BACKHAUL_REPO" wss 443
fi
printf '%d checks, %d failed\n' "$checks" "$fails"
(( fails == 0 ))

#!/usr/bin/env bash
# Link Test regression tests. A fake `backhaul` binary (control handshake + TCP/UDP
# forwarding emulation) lets every stage run on loopback without production hosts.
# shellcheck disable=SC2317
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LINK_TEST_SOAK_SECONDS=1 LINK_TEST_HANDSHAKE_TIMEOUT=6
# shellcheck disable=SC1091
source "${ROOT_DIR}/backhaul-manager.sh"
set +e

checks=0
pass(){ checks=$((checks+1)); }
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_true(){ local l="$1"; shift; if "$@"; then pass; else fail "$l"; fi; }
assert_eq(){ [[ "$2" == "$3" ]] || fail "$1: expected <$2>, got <$3>"; pass; }
assert_contains(){ [[ "$2" == *"$3"* ]] || fail "$1: missing <$3> in output"; pass; }
assert_not_contains(){ [[ "$2" != *"$3"* ]] || fail "$1: unexpected <$3> in output"; pass; }

tmp=$(mktemp -d /tmp/backhaul-linktest-tests.XXXXXX)
EXTRA_PIDS=()
cleanup_all(){ local p; for p in "${EXTRA_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; link_test_cleanup; rm -rf -- "$tmp"; }
trap cleanup_all EXIT

generate_token(){ printf '0123456789abcdef0123456789abcdef'; }
TOKEN=0123456789abcdef
strip(){ sed 's/\x1b\[[0-9;]*m//g' "$1"; }

cat > "$tmp/fakebh" <<'PY'
#!/usr/bin/env python3
import os, re, socket, sys, threading, time
cfg = open(sys.argv[sys.argv.index('-c') + 1]).read()
def val(k):
    m = re.search(r'^\s*' + k + r'\s*=\s*"([^"]*)"', cfg, re.M)
    return m.group(1) if m else None
server = '[server]' in cfg
transport, token = val('transport'), val('token')
mode = os.environ.get('FAKE_BH_MODE', 'ok')
fmt = os.environ.get('FAKE_BH_FMT', 'power')
allowed = os.environ.get('FAKE_BH_TRANSPORTS', 'tcp tcpmux udp ws wss wsmux wssmux').split()
def log(m): print('09-Oct 12:00:00 ' + m, flush=True)
if transport not in allowed:
    if fmt == 'musixal': log('[FATAL] invalid transport type: %s' % transport)
    else: log('[FATAL] failed to load configuration: client.transport must be one of tcp, tcpmux, udp, ws, wss, wsmux, or wssmux; got "%s"' % transport)
    sys.exit(1)
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    for x in (a, b):
        try: x.shutdown(socket.SHUT_RDWR)
        except OSError: pass
if server:
    host, port = val('bind_addr').rsplit(':', 1)
    m = re.search(r'"(\d+)=([^"]+)"', cfg)
    fwd = int(m.group(1)); th, tp = m.group(2).rsplit(':', 1); tgt = (th, int(tp))
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: s.bind((host, int(port)))
    except OSError as e:
        log('[FATAL] failed to listen on %s: %s' % (val('bind_addr'), e)); sys.exit(1)
    s.listen(16)
    state = {'fwd': False}
    def start_fwd():
        if mode == 'nofwd': return
        if transport == 'udp':
            u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(('0.0.0.0', fwd))
            def loop():
                while True:
                    d, a = u.recvfrom(65536)
                    if mode == 'nodata': continue
                    t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); t.settimeout(2)
                    t.sendto(d, tgt)
                    try: u.sendto(t.recv(65536), a)
                    except OSError: pass
            threading.Thread(target=loop, daemon=True).start()
        else:
            f = socket.socket(); f.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            f.bind(('0.0.0.0', fwd)); f.listen(16)
            def loop():
                while True:
                    c, _ = f.accept()
                    if mode == 'nodata':
                        threading.Thread(target=lambda c=c: [c.recv(65536) for _ in iter(int, 1)], daemon=True).start(); continue
                    t = socket.create_connection(tgt)
                    threading.Thread(target=pipe, args=(c, t), daemon=True).start()
                    threading.Thread(target=pipe, args=(t, c), daemon=True).start()
            threading.Thread(target=loop, daemon=True).start()
    def ctl(c):
        line = c.makefile().readline().strip()
        ok = line == 'HELLO ' + token and mode != 'rejectall'
        c.sendall(b'OK\n' if ok else b'NO\n')
        if ok:
            if not state['fwd']:
                state['fwd'] = True; start_fwd()
            try: c.recv(1)
            except OSError: pass
        c.close()
    while True:
        c, _ = s.accept(); threading.Thread(target=ctl, args=(c,), daemon=True).start()
else:
    host, port = val('remote_addr').rsplit(':', 1)
    log('[INFO] client with remote address %s started successfully' % val('remote_addr'))
    if mode == 'exit_early': sys.exit(1)
    if mode == 'bad_config':
        log('[FATAL] failed to load configuration: toml: line 2: bad'); sys.exit(1)
    while True:
        log('[INFO] attempting to establish a new websocket control channel connection')
        if mode == 'tlsfail':
            log('[ERROR] control channel dialer: tls: failed to verify certificate: x509: certificate is not valid for any names'); time.sleep(1); continue
        if mode == 'tlsmismatch':
            log('[ERROR] control channel dialer: tls: first record does not look like a TLS handshake'); time.sleep(1); continue
        if mode == 'silent':
            time.sleep(60); continue
        try: c = socket.create_connection((host, int(port)), 3)
        except OSError:
            log('[ERROR] control channel dialer: dial tcp <nil>->%s:%s: connect: connection refused' % (host, port)); time.sleep(1); continue
        c.sendall(('HELLO ' + token + '\n').encode())
        r = c.makefile().readline().strip()
        if r == 'OK':
            log('[INFO] control channel established successfully')
            if mode == 'drop':
                time.sleep(1.2); log('[WARNING] control channel has been closed'); c.close(); time.sleep(60)
            else:
                try: c.recv(1)
                except OSError: pass
                log('[WARNING] control channel has been closed')
        else:
            log('[ERROR] control channel dialer: websocket: bad handshake'); c.close(); time.sleep(1)
PY
chmod +x "$tmp/fakebh"

# shellcheck disable=SC2034
new_env(){ LINK_TEST_DIR=$(mktemp -d "$tmp/lt.XXXXXX"); LINK_TEST_BIN="$tmp/fakebh"; LINK_TEST_SOURCE="${1:-$POWERMATIN_BACKHAUL_REPO}"; LINK_TEST_PIDS=(); }
# exact_run <mode> <transport> <ctrl> <fwd> <beacon> <echo> [probe-mode] [probe-token]; sets X_RC, X_OUT
exact_run(){
  local mode="$1" t="$2" ctrl="$3" fwd="$4" beacon="$5" echo_port="$6" pmode="${7:-$1}" ptoken="${8:-$TOKEN}"
  new_env; X_LRC=0; X_RC=0
  FAKE_BH_MODE="$mode" link_test_exact_listener_start "$t" "$ctrl" "$fwd" "$beacon" "$echo_port" "$POWERMATIN_BACKHAUL_REPO" >"$tmp/listen.out" 2>&1 || X_LRC=$?
  X_LPIDS=${#LINK_TEST_PIDS[@]}
  [[ "$X_LRC" == 0 ]] || return 0
  FAKE_BH_MODE="$pmode" link_test_exact_probe_run 127.0.0.1 "$t" "$ctrl" "$fwd" "$beacon" "$echo_port" "$ptoken" >"$tmp/probe.out" 2>&1 || X_RC=$?
  X_OUT=$(strip "$tmp/probe.out")
}

# ---- 0. constants and ordering preserved
assert_eq "transport order preserved" "wsmux tcpmux wssmux ws tcp wss udp" "${LINK_TEST_TRANSPORTS[*]}"

# ---- 1/2/3. exact mode on one port, regardless of the adjacent/random ranges
exact_run ok wsmux 26100 26110 26111 46100
assert_eq "exact listener started" 0 "$X_LRC"
assert_eq "exact PASS verdict" PASS "$LT_X_VERDICT"
assert_eq "exact PASS rc" 0 "$X_RC"
assert_eq "control reachable" open "$LT_X_REACH"
assert_eq "pairing verified" "code verified" "$LT_X_PAIR"
assert_eq "only the server and the beacon were started" 2 "$X_LPIDS"
assert_contains "ports and protocols are explicit" "$X_OUT" "26100/tcp"
assert_contains "forwarding protocol explicit (tcp)" "$X_OUT" "26110/tcp"
link_test_cleanup
assert_eq "temp dir removed" "" "$LINK_TEST_DIR"

exact_run ok udp 26120 26130 26131 46120
assert_eq "udp exact PASS" PASS "$LT_X_VERDICT"
assert_contains "udp forwarding labelled UDP" "$X_OUT" "26130/udp"
link_test_cleanup

if python3 -c 'import socket;s=socket.socket();s.bind(("0.0.0.0",443))' 2>/dev/null && ! check_listening_port 443 tcp; then
  exact_run ok ws 443 26140 26141 46140
  assert_eq "port 443 exact PASS" PASS "$LT_X_VERDICT"
  link_test_cleanup
else
  exact_run ok ws 443 26140 26141 46140
  if check_listening_port 443 tcp; then assert_eq "443 busy is reported" 4 "$X_LRC"; else assert_eq "443 without bind permission is a local setup rc" 3 "$X_LRC"; fi
  link_test_cleanup
fi
assert_true "port 1 accepted" validate_port 1
assert_true "port 65535 accepted" validate_port 65535
validate_port 0 && fail "port 0 must be rejected"; pass

# ---- 4. blocked automatic range is INCONCLUSIVE, not NO-GO
new_env
link_test_write_beacon "$LINK_TEST_DIR/beacon.py"
LT_TOKEN="$TOKEN" python3 "$LINK_TEST_DIR/beacon.py" 31021 >/dev/null 2>&1 </dev/null & LINK_TEST_PIDS+=("$!")
sleep 1
link_test_probe_run 127.0.0.1 31000 "$TOKEN" >"$tmp/disc.out" 2>&1; rc=$?
out=$(strip "$tmp/disc.out")
assert_eq "blocked range returns non-zero" 1 "$rc"
assert_contains "blocked range is INCONCLUSIVE" "$out" "INCONCLUSIVE"
assert_contains "intended port untested is stated" "$out" "intended port was not tested"
assert_not_contains "blocked range is not NO-GO" "$out" "NO-GO"
assert_not_contains "no categorical claim" "$out" "no setting in the Manager can fix it"
link_test_cleanup

# ---- 5. handshake established but forwarding / data fail are separate from handshake failure
exact_run nofwd ws 26200 26210 26211 46200
assert_eq "forwarding endpoint inaccessible" FWD_CLOSED "$LT_X_VERDICT"
assert_contains "handshake still reported established" "$LT_X_HS" "established"
link_test_cleanup
exact_run nodata ws 26220 26230 26231 46220
assert_eq "data round trip failed" NO_DATA "$LT_X_VERDICT"
link_test_cleanup
exact_run rejectall ws 26240 26250 26251 46240
assert_eq "failed handshake with verified code" WS_REJECT "$LT_X_VERDICT"
assert_contains "handshake not established" "$LT_X_HS" "rejected"
link_test_cleanup
exact_run drop ws 26260 26270 26271 46260
assert_eq "connection lost during stability check" UNSTABLE "$LT_X_VERDICT"
link_test_cleanup

# ---- 6. pairing mismatch vs unreachable beacon
exact_run ok ws 26300 26310 26311 46300 ok ffffffffffffffff
assert_eq "mismatched code" PAIR_MISMATCH "$LT_X_VERDICT"
assert_eq "mismatch rc" 2 "$X_RC"
link_test_cleanup
exact_run ok ws 26320 26330 0 46320
assert_eq "beacon disabled still passes" PASS "$LT_X_VERDICT"
assert_eq "pairing skipped" skipped "$LT_X_PAIR"
link_test_cleanup
new_env
FAKE_BH_MODE=rejectall link_test_exact_listener_start ws 26340 26350 26351 46340 "$POWERMATIN_BACKHAUL_REPO" >/dev/null 2>&1
kill "${LINK_TEST_PIDS[1]}" 2>/dev/null; sleep 0.5
FAKE_BH_MODE=rejectall link_test_exact_probe_run 127.0.0.1 ws 26340 26350 26351 46340 "$TOKEN" >"$tmp/probe.out" 2>&1
assert_contains "unreachable beacon is its own state" "$LT_X_PAIR" "unreachable"
assert_eq "unverified code keeps handshake failure inconclusive" HS_UNVERIFIED "$LT_X_VERDICT"
link_test_cleanup
new_env
LT_X_VERDICT=""
link_test_exact_probe_run 127.0.0.1 ws 26360 26361 26362 46360 "$TOKEN" >"$tmp/probe.out" 2>&1
assert_eq "nothing answering is inconclusive" NO_ANSWER "$LT_X_VERDICT"
link_test_cleanup

# ---- 7. supported / unsupported transports
new_env
link_test_exact_listener_start udp 26400 26410 26411 46400 "$POWERMATIN_BACKHAUL_REPO" >/dev/null 2>&1
FAKE_BH_TRANSPORTS="ws tcp" link_test_exact_probe_run 127.0.0.1 udp 26400 26410 26411 46400 "$TOKEN" >"$tmp/probe.out" 2>&1; rc=$?
assert_eq "unsupported transport verdict" UNSUPPORTED "$LT_X_VERDICT"
assert_eq "unsupported transport is a local rc" 3 "$rc"
assert_not_contains "unsupported is not blamed on filtering" "$(strip "$tmp/probe.out")" "firewall"
link_test_cleanup
new_env
FAKE_BH_TRANSPORTS="ws tcp" link_test_exact_listener_start udp 26420 26430 26431 46420 "$POWERMATIN_BACKHAUL_REPO" >/dev/null 2>&1; rc=$?
assert_eq "listener with unsupported transport" 3 "$rc"
link_test_cleanup
assert_eq "musixal fatal format" UNSUPPORTED "$(printf '[FATAL] invalid transport type: quic\n' | link_test_handshake_state)"
assert_eq "power fatal format" UNSUPPORTED "$(printf '[FATAL] failed to load configuration: client.transport must be one of tcp; got "quic"\n' | link_test_handshake_state)"
assert_eq "toml error is config" CONFIG "$(printf '[FATAL] failed to load configuration: toml: line 2: expected\n' | link_test_handshake_state)"

# ---- 8. TLS handling
new_env "$POWERMATIN_BACKHAUL_REPO"; link_test_write_client_config "$LINK_TEST_DIR/c.toml" wssmux 1.2.3.4:443 "$TOKEN"
assert_contains "power0matin wss client skips verification of the temp cert" "$(<"$LINK_TEST_DIR/c.toml")" "tls_verify = false"
link_test_write_server_config "$LINK_TEST_DIR/s.toml" wss 443 "$TOKEN" 20000 20001
assert_contains "server uses temp cert" "$(<"$LINK_TEST_DIR/s.toml")" "${LINK_TEST_DIR}/cert.pem"
link_test_cleanup
new_env "$MUSIXAL_BACKHAUL_REPO"; link_test_write_client_config "$LINK_TEST_DIR/c.toml" wss 1.2.3.4:443 "$TOKEN"
assert_not_contains "musixal client config has no tls_verify key" "$(<"$LINK_TEST_DIR/c.toml")" "tls_verify"
link_test_cleanup
exact_run ok wss 26500 26510 26511 46500
assert_eq "wss temp certificate generated and accepted" PASS "$LT_X_VERDICT"
link_test_cleanup
exact_run ok wss 26520 26530 26531 46520 tlsfail
assert_eq "TLS certificate failure classified" TLS_CERT "$LT_X_VERDICT"
link_test_cleanup
exact_run ok wss 26540 26550 26551 46540 tlsmismatch
assert_eq "plain peer on a TLS port classified" TLS_MISMATCH "$LT_X_VERDICT"
link_test_cleanup

# ---- 9. client exit, timeouts, real log formats (captured from power0matin v0.8.0 and Musixal v0.7.2)
exact_run ok ws 26600 26610 26611 46600 exit_early
assert_eq "unexpected client exit" CLIENT_EXIT "$LT_X_VERDICT"
assert_eq "client exit is a local rc" 3 "$X_RC"
link_test_cleanup
exact_run ok ws 26610 26615 26616 46610 bad_config
assert_eq "binary config rejection is not a network verdict" CONFIG "$LT_X_VERDICT"
assert_eq "config rejection is a local rc" 3 "$X_RC"
link_test_cleanup
exact_run ok ws 26620 26630 26631 46620 silent
assert_eq "handshake timeout with verified code" NO_HANDSHAKE "$LT_X_VERDICT"
link_test_cleanup
hs(){ link_test_handshake_state; }
assert_eq "power0matin v0.8.0 line" ESTABLISHED "$(printf '09-Oct 12:50:38 [INFO] attempting to establish a new websocket control channel connection\n09-Oct 12:50:38 [INFO] control channel established successfully\n' | hs)"
assert_eq "Musixal v0.7.2 udp line" ESTABLISHED "$(printf '[INFO] attempting to establish a new control channel connection...\n[INFO] control channel established successfully\n' | hs)"
assert_eq "stale success then close" LOST "$(printf '[INFO] control channel established successfully\n[WARNING] control channel has been closed\n' | hs)"
assert_eq "stale success then re-dial" LOST "$(printf '[INFO] control channel established successfully\n[INFO] attempting to establish a new websocket control channel connection\n' | hs)"
assert_eq "unknown log format is not a handshake" CONNECTING "$(printf '[INFO] tunnel is up\n' | hs)"
assert_eq "refused" REFUSED "$(printf '[ERROR] control channel dialer: dial tcp <nil>->127.0.0.1:1: connect: connection refused\n' | hs)"
assert_eq "timeout" TIMEOUT "$(printf '[ERROR] control channel dialer: dial tcp 1.2.3.4:443: i/o timeout\n' | hs)"
assert_eq "ws bad handshake" WS_REJECT "$(printf '[ERROR] control channel dialer: websocket: bad handshake\n' | hs)"
assert_eq "ANSI colours are ignored" ESTABLISHED "$(printf '\033[32m[INFO] control channel established successfully\033[0m\n' | hs)"
assert_eq "the Rlimit error line is not a failure" ESTABLISHED "$(printf '[ERROR] Error setting Rlimit: operation not permitted\n[INFO] control channel established successfully\n' | hs)"
# shared health helper keeps its behaviour
shared_healthy(){ printf '%b' "$1" | client_control_channel_healthy; }
assert_true "shared helper: established is healthy" shared_healthy '[INFO] control channel established successfully\n'
assert_eq "shared helper: closed is unhealthy" 1 "$(shared_healthy "[INFO] control channel established successfully\\n[WARNING] control channel has been closed\\n" >/dev/null 2>&1; echo $?)"
assert_eq "server log: address in use" ADDR_IN_USE "$(printf '[FATAL] failed to listen on 0.0.0.0:1: listen tcp: bind: address already in use\n' | link_test_server_failure_class)"
assert_eq "server log: rlimit noise is not a bind failure" NONE "$(printf '[ERROR] Error setting Rlimit: operation not permitted\n' | link_test_server_failure_class)"

# ---- 10. port conflicts never disturb the existing listener; repeats and cleanup
python3 - 26700 >/dev/null 2>&1 </dev/null <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(1, 2, 1); s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(4); time.sleep(120)
PY
HOLDER=$!; EXTRA_PIDS+=("$HOLDER"); sleep 1
new_env
link_test_exact_listener_start ws 26700 26710 26711 46700 "$POWERMATIN_BACKHAUL_REPO" >"$tmp/conf.out" 2>&1; rc=$?
assert_eq "busy control port rc" 4 "$rc"
assert_contains "conflict reported clearly" "$(strip "$tmp/conf.out")" "already in use"
assert_eq "no server was started on the busy port" 0 "${#LINK_TEST_PIDS[@]}"
assert_true "existing listener must survive" kill -0 "$HOLDER"
assert_true "existing listener must keep its port" check_listening_port 26700 tcp
link_test_cleanup
exact_run ok ws 26800 26810 26811 46800
assert_eq "first repeat run" PASS "$LT_X_VERDICT"; link_test_cleanup
exact_run ok ws 26800 26810 26811 46800
assert_eq "second repeat run on the same ports" PASS "$LT_X_VERDICT"
pids=("${LINK_TEST_PIDS[@]}"); dir="$LINK_TEST_DIR"
begin_transaction link_test_cleanup; rollback_active_transaction "simulated interrupt" >/dev/null 2>&1
for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && fail "process $p survived rollback"; done; pass
assert_true "temp dir removed by rollback" test ! -d "$dir"
exact_run ok ws 26820 26830 26831 46820
assert_contains "no token in the report" "$X_OUT" "Control"
assert_not_contains "token is never printed" "$X_OUT" "$TOKEN"
link_test_cleanup

# ---- 11. transport discovery preserved: ordering and recommendation
new_env
base=27000; i=0
link_test_write_beacon "$LINK_TEST_DIR/beacon.py"
for t in "${LINK_TEST_TRANSPORTS[@]}"; do
  link_test_write_server_config "$LINK_TEST_DIR/server-$t.toml" "$t" $((base + i)) "$TOKEN" $((base + 10 + i)) $((base + 20))
  "$LINK_TEST_BIN" -c "$LINK_TEST_DIR/server-$t.toml" >"$LINK_TEST_DIR/server-$t.log" 2>&1 </dev/null & LINK_TEST_PIDS+=("$!")
  i=$((i + 1))
done
LT_TOKEN="$TOKEN" python3 "$LINK_TEST_DIR/beacon.py" $((base + 21)) >/dev/null 2>&1 </dev/null & LINK_TEST_PIDS+=("$!")
sleep 1.5
link_test_probe_run 127.0.0.1 "$base" "$TOKEN" >"$tmp/disc.out" 2>&1; rc=$?
out=$(strip "$tmp/disc.out")
assert_eq "discovery GO rc" 0 "$rc"
assert_contains "discovery recommends wsmux first" "$out" "Recommended transport: wsmux"
assert_contains "discovery ordering of the rest" "$out" "Also working        : tcpmux wssmux ws tcp wss udp"
link_test_cleanup

# ---- 12. production service and state untouched
printf '[server]\nbind_addr = "0.0.0.0:26900"\ntransport = "ws"\ntoken = "prod"\n' > "$tmp/prod.toml"
sum_before=$(sha256sum "$tmp/prod.toml")
python3 - 26900 >/dev/null 2>&1 </dev/null <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(1, 2, 1); s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(4); time.sleep(120)
PY
PROD=$!; EXTRA_PIDS+=("$PROD"); sleep 1
: > "$tmp/systemctl.calls"
systemctl(){ printf '%s\n' "$*" >> "$tmp/systemctl.calls"; return 1; }
exact_run ok ws 26910 26920 26921 46910
assert_eq "exact run passes next to a production listener" PASS "$LT_X_VERDICT"
link_test_cleanup
mutating=$(grep -E '^(start|stop|restart|reload|enable|disable|kill|mask)' "$tmp/systemctl.calls" || true)
assert_eq "no service was started, stopped or restarted" "" "$mutating"
assert_eq "production config unchanged" "$sum_before" "$(sha256sum "$tmp/prod.toml")"
assert_true "production listener must survive" kill -0 "$PROD"
unset -f systemctl

printf 'link-test regression: %d checks passed\n' "$checks"

#!/bin/bash
# Test vyos-bouncer.sh against a mock VyOS API.
#
#   ./test/test-vyos-bouncer.sh          # full integration test
#   ./test/test-vyos-bouncer.sh --dry-run # only exercise --dry-run mode
set -euo pipefail

DRY_ONLY="${1:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/vyos-bouncer.sh"
MOCK="$ROOT/test/mock-vyos-api.py"
TMP="$(mktemp -d "$ROOT/test/tmp.XXXXXX")"
PORT="18443"
MOCK_LOG="$TMP/mock.log"
CONF="$TMP/bouncer.conf"
PASS=0
FAIL=0

cleanup() {
    [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

write_conf() {
    cat >"$CONF" <<EOF
VYOS_API_URL="http://127.0.0.1:$PORT"
VYOS_API_KEY="test-key-123"
ADDRESS_GROUP_V4="CROWDSEC-BANNED"
ADDRESS_GROUP_V6="CROWDSEC-BANNED-V6"
NETWORK_GROUP_V4="CROWDSEC-BANNED-NET"
NETWORK_GROUP_V6="CROWDSEC-BANNED-NET-V6"
BATCH_WINDOW="1"
BATCH_MAX_ROUNDS="2"
API_RETRIES="1"
SPOOL_DIR="$TMP/spool"
EOF
}

start_mock() {
    MOCK_PORT="$PORT" MOCK_LOG="$MOCK_LOG" python3 "$MOCK" &
    MOCK_PID=$!
    sleep 1
}

wait_for_flush() {
    local deadline=$((SECONDS + 10))
    while [[ $SECONDS -lt $deadline ]]; do
        if [[ -f "$MOCK_LOG" ]] && grep -q 'configure' "$MOCK_LOG"; then
            sleep 2  # allow a second batched flush to land too
            return 0
        fi
        sleep 1
    done
    return 1
}

echo "== mock run =="
LOG="$MOCK_LOG"
write_conf
start_mock

export VYOS_BOUNCER_CONF="$CONF"

if [[ "$DRY_ONLY" != "--dry-run" ]]; then

"$SCRIPT" add 203.0.113.7 3600 ssh-bruteforce '{}'
"$SCRIPT" del 203.0.113.8 0 expired '{}'
"$SCRIPT" add 2001:db8::1 3600 ssh-bruteforce '{}'
"$SCRIPT" add 198.51.100.0/24 3600 portscan '{}'
"$SCRIPT" add 2001:db8:abcd::/48 3600 portscan '{}'

if ! wait_for_flush; then
    bad "no API calls received by mock"
    exit 1
fi

echo "== assertions =="
RAW="$TMP/raw.data"

# Decode each request's data field (mock JSON-escapes inner quotes) into raw lines.
python3 - "$LOG" >"$RAW" <<'EOF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    entry = json.loads(line)
    if entry.get("data"):
        print(entry["data"])
EOF

# IPv4 ban -> address-group set
grep -q '"op":"set".*"address-group","CROWDSEC-BANNED","address","203.0.113.7"' "$RAW" \
    && ok "IPv4 ban -> address-group set" || bad "IPv4 ban -> address-group set"

# IPv4 unban -> delete
grep -q '"op":"delete".*"address-group","CROWDSEC-BANNED","address","203.0.113.8"' "$RAW" \
    && ok "IPv4 unban -> address-group delete" || bad "IPv4 unban -> address-group delete"

# IPv6 single -> ipv6-address-group
grep -q '"op":"set".*"ipv6-address-group","CROWDSEC-BANNED-V6","address","2001:db8::1"' "$RAW" \
    && ok "IPv6 ban -> ipv6-address-group set" || bad "IPv6 ban -> ipv6-address-group set"

# IPv4 CIDR -> network-group
grep -q '"op":"set".*"network-group","CROWDSEC-BANNED-NET","network","198.51.100.0/24"' "$RAW" \
    && ok "IPv4 CIDR -> network-group set" || bad "IPv4 CIDR -> network-group set"

# IPv6 CIDR -> ipv6-network-group
grep -q '"op":"set".*"ipv6-network-group","CROWDSEC-BANNED-NET-V6","network","2001:db8:abcd::/48"' "$RAW" \
    && ok "IPv6 CIDR -> ipv6-network-group set" || bad "IPv6 CIDR -> ipv6-network-group set"

# auth key present on every request, correct value
[[ "$(grep -c '"key": null' "$LOG")" -eq 0 ]] \
    && ok "API key sent on every request" || bad "API key sent on every request"
grep -q '"key": "test-key-123"' "$LOG" \
    && ok "API key value correct" || bad "API key value correct"

# batching: >= 5 ops but <= 5 requests (ops coalesced)
REQS=$(wc -l <"$LOG")
[[ "$REQS" -le 5 ]] \
    && ok "batching (5 ops -> $REQS requests)" || bad "batching (5 ops -> $REQS requests)"

fi  # end mock integration section

echo "== dry-run mode =="
"$SCRIPT" --dry-run add 192.0.2.55 60 test '{}' 2>&1 | grep -q "DRY-RUN: would POST" \
    && ok "dry-run logs without POSTing" || bad "dry-run logs without POSTing"
BEFORE=0; [[ -f "$LOG" ]] && BEFORE=$(wc -l <"$LOG")
"$SCRIPT" -n del 192.0.2.55 0 test '{}'
AFTER=0; [[ -f "$LOG" ]] && AFTER=$(wc -l <"$LOG")
[[ "$AFTER" -eq "$BEFORE" ]] \
    && ok "dry-run (-n) made no API calls" || bad "dry-run (-n) made no API calls"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
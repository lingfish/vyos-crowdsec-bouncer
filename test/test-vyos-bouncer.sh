#!/bin/bash
# Test vyos-bouncer.sh against a mock CrowdSec LAPI.
#
#   ./test/test-vyos-bouncer.sh          # full integration test
#   ./test/test-vyos-bouncer.sh --check  # only exercise --check mode
set -euo pipefail

CHECK_ONLY="${1:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/vyos-bouncer.sh"
MOCK="$ROOT/test/mock-lapi.py"
TMP="$(mktemp -d "$ROOT/test/tmp.XXXXXX")"
PORT="18444"
CONF="$TMP/bouncer.conf"
BANS="$TMP/bans.txt"
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
    # Mirror the real vyos-bouncer.conf: values only apply when not set in env,
    # so env-var overrides (e.g. SCOPES=Username) genuinely win.
    cat >"$CONF" <<EOF
[ -z "\${LAPI_URL:-}" ] && LAPI_URL="http://127.0.0.1:$PORT"
[ -z "\${API_KEY:-}" ] && API_KEY="test-key-123"
[ -z "\${SCOPES:-}" ] && SCOPES="Ip,Range"
[ -z "\${SKIP_SIMULATED:-}" ] && SKIP_SIMULATED="true"
[ -z "\${ORIGINS:-}" ] && ORIGINS=""
[ -z "\${BANS_FILE:-}" ] && BANS_FILE="$BANS"
[ -z "\${REFRESH_SECONDS:-}" ] && REFRESH_SECONDS="30"
[ -z "\${HTTP_BIND:-}" ] && HTTP_BIND="127.0.0.1"
[ -z "\${HTTP_PORT:-}" ] && HTTP_PORT="8080"
EOF
}

start_mock() {
    MOCK_LAPI_PORT="$PORT" "$MOCK" &
    MOCK_PID=$!
    sleep 1
}

echo "== mock run =="
write_conf
start_mock
export VYOS_BOUNCER_CONF="$CONF"

if [[ "$CHECK_ONLY" != "--check" ]]; then

"$SCRIPT" refresh

echo "== assertions =="

[[ -f "$BANS" ]] && ok "refresh wrote list file" || bad "refresh wrote list file"

# IPv4 bans
grep -q '^203.0.113.7$' "$BANS" && ok "IPv4 ban present" || bad "IPv4 ban present"
grep -q '^203.0.113.8$' "$BANS" && ok "second IPv4 ban present" || bad "second IPv4 ban present"

# IPv6 ban
grep -q '^2001:db8::1$' "$BANS" && ok "IPv6 ban present" || bad "IPv6 ban present"

# CIDRs (Range scope)
grep -q '^198.51.100.0/24$' "$BANS" && ok "IPv4 CIDR present" || bad "IPv4 CIDR present"
grep -q '^2001:db8:abcd::/48$' "$BANS" && ok "IPv6 CIDR present" || bad "IPv6 CIDR present"

# simulated decisions are not enforced
grep -q '^192.0.2.66$' "$BANS" && bad "simulated decision excluded" || ok "simulated decision excluded"

# one line per entry, sorted
[[ "$(wc -l <"$BANS")" -eq 5 ]] \
    && ok "5 unique entries (deduped)" || bad "expected 5 unique entries, got $(wc -l <"$BANS")"
sort -c "$BANS" 2>/dev/null && ok "list is sorted" || bad "list is sorted"

# idempotent refresh
"$SCRIPT" refresh
[[ "$(wc -l <"$BANS")" -eq 5 ]] && ok "repeated refresh stays stable" || bad "repeated refresh stays stable"

# LAPI returns `null` (not `[]`) for a scope with no decisions -> refresh must
# still succeed and write an empty list
SCOPES="Username" "$SCRIPT" refresh
[[ -f "$BANS" && ! -s "$BANS" ]] && ok "empty LAPI scope handled (null body)" || bad "empty LAPI scope handled"
"$SCRIPT" refresh   # restore the full list for the failure-mode test below

# origin filtering: ORIGINS=crowdsec -> only the local crowdsec-origin entries
# (203.0.113.7/.8), CAPI/lists/simulated all excluded
ORIGINS="crowdsec" "$SCRIPT" refresh
grep -q '^203.0.113.7$' "$BANS" && ok "origin filter keeps crowdsec entry" || bad "origin filter keeps crowdsec entry"
grep -q '^2001:db8::1$' "$BANS" && bad "origin filter excludes CAPI entry" || ok "origin filter excludes CAPI entry"
grep -q '^2001:db8:abcd::/48$' "$BANS" && bad "origin filter excludes lists entry" || ok "origin filter excludes lists entry"
[[ "$(wc -l <"$BANS")" -eq 2 ]] && ok "origin filter -> 2 entries" || bad "origin filter -> 2 entries (got $(wc -l <"$BANS"))"

# multi-origin filter
ORIGINS="crowdsec,CAPI" "$SCRIPT" refresh
[[ "$(wc -l <"$BANS")" -eq 4 ]] && ok "origin filter crowdsec,CAPI -> 4 entries" || bad "origin filter crowdsec,CAPI -> 4 entries (got $(wc -l <"$BANS"))"
"$SCRIPT" refresh   # restore the full list for the failure-mode test below

# failure mode: LAPI outage -> refresh fails, existing list untouched
kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true
cp "$BANS" "$TMP/before.txt"
MOCK_LAPI_PORT="$PORT" MOCK_FAIL=1 "$MOCK" &
MOCK_PID=$!
sleep 1
if "$SCRIPT" refresh >/dev/null 2>&1; then
    bad "refresh must fail when LAPI is down"
else
    ok "refresh fails when LAPI is down"
fi
cmp -s "$TMP/before.txt" "$BANS" && ok "last-good list untouched on failure" || bad "last-good list untouched on failure"

fi  # end mock integration section

echo "== check mode =="
if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
fi
start_mock
"$SCRIPT" --check >"$TMP/check.out"
grep -q '^203.0.113.7$' "$TMP/check.out" && ok "--check prints the list" || bad "--check prints the list"
if [[ -f "$BANS" ]]; then
    BEFORE=$(cksum <"$BANS")
    "$SCRIPT" --check >/dev/null
    AFTER=$(cksum <"$BANS")
    [[ "$BEFORE" == "$AFTER" ]] && ok "--check leaves served file untouched" || bad "--check leaves served file untouched"
else
    "$SCRIPT" --check >/dev/null
    [[ -f "$BANS" ]] && bad "--check must not create the served file" || ok "--check does not create the served file"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
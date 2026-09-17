#!/usr/bin/env bash
# Issue 3: confirm a short-TTL ban is auto-removed from the firewall group on
# LAPI expiry -- with no manual delete anywhere in the flow.
#
#   ./lab/test-expiry.sh
#
# Expects the lab from ./lab/provision.sh to be up.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PASS=0
FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [[ "$(vsh domstate "$GUEST" 2>/dev/null)" != *running* ]]; then
    die "lab not up; run ./lab/provision.sh first"
fi
GUEST_IP="$(guest_ip)"
[[ -n "$GUEST_IP" ]] || die "no guest DHCP lease"
log "guest IP: $GUEST_IP"

member_present() {
    local out
    out="$(guest_op "show firewall group")"
    [[ "$out" == *"$ATTACKER_IP"* ]]
}

echo "== baseline (no ban) =="
code="$(attacker_http_code)"
echo "  attacker HTTP (unbanned): $code"
if [[ "$code" == "200" ]]; then
    ok "baseline: attacker reaches listener"
else
    bad "baseline: expected 200, got $code"
fi

echo "== add short-TTL ban =="
podman exec "$LAPI_NAME" cscli decisions add --ip "$ATTACKER_IP" -d 1m >/dev/null
log "waiting for member $ATTACKER_IP to appear in CROWDSEC-BANNED"
T_APPEAR=$SECONDS
if wait_for 90 "group member $ATTACKER_IP" member_present; then
    log "member appeared after $((SECONDS - T_APPEAR))s"
    ok "member present in firewall group"
else
    bad "group member never appeared"
    echo
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi

code="$(attacker_http_code)"
echo "  attacker HTTP (banned): $code"
if [[ "$code" == "000" ]]; then
    ok "traffic dropped while banned"
else
    bad "expected 000 while banned, got $code"
fi

echo "== auto-expiry (no manual delete anywhere) =="
T_EXPIRE=$SECONDS
REMOVED=0
deadline=$((SECONDS + 240))
while ((SECONDS < deadline)); do
    if ! member_present; then
        REMOVED=1
        break
    fi
    sleep 5
done
if [[ "$REMOVED" == "1" ]]; then
    log "member auto-removed $((SECONDS - T_EXPIRE))s after expiry deadline (ttl=1m + batching)"
    ok "member auto-removed on LAPI expiry"
else
    bad "member never auto-removed within 240s"
fi

code="$(attacker_http_code)"
echo "  attacker HTTP (after expiry): $code"
if [[ "$code" == "200" ]]; then
    ok "traffic recovered after expiry"
else
    bad "expected 200 after expiry, got $code"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
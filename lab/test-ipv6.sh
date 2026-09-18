#!/usr/bin/env bash
# Issue 1: prove an IPv6 ban produces a real packet drop on a live VyOS.
#
#   ./lab/test-ipv6.sh
#
# Bans the attacker netns' IPv6 address (fd00:9::77), confirms membership in
# the ipv6-address-group via `show firewall group detail`, measures the drop to the
# IPv6 listener, then unbans and confirms recovery. Mirrors the IPv4 flow from
# docs/lab-validation.md.
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
log "guest IP: $(guest_ip)  v6 attacker: $ATTACKER_IP6"

member_present_v6() {
    local out
    out="$(guest_op "show firewall group detail")"
    [[ "$out" == *"$ATTACKER_IP6"* ]]
}

member_under_v6_group() {
    local out
    out="$(guest_op "show firewall group detail")"
    [[ "$out" == *"CROWDSEC-BANNED"* && "$out" == *"$ATTACKER_IP6"* ]]
}

member_absent_v6() {
    ! member_present_v6
}

echo "== baseline (no ban) =="
code="$(attacker_http_code_v6)"
echo "  attacker HTTP v6 (unbanned): $code"
if [[ "$code" == "200" ]]; then
    ok "baseline: attacker reaches IPv6 listener"
else
    bad "baseline: expected 200, got $code"
fi

echo "== add IPv6 ban =="
podman exec "$LAPI_NAME" cscli decisions add --ip "$ATTACKER_IP6" -d 2h >/dev/null
log "waiting for member $ATTACKER_IP6 to appear in CROWDSEC-BANNED"
T_APPEAR=$SECONDS
if wait_for 90 "group member $ATTACKER_IP6" member_present_v6; then
    log "member appeared after $((SECONDS - T_APPEAR))s"
    ok "member present in firewall group"
else
    bad "group member never appeared"
    echo
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi
if member_under_v6_group; then
    ok "member under CROWDSEC-BANNED (remote-group, IPv6 set)"
else
    bad "member not shown under CROWDSEC-BANNED"
fi

code="$(attacker_http_code_v6)"
echo "  attacker HTTP v6 (banned): $code"
if [[ "$code" == "000" ]]; then
    ok "traffic dropped while banned"
else
    bad "expected 000 while banned, got $code"
fi

echo "== unban =="
podman exec "$LAPI_NAME" cscli decisions delete --ip "$ATTACKER_IP6" >/dev/null 2>&1 || true
log "waiting for member $ATTACKER_IP6 to disappear"
T_GONE=$SECONDS
if wait_for 90 "group member $ATTACKER_IP6 removal" member_absent_v6; then
    log "member removed after $((SECONDS - T_GONE))s"
    ok "member removed from firewall group"
else
    bad "group member never removed"
fi

code="$(attacker_http_code_v6)"
echo "  attacker HTTP v6 (unbanned): $code"
if [[ "$code" == "200" ]]; then
    ok "traffic recovered after unban"
else
    bad "expected 200 after unban, got $code"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
#!/usr/bin/env bash
# Issue 2: prove forwarded (routed) traffic is dropped by the VyOS forward
# hook, end-to-end, from the attacker netns through VyOS to a routed server
# netns behind it.
#
#   ./lab/test-forward.sh
#
# Three scenarios, each: baseline 200 -> ban -> member in group
# (`show firewall group detail`) -> drop (000 / curl timeout) -> unban -> member gone
# -> recovery (200). All map to the single remote-group CROWDSEC-BANNED
# (its IPv4/IPv6 sets hold addresses and CIDRs alike):
#   1. IPv4 address  (ban --ip 10.9.0.77      -> CROWDSEC-BANNED)
#   2. IPv4 CIDR     (ban --range 10.9.0.0/24 -> CROWDSEC-BANNED)
#   3. IPv6 address  (ban --ip fd00:9::77     -> CROWDSEC-BANNED)
#
# The server netns (10.9.1.10 / fd00:9:1::10) is a separate routed subnet
# behind VyOS, so every request transits the FORWARD hook -- the input rules
# cannot be what drops it. Expects the lab from ./lab/provision.sh to be up.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PASS=0
FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [[ "$(vsh domstate "$GUEST" 2>/dev/null)" != *running* ]]; then
    die "lab not up; run ./lab/provision.sh first"
fi
log "guest IP: $(guest_ip)  routed server: $SERVER_IP / $SERVER_IP6"

member_present() {
    local out
    out="$(guest_op "show firewall group detail")"
    [[ "$out" == *"$1"* ]]
}

member_under() {
    local out
    out="$(guest_op "show firewall group detail")"
    [[ "$out" == *"$1"* && "$out" == *"$2"* ]]
}

member_absent() { ! member_present "$1"; }

# scenario <desc> <cscli add/delete value> <member> <group> <curl-fn>
scenario() {
    local desc="$1" value="$2" member="$3" group="$4" curl_fn="$5"
    echo "== $desc =="

    code="$("$curl_fn")"
    echo "  attacker HTTP (unbanned): $code"
    if [[ "$code" == "200" ]]; then
        ok "baseline: attacker reaches routed server"
    else
        bad "baseline: expected 200, got $code"
    fi

    # `value` is a deliberately unquoted "flag arg" string (e.g. "--ip 10.9.0.77").
    # shellcheck disable=SC2086
    podman exec "$LAPI_NAME" cscli decisions add $value >/dev/null
    log "waiting for member $member to appear in $group"
    T_APPEAR=$SECONDS
    if wait_for 150 "group member $member" member_present "$member"; then
        log "member appeared after $((SECONDS - T_APPEAR))s"
        ok "member present in firewall group"
    else
        bad "group member never appeared"
        return 1
    fi
    if member_under "$group" "$member"; then
        ok "member under $group"
    else
        bad "member not shown under $group"
    fi

    code="$("$curl_fn")"
    echo "  attacker HTTP (banned): $code"
    if [[ "$code" == "000" ]]; then
        ok "forwarded traffic dropped while banned"
    else
        bad "expected 000 while banned, got $code"
    fi

    # shellcheck disable=SC2086
    podman exec "$LAPI_NAME" cscli decisions delete $value >/dev/null 2>&1 || true
    log "waiting for member $member to disappear"
    T_GONE=$SECONDS
    if wait_for 150 "group member $member removal" member_absent "$member"; then
        log "member removed after $((SECONDS - T_GONE))s"
        ok "member removed from firewall group"
    else
        bad "group member never removed"
    fi

    code="$("$curl_fn")"
    echo "  attacker HTTP (unbanned): $code"
    if [[ "$code" == "200" ]]; then
        ok "traffic recovered after unban"
    else
        bad "expected 200 after unban, got $code"
    fi
}

scenario "IPv4 address forward (remote-group)" \
    "--ip $ATTACKER_IP" "$ATTACKER_IP" "CROWDSEC-BANNED" attacker_http_code_fwd || true
scenario "IPv4 CIDR forward (remote-group)" \
    "--range $ATTACKER_NET" "$ATTACKER_NET" "CROWDSEC-BANNED" attacker_http_code_fwd || true
scenario "IPv6 address forward (remote-group)" \
    "--ip $ATTACKER_IP6" "$ATTACKER_IP6" "CROWDSEC-BANNED" attacker_http_code_fwd_v6 || true

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
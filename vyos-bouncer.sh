#!/bin/bash
# vyos-bouncer.sh
#
# CrowdSec Custom Bouncer -> VyOS HTTPS API translator.
# Called by crowdsec-custom-bouncer as:
#   vyos-bouncer.sh <add|del> <value> [duration] [reason] [json]
#
# - value may be IPv4/IPv6 or CIDR.
# - Decisions are spooled and flushed in batches (one VyOS /configure commit
#   per short quiet window) to bound config-commit frequency.
# - Fail-open: API errors are logged and retried; existing members untouched.
# - --dry-run / -n logs the intended API call and exits without POSTing.

set -u

log() { echo "[vyos-bouncer] $(date -Is) $*"; }

CONF="${VYOS_BOUNCER_CONF:-/etc/crowdsec/vyos-bouncer.conf}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

: "${VYOS_API_URL:=https://127.0.0.1}"
: "${VYOS_API_KEY:=}"
: "${ADDRESS_GROUP_V4:=CROWDSEC-BANNED}"
: "${ADDRESS_GROUP_V6:=CROWDSEC-BANNED-V6}"
: "${NETWORK_GROUP_V4:=CROWDSEC-BANNED-NET}"
: "${NETWORK_GROUP_V6:=CROWDSEC-BANNED-NET-V6}"
: "${BATCH_WINDOW:=3}"
: "${BATCH_MAX_ROUNDS:=10}"
: "${API_TIMEOUT:=30}"
: "${API_RETRIES:=3}"
: "${API_RETRY_DELAY:=2}"
: "${SPOOL_DIR:=/var/spool/crowdsec}"

is_ipv6() { [[ "$1" == *:* ]]; }
is_cidr() { [[ "$1" == */* ]]; }

validate_value() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    [[ "$v" =~ ^[0-9a-fA-F.:/_-]+$ ]] || return 1
    [[ "$v" == *.* || "$v" == *:* ]] || return 1
    return 0
}

# Emit the vyos path node + group name for a value.
group_node_for() {
    local val="$1"
    if is_ipv6 "$val"; then
        if is_cidr "$val"; then
            echo "ipv6-network-group|${NETWORK_GROUP_V6}"
        else
            echo "ipv6-address-group|${ADDRESS_GROUP_V6}"
        fi
    else
        if is_cidr "$val"; then
            echo "network-group|${NETWORK_GROUP_V4}"
        else
            echo "address-group|${ADDRESS_GROUP_V4}"
        fi
    fi
}

# Build a single /configure command object.
cmd_for() {
    local op="$1" val="$2" node gname child opname
    IFS='|' read -r node gname <<<"$(group_node_for "$val")"
    if [[ "$node" == *network* ]]; then child="network"; else child="address"; fi
    if [[ "$op" == "del" ]]; then opname="delete"; else opname="set"; fi
    printf '{"op":"%s","path":["firewall","group","%s","%s","%s","%s"]}' \
        "$opname" "$node" "$gname" "$child" "$val"
}

call_api() {
    local payload="$1" http_code rc attempt
    for attempt in $(seq 1 "$API_RETRIES"); do
        http_code=$(curl -sk --max-time "$API_TIMEOUT" -o /dev/null -w '%{http_code}' \
            -X POST "${VYOS_API_URL}/configure" \
            --data-urlencode "data=$payload" \
            --data-urlencode "key=$VYOS_API_KEY" 2>/dev/null)
        rc=$?
        if [[ "$rc" -eq 0 && "$http_code" =~ ^2 ]]; then
            log "OK: HTTP $http_code"
            return 0
        fi
        log "WARN: API call failed (rc=$rc http=$http_code) attempt $attempt/$API_RETRIES"
        [[ $attempt -lt "$API_RETRIES" ]] && sleep "$API_RETRY_DELAY"
    done
    log "ERROR: exhausted retries posting to ${VYOS_API_URL}/configure"
    return 1
}

# Collect pending spooled ops until the set stabilizes, then POST once.
flush() {
    local prev=-1 count=0 round=0 f op val
    while :; do
        round=$((round + 1))
        sleep "$BATCH_WINDOW"
        count=$(find "$SPOOL_DIR" -maxdepth 1 -name 'op-*' 2>/dev/null | wc -l)
        if [[ "$count" -eq 0 || "$count" -eq "$prev" || "$round" -ge "$BATCH_MAX_ROUNDS" ]]; then
            break
        fi
        prev="$count"
    done

    local cmds=()
    for f in "$SPOOL_DIR"/op-*; do
        [[ -e "$f" ]] || continue
        read -r op val <"$f" || continue
        cmds+=("$(cmd_for "$op" "$val")")
    done
    rm -f "$SPOOL_DIR"/op-*

    [[ "${#cmds[@]}" -eq 0 ]] && return 0

    local payload
    if [[ "${#cmds[@]}" -eq 1 ]]; then
        payload="${cmds[0]}"
    else
        payload="$(IFS=,; printf '[%s]' "${cmds[*]}")"
    fi

    log "payload: $payload"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "DRY-RUN: would POST ${VYOS_API_URL}/configure"
        return 0
    fi
    call_api "$payload"
}

spool_and_flush() {
    local op="$1" val="$2"
    mkdir -p "$SPOOL_DIR"
    echo "$op $val" >"$SPOOL_DIR/op-$(date +%s%N)-$RANDOM"
    (
        flock -x 9 || return 0
        flush
    ) 9>"$SPOOL_DIR/.lock"
}

main() {
    local DRY_RUN=false
    if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
        DRY_RUN=true
        shift
    fi
    local action="${1:-}" value="${2:-}"
    if [[ -z "$action" || -z "$value" ]]; then
        log "usage: $0 [--dry-run] <add|del> <ip|cidr> [duration reason json]"
        exit 1
    fi
    if ! validate_value "$value"; then
        log "ERROR: rejecting invalid value '$value'"
        exit 1
    fi
    log "spooling $action $value"
    spool_and_flush "$action" "$value"
}

main "$@"
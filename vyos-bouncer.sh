#!/bin/bash
# vyos-bouncer.sh
#
# CrowdSec LAPI -> VyOS remote-group list generator.
#
# Pull-based: the served list always reflects LAPI's current *active*
# decisions (GET /v1/decisions only returns non-expired entries), so
# add/delete/expiry are handled implicitly by re-fetching.
#
#   vyos-bouncer.sh refresh     fetch decisions, atomically rewrite the list
#   vyos-bouncer.sh --check     fetch and print the list to stdout (no write)
#
# Fail-open: on any LAPI/HTTP failure the existing list file is left
# untouched and the script exits non-zero, so busybox httpd keeps serving
# the last-good list and VyOS's resolver falls back to its cached copy.

set -u
set -o pipefail

log() { echo "[vyos-bouncer] $(date -Is) $*"; }

CONF="${VYOS_BOUNCER_CONF:-/etc/crowdsec/vyos-bouncer.conf}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

: "${LAPI_URL:=}"
: "${API_KEY:=}"
: "${SCOPES:=Ip,Range}"
: "${SKIP_SIMULATED:=true}"
: "${BANS_FILE:=/www/bans.txt}"

fetch_scope() {
    curl -sfk --max-time 20 \
        -H "X-Api-Key: $API_KEY" \
        "$LAPI_URL/v1/decisions?scope=$1"
}

main() {
    local mode="${1:-}"
    if [[ -z "$LAPI_URL" || -z "$API_KEY" ]]; then
        log "ERROR: LAPI_URL and API_KEY must be set"
        exit 1
    fi

    # LAPI returns `null` (not `[]`) when a scope has no decisions; `.[]?`
    # iterates an array and yields nothing on null instead of erroring.
    local jq_filter='.[]?'
    if [[ "$SKIP_SIMULATED" == "true" ]]; then
        jq_filter='.[]? | select(.simulated != true)'
    fi

    local tmp rc scope
    tmp="$(mktemp)"
    rc=0
    for scope in ${SCOPES//,/ }; do
        if ! fetch_scope "$scope" | jq -r "$jq_filter | .value" >>"$tmp"; then
            log "ERROR: LAPI request failed for scope '$scope'"
            rc=1
            break
        fi
    done

    if [[ "$rc" -ne 0 ]]; then
        rm -f "$tmp"
        log "ERROR: leaving $BANS_FILE unchanged"
        exit 1
    fi

    local list
    list="$(sort -u "$tmp")"
    rm -f "$tmp"

    if [[ "$mode" == "--check" ]]; then
        [[ -n "$list" ]] && printf '%s\n' "$list"
        return 0
    fi

    local dir="$BANS_FILE.tmp"
    mkdir -p "$(dirname "$BANS_FILE")"
    if [[ -n "$list" ]]; then
        printf '%s\n' "$list" >"$dir"
    else
        : >"$dir"
    fi
    mv "$dir" "$BANS_FILE"
    log "refreshed $BANS_FILE ($(wc -l <"$BANS_FILE") entries)"
}

main "$@"
#!/bin/sh
# Container entrypoint: keep the served ban list fresh, then serve it.
#
# We refuse to serve until the first successful refresh so a restart during a
# LAPI outage never exposes an empty list (VyOS keeps its cached copy while
# httpd is not listening). Afterwards a background loop refreshes every
# REFRESH_SECONDS, keeping the last-good list on failure.

set -u

log() { echo "[entrypoint] $(date -Is) $*"; }

SCRIPT=/opt/vyos-crowdsec-bouncer/vyos-bouncer.sh

CONF="${VYOS_BOUNCER_CONF:-/etc/crowdsec/vyos-bouncer.conf}"
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

: "${REFRESH_SECONDS:=30}"
: "${HTTP_BIND:=127.0.0.1}"
: "${HTTP_PORT:=8080}"
: "${BANS_FILE:=/www/bans.txt}"

until "$SCRIPT" refresh; do
    log "WARN: initial refresh failed, retrying (LAPI unreachable?)"
    sleep 2
done

(
    while :; do
        sleep "$REFRESH_SECONDS"
        "$SCRIPT" refresh || log "WARN: refresh failed, keeping $BANS_FILE"
    done
) &

exec httpd -f -p "$HTTP_BIND:$HTTP_PORT" -h /www
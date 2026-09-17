#!/usr/bin/env bash
# Tear down the isolated VyOS CrowdSec lab: destroy + undefine the domain and
# network, remove the LAPI container, and clear the runtime cache (the ISO is
# kept so the next `make lab-up` does not re-download it).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "$(vsh domstate "$GUEST" 2>/dev/null)" == *running* ]]; then
    log "destroying guest $GUEST"
    vsh destroy "$GUEST" >/dev/null
fi
vsh undefine "$GUEST" >/dev/null 2>&1 || true

if vsh net-info "$NET" >/dev/null 2>&1; then
    log "removing network $NET"
    vsh net-destroy "$NET" >/dev/null 2>&1 || true
    vsh net-undefine "$NET" >/dev/null 2>&1 || true
fi

podman rm -f "$LAPI_NAME" >/dev/null 2>&1 || true

if [[ -d "$LAB_CACHE" ]]; then
    log "clearing runtime cache (keeping ISOs)"
    find "$LAB_CACHE" -maxdepth 1 -type f ! -name '*.iso' -delete
    rm -rf "$LAB_CACHE/lapi-data"
fi

log "down complete"
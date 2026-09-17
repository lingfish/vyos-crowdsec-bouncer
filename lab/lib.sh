#!/usr/bin/env bash
# Shared helpers for the VyOS CrowdSec lab (isolated libvirt guest).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/lab"
LAB_CACHE="$LAB/.cache"

CONN="qemu:///system"
GUEST="vyos-crowdsec-lab"
NET="crowdsec-lab"
GUEST_USER="vyos"
GUEST_PASS="vyos"

LAPI_NAME="cs-lapi"
LAPI_BIND="192.0.2.1"
LAPI_PORT="18080"

SERIAL_HOST="127.0.0.1"
SERIAL_PORT="23000"

ATTACKER_IP="10.9.0.77"
ATTACKER_NET="10.9.0.0/24"
ATTACKER_IP6="fd00:9::77"
ATTACKER_NET6="fd00:9::/64"
V6_GW="fd00:9::1"
SERVER_IP="10.9.1.10"
SERVER_NET="10.9.1.0/24"
SERVER_GW="10.9.1.1"
SERVER_IP6="fd00:9:1::10"
SERVER_NET6="fd00:9:1::/64"
SERVER_GW6="fd00:9:1::1"
LISTENER_PORT="8081"
LISTENER_PORT_V6="8082"
SERVER_PORT="8083"
SERVER_PORT_V6="8084"
IMAGE_SERVER_PORT="8000"

SSH_KEY="$LAB_CACHE/id_lab"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

log() { echo "[lab] $(date -Is) $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

vsh() { virsh -c "$CONN" "$@"; }

# Guest IPv4 from the libvirt DHCP lease (populated once eth0 is up).
guest_ip() {
    vsh net-dhcp-leases "$NET" 2>/dev/null \
        | awk '$4 ~ /^ipv4/ {print $5}' | cut -d/ -f1 | head -n1
}

# Run an op-mode command on the guest via the serial CLI.
# (Non-interactive `ssh vyos@host 'show ...'` does not work on this VyOS build
# -- vbash rejects the command -- so we use the reliable serial console.)
guest_op() {
    local cmd="$1"
    serial --login "$GUEST_USER" "$GUEST_PASS" --cmd "$cmd" \
        --timeout 40 --idle-timeout 25 2>/dev/null
}

# Drive the guest serial console over the domain's TCP chardev (serial.py).
serial() {
    python3 "$LAB/serial.py" --tcp "$SERIAL_HOST" "$SERIAL_PORT" "$@"
}

# Run one or more raw shell commands as root via a fresh serial session.
# Always `exit` back to the vyos CLI shell so a later session isn't left in bash.
guest_root() {
    local cmds=()
    for c in "$@"; do cmds+=(--cmd "$c"); done
    serial --login "$GUEST_USER" "$GUEST_PASS" --cmd "sudo -i" "${cmds[@]}" --cmd "exit"
}

# Poll until a command succeeds.  usage: wait_for <timeout> <desc> <cmd...>
wait_for() {
    local t="$1" desc="$2"
    shift 2
    local deadline=$((SECONDS + t))
    while ((SECONDS < deadline)); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    log "ERROR: timeout waiting for: $desc"
    return 1
}

# HTTP status code a request from the attacker netns to the given URL gets.
# usage: attacker_http_code_to <url>   e.g. attacker_http_code_to "http://$gip:$LISTENER_PORT/"
attacker_http_code_to() {
    serial --login "$GUEST_USER" "$GUEST_PASS" --cmd "sudo -i" \
        --cmd "ip netns exec attacker curl -s -o /dev/null -w 'CODE=%{http_code}' --max-time 5 '$1'" \
        --cmd "exit" --timeout 30 --idle-timeout 20 2>/dev/null \
        | grep -oE 'CODE=[0-9]{3}' | tail -n1 | cut -d= -f2
}

# HTTP status code a request from the attacker netns to the guest listener gets.
attacker_http_code() {
    local gip
    gip="$(guest_ip)"
    attacker_http_code_to "http://$gip:$LISTENER_PORT/"
}

# Same, but IPv6: attacker netns -> veth gateway's IPv6 listener. The gateway
# address is fixed (no DHCP lookup needed, unlike the IPv4 variant).
attacker_http_code_v6() {
    attacker_http_code_to "http://[$V6_GW]:$LISTENER_PORT_V6/"
}

# Forward-path variants: attacker netns -> routed server netns behind VyOS
# (transits the FORWARD hook; the server is not a VyOS-local address).
attacker_http_code_fwd()   { attacker_http_code_to "http://$SERVER_IP:$SERVER_PORT/"; }
attacker_http_code_fwd_v6() { attacker_http_code_to "http://[$SERVER_IP6]:$SERVER_PORT_V6/"; }
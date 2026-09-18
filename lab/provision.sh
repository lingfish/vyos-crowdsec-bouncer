#!/usr/bin/env bash
# Bring up the isolated VyOS CrowdSec lab.
#
#   ./lab/provision.sh
#
# Downloads the latest VyOS rolling nightly ISO, boots it in an isolated
# libvirt network (192.0.2.0/24, no LAN/internet access), configures the
# bouncer stack exactly like production (VyOS HTTPS API + firewall groups +
# `set container`), and stages the in-guest attacker netns + listener used
# by lab/test-expiry.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VYOS_JSON_URL="https://raw.githubusercontent.com/vyos/vyos-nightly-build/rolling/version.json"
IMAGE="localhost/vyos-crowdsec-bouncer:latest"

mkdir -p "$LAB_CACHE"
log "== 1/7 ISO =="
INFO="$(curl -fsSL "$VYOS_JSON_URL")"
ISO_URL="$(python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["url"])' <<<"$INFO")"
VERSION="$(python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["version"])' <<<"$INFO")"
ISO="$LAB_CACHE/vyos-$VERSION-generic-amd64.iso"
if [[ -f "$ISO" ]]; then
    log "ISO already cached: $(basename "$ISO")"
else
    log "downloading $ISO_URL"
    curl -fL --retry 3 --retry-delay 5 -o "$ISO" "$ISO_URL"
fi

log "== 2/7 network + domain =="
if ! vsh net-info "$NET" >/dev/null 2>&1; then
    vsh net-define "$LAB/crowdsec-net.xml"
fi
if [[ "$(vsh net-info "$NET" 2>/dev/null | awk '/^Active:/{print $2}')" != "yes" ]]; then
    vsh net-start "$NET"
fi
if [[ "$(vsh domstate "$GUEST" 2>/dev/null)" == *running* ]]; then
    log "$GUEST already running; reusing existing domain"
else
    vsh destroy "$GUEST" >/dev/null 2>&1 || true
    vsh undefine "$GUEST" >/dev/null 2>&1 || true
    sed "s|__ISO_PATH__|$ISO|" "$LAB/vyos-lab.xml" >"$LAB_CACHE/vyos-lab.gen.xml"
    vsh define "$LAB_CACHE/vyos-lab.gen.xml" >/dev/null
    log "starting $GUEST (live ISO boot, please be patient)"
    vsh start "$GUEST"
fi

log "== 3/7 base VyOS config (ssh, firewall remote-group) =="
serial --login "$GUEST_USER" "$GUEST_PASS" --timeout 900 --idle-timeout 120 \
    --cmd "configure" \
    --cmd "set interfaces ethernet eth0 address 'dhcp'" \
    --cmd "set service ssh" \
    --cmd "set firewall group remote-group CROWDSEC-BANNED url 'http://127.0.0.1:8080/bans.txt'" \
    --cmd "set firewall global-options resolver-interval '10'" \
    --cmd "set firewall ipv4 input filter default-action 'accept'" \
    --cmd "set firewall ipv4 input filter rule 100 action 'drop'" \
    --cmd "set firewall ipv4 input filter rule 100 source group remote-group 'CROWDSEC-BANNED'" \
    --cmd "set firewall ipv6 input filter default-action 'accept'" \
    --cmd "set firewall ipv6 input filter rule 100 action 'drop'" \
    --cmd "set firewall ipv6 input filter rule 100 source group remote-group 'CROWDSEC-BANNED'" \
    --cmd "set firewall ipv4 forward filter default-action 'accept'" \
    --cmd "set firewall ipv4 forward filter rule 100 action 'drop'" \
    --cmd "set firewall ipv4 forward filter rule 100 source group remote-group 'CROWDSEC-BANNED'" \
    --cmd "set firewall ipv6 forward filter default-action 'accept'" \
    --cmd "set firewall ipv6 forward filter rule 100 action 'drop'" \
    --cmd "set firewall ipv6 forward filter rule 100 source group remote-group 'CROWDSEC-BANNED'" \
    --cmd "commit" \
    --cmd "exit"

GUEST_IP="$(guest_ip)"
if [[ -z "$GUEST_IP" ]]; then
    log "waiting for guest DHCP lease"
    for _ in $(seq 1 90); do
        GUEST_IP="$(guest_ip)"
        [[ -n "$GUEST_IP" ]] && break
        sleep 2
    done
fi
[[ -n "$GUEST_IP" ]] || die "guest never got a DHCP lease"
log "guest IP: $GUEST_IP"

log "== 4/7 stage guest: bouncer.conf, ssh key, attacker netns, listener =="
PUBKEY="$(cat "$SSH_KEY.pub" 2>/dev/null || true)"
if [[ -z "$PUBKEY" ]]; then
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "vyos-crowdsec-bouncer-lab" >/dev/null
    PUBKEY="$(cat "$SSH_KEY.pub")"
fi
CONF="[ -z \"\${LAPI_URL:-}\" ] && LAPI_URL=\"http://$LAPI_BIND:$LAPI_PORT\"
[ -z \"\${API_KEY:-}\" ] && API_KEY=\"CHANGE_ME\"
[ -z \"\${SCOPES:-}\" ] && SCOPES=\"Ip,Range\"
[ -z \"\${SKIP_SIMULATED:-}\" ] && SKIP_SIMULATED=\"true\"
[ -z \"\${BANS_FILE:-}\" ] && BANS_FILE=\"/www/bans.txt\"
[ -z \"\${REFRESH_SECONDS:-}\" ] && REFRESH_SECONDS=\"5\"
[ -z \"\${HTTP_BIND:-}\" ] && HTTP_BIND=\"127.0.0.1\"
[ -z \"\${HTTP_PORT:-}\" ] && HTTP_PORT=\"8080\""
CONF_B64="$(printf '%s\n' "$CONF" | base64 -w0)"

guest_root \
    "pkill -f 'http.server $LISTENER_PORT' 2>/dev/null || true" \
    "pkill -f 'http.server $LISTENER_PORT_V6' 2>/dev/null || true" \
    "pkill -f 'http.server $SERVER_PORT' 2>/dev/null || true" \
    "pkill -f 'http.server $SERVER_PORT_V6' 2>/dev/null || true" \
    "ip netns del attacker 2>/dev/null || true" \
    "ip link del veth-m 2>/dev/null || true" \
    "ip netns del server 2>/dev/null || true" \
    "ip link del veth-s 2>/dev/null || true" \
    "mkdir -p /config/crowdsec /home/vyos/.ssh" \
    "echo '$CONF_B64' | base64 -d > /config/crowdsec/vyos-bouncer.conf" \
    "chmod 600 /config/crowdsec/vyos-bouncer.conf" \
    "echo '$PUBKEY' > /home/vyos/.ssh/authorized_keys" \
    "chown -R vyos /home/vyos/.ssh && chmod 700 /home/vyos/.ssh && chmod 600 /home/vyos/.ssh/authorized_keys" \
    "ip netns add attacker" \
    "ip link add veth-m type veth peer name veth-a" \
    "ip link set veth-a netns attacker" \
    "ip addr add 10.9.0.1/24 dev veth-m" \
    "ip -6 addr add $V6_GW/64 dev veth-m" \
    "ip link set veth-m up" \
    "ip netns exec attacker ip link set lo up" \
    "ip netns exec attacker ip addr add 10.9.0.77/24 dev veth-a" \
    "ip netns exec attacker ip -6 addr add $ATTACKER_IP6/64 dev veth-a" \
    "ip netns exec attacker ip link set veth-a up" \
    "ip netns exec attacker ip route add default via 10.9.0.1" \
    "ip netns exec attacker ip -6 route add default via $V6_GW dev veth-a" \
    "nohup python3 -m http.server $LISTENER_PORT --bind 0.0.0.0 >/tmp/listener.log 2>&1 &" \
    "nohup python3 -m http.server $LISTENER_PORT_V6 --bind :: >/tmp/listener6.log 2>&1 &" \
    "ip netns add server" \
    "ip link add veth-s type veth peer name veth-sa" \
    "ip link set veth-sa netns server" \
    "ip addr add $SERVER_GW/24 dev veth-s" \
    "ip -6 addr add $SERVER_GW6/64 dev veth-s" \
    "ip link set veth-s up" \
    "ip netns exec server ip link set lo up" \
    "ip netns exec server ip addr add $SERVER_IP/24 dev veth-sa" \
    "ip netns exec server ip -6 addr add $SERVER_IP6/64 dev veth-sa" \
    "ip netns exec server ip link set veth-sa up" \
    "ip netns exec server ip route add default via $SERVER_GW" \
    "ip netns exec server ip -6 route add default via $SERVER_GW6 dev veth-sa" \
    "nohup ip netns exec server python3 -m http.server $SERVER_PORT --bind 0.0.0.0 >/tmp/server-listener.log 2>&1 &" \
    "nohup ip netns exec server python3 -m http.server $SERVER_PORT_V6 --bind :: >/tmp/server-listener6.log 2>&1 &" \
    "ip -6 neigh add $SERVER_IP6 lladdr \$(ip netns exec server ip link show veth-sa | sed -n 's/.*link\\/ether \\([0-9a-f:]*\\).*/\\1/p') dev veth-s nud permanent" \
    "ip -6 neigh add $ATTACKER_IP6 lladdr \$(ip netns exec attacker ip link show veth-a | sed -n 's/.*link\\/ether \\([0-9a-f:]*\\).*/\\1/p') dev veth-m nud permanent"

log "== 5/7 bouncer image into guest podman =="
# Always rebuild: a stale `:latest` from an earlier run must not be reused
# after the design changes (layers are cached, so this is fast).
make -C "$ROOT" build VERSION=latest
podman save "$IMAGE" | gzip >"$LAB_CACHE/bouncer-image.tar.gz"
python3 -m http.server "$IMAGE_SERVER_PORT" --bind "$LAPI_BIND" --directory "$LAB_CACHE" >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT
wait_for 15 "image http server" curl -fsSI "http://$LAPI_BIND:$IMAGE_SERVER_PORT/bouncer-image.tar.gz"
guest_root \
    "curl -fsSL http://$LAPI_BIND:$IMAGE_SERVER_PORT/bouncer-image.tar.gz | podman load" \
    "podman images"
kill "$HTTP_PID" 2>/dev/null || true
trap - EXIT

log "== 6/7 LAPI + bouncer registration =="
if ! podman image exists crowdsecurity/crowdsec:latest; then
    podman pull crowdsecurity/crowdsec:latest
fi
podman rm -f "$LAPI_NAME" >/dev/null 2>&1 || true
mkdir -p "$LAB_CACHE/lapi-data"
podman run -d --name "$LAPI_NAME" -p "$LAPI_BIND:$LAPI_PORT:8080" \
    -v "$LAB_CACHE/lapi-data:/var/lib/crowdsec/data" crowdsecurity/crowdsec:latest
wait_for 90 "LAPI ready" podman exec "$LAPI_NAME" cscli decisions list
podman exec "$LAPI_NAME" cscli bouncers delete vyos-bouncer >/dev/null 2>&1 || true
LAPI_KEY="$(podman exec "$LAPI_NAME" cscli bouncers add vyos-bouncer -o raw | tr -d '[:space:]')"
log "bouncer key obtained"

log "== 7/7 deploy bouncer container =="
serial --login "$GUEST_USER" "$GUEST_PASS" --timeout 900 --idle-timeout 120 \
    --cmd "configure" \
    --cmd "set container name cs-bouncer image 'localhost/vyos-crowdsec-bouncer:latest'" \
    --cmd "set container name cs-bouncer allow-host-networks" \
    --cmd "set container name cs-bouncer environment LAPI_URL value 'http://$LAPI_BIND:$LAPI_PORT'" \
    --cmd "set container name cs-bouncer environment API_KEY value '$LAPI_KEY'" \
    --cmd "set container name cs-bouncer volume 'bouncer-conf' source '/config/crowdsec/vyos-bouncer.conf'" \
    --cmd "set container name cs-bouncer volume 'bouncer-conf' destination '/etc/crowdsec/vyos-bouncer.conf'" \
    --cmd "set container name cs-bouncer volume 'bouncer-conf' mode 'ro'" \
    --cmd "set container name cs-bouncer restart 'always'" \
    --cmd "commit" \
    --cmd "exit"

log "waiting for cs-bouncer container to be running"
wait_for 120 "bouncer container running" guest_op "show container"
log "provision complete (guest IP $GUEST_IP, LAPI http://$LAPI_BIND:$LAPI_PORT)"
log "next: ./lab/test-expiry.sh"
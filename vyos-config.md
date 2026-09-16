# VyOS configuration for the CrowdSec bouncer

Targets VyOS **1.4 (sagitta) LTS** and later (HTTP REST API + `allow-host-networks` containers).

All commands run from config mode (`configure`) and are committed once at the end.

## 1. HTTPS API (loopback-only + API key)

The bouncer container runs with host networking, so it reaches the API via `127.0.0.1`.

```bash
set service https api keys id crowdsec key '<STRONG-RANDOM-KEY>'
set service https api rest
set service https listen-address '127.0.0.1'
set service https allow-client address '127.0.0.1'
```

- `listen-address 127.0.0.1` + `allow-client` keep the full-permission key off the network.
- Use a TLS cert from `pki` for a trusted cert, or the script already handles self-signed (`curl -k`).

## 2. Firewall groups

```bash
set firewall group address-group CROWDSEC-BANNED description 'CrowdSec IPv4 bans'
set firewall group ipv6-address-group CROWDSEC-BANNED-V6 description 'CrowdSec IPv6 bans'
set firewall group network-group CROWDSEC-BANNED-NET description 'CrowdSec IPv4 CIDR bans'
set firewall group ipv6-network-group CROWDSEC-BANNED-NET-V6 description 'CrowdSec IPv6 CIDR bans'
```

Group names must match `vyos-bouncer.conf`.

## 3. Drop rules (router-local + forwarded traffic)

Use a **low rule number** so the drop is evaluated before any accept/allow rules.

Protect VyOS itself (input):

```bash
set firewall ipv4 input filter rule 100 action 'drop'
set firewall ipv4 input filter rule 100 source group address-group 'CROWDSEC-BANNED'
set firewall ipv4 input filter rule 101 action 'drop'
set firewall ipv4 input filter rule 101 source group network-group 'CROWDSEC-BANNED-NET'

set firewall ipv6 input filter rule 100 action 'drop'
set firewall ipv6 input filter rule 100 source group ipv6-address-group 'CROWDSEC-BANNED-V6'
set firewall ipv6 input filter rule 101 action 'drop'
set firewall ipv6 input filter rule 101 source group ipv6-network-group 'CROWDSEC-BANNED-NET-V6'
```

Protect services behind VyOS (forward):

```bash
set firewall ipv4 forward filter rule 100 action 'drop'
set firewall ipv4 forward filter rule 100 source group address-group 'CROWDSEC-BANNED'
set firewall ipv4 forward filter rule 101 action 'drop'
set firewall ipv4 forward filter rule 101 source group network-group 'CROWDSEC-BANNED-NET'

set firewall ipv6 forward filter rule 100 action 'drop'
set firewall ipv6 forward filter rule 100 source group ipv6-address-group 'CROWDSEC-BANNED-V6'
set firewall ipv6 forward filter rule 101 action 'drop'
set firewall ipv6 forward filter rule 101 source group ipv6-network-group 'CROWDSEC-BANNED-NET-V6'
```

> If you use zone-based firewall, add matching rules to the relevant zone's input/forward
> rule sets instead. Rule **ordering** is what matters — keep the CrowdSec drop rules before
> your accept rules.

## 4. Container

Place secrets and config under `/config` so they survive reboots:

```bash
sudo mkdir -p /config/crowdsec
sudo install -m 600 -o root -g root vyos-bouncer.conf /config/crowdsec/vyos-bouncer.conf
# edit /config/crowdsec/vyos-bouncer.conf and set VYOS_API_KEY
```

Configure the container:

```bash
set container name cs-bouncer image 'your-registry/vyos-crowdsec-bouncer:latest'
set container name cs-bouncer allow-host-networks
set container name cs-bouncer environment CROWDSEC_LAPI_URL value 'https://lapi.example.com:8080'
set container name cs-bouncer environment API_KEY value '<LAPI_BOUNCER_KEY>'
set container name cs-bouncer device source '/config/crowdsec/vyos-bouncer.conf'
set container name cs-bouncer device destination '/etc/crowdsec/vyos-bouncer.conf'
set container name cs-bouncer restart 'always'
```

Notes:

- `allow-host-networks` gives the container access to `127.0.0.1:443` (the VyOS API) and lets
  `curl` reach LAPI outbound. The bouncer needs **no** capabilities.
- The `CROWDSEC_LAPI_URL` / `API_KEY` env vars fill `${CROWDSEC_LAPI_URL}` / `${API_KEY}` in
  `bouncer.yaml` (expanded by the image entrypoint).
- Optional: `set container name cs-bouncer environment VYOS_BOUNCER_CONF value '/etc/crowdsec/vyos-bouncer.conf'` (already the script default).
- Persistent logs land in `show log container cs-bouncer`.

## 5. Commit

```bash
commit
save
```

## 6. Verify

```bash
# members appear as bans stream in
run show firewall group

# force a test ban from the LAPI host:
cscli decisions add --ip 203.0.113.7 -d 10m
```

## Cleanup / uninstall

```bash
delete container name cs-bouncer
delete firewall ipv4 input filter rule 100
delete firewall ipv4 input filter rule 101
delete firewall ipv6 input filter rule 100
delete firewall ipv6 input filter rule 101
delete firewall ipv4 forward filter rule 100
delete firewall ipv4 forward filter rule 101
delete firewall ipv6 forward filter rule 100
delete firewall ipv6 forward filter rule 101
delete firewall group address-group CROWDSEC-BANNED
delete firewall group ipv6-address-group CROWDSEC-BANNED-V6
delete firewall group network-group CROWDSEC-BANNED-NET
delete firewall group ipv6-network-group CROWDSEC-BANNED-NET-V6
delete service https api
```
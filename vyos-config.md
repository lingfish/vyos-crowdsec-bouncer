# VyOS configuration for the CrowdSec bouncer

This uses the VyOS [remote-group](https://docs.vyos.io/en/1.5/configuration/firewall/groups.html#remote-groups) feature.
No VyOS HTTPS API is involved: the bouncer container only serves a ban list over loopback HTTP and VyOS's
`vyos-domain-resolver` polls it and updates nftables sets in place (no config commit per ban).

All commands run from config mode (`configure`) and are committed once at the end.
`add container image` is the exception: it runs in **op-mode** (before entering `configure`).

## 1. Firewall remote-group + resolver cadence

The bouncer serves a newline-delimited list of active CrowdSec decisions (IPv4/IPv6
addresses and CIDRs) at `http://127.0.0.1:8080/bans.txt`. Define one remote-group and poll it
fast:

```bash
set firewall group remote-group CROWDSEC-BANNED url 'http://127.0.0.1:8080/bans.txt'
set firewall group remote-group CROWDSEC-BANNED description 'CrowdSec active decisions (LAPI mirror)'
set firewall global-options resolver-interval '10'
```

- `resolver-interval 10` refreshes the group every 10s → bans apply within ~10s.
- `resolver-interval` also drives domain-group/FQDN resolution. If you use those and don't
  want them re-resolving every 10s, keep the global default and set a per-group interval
  instead: `set firewall group remote-group CROWDSEC-BANNED interval '60s'` (minimum 60s →
  bans apply within ~60s).
- The list is cached in `/config/firewall/`, so rules keep working if the source is down.

## 2. Firewall policy

The design is **fail-open**: bans apply only where *you* reference the group. The single
requirement is a `drop` rule with `source group remote-group 'CROWDSEC-BANNED'` on each path
you want protected — VyOS keeps `ipv4`/`ipv6` and `input`/`forward` as separate rule trees,
and the same group works inside named rule-sets of a zone-based firewall. Give it a **low
rule number** so it evaluates before any accept/allow rules. One remote-group name covers
both families: VyOS renders `@R_CROWDSEC-BANNED` in IPv4 rules and `@R6_CROWDSEC-BANNED`
in IPv6 rules.

```bash
set firewall ipv4 input filter rule 100 action 'drop'
set firewall ipv4 input filter rule 100 source group remote-group 'CROWDSEC-BANNED'
```

How you structure the rest of your firewall — base chains or zones, default-actions,
management rules — is your call.

## 3. Container

The container's settings come from a bash conf it sources at startup. The starting point is
the example config in this repo:
[`vyos-bouncer.conf`](vyos-bouncer.conf)
([GitHub](https://github.com/lingfish/vyos-crowdsec-bouncer/blob/main/vyos-bouncer.conf)).
The image also ships a copy baked in at `/etc/crowdsec/vyos-bouncer.conf`, but its `LAPI_URL`
and `API_KEY` are **placeholders**, so you must either mount your edited copy over it or set
those two as environment variables (see [§4](#4-environment-variables)).

Place secrets and config under `/config` so they survive reboots:

```bash
sudo mkdir -p /config/crowdsec
curl -fsSL -o /config/crowdsec/vyos-bouncer.conf \
  https://raw.githubusercontent.com/lingfish/vyos-crowdsec-bouncer/main/vyos-bouncer.conf
sudo chmod 600 /config/crowdsec/vyos-bouncer.conf
# edit /config/crowdsec/vyos-bouncer.conf and set LAPI_URL + API_KEY
```

(Alternatively extract the template from the image:
`podman run --rm ghcr.io/lingfish/vyos-crowdsec-bouncer:latest cat /etc/crowdsec/vyos-bouncer.conf`
redirected into the path above.)

Pull the image **first**, in op-mode. VyOS stores container images in podman's local
storage and does **not** auto-pull them at commit — it only warns and skips starting the
container (see [vyos.dev/T4487](https://vyos.dev/T4487)):

```bash
add container image ghcr.io/lingfish/vyos-crowdsec-bouncer:latest
show container image   # confirm it's present
```

Then enter config mode and configure the container:

```bash
set container name cs-bouncer image 'ghcr.io/lingfish/vyos-crowdsec-bouncer:latest'
set container name cs-bouncer allow-host-networks
set container name cs-bouncer volume 'bouncer-conf' source '/config/crowdsec/vyos-bouncer.conf'
set container name cs-bouncer volume 'bouncer-conf' destination '/etc/crowdsec/vyos-bouncer.conf'
set container name cs-bouncer volume 'bouncer-conf' mode 'ro'
set container name cs-bouncer restart 'always'
```

Notes:

- The bouncer serves `bans.txt` on **`127.0.0.1:8080`** (loopback only, host networking);
  `vyos-domain-resolver` fetches it from the same loopback. No container port mapping, no
  capabilities needed.
- `allow-host-networks` gives the container the host loopback (for VyOS to poll) and lets
  `curl` reach LAPI outbound.
- The container holds the **LAPI key** (in the mounted `0600` conf). The VyOS API key from
  the previous design is gone — nothing talks to the VyOS HTTPS API anymore.
- Every conf value can instead be set as a container `environment` entry; env vars always
  win over the conf. See [§4](#4-environment-variables).
- By default the bouncer mirrors **every** decision origin, including the CAPI community
  blocklist (typically tens of thousands of entries). Restrict with `ORIGINS`
  (see [§4](#4-environment-variables)); LAPI filters by origin server-side, so the container
  only pulls matching decisions.
- Persistent logs land in `show log container cs-bouncer`.
- `restart 'always'` means `podman stop` will be immediately resurrected by systemd; use
  `podman restart` for a deliberate cold restart.

## 4. Environment variables

The conf is a bash file in which every value is only applied if not already set in the
environment:

```bash
[ -z "${LAPI_URL:-}" ] && LAPI_URL="https://lapi.example.com:8080"
```

So container `environment` entries always win over the conf, and the bouncer can run on env
vars alone with no conf mount (the baked-in conf yields to each var you set). Set them from
config mode:

```bash
set container name cs-bouncer environment LAPI_URL value 'https://192.0.2.10:8080'
set container name cs-bouncer environment API_KEY value 'xxxxxxxx-xxxx-xxxx-xxxx'
set container name cs-bouncer environment ORIGINS value 'crowdsec,cscli'
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `LAPI_URL` | placeholder in conf | CrowdSec LAPI base URL. Self-signed HTTPS is fine (`curl -k`). |
| `API_KEY` | placeholder in conf | Bouncer key from `cscli bouncers add`. |
| `SCOPES` | `Ip,Range` | Comma-separated decision scopes to mirror. |
| `SKIP_SIMULATED` | `true` | Drop decisions made in simulation mode. |
| `ORIGINS` | empty = all | Comma-separated origin filter applied by LAPI server-side, e.g. `crowdsec,cscli` for local-only (excludes the CAPI blocklist). |
| `BANS_FILE` | `/www/bans.txt` | Where the list is written and served. |
| `REFRESH_SECONDS` | `5` | Refresh loop cadence (seconds). |
| `HTTP_BIND` | `127.0.0.1` | Keep loopback — VyOS polls the list over the host loopback. |
| `HTTP_PORT` | `8080` | Must match the port in the remote-group URL. |
| `VYOS_BOUNCER_CONF` | `/etc/crowdsec/vyos-bouncer.conf` | Path of the conf to source; read from the environment only (before the conf). |

Secrets caveat: env values are visible in `show container` and in `/config/config.boot`, so
keep `API_KEY` in the `0600` mounted conf and use env vars mainly for non-secret tuning
(`ORIGINS`, `REFRESH_SECONDS`, …). A good middle ground is mounting the conf read-only and
overriding just the values you want to vary per host.

## 5. Commit

```bash
commit
save
```

## 6. Verify

```bash
# in op-mode (no `run` prefix interactively):
show firewall group

# list served by the bouncer:
curl http://127.0.0.1:8080/bans.txt

# force a test ban from the LAPI host:
cscli decisions add --ip 203.0.113.7 -d 10m
```

The member appears in the remote-group within one `resolver-interval` (~10s), as
`R_CROWDSEC-BANNED` (IPv4) / `R6_CROWDSEC-BANNED` (IPv6).

## Troubleshooting

- **`WARNING: Image "..." does not exist locally ... Container will not be started!`** —
  you committed before pulling the image. Fix in op-mode, then restart the already-applied
  config (commit will not start it retroactively):

  ```bash
  add container image ghcr.io/lingfish/vyos-crowdsec-bouncer:latest
  restart container cs-bouncer
  show container
  ```

- **Remote-group stays empty / bans never appear** — check `journalctl -u vyos-domain-resolver`
  on the router; confirm `curl http://127.0.0.1:8080/bans.txt` returns the list and that
  `resolver-interval` (or the group's `interval`) is what you expect.

## Cleanup / uninstall

```bash
delete container name cs-bouncer
delete firewall group remote-group CROWDSEC-BANNED
delete firewall global-options resolver-interval
```

Plus any firewall rules of your own that reference `CROWDSEC-BANNED`.
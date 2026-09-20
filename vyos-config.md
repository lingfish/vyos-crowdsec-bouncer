# VyOS configuration for the CrowdSec bouncer

This uses the VyOS [remote-group](https://docs.vyos.io/en/1.5/configuration/firewall/groups.html#remote-groups) feature.
No VyOS HTTPS API is involved: the bouncer container only serves a ban list over loopback HTTP and VyOS's
`vyos-domain-resolver` polls it and updates nftables sets in place (no config commit per ban).

All commands run from config mode (`configure`) and are committed once at the end.
`add container image` is the exception: it runs in **op-mode** (before entering `configure`).

## 1. Firewall remote-group + poll cadence

The bouncer serves a newline-delimited list of active CrowdSec decisions (IPv4/IPv6
addresses and CIDRs) at `http://127.0.0.1:8080/bans.txt`. Define one remote-group and give it
its own 60s poll interval:

```bash
set firewall group remote-group CROWDSEC-BANNED url 'http://127.0.0.1:8080/bans.txt'
set firewall group remote-group CROWDSEC-BANNED description 'CrowdSec active decisions (LAPI mirror)'
set firewall group remote-group CROWDSEC-BANNED interval '60s'
```

Deliberately **do not** set `firewall global-options resolver-interval`: the per-group
`interval` overrides it for this group only, so the global cadence (which also drives
`domain-group`/FQDN rule resolution) stays at VyOS's default.

### The three timing knobs

They sit in a **serial chain** — LAPI → container file → VyOS nftables set — so their delays
add up:

| Knob | Set where | Range / default | What it governs |
|------|-----------|-----------------|-----------------|
| `REFRESH_SECONDS` | bouncer container (conf/env) | shipped default `30` | how often the bouncer re-pulls LAPI's active decisions and atomically rewrites `bans.txt` |
| remote-group `interval` | VyOS, **per group** | `60`–`2419200` s (suffixes `s/m/h/d/w`); falls back to `resolver-interval` | how often `vyos-domain-resolver` re-fetches *this* group's URL |
| `resolver-interval` | VyOS, global | `10`–`3600` s, default `300` | fallback poll for **every** remote-group, and the resolution cadence for `domain-group`/FQDN matches |

- **Worst case ≈ `REFRESH_SECONDS` + group `interval`** (+ fetch/parse time) → about **90s** with
  the values above, ~45s typically (a decision lands mid-window on both loops). Both directions
  ride the same loop, so expiry and manual unbans take just as long as a ban.
- Pacing `REFRESH_SECONDS` below the group `interval` buys nothing: VyOS only looks at the file
  once per `interval`. It is there to keep the served list fresh and to recover quickly after a
  LAPI outage.
- The per-group `interval` floor is **60s**; a sub-minute ban is only possible by lowering the
  *global* `resolver-interval` (min 10s), which also makes every FQDN/domain-group re-resolve at
  that rate. Do that only if you need it and don't use those groups.
- 60s is ample for CrowdSec remediation: a decision is minted seconds after the offending burst,
  and scanners/brute-forcers run for minutes — so the difference between 15s and 90s enforcement is
  academic. Note also that with the usual `state-policy established accept`, a ban does not
  interrupt traffic already in flight (that chain is evaluated before the rules); it blocks new
  connections only. Drop established traffic yourself if you want sessions killed on ban.
- VyOS caches the fetched list at `/config/firewall/R_CROWDSEC-BANNED.txt` and keeps using the
  cached copy when a poll fails, so rules survive a container or LAPI outage. Failed polls retry
  every `min(interval, resolver-interval)`, not at the full group interval.

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
| `REFRESH_SECONDS` | `30` | Refresh loop cadence (seconds). Only needs to be ≤ the group's `interval`; see [§1](#1-firewall-remote-group--poll-cadence). |
| `HTTP_BIND` | `127.0.0.1` | Keep loopback — VyOS polls the list over the host loopback. |
| `HTTP_PORT` | `8080` | Must match the port in the remote-group URL. |
| `VYOS_BOUNCER_CONF` | `/etc/crowdsec/vyos-bouncer.conf` | Path of the conf to source; read from the environment only (before the conf). |

Secrets caveat: container `environment` values are part of the commit config, so they show up in
`show configuration` (any admin, op-mode) and in `/config/config.boot` — and in every config
archive under `/config/archive/`, since VyOS retains all committed configs. `sudo podman inspect`
shows the container's runtime env too. (`show container` only lists running containers —
`podman ps -a` — and does **not** reveal env values.) Keep `API_KEY` in the `0600` mounted conf
so it never enters the config tree or the archives; that is defense-in-depth rather than a hard
requirement — this key is read-only against your own LAPI, so env-only deployment is fine if you
accept it appearing in the config. Use env vars mainly for non-secret tuning (`ORIGINS`,
`REFRESH_SECONDS`, …). A good middle ground is mounting the conf read-only and overriding just
the values you want to vary per host.

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

The member appears in the remote-group within one group `interval` (~60s, worst ~90s including
`REFRESH_SECONDS`), as `R_CROWDSEC-BANNED` (IPv4) / `R6_CROWDSEC-BANNED` (IPv6).

## Troubleshooting

- **`WARNING: Image "..." does not exist locally ... Container will not be started!`** —
  you committed before pulling the image. Fix in op-mode, then restart the already-applied
  config (commit will not start it retroactively):

  ```bash
  add container image ghcr.io/lingfish/vyos-crowdsec-bouncer:latest
  restart container cs-bouncer
  show container
  ```

- **Remote-group stays empty / bans never appear** — confirm `curl http://127.0.0.1:8080/bans.txt`
  returns the list, then check that the group's own `interval` is what you expect
  (`show configuration commands | match remote-group`); the global `resolver-interval` only matters
  as a fallback when no per-group `interval` is set. Look at `journalctl -u vyos-domain-resolver`
  on the router for fetch errors, and `sudo systemctl restart vyos-domain-resolver.service` (from
  the VyOS shell) to force an immediate poll instead of waiting for the next one.

## Cleanup / uninstall

```bash
delete container name cs-bouncer
delete firewall group remote-group CROWDSEC-BANNED
# only needed if you lowered the global cadence for sub-minute enforcement:
delete firewall global-options resolver-interval
```

Plus any firewall rules of your own that reference `CROWDSEC-BANNED`. VyOS leaves the cached list
at `/config/firewall/R_CROWDSEC-BANNED.txt`; delete it once the group is gone.
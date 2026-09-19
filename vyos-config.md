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

Place secrets and config under `/config` so they survive reboots:

```bash
sudo mkdir -p /config/crowdsec
sudo install -m 600 -o root -g root vyos-bouncer.conf /config/crowdsec/vyos-bouncer.conf
# edit /config/crowdsec/vyos-bouncer.conf and set LAPI_URL + API_KEY
```

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
- `LAPI_URL` / `API_KEY` can instead be set as container `environment` entries; the conf is
  only a fallback (each value yields to an already-set env var).
- By default the bouncer mirrors **every** decision origin, including the CAPI community
  blocklist (typically tens of thousands of entries). To restrict to local decisions, set
  `ORIGINS` to a comma-separated origin list — as an env entry or in the conf — e.g.
  `set container name cs-bouncer environment ORIGINS value 'crowdsec,cscli'`. LAPI filters
  by origin server-side, so the container only pulls matching decisions.
- Persistent logs land in `show log container cs-bouncer`.
- `restart 'always'` means `podman stop` will be immediately resurrected by systemd; use
  `podman restart` for a deliberate cold restart.

## 4. Commit

```bash
commit
save
```

## 5. Verify

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
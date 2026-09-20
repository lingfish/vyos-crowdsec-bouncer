# Changelog

## [0.3.0] - 2026-09-19

### Changed
- **Recommended enforcement cadence is now the per-group remote-group `interval '60s'`** instead of
  shortening the global `firewall global-options resolver-interval` to `10`. The global stays at
  VyOS's default (300s), so ban polling no longer churns `domain-group`/FQDN resolution. Worst-case
  ban **and** unban latency becomes ~90s (`REFRESH_SECONDS` + group `interval`) instead of ~15s —
  still comfortably inside the window that matters for CrowdSec remediation, and with the usual
  `state-policy established accept` a ban only blocks new connections, never in-flight traffic.
- **`REFRESH_SECONDS` default raised `5` → `30`** (`vyos-bouncer.conf`, `entrypoint.sh`). It only
  needs to be at or below the group `interval`; deployments pinning it via conf or env are
  unaffected.
- `vyos-config.md` / `README.md`: new "three timing knobs" table (ranges and defaults taken from
  upstream vyos-1x: `resolver-interval` 10–3600s default 300s, remote-group `interval`
  60–2419200s), plus refreshed latency claims, troubleshooting (cached
  `/config/firewall/R_CROWDSEC-BANNED.txt`, retry cadence, forcing an immediate poll with
  `systemctl restart vyos-domain-resolver.service`) and uninstall steps.
- **Lab rebased onto the documented cadence** (not re-run yet): `lab/provision.sh` sets the group
  `interval '60s'` and ships `REFRESH_SECONDS=30`; `lab/test-expiry.sh` uses a `-d 3m` ban (a 1m
  ban could expire before VyOS installs it at this cadence) and membership windows are raised to
  150s/300s. See the cadence caveat in `docs/lab-validation.md`.

## [0.2.1] - 2026-09-19

### Added

- **`ORIGINS` decision-origin filter.** New config value (comma-separated origins, default
  empty = all). When set, the bouncer appends `&origins=<url-encoded>` to each LAPI fetch so
  CrowdSec filters by origin server-side. Lets deployments exclude the CAPI community
  blocklist and mirror only local decisions (e.g. `ORIGINS="crowdsec,cscli"`).

## [0.2.0] - 2026-09-18

### Added
- VyOS firewall `remote-group` integration: the bouncer serves a newline-delimited ban list over
  loopback HTTP (`127.0.0.1:8080/bans.txt`) and VyOS applies it to the
  `R_CROWDSEC-BANNED` / `R6_CROWDSEC-BANNED` nftables sets in place.
- `vyos-bouncer.sh` fetches LAPI's **active** decisions (`GET /v1/decisions`, scopes `Ip,Range`,
  simulated excluded), writing `BANS_FILE` atomically and only on success.
- `entrypoint.sh` gates httpd on the first successful refresh, then refreshes every
  `REFRESH_SECONDS` and serves the list.
- `vyos-bouncer.conf` provides `LAPI_URL` / `API_KEY`, scopes, simulated filtering, refresh cadence,
  and HTTP settings; environment variables override the shipped defaults.
- The integration harness validates exact list contents, simulated exclusion, sorting/deduplication,
  origin filtering, and last-good-on-failure behavior.
- Pull-based expiry: decisions expire or delete implicitly because LAPI returns only active entries.

### Changed
- Ban updates are applied through the remote-group's nftables sets, so they do not require a
  configuration update for each decision.

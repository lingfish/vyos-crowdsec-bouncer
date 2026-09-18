# Changelog

## [0.2.0] - 2026-09-18

### Changed (breaking)
- **Redesigned around VyOS firewall `remote-group`.** The bouncer no longer calls the VyOS HTTPS
  API or commits config. It serves a newline-delimited ban list over loopback HTTP
  (`127.0.0.1:8080/bans.txt`) that VyOS's `vyos-domain-resolver` polls and applies to the
  `R_CROWDSEC-BANNED` / `R6_CROWDSEC-BANNED` nftables sets **in place — no commit per ban**.
- **Dropped the stock `crowdsecurity/custom-bouncer`.** The image is now minimal Alpine
  (`Dockerfile`) running busybox `httpd` (`busybox-extras`); `bouncer.yaml` was removed.
- `vyos-bouncer.sh` is now a fetch-and-write script (`refresh` / `--check`) that mirrors LAPI's
  **active** decisions (`GET /v1/decisions`, scopes `Ip,Range`, simulated excluded), writing
  `BANS_FILE` atomically and only on success.
- New `entrypoint.sh`: gates httpd on the first successful refresh (so a restart during a LAPI
  outage never serves an empty list), then refreshes every `REFRESH_SECONDS` and serves.
- `vyos-bouncer.conf`: now `LAPI_URL` / `API_KEY` (plus scopes, simulated flag, refresh cadence,
  HTTP bind); env-var overrides now genuinely win over the file.
- `vyos-config.md`: remote-group + `resolver-interval 10` + `source group remote-group` rules;
  no HTTPS API, no VyOS API key.

### Fixed
- **Per-decision config-commit storm.** The old flock-based batching assumed the
  `custom-bouncer` invoked the script concurrently; it is strictly serial, so every decision
  became its own `POST /configure` commit (1320 decisions → 1320 commits over ~2h). The
  remote-group design has no per-ban commits at all.
- The old test's batching assertion (`REQS <= 5`) was too loose to catch that; the new harness
  asserts exact list contents, simulated exclusion, and last-good-on-failure.

### Added
- `test/mock-lapi.py` (replaces `mock-vyos-api.py`) with a `MOCK_FAIL=1` outage mode.
- Pull-based expiry: decisions expire/delete implicitly because LAPI only returns active ones.

## [0.1.0] - 2026-09-17

Initial release (original HTTPS API + address-group design).
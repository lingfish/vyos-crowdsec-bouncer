# Changelog

## [0.1.0] - 2026-09-17

Initial release.

### Added
- `vyos-bouncer.sh` decision → VyOS firewall group translator: IPv4/IPv6 addresses and
  CIDRs mapped to address-groups / network-groups via the VyOS HTTPS API.
- Fail-open spooled batching: ops coalesce into one `POST /configure` per quiet window
  (one VyOS commit), guarded by `flock`; API retries on failure.
- `--dry-run` / `-n` mode that logs the intended call without POSTing.
- Container image based on stock `crowdsecurity/custom-bouncer` (`Dockerfile`,
  `bouncer.yaml`, `vyos-bouncer.conf`).
- `vyos-bouncer.conf`: bash-sourced config with per-value env-var overrides
  (`VYOS_BOUNCER_CONF`).
- Integration test harness against a mock VyOS API (`make test` / `make dry-run`).
- Reproducible isolated libvirt lab (`make lab-up` / `lab-test-expiry` / `lab-test-ipv6`
  / `lab-test-forward` / `lab-down`).
- CI: build + `make test` + `make dry-run` on every push/PR; publish to GHCR on `v*`
  tags.
- Docs: `vyos-config.md`, `README.md`, `docs/alternatives.md`, `docs/lab-validation.md`.

### Fixed
- IPv6 group targeting uses `ipv6-address-group` / `ipv6-network-group`.
- Config file mounted with `volume` (not `device`), which rejects regular files.
- Alpine base image includes `bash` (the script requires it).
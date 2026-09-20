# AGENTS.md

## What this is

CrowdSec bouncer that runs as a VyOS container and enforces LAPI decisions by serving a ban
list that VyOS consumes as a firewall **remote-group**. The only custom code is
`vyos-bouncer.sh` (+ `entrypoint.sh`); the image is minimal Alpine running busybox `httpd`.
It is a passive list mirror: it makes no host firewall writes and no config commits for bans.

## Commands

- `make test` — integration test of `vyos-bouncer.sh` against `test/mock-lapi.py` (mock
  `GET /v1/decisions`). Needs `python3` and `bash`; no container/VyOS required. Sets
  `VYOS_BOUNCER_CONF` itself.
- `make check` — same harness, only exercises `--check` mode.
- `make build` — `podman build` by default (`ENGINE=podman`). The image must keep
  `apk add curl bash jq busybox-extras` (curl/jq for the refresh, busybox-extras for httpd).
- `make push` — publishes to `ghcr.io/lingfish/vyos-crowdsec-bouncer` (set `REGISTRY` to
  override; requires `podman login` to GHCR). CI builds+publishes on `v*` tags only.
- No CI, lint, or test framework in this repo; the only checks are `make test`/`make check`.

## Lab harness (`make lab-up` / `lab-test-expiry` / `lab-test-ipv6` / `lab-test-forward` / `lab-down` / `lab`)

- Reproducible end-to-end lab in `lab/`: boots the latest VyOS rolling nightly
  under libvirt on an **isolated `192.0.2.0/24` network** (no LAN/internet), configures
  VyOS per `vyos-config.md`, deploys a host LAPI + the bouncer, and runs the three scenario
  tests (`lab-test-expiry`, `lab-test-ipv6`, `lab-test-forward`). Needs host `python3`+`pexpect`,
  `virsh` (libvirt group), `/dev/kvm`, podman.
- Lab gotchas (see `lab/README.md`): the guest console is a raw TCP chardev driven by
  `lab/serial.py` (pexpect); **non-interactive SSH op commands don't work on this VyOS
  build** — use `guest_op`/`guest_root` (serial); avoid `| grep -q` under `set -o pipefail`.
- All three scenario tests were validated green against the remote-group design (see
  `docs/lab-validation.md`), but under the lab's *fast* cadence (`resolver-interval 10`); the lab
  now uses the documented production cadence (per-group `interval '60s'`, `REFRESH_SECONDS 30`)
  and has **not been re-run** since. Re-validate with `make lab` after `make lab-up` before
  quoting any latency numbers.

## Bouncer script contract

- `vyos-bouncer.sh refresh` — `GET /v1/decisions?scope=Ip` and `?scope=Range` against `LAPI_URL`
  with `X-Api-Key: $API_KEY` (`curl -k`, fail on HTTP error), `jq` to drop `simulated != true`
  decisions and extract `.value`, `sort -u`, then write `BANS_FILE` **atomically only on
  success**. On any failure: leave the file untouched, exit non-zero. When `ORIGINS` is set
  (comma-separated), `&origins=<url-encoded>` is appended so LAPI filters by origin
  server-side (e.g. `crowdsec,cscli` for local-only, excluding the CAPI blocklist).
- `vyos-bouncer.sh --check` — same fetch, print the list to stdout, never write.
- Pull-based: LAPI only returns active (non-expired) decisions, so add/del/expiry are implicit.
- `entrypoint.sh` — retries `refresh` until it succeeds (gate), then loops `refresh` every
  `REFRESH_SECONDS` and `exec httpd -f -p $HTTP_BIND:$HTTP_PORT -h /www`. Gate exists so a
  restart during a LAPI outage never serves an empty list (VyOS keeps its cached copy).
- Fail-open by design; the script deliberately omits `set -e` (uses `set -u` + `pipefail`).

## Config

- `vyos-bouncer.conf` is a **bash file that the script `source`s** (not YAML/INI). Override its
  path with `VYOS_BOUNCER_CONF`. Every value only applies if **not already set in the
  environment**, so env vars win (`[ -z "${VAR:-}" ] && VAR=...`).
- Values: `LAPI_URL`, `API_KEY`, `SCOPES` (default `Ip,Range`), `SKIP_SIMULATED` (default
  `true`), `ORIGINS` (default empty = all origins; comma-separated local-only filter, see
  above), `BANS_FILE` (default `/www/bans.txt`), `REFRESH_SECONDS` (30), `HTTP_BIND`
  (`127.0.0.1`), `HTTP_PORT` (8080).
- Enforcement latency is a **serial chain** of three knobs, so their delays add: `REFRESH_SECONDS`
  (container pulls LAPI) → VyOS remote-group `interval` (60–2419200s, min **60s**) → nft sets.
  The global `firewall global-options resolver-interval` (10–3600s, default **300s**) is only the
  fallback when a group has no `interval`, and it also paces `domain-group`/FQDN resolution — the
  documented setup deliberately leaves it alone. Worst case ≈ `REFRESH_SECONDS` + `interval` (~90s).
- `HTTP_BIND` must stay on loopback: the container runs with `allow-host-networks` and VyOS's
  `vyos-domain-resolver` polls the list at `http://127.0.0.1:8080/bans.txt`.

## Testing notes

- Mock listens on hardcoded port `18444`; the harness writes a temp conf and asserts scope
  filtering, IPv4/IPv6/CIDR entries, simulated exclusion, sorting/dedup, and that a LAPI
  failure (`MOCK_FAIL=1`) leaves the last-good list untouched and exits non-zero.
- Manual spot-check: `VYOS_BOUNCER_CONF=test/tmp/... ./vyos-bouncer.sh --check`

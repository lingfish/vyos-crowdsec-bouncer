# AGENTS.md

## What this is

CrowdSec bouncer that runs as a VyOS container and turns LAPI decisions into VyOS firewall
address-group members via the VyOS HTTPS API. The only custom code is `vyos-bouncer.sh`;
`bouncer.yaml`, `Dockerfile`, and the base image (`crowdsecurity/custom-bouncer`) are stock.

## Commands

- `make test` — integration test of `vyos-bouncer.sh` against `test/mock-vyos-api.py`. Needs
  `python3` (mock server) and `bash`; no VyOS required. Sets `VYOS_BOUNCER_CONF` itself.
- `make dry-run` — same harness, only exercises `--dry-run`.
- `make build` — `podman build` by default (`ENGINE=podman`). Image base is Alpine: the
  Dockerfile must keep `apk add curl bash` or the script breaks.
- `make push` — publishes to `ghcr.io/lingfish/vyos-crowdsec-bouncer` (set `REGISTRY` to
  override; requires `podman login` to GHCR). CI builds+publishes on `v*` tags only.
- No CI, lint, or test framework in this repo; the only checks are `make test`/`make dry-run`.

## Lab harness (`make lab-up` / `lab-test-expiry` / `lab-down`)

- Reproducible end-to-end lab in `lab/`: boots the latest VyOS rolling nightly
  under libvirt on an **isolated `192.0.2.0/24` network** (no LAN/internet), configures
  VyOS per `vyos-config.md`, deploys a host LAPI + the bouncer, and runs the issue-3
  expiry test. Needs host `python3`+`pexpect`, `virsh` (libvirt group), `/dev/kvm`, podman.
- Lab gotchas (see `lab/README.md`): the guest console is a raw TCP chardev driven by
  `lab/serial.py` (pexpect); **non-interactive SSH op commands don't work on this VyOS
  build** — use `guest_op`/`guest_root` (serial); avoid `| grep -q` under `set -o pipefail`.

## Bouncer script contract

- Invoked once per decision as `vyos-bouncer.sh <add|del> <value> [duration] [reason] [json]`.
  `bouncer.yaml` sets `feed_via_stdin: false`, so decisions arrive as args, never stdin.
- Value→group mapping: IPv4 → `address-group`, IPv6 → `ipv6-address-group`, CIDR →
  `network-group` / `ipv6-network-group` (names from config).
- Ops are spooled then flushed as one batched `POST /configure` under a `flock`, so each quiet
  window = one VyOS commit. Design is fail-open; the script deliberately omits `set -e`.
- `--dry-run` / `-n` logs the intended call and skips the POST.

## Config

- `vyos-bouncer.conf` is a **bash file that the script `source`s** (not YAML/INI). Override its
  path with `VYOS_BOUNCER_CONF`; every value can also be overridden via env vars.
- `bouncer.yaml` is env-templated by the official image (`${CROWDSEC_LAPI_URL}`, `${API_KEY}`).
- The script calls curl with `-k` (self-signed TLS). `VYOS_API_KEY` has full VyOS API
  permissions — the API must stay bound to loopback on the VyOS side.

## Testing notes

- Mock listens on hardcoded port `18443`; the harness writes a temp conf with short batch
  windows and asserts group mapping, API-key presence, and batching (5 ops → ≤5 requests).
- Manual spot-check: `VYOS_BOUNCER_CONF=test/tmp/... ./vyos-bouncer.sh add 203.0.113.1 3600 r '{}'`
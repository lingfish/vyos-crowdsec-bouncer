# VyOS CrowdSec Bouncer

A CrowdSec remediation component that runs as a **VyOS container** and enforces LAPI decisions
by feeding a **firewall remote-group** that VyOS polls and applies as nftables set members.

The CrowdSec Security Engine (agent + LAPI) is expected to run **centrally** — this project only
ships the bouncer. The only custom code is `vyos-bouncer.sh`; the container image is a minimal
Alpine + busybox `httpd` that mirrors LAPI's active decisions.

```
Central CrowdSec LAPI (external)
        ▲  GET /v1/decisions?scope=Ip|Range (X-Api-Key)
        │
VyOS container: minimal Alpine, busybox httpd on 127.0.0.1:8080
        │  serves /bans.txt (newline-delimited Ip/CIDR list, refreshed every 5s)
        ▼
vyos-domain-resolver (VyOS): polls the remote-group URL (resolver-interval 10)
        │  updates R_CROWDSEC-BANNED / R6_CROWDSEC-BANNED nft sets in place — NO commit
        ▼
VyOS firewall rules: source group remote-group CROWDSEC-BANNED → drop (input + forward)
```

## Why this design

- **No config commits for bans.** VyOS's `remote-group` mechanism re-renders only the affected
  nftables sets (`R_*` / `R6_*`) on a timer — adding or removing a decision never triggers a
  VyOS `commit`. This is the whole point: per-decision commits (the previous design's approach)
  churned the whole firewall config on every ban.
- **Pull-based, so expiry is free.** `GET /v1/decisions` only returns *active* decisions, so a
  decision that expires or is deleted simply disappears from the next served list — no del
  events, no TTL bookkeeping, no missed-delete accumulation.
- **Fail-open.** If LAPI is unreachable, the container keeps serving its last-good list and VyOS
  keeps its cached copy, so existing bans persist and nothing is silently unlocked. If the
  container starts during a LAPI outage it refuses to serve until it has a fresh list, so it
  can never present an empty list that would clear all bans.
- **Stock where it counts**: LAPI streaming, filtering and the remote-group refresh are all
  stock CrowdSec / VyOS. We only write a fetch-and-serve script.
- **No privileged access**: no `net-admin`, no direct nftables manipulation, no VyOS HTTPS API
  or API key.

### Trade-offs

- **Latency**: a ban takes up to one `resolver-interval` to apply (~10s with the recommended
  `resolver-interval 10`). The container refreshes its list every 5s, so the total is ~5–15s.
  Use the per-group `interval` (min 60s) if you don't want the global resolver-interval at 10s.
- **No Prometheus metrics** from the stock bouncer (dropped with the custom-bouncer image).

## Components

| File | Purpose |
|------|---------|
| `vyos-bouncer.sh` | fetch active LAPI decisions, write the list atomically (`refresh` / `--check`) |
| `entrypoint.sh` | gate httpd on first successful refresh, run the refresh loop, serve |
| `vyos-bouncer.conf` | LAPI URL/key, scopes, refresh cadence, HTTP bind (mounted, `0600`) |
| `Dockerfile` | Alpine + `curl`/`bash`/`jq`/`busybox-extras`, loopback `httpd` PID1 |
| [`vyos-config.md`](vyos-config.md) | copy-paste VyOS configuration |
| `test/` | mock LAPI + integration test harness |
| `lab/` | reproducible isolated VyOS + LAPI lab (`make lab-up` / `lab-test-expiry` / `lab-down`) |
| [`docs/lab-validation.md`](docs/lab-validation.md) | end-to-end results against a real VyOS + LAPI (pre-remote-group) |

## Validation

See [`docs/lab-validation.md`](docs/lab-validation.md) and `lab/` for the reproducible
harness (`make lab`). **Note:** the recorded validation predates the remote-group redesign;
the lab tests are being re-validated against the new architecture (ban → drop, unban →
recovery, short-TTL auto-expiry, IPv6, forward path).

## CI / published image

GitHub Actions (`.github/workflows/ci.yml`) runs on every push and PR:

- `make test` + `make check` (mock LAPI, no VyOS/container needed).
- Builds the image on every run and, on a `v*` tag, publishes it to
  [`ghcr.io/lingfish/vyos-crowdsec-bouncer`](https://github.com/lingfish/vyos-crowdsec-bouncer/pkgs).

Tags published to GHCR for a `v1.2.3` tag: `1.2.3`, `1.2`, `1`, `latest`.

To cut a release:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

PRs build the image but never push. `make push` publishes a locally built image to the same
registry (requires a `podman login` to GHCR first).

## Quick start

1. **Register the bouncer on your central LAPI** and note the API key:

   ```bash
   cscli bouncers add vyos-bouncer -o raw
   ```

2. **Configure VyOS** per [`vyos-config.md`](vyos-config.md): the remote-group + `resolver-interval`,
   the drop rules referencing it, and the container definition.

3. **Get the image** — either pull the published build or build locally:

   ```bash
   # published image (see "CI / published image" below)
   podman pull ghcr.io/lingfish/vyos-crowdsec-bouncer:latest

   # or build locally (podman)
   make build
   ```

   On the VyOS box the image is pulled via `add container image` (op-mode), not `podman pull` —
   see [`vyos-config.md`](vyos-config.md). The image is **linux/amd64 only**; an arm64 VyOS
   router will refuse to run it.

4. **Test locally** (no VyOS needed):

   ```bash
   make test   # runs vyos-bouncer.sh against a mock LAPI
   make check  # prints the list the bouncer would serve
   ```

## Bouncer behavior (`vyos-bouncer.sh`)

- `vyos-bouncer.sh refresh` — fetch `scope=Ip` and `scope=Range` decisions from LAPI
  (`GET /v1/decisions`, `X-Api-Key`), skip simulated ones, dedupe/sort, write
  `BANS_FILE` atomically. Only writes on a fully successful fetch; on failure the existing
  list is left untouched and the script exits non-zero.
- `vyos-bouncer.sh --check` — same fetch, prints the list to stdout without writing.
- `entrypoint.sh` — refuses to serve until the first successful refresh, then runs the refresh
  loop every `REFRESH_SECONDS` (5) and `exec`s busybox `httpd -f -p 127.0.0.1:8080 -h /www`.
- Values are sourced from `vyos-bouncer.conf`; every value yields to an already-set env var
  (`VYOS_BOUNCER_CONF` overrides the config path).

## Security

- The container holds the **LAPI key** in a `0600` conf mounted from `/config`. Keep the LAPI
  key scoped to this bouncer.
- busybox `httpd` binds **loopback only** (`127.0.0.1:8080`), and the container uses
  `allow-host-networks`, so the served list is only reachable by VyOS itself — it is not
  exposed on the WAN.
- The container needs **no capabilities** and never touches nftables or the VyOS config.

## Ops / troubleshooting

- Bouncer + refresh logs: `show log container cs-bouncer` (or podman logs).
- Inspect current bans: `run show firewall group` (look at the `CROWDSEC-BANNED` remote group).
- Inspect the served list: `curl http://127.0.0.1:8080/bans.txt`.
- Manual list: `podman exec cs-bouncer vyos-bouncer.sh --check`.
- Force a refresh early: `restart vyos-domain-resolver` (VyOS host) — also re-applies the group.

## License

MIT
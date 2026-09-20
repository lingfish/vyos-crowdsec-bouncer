# VyOS CrowdSec Bouncer

A CrowdSec **blocklist-mirror bouncer** that runs as a **VyOS container**: it mirrors LAPI's
active decisions to a served list, and a VyOS **firewall remote-group** polls that list and
applies it as nftables set members. It fills the same role as CrowdSec's own
[blocklist-mirror bouncer](https://github.com/crowdsecurity/crowdsec-blocklist-mirror) — a
*passive* bouncer that exposes active decisions as a consumable list — built on stock VyOS
machinery.

The CrowdSec Security Engine (agent + LAPI) is expected to run **centrally** — this project only
ships the bouncer. The only custom code is `vyos-bouncer.sh`; the container image is a minimal
Alpine + busybox `httpd` that mirrors LAPI's active decisions.

```
Central CrowdSec LAPI (external)
        ▲  GET /v1/decisions?scope=Ip|Range (X-Api-Key)
        │
VyOS container: minimal Alpine, busybox httpd on 127.0.0.1:8080
        │  serves /bans.txt (newline-delimited Ip/CIDR list, refreshed every 30s)
        ▼
vyos-domain-resolver (VyOS): polls the remote-group URL (group interval 60s)
        │  updates R_CROWDSEC-BANNED / R6_CROWDSEC-BANNED nft sets in place — NO commit
        ▼
VyOS firewall rules: source group remote-group CROWDSEC-BANNED → drop (input + forward)
```

## Quick start

1. **Register the bouncer on your central LAPI** and note the API key:

   ```bash
   cscli bouncers add vyos-bouncer -o raw
   ```

2. **Configure VyOS** per [`vyos-config.md`](vyos-config.md): pull the published image in
   op-mode (`add container image`), define the remote-group + resolver cadence, the drop
   rules referencing it, and the container configured with its environment variables (the
   default; a mounted conf is optional). Commit and save.

3. **Verify** — force a test ban from the LAPI host:

   ```bash
   cscli decisions add --ip 203.0.113.7 -d 10m
   ```

   It appears in `show firewall group` within one group `interval` (~60s; worst ~90s) and
   disappears on its own at expiry. More checks in [`vyos-config.md`](vyos-config.md).

## Why this design

- **No config commits for bans.** VyOS's `remote-group` mechanism re-renders only the affected
  nftables sets (`R_*` / `R6_*`) on a timer — adding or removing a decision never triggers a
  VyOS `commit`. This keeps ban updates isolated to the affected firewall sets instead of
   churning the whole firewall config on every ban.
- **Pull-based, so expiry is free.** `GET /v1/decisions` only returns *active* decisions, so a
  decision that expires or is deleted simply disappears from the next served list — no del
  events, no TTL bookkeeping, no missed-delete accumulation.
- **Fail-open.** If LAPI is unreachable, the container keeps serving its last-good list and VyOS
  keeps its cached copy, so existing bans persist and nothing is silently unlocked. If the
  container starts during a LAPI outage it refuses to serve until it has a fresh list, so it
  can never present an empty list that would clear all bans.
- **Stock where it counts**: LAPI streaming, filtering and the remote-group refresh are all
  stock CrowdSec / VyOS. We only write a fetch-and-serve script.
- **No privileged access**: no `net-admin`, no direct nftables manipulation, and no host firewall
  writes. The container only needs the LAPI credential.

### Trade-offs

- **Latency**: with the recommended cadence a ban — and its expiry/unban — lands in **~45s typical,
  ~90s worst case**. Three serial knobs govern it (LAPI → container file → VyOS nftables set), so
  their delays add:

  | Knob | Set where | Default | Controls |
  |------|-----------|---------|----------|
  | `REFRESH_SECONDS` | bouncer container | `30` s | how often the list is re-pulled from LAPI and `bans.txt` rewritten |
  | remote-group `interval` | VyOS, per group | unset → global; min `60` s | how often VyOS re-fetches this group's URL |
  | `resolver-interval` | VyOS, global | `300` s | fallback poll for every remote-group, and FQDN/`domain-group` resolution rate |

  That delay is comfortably good enough for remediation: a decision is minted seconds after the
  offending burst, and scanners and brute-force runs last minutes, so 15s vs 90s is not observable.
  (And with the usual `state-policy established accept`, a ban blocks *new* connections only — it
  never interrupted in-flight traffic at 15s either.) Sub-minute enforcement requires lowering the
  **global** `resolver-interval` (min 10s), which also re-resolves every FQDN/domain group at that
  rate — see [`vyos-config.md`](vyos-config.md#1-firewall-remote-group--poll-cadence).
- **No Prometheus metrics**; metrics are outside the scope of this passive mirror.

## Components

| File | Purpose |
|------|---------|
| `vyos-bouncer.sh` | fetch active LAPI decisions, write the list atomically (`refresh` / `--check`) |
| `entrypoint.sh` | gate httpd on first successful refresh, run the refresh loop, serve |
| `vyos-bouncer.conf` | shipped defaults (env-var overridable); mount a `0600` copy for the LAPI key |
| `Dockerfile` | Alpine + `curl`/`bash`/`jq`/`busybox-extras`, loopback `httpd` PID1 |
| [`vyos-config.md`](vyos-config.md) | copy-paste VyOS configuration |
| `test/` | mock LAPI + integration test harness |
| `lab/` | reproducible isolated VyOS + LAPI lab (`make lab-up` / `lab-test-expiry` / `lab-test-ipv6` / `lab-test-forward` / `lab-down`) |
| [`docs/lab-validation.md`](docs/lab-validation.md) | end-to-end results against a real VyOS + LAPI (remote-group design, all scenarios green) |

## Bouncer behavior (`vyos-bouncer.sh`)

- `vyos-bouncer.sh refresh` — fetch `scope=Ip` and `scope=Range` decisions from LAPI
  (`GET /v1/decisions`, `X-Api-Key`), skip simulated ones, dedupe/sort, write
  `BANS_FILE` atomically. Only writes on a fully successful fetch; on failure the existing
  list is left untouched and the script exits non-zero. Set `ORIGINS` (comma-separated,
  e.g. `crowdsec,cscli`) to have LAPI filter decisions by origin server-side — empty means
  all origins, including the CAPI community blocklist.
- `vyos-bouncer.sh --check` — same fetch, prints the list to stdout without writing.
- `entrypoint.sh` — refuses to serve until the first successful refresh, then runs the refresh
  loop every `REFRESH_SECONDS` (30) and `exec`s busybox `httpd -f -p 127.0.0.1:8080 -h /www`.
- Values are sourced from `vyos-bouncer.conf`; every value yields to an already-set env var
  (`VYOS_BOUNCER_CONF` overrides the config path).

## Security

- The **LAPI key** goes in as a container env var by default, or in a `0600` conf mounted from
  `/config` to keep it out of the commit config. Keep the key scoped to this bouncer.
- busybox `httpd` binds **loopback only** (`127.0.0.1:8080`), and the container uses
  `allow-host-networks`, so the served list is only reachable by VyOS itself — it is not
  exposed on the WAN.
- The container needs **no capabilities** and never touches nftables or the VyOS config.

## Ops / troubleshooting

- Bouncer + refresh logs: `show log container cs-bouncer` (or podman logs).
- Inspect current bans: `run show firewall group` (look at the `CROWDSEC-BANNED` remote group).
- Inspect the served list: `curl http://127.0.0.1:8080/bans.txt`.
- Manual list: `podman exec cs-bouncer vyos-bouncer.sh --check`.
- Force a refresh early: `sudo systemctl restart vyos-domain-resolver.service` (VyOS shell) —
  re-polls every remote-group immediately.

## CI / published image

GitHub Actions (`.github/workflows/ci.yml`) runs on every push and PR:

- `make test` + `make check` (mock LAPI, no VyOS/container needed).
- Builds the image on every run and, on a `v*` tag, publishes it to
  [`ghcr.io/lingfish/vyos-crowdsec-bouncer`](https://github.com/lingfish/vyos-crowdsec-bouncer/pkgs).

Tags published to GHCR for a `v1.2.3` tag: `1.2.3`, `1.2`, `1`, `latest`. The image is
**linux/amd64 only**; an arm64 VyOS router will refuse to run it.

To cut a release:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

PRs build the image but never push. `make push` publishes a locally built image to the same
registry (requires a `podman login` to GHCR first).

## Development & testing

```bash
make test   # integration test of vyos-bouncer.sh against a mock LAPI (test/mock-lapi.py)
make check  # same harness, only exercises --check mode
make build  # build the container image locally (ENGINE=podman by default)
```

End-to-end lab: `make lab-up` boots the latest VyOS rolling nightly under libvirt on an
isolated `192.0.2.0/24` network with a host LAPI and the bouncer; `make lab` then runs the
three scenario tests (short-TTL expiry, IPv6, forward-path). See
[`lab/README.md`](lab/README.md) for prerequisites and gotchas; `make lab-down` tears it
down.

## Validation

See [`docs/lab-validation.md`](docs/lab-validation.md) and `lab/` for the reproducible
harness (`make lab`). Validated green against the remote-group design on VyOS rolling
`2026.09.17-0028`: short-TTL auto-expiry, IPv6 ban/unban, and forward-path drops all pass.

## License

MIT

# VyOS CrowdSec Bouncer

A CrowdSec remediation component that runs as a **VyOS container** and enforces LAPI decisions
by adding/removing IPs in VyOS firewall address-groups via the **VyOS HTTPS API**.

The CrowdSec Security Engine (agent + LAPI) is expected to run **centrally** — this project only
ships the bouncer. The only custom code is `vyos-bouncer.sh`; everything else is stock CrowdSec.

```
Central CrowdSec LAPI (external)
        │  decisions stream (api_key)
        ▼
VyOS container: crowdsecurity/custom-bouncer  (official image)
        │  invokes vyos-bouncer.sh
        ▼
VyOS HTTPS API (service https api rest, loopback-only, API key)
        │  set/delete firewall group members + commit
        ▼
VyOS firewall address-groups → nftables (vyos_filter) → input + forward hooks
```

## Why this design

- **Config-native**: bans are ordinary VyOS firewall group members, visible via
  `show firewall group` — no direct nftables manipulation, nothing that fights VyOS commits.
- **Stock where it counts**: the official `crowdsecurity/custom-bouncer` handles LAPI streaming,
  filtering, retries, and Prometheus metrics. We only write a translator script.
- **Both traffic directions**: drop rules reference the groups in both the `input` and `forward`
  rule sets, so VyOS itself (SSH/admin) and services behind it are protected.

### Known trade-off

Each batch of changes triggers a VyOS config commit (the firewall is regenerated from config).
`vyos-bouncer.sh` **coalesces** decisions into a single API call per short window to bound commit
frequency. If commit latency becomes a problem under heavy ban churn, see `docs/alternatives.md`.

## Components

| File | Purpose |
|------|---------|
| `bouncer.yaml` | `crowdsec-custom-bouncer` config (env-var based) |
| `vyos-bouncer.sh` | decision → VyOS HTTPS API translator (the only custom code) |
| `vyos-bouncer.conf` | API URL/key, group names, batching window (mounted, `0600`) |
| `Dockerfile` | `FROM crowdsecurity/custom-bouncer:v0.0.19` + curl + script/config |
| `vyos-config.md` | copy-paste VyOS configuration |
| `test/` | mock VyOS API + integration test harness |
| `docs/lab-validation.md` | end-to-end results against a real VyOS + LAPI |

## Validation

Validated end-to-end on a live VyOS rolling (QEMU) with a real LAPI: ban → packet drop,
unban → recovery, CIDR groups, and startup re-sync after a cold restart. See
[`docs/lab-validation.md`](docs/lab-validation.md).

## Quick start

1. **Register the bouncer on your central LAPI** and note the API key:

   ```bash
   cscli bouncers add vyos-bouncer -o raw
   ```

2. **Configure VyOS** per `vyos-config.md`: HTTPS API (loopback + key), firewall groups and
   drop rules, and the container definition.

3. **Build the image** (podman):

   ```bash
   make build
   ```

4. **Test locally** (no VyOS needed):

   ```bash
   make test        # runs vyos-bouncer.sh against a mock VyOS API
   make dry-run     # shows what would be sent, without an API
   ```

## Bouncer behavior (`vyos-bouncer.sh`)

Invoked by `crowdsec-custom-bouncer` as:

```
vyos-bouncer.sh <add|del> <value> <duration> <reason> <json>
```

- `value` may be an IPv4/IPv6 address or a CIDR.
- Mapping: IPv4 → `address-group`; IPv6 → `ipv6-address-group`; CIDR → `network-group`
  (IPv4/IPv6 variants). Group names come from `vyos-bouncer.conf`.
- Each invocation spools its op and participates in a `flock`-protected **batch flusher**: it
  waits a short quiet window, collects all pending ops, and sends them as one
  `POST /configure` with a command list → one VyOS commit per window.
- **Fail-open**: if the VyOS API is unreachable it logs and retries; existing group members are
  left untouched. Never adds rules; only members.
- `--dry-run` / `-n`: log the intended API call and exit without POSTing.

## Security

- The VyOS API key has **full permissions** — bind the HTTPS API to loopback only and run the
  bouncer container with `allow-host-networks` (so it reaches `127.0.0.1`).
- Store `VYOS_API_KEY` in a `0600` file under `/config` and mount it; keep `bouncer.yaml`'s LAPI
  key in the VyOS container env.
- The bouncer never `save`s the config, so runtime bans are ephemeral by design.

## Ops / troubleshooting

- Bouncer + script logs: `show log container cs-bouncer` (or podman logs).
- Inspect current bans: `run show firewall group`.
- Force-remove a ban: `delete firewall group address-group CROWDSEC-BANNED address <ip>` + `commit`.
- bouncer health: `curl 127.0.0.1:60602/metrics` (Prometheus) from the host network.

## License

MIT
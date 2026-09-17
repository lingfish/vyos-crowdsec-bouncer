# Lab validation

End-to-end validation of the bouncer against a real VyOS instance and a real CrowdSec LAPI.

## Topology

```
crowdsec LAPI (host podman, 127.0.0.1:18080)
        ▲
        │ LAPI stream (http)
        │
VyOS rolling (QEMU/KVM)                          attacker netns (in VyOS)
  └── container cs-bouncer (set container)         10.9.0.77/24
        ├─ allow-host-networks                     via veth-m 10.9.0.1
        ├─ volume: /config/crowdsec/vyos-bouncer.conf → /etc/crowdsec/vyos-bouncer.conf (ro)
        └─ env: CROWDSEC_LAPI_URL, API_KEY
        │ VyOS HTTPS API (https://127.0.0.1, loopback)
        ▼
  firewall group CROWDSEC-BANNED → ipv4 input/forward rule 100 (drop)
  listener 10.0.2.15:8081
```

- LAPI: `crowdsecurity/crowdsec` container (host podman).
- VyOS: rolling nightly ISO booted under QEMU/KVM (live image).
- Bouncer: this project's image, deployed the production way via VyOS `set container`.

## Results

| Test | Method | Result |
|------|--------|--------|
| VyOS API contract | `POST /retrieve`, `/configure`, `/show` with form key | `success: true`; `firewall group address-group X address IP` path accepted |
| Ban (IPv4) | `cscli decisions add --ip 10.9.0.77 -d 2h` | member appears in `CROWDSEC-BANNED`, referenced by `ipv4-input-filter-100` **and** `ipv4-forward-filter-100` |
| Packet drop | netns attacker (src `10.9.0.77`) → listener `10.0.2.15:8081` | `000` / 3s timeout (dropped) |
| Unban | `cscli decisions delete --ip 10.9.0.77` | member removed (`N/D`); attacker recovers (`200`, ~1ms) |
| CIDR → network-group | `cscli decisions add --range 198.51.100.0/24` | member appears in `CROWDSEC-BANNED-NET` (`network_group`) |
| Startup re-sync / reboot recovery | decision active in LAPI, group wiped, cold `podman restart` | logs `adding 1 decision`; member repopulated |
| Batching | 20 concurrent ops (unit harness) | 1 batched `/configure` request |
| **Short-TTL auto-expiry** | `cscli decisions add --ip 10.9.0.77 -d 1m`, then **no manual delete**; member polled until gone | member appeared (`17s`), traffic dropped (`000`); member **auto-removed ~57s after the 1m expiry**, attacker recovered (`200`). *Issue 3.* |

Control observations: unbanned source = `200` (~1ms); banned source = `000` (3s). The only
variable is group membership, so the drop is attributable to the bouncer.

## Findings (fixed / documented)

1. **Alpine base has no bash.** `fork/exec .../vyos-bouncer.sh: no such file or directory` is the
   kernel failing on `#!/bin/bash`. Fixed: `apk add bash` in the Dockerfile.
2. **VyOS `device` ≠ bind mount.** `set container ... device` maps to podman `--device`, which
   rejects regular files: *"not a valid device: not a device node"*. Use `set container ...
   volume '<name>' source <host> destination <container> [mode ro]`. `vyos-config.md` updated.
3. **`restart 'always'`** means `podman stop` is resurrected by systemd. Use `podman restart` for
   a deliberate cold restart.
4. **Op-mode interactively** uses `show firewall group` (no `run` prefix; `run` is for scripts).
5. **Members live in the running config**, not just the kernel — but are not `save`d, so they are
   lost on reboot. This is why startup re-sync matters, and it works (cold start re-pulls all
   active LAPI decisions).

## Reproducible via `make lab`

The earlier runs above were manual and out-of-band. `lab/` now scripts the whole
thing against an **isolated libvirt network** (`192.0.2.0/24`, no LAN/internet
in the guest) so it can be re-run on demand:

```bash
make lab-up            # ISO -> boot latest rolling nightly -> configure -> LAPI -> bouncer
make lab-test-expiry   # issue-3 scenario (short-TTL auto-expiry)
make lab-down          # teardown (keeps the cached ISO)
```

See `lab/README.md` for details and gotchas (serial-console automation, the
non-interactive SSH limitation on this VyOS build, etc.).

## Environment

- VyOS: rolling nightly `2026.09.16-0028` (QEMU/KVM, 2 vCPU, 2 GB).
- CrowdSec LAPI image: `crowdsecurity/crowdsec` (latest at test time).
- Bouncer image: `vyos-crowdsec-bouncer:latest` (`crowdsecurity/custom-bouncer:v0.0.19` base).
- podman in guest: 5.8.4; host: 5.4.2.

## Not covered here

- IPv6 end-to-end packet drops (IPv6 mapping is covered by the unit harness).
- Forward-path packet drop from an external routed client (forward rule reference is confirmed).
- Long-running soak / large blocklists.

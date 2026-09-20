# Lab validation

End-to-end validation of the bouncer against a real VyOS instance and a real CrowdSec LAPI.

> **Note:** the project's design is the **firewall remote-group** model (see
> `vyos-config.md`): the minimal Alpine container mirrors LAPI's active decisions into `bans.txt`,
> which VyOS polls as a single `CROWDSEC-BANNED` remote-group. The results below were recorded
> on 2026-09-18 (`make lab-up` + the three `lab-test-*` scenarios, VyOS
> `2026.09.17-0028-rolling`, bouncer image `12fb910e3783`). All scenarios pass.

> **Cadence caveat:** those numbers were measured with the lab's *fast* poll settings
> (`resolver-interval 10`, `REFRESH_SECONDS 5`). The lab and the docs now use the recommended
> production cadence — per-group `interval '60s'`, global `resolver-interval` left at VyOS's
> default 300s, `REFRESH_SECONDS 30` — which every transition in ~90s instead of ~15s. The
> 60s/30s cadence has **not been re-run yet**; treat the appearance/removal times below as
> ~6x larger and re-validate with `make lab` before trusting them.

## Results (remote-group design)

| Test | Result |
|------|--------|
| Ban (IPv4, `-d 1m`) | member in `CROWDSEC-BANNED` after **6s**; input+forward traffic dropped |
| **Short-TTL auto-expiry** | member auto-removed **~52s after the 1m expiry** — no manual delete, traffic recovers |
| Ban (IPv6 `fd00:9::77`) | member after **14s**; IPv6 drop; unban → removed in 14s → recovery |
| Forward (IPv4 address `10.9.0.77`) | member after **7s**; routed drop; unban → removed in 13s → recovery |
| Forward (IPv4 CIDR `10.9.0.0/24`) | member after **10s**; routed drop; unban → removed in 6s → recovery |
| Forward (IPv6 address `fd00:9::77`) | member after **7s**; routed drop; unban → removed in 7s → recovery |

## Topology

```
crowdsec LAPI (host podman, 192.0.2.1:18080)
        ▲
        │ GET /v1/decisions (X-Api-Key), polled every 5s   <- as recorded, now 30s
        │
VyOS rolling (QEMU/KVM)                          attacker netns (in VyOS)
  └── container cs-bouncer (set container)         10.9.0.77/24 (fd00:9::77/64)
        ├─ allow-host-networks                     via veth-m 10.9.0.1 (fd00:9::1)
        ├─ volume: /config/crowdsec/vyos-bouncer.conf → /etc/crowdsec/vyos-bouncer.conf (ro)
        └─ env: LAPI_URL, API_KEY
        ▼ serves bans.txt on 127.0.0.1:8080
  vyos-domain-resolver → remote-group CROWDSEC-BANNED (resolver-interval 10   <- now interval 60s)
        ▼ R_CROWDSEC-BANNED / R6_CROWDSEC-BANNED nft sets (no commit)
  ipv4/ipv6 input/forward rule 100 (drop, source group remote-group)
  listener guest-eth0:8081  +  listener [fd00:9::1]:8082 (IPv6)

  server netns (in VyOS, behind the forward hook)
    10.9.1.10/24 (fd00:9:1::10/64)  via veth-s 10.9.1.1 (fd00:9:1::1)
    listeners 10.9.1.10:8083 + [fd00:9:1::10]:8084  ← forward-path targets
```

- LAPI: `crowdsecurity/crowdsec` container (host podman).
- VyOS: rolling nightly ISO booted under QEMU/KVM (live image).
- Bouncer: this project's image, deployed the production way via VyOS `set container`.

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
6. **IPv6 firewall rules reference groups via `address-group`/`network-group`, not
   `ipv6-address-group`/`ipv6-network-group`.** The `firewall ipv6 ... source group` node has no
   `ipv6-*` children (`Configuration path ... is not valid`); VyOS maps `address-group` →
   `ipv6-address-group` when the rule family is IPv6 (see `firewall.py`). `provision.sh` and
   `vyos-config.md` originally used the invalid `ipv6-*` nodes, so the IPv6 drop rules silently
   had **no source group** (a bare `action drop`, which would drop all IPv6). Fixed to
   `source group address-group` / `source group network-group`; confirmed live: rules compile to
   `ip6 saddr @A6_CROWDSEC-BANNED-V6` / `@N6_CROWDSEC-BANNED-NET-V6`. *Issue 1.*
7. **VyOS IPv6-ND defect for forwarded veth traffic (rolling nightly).** For *forwarded* IPv6 the
   guest kernel never emits the ND NS to resolve the peer veth — neighbor entries sit
   `FAILED`/`INCOMPLETE` and forwarded v6 packets are black-holed with ICMPv6 "address
   unreachable", even though locally-generated traffic resolves fine and `nft` accepts the
   packet through every hook (verified with `nft monitor trace`). The lab pins the L2 adjacency
   with `nud permanent` IPv6 neighbors on `veth-m`/`veth-s` (from the peers' MACs) in
   `provision.sh`. This is a lab/VM artefact, not a bouncer issue. *Issue 2.*

## Reproducible via `make lab`

The earlier runs above were manual and out-of-band. `lab/` now scripts the whole
thing against an **isolated libvirt network** (`192.0.2.0/24`, no LAN/internet
in the guest) so it can be re-run on demand:

```bash
make lab-up            # ISO -> boot latest rolling nightly -> configure -> LAPI -> bouncer
make lab-test-expiry   # issue-3 scenario (short-TTL auto-expiry)
make lab-test-ipv6     # issue-1 scenario (IPv6 ban -> drop, unban -> recovery)
make lab-test-forward  # issue-2 scenario (routed-client forward-path drop)
make lab-down          # teardown (keeps the cached ISO)
```

See `lab/README.md` for details and gotchas (serial-console automation, the
non-interactive SSH limitation on this VyOS build, etc.).

## Environment

- VyOS: rolling nightly `2026.09.17-0028` (QEMU/KVM, 2 vCPU, 2 GB).
- CrowdSec LAPI image: `crowdsecurity/crowdsec` (latest at test time).
- Bouncer image: `vyos-crowdsec-bouncer:latest` (minimal Alpine + busybox `httpd`).
- podman in guest: 5.8.4; host: 5.4.2.

## Not covered here

- Long-running soak / large blocklists.

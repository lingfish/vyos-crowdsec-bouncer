# Alternatives

The default design enforces bans through a VyOS **firewall remote-group** that polls a ban list
served by the bouncer container (no config commits per ban). Alternatives exist if that
trade-off doesn't fit.

## 1. Stock `crowdsec-firewall-bouncer` (nftables mode)

Run the official firewall bouncer in a privileged container instead:

```
set container name cs-fw-bouncer image 'your-registry/cs-firewall-bouncer:latest'
set container name cs-fw-bouncer allow-host-networks
set container name cs-fw-bouncer capability net-admin
set container name cs-fw-bouncer environment ...
```

- **Pros**: kernel-level drops at input+forward hooks, low latency, no config commits, proven;
  its own nftables table is untouched by VyOS commits.
- **Cons**: not visible in `show firewall`; writes its own `crowdsec` nftables table; requires
  `net-admin` capability; more invasive on the host.
- **Best for**: huge ban volume or sub-second latency requirements.

## 2. VyOS dynamic groups via direct nft writes (not recommended)

Rejected during design: populate a VyOS `dynamic-group` by writing `DA_*`/`DA6_*` nftables sets
directly (needs `net-admin` + an `nft` binary in the container). **Any firewall (re)commit wipes
all dynamic members** (they are runtime-only), so an unrelated config change silently un-bans
everyone until a re-sync; the sets also cannot hold CIDRs (`type ipv4_addr`, no `interval`).

## Decision guide

| Requirement | Choose |
|---|---|
| Config-native bans, no commits, tolerant of ~1 min latency (`interval` floor is 60s) | **Default (remote-group, this project)** |
| Minimal latency / huge ban volume | nftables firewall-bouncer |

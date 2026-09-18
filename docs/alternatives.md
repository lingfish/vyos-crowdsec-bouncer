# Alternatives

The default design enforces bans through a VyOS **firewall remote-group** that polls a ban list
served by the bouncer container (no config commits per ban). Alternatives exist if that
trade-off doesn't fit.

## 1. Original design: HTTPS API + config address-groups (commits)

The pre-remote-group approach: the bouncer called the VyOS HTTPS API to `set`/`delete` group
members, one config commit per batched window.

- **Pros**: bans are ordinary config members (`show firewall group` lists them as
  `address_group`/`network_group`); ~6s latency.
- **Cons**: **every batch triggers a VyOS config commit** (full firewall regeneration). Under
  heavy churn (e.g. 1320 decisions) that is thousands of commits; the `custom-bouncer` also
  invokes the script serially, which defeated the in-script batching and made it one commit per
  decision. Requires the VyOS HTTPS API + full-permission API key.
- **Best for**: configs that must keep bans as committed group members.

## 2. Stock `crowdsec-firewall-bouncer` (nftables mode)

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

## 3. VyOS dynamic groups via direct nft writes (not recommended)

Rejected during design: populate a VyOS `dynamic-group` by writing `DA_*`/`DA6_*` nftables sets
directly (needs `net-admin` + an `nft` binary in the container). **Any firewall (re)commit wipes
all dynamic members** (they are runtime-only), so an unrelated config change silently un-bans
everyone until a re-sync; the sets also cannot hold CIDRs (`type ipv4_addr`, no `interval`).

## Decision guide

| Requirement | Choose |
|---|---|
| Config-native bans, no commits, tolerant of ~10s latency | **Default (remote-group, this project)** |
| Minimal latency / huge ban volume | nftables firewall-bouncer |
| Bans must be committed config members | Original HTTPS API design (#1) |
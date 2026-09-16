# Alternatives

The default design enforces bans through VyOS firewall address-groups via the HTTPS API
(config-native, one commit per batch). Two alternatives exist if that trade-off doesn't fit.

## 1. Stock `crowdsec-firewall-bouncer` (nftables mode)

Run the official firewall bouncer in a privileged container instead:

```
set container name cs-fw-bouncer image 'your-registry/cs-firewall-bouncer:latest'
set container name cs-fw-bouncer allow-host-networks
set container name cs-fw-bouncer capability net-admin
set container name cs-fw-bouncer environment ...
```

- **Pros**: kernel-level drops at input+forward hooks, low latency, no config commits, proven.
- **Cons**: not visible in `show firewall`; writes its own `crowdsec` nftables table; requires
  `net-admin` capability; more invasive on the host. A foreign nftables table survives VyOS
  commits (VyOS only manages tables it owns) but is recreated by the bouncer on startup.
- **Best for**: high ban churn or when commit latency matters more than config transparency.

## 2. `crowdsec-blocklist-mirror` + host consumer

Expose active decisions as an HTTP blocklist and let a host-side job ingest them:

- **Pros**: bouncer container needs no host network; pull-based; non-privileged.
- **Cons**: extra moving part (scheduler + parser), higher enforcement latency, still has to
  write nftables or groups somewhere.
- **Best for**: appliances that natively pull blocklists; overkill for a single VyOS box.

## Decision guide

| Requirement | Choose |
|---|---|
| Config-native bans, visible in `show firewall` | **Default (this project)** |
| Minimal latency / huge ban volume | nftables firewall-bouncer |
| No privileged container, tolerant of latency | blocklist-mirror + consumer |
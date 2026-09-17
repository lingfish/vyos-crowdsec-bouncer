# Lab harness

Reproducible end-to-end lab for validating `vyos-bouncer.sh` against a **real
VyOS** instance and a **real CrowdSec LAPI**, fully isolated from the host and
its LAN.

## What it does

- Boots the **latest VyOS rolling nightly** ISO (resolved from
  `vyos-nightly-build/rolling/version.json`) as a KVM guest under **libvirt**.
- Puts the guest on an **isolated libvirt network** `192.0.2.0/24` (TEST-NET-1):
  the guest reaches the host (`192.0.2.1`) and nothing else — no LAN, no
  internet in-guest. All addressing in this repo is TEST-NET or the in-guest
  `10.9.0.0/24` attacker network.
- Configures the guest exactly like production (`vyos-config.md`): HTTPS API on
  loopback, firewall groups + input/forward drop rules, and `set container
  cs-bouncer`.
- Deploys the bouncer image (`podman save` → served over HTTP on the isolated
  net → `podman load` in the guest) and a host-side `crowdsecurity/crowdsec`
  LAPI, registers the bouncer, and stages an in-guest **attacker netns**
  (`10.9.0.77`) with an HTTP listener so packet drops are measurable.

## Usage

```bash
make lab-up            # bring up: ISO -> VM -> config -> LAPI -> bouncer
make lab-test-expiry   # issue 3: short-TTL decision auto-removes on expiry
make lab-down          # destroy VM/network, stop LAPI, purge runtime state
make lab               # lab-up + lab-test-expiry (fresh-cycle convenience)
```

Prereqs on the host: `python3` + `pexpect`, `virsh` (libvirt, qemu:///system
with the user in the `libvirt` group, `/dev/kvm`), `podman`, `curl`, and
`openssl`. About 1.5 GB RAM + ~1.5 GB disk for the ISO; the ISO is cached in
`lab/.cache/` and kept across `lab-down`.

## Layout

| File | Purpose |
|------|---------|
| `vyos-lab.xml` | Minimal KVM domain template (`__ISO_PATH__` is templated at provision time). Headless: boots the live ISO, virtio NIC on `crowdsec-lab`, raw TCP serial chardev on `127.0.0.1:23000`. |
| `crowdsec-net.xml` | Isolated libvirt network (`virbr-cs`, `192.0.2.1/24`, dnsmasq DHCP `.50–.200`). No `<forward>` = no outbound routing. |
| `serial.py` | pexpect driver for the guest serial console: fresh login or leftover-shell detection, `sudo` auto-answer, command/prompt state machine. |
| `lib.sh` | Shared helpers: `guest_ip`, `guest_op` (op commands via serial), `guest_root` (raw root commands via serial), `attacker_http_code`, `wait_for`. |
| `provision.sh` | Full bring-up (7 phases, idempotent; see comments in-file). |
| `test-expiry.sh` | Issue-3 scenario: add `-d 1m` ban → member appears + traffic drops → **no manual delete** → auto-removal on expiry → traffic recovers. |
| `down.sh` | Teardown: `virsh destroy`+`undefine` domain & network, remove LAPI container, purge runtime cache (ISO kept). |

## Notes / gotchas learned

- The domain's pty slave is only readable by `libvirt-qemu`, so the console is
  exposed as a **raw TCP chardev** and driven over a socket, not `virsh console`.
- **No op-mode command works over non-interactive SSH** on this VyOS build
  (vbash rejects `show ...`). Use `guest_op`/`guest_root` (serial), not `ssh`.
- Every `| grep -q` in a `set -o pipefail` script breaks: `grep -q` exits early,
  SIGPIPEs the upstream command, and the pipeline reports failure. The scripts
  deliberately avoid `grep -q` on pipes.
- The LAPI DB lives in `lab/.cache/lapi-data` (gitignored); `down.sh` removes it
  so a fresh `lab-up` starts with a clean LAPI.
- VyOS config is not `save`d in the live guest: a VM reboot loses the config,
  image, and attacker netns — always `make lab-down` before a full re-run.
# vme-netconfig v2.13.0

Network configurator, auditor, and repair tool for **HPE Morpheus VM Essentials /
HVM 9.0.1+** hosts on Ubuntu 22.04 / 24.04.

It covers three moments in a host's life:

| moment | mode |
|---|---|
| after Ubuntu, before `hpe-vm` | `--wizard` / `--apply` |
| host already prepped, uplinks wrong | `--reconfigure` |
| anytime | `--doctor`, `--doctor --fix` |

Everything it changes is backed up first, verified, and restorable from an iLO
console with no network.

```bash
sudo ./vme-netconfig.sh --wizard          # greenfield build
sudo ./vme-netconfig.sh --reconfigure     # fix mgmt/cmpt on a prepped host
sudo ./vme-netconfig.sh --doctor          # audit (read-only)
sudo ./vme-netconfig.sh --doctor --fix    # audit and repair
sudo ./vme-netconfig.sh --rollback        # undo the last change
```

---

## Modes

### `--wizard` — greenfield

Discovers every physical NIC (driver, speed, PCI address, NUMA node, permanent
MAC, carrier, LLDP peer), walks you through role assignment, renders netplan, and
applies it behind a dead-man rollback. Writes a reusable profile to
`/etc/vme-netconfig/profile.conf`.

Refuses to run if netplan already declares OVS bridges — that host is prepped and
wants `--reconfigure` instead.

### `--apply --profile FILE` — clone to the rest of the cluster

Non-interactive. Copy the profile to the next host, edit the addresses, apply.

### `--reconfigure` — repair a prepped host

For a host where `hpe-vm` has already run and the uplinks are wrong: `mgmt`
exists but `cmpt` was never built, or management sits on the wrong interface.

It asks which NICs form the management bond, whether management is tagged and on
what VLAN, then which NICs form the compute bond. It rewrites only those, plus
`60-mvm-mgmt.yaml` and `61-mvm-compute.yaml`.

Before anything else it runs a **cluster guard**: it refuses to proceed if GFS2
is mounted or if guests are running. Rebuilding uplinks under a live GFS2 mount
cuts the storage path and cluster lock traffic mid-write — the mount hangs, the
cluster marks the host down, and VME HA acts on that.

Morpheus VME 9.0+ manages GFS2 consistency itself through heartbeat datastores
and its own HA. There is no pacemaker/corosync layer, so `pcs`/`crm` procedures
from older VME releases do not apply.

Instead the tool offers to **wait**. Maintenance Mode migrates guests off and
drops the host out of the storage cluster, which unmounts GFS2 — so that unmount
is the green light. Answer yes, flip Maintenance Mode on the cluster detail page
in VME Manager, and the tool polls until the guests are gone and the mount has
cleared, then continues on its own:

```
== Waiting for Maintenance Mode to settle
   [   0s] GFS2 still mounted; 2 guests still running...
   [  20s] GFS2 still mounted...
   [ ok ] host is parked: no GFS2 mount, no running guests (30s)
```

`--maint-timeout N` sets the ceiling (default 900s). `--force` skips the guard
entirely. When the run finishes it reminds you the host is still parked and to
take it out only after `--doctor` is clean.

**Any NIC that already carries an IP is protected.** It's treated as storage,
never offered as a candidate, never rewritten. The existing management L3 is read
out of the current `mgmt` bridge and reused rather than retyped.

This mode writes VME-owned files, which is a deliberate override — see
[File ownership](#file-ownership-after-install). It says so before asking to
proceed. The clean path is still to re-add the host so prep regenerates them;
this is for fixing a host in place.

### `--doctor` — audit

Read-only. Bonds, LACP aggregation, MTU, routing, OVS bridge health, L3
ownership, iSCSI/multipath, sysctls, dark links, netplan hygiene. Reports
pass/warn/fail and lists repairable items by ID.

With `lldpd` installed it also reports the **switch side**: the neighbour chassis,
port, and advertised VLANs for each bond member, and whether the bond lands on one
switch or two. That fact decides whether LACP is possible at all — across two
independent chassis it is not, and `balance-xor` there puts one source MAC on ports
of both, which switches log as MAC moves and some punish with err-disable.

It also flags a host with a `mgmt` bridge but no `cmpt` — host prep that built
the management path and stopped — and tells you whether there are spare NICs for
a dedicated compute uplink or whether the host has to go converged.

### `--discover`, `--show`, `--list-backups`, `--rollback`

Inspection and recovery. All read-only except `--rollback`.

## Options

| flag | effect |
|---|---|
| `--profile FILE` | profile to read (default `/etc/vme-netconfig/profile.conf`) |
| `--dry-run` | render everything, write nothing |
| `--yes` | assume yes; also auto-confirms the dead-man rollback |
| `--fix` / `--fix=F03,F06` | apply all safe repairs, or a named subset |
| `--safety-timer N` | seconds before automatic rollback (default 180, `0` = off) |
| `--maint-timeout N` | seconds to wait for Maintenance Mode to settle (default 900) |
| `--probe-links` | bring admin-down NICs up during discovery to detect carrier |
| `--no-sysctl` | skip the kernel tunables file |
| `--force` | proceed past preflight and cluster-guard objections |
| `--version`, `--help` | as expected |

---

## Topologies

Both come from the HPE VME Deployment Guide's *Example Network Configurations*.
Each role independently uses a **bond** (2+ NICs) or a **single unbonded port**.

### `decoupled` — 6+ NICs

```
bond0  ens1f0 + ens1f1   management (host IP, agent, cluster heartbeat)
bond1  ens2f0 + ens2f1   compute trunk (VM traffic, no L3)
bond2  ens4f0 + ens4f1   optional second compute (DMZ / physically segmented)
ens3f0                   iSCSI path A   192.168.201.x/24
ens3f1                   iSCSI path B   192.168.202.x/24
```

### `converged` — 4 NICs

HPE's documented answer for four-NIC hosts, not a workaround. Two NICs (one per
card) bond into a trunk carrying the management VLAN *and* the compute VLANs;
the other two do storage MPIO, one per storage VLAN.

`--reconfigure` offers it automatically when no NICs remain after the management
bond, and refuses to build it with an untagged management VLAN — the untagged
bond becomes the `cmpt` port, and an OVS port belongs to one bridge only.


```
bond0        ens1f0 + ens1f1   carries both
bond0.<vlan>                   management L3 (HPE's example uses bond0.2)
bond0                          compute trunk, untagged
ens3f0 / ens3f1                iSCSI MPIO
```

The wizard pushes toward a **tagged** management VLAN in converged mode. An
untagged management VLAN sharing the native VLAN with the compute trunk is the
setup that bites later.

### Minimal split — one port per role

```
eno1        management port
eno1.200    management L3
eno2        compute trunk, no L3, no VLANs
eno3/eno4   iSCSI MPIO
```

### Bond of one

A bond over a single NIC is supported and encouraged. VME pins the cluster to an
interface *name*, so `bond1` over one port means adding a second link later is a
netplan edit rather than re-pointing the cluster at a different device.

Single-member bonds automatically degrade from LACP or XOR to `active-backup` —
a one-port LAG negotiates with nothing useful and some switches refuse to form
it. The degrade is printed at render time.

---

## Bond modes

| mode | netplan | switch requirement |
|---|---|---|
| `lacp` | `802.3ad`, `layer3+4`, `lacp-rate: fast`, `ad-select: bandwidth` | LAG/MLAG on the peer ports |
| `xor` | `balance-xor`, `layer3+4` | none |
| `active-backup` | `active-backup`, `fail-over-mac-policy: active` | none |

All get `mii-monitor-interval: 100` and 200ms up/down delay.

Pick LACP without the switch side in a LAG and `--doctor` will say so: the bond
looks up, the LACP partner MAC is null, and roughly half your traffic disappears
into the switch.

---

## MTU

- iSCSI and compute default to **9000**; management to 1500 unless raised.
- The wizard blocks a converged bond below **1550** — a 1500-byte guest over VXLAN
  needs 50 bytes of overlay headroom, without which you get the classic "ping
  works, TLS handshake hangs" failure.
- After apply, each iSCSI portal gets a real `ping -M do` at full payload size. A
  path that answers small pings but drops jumbo frames is reported as a failure,
  not a pass.

---

## What it never does

- **Never creates the OVS `mgmt` or `cmpt` bridges during a greenfield build.**
  VME Manager owns those. Preflight refuses if they exist without `hpe-vm`
  installed.
- **Never bonds iSCSI NICs.** HPE recommends MPIO for iSCSI/FC LUNs backing GFS2.
- **Never changes NICs or iSCSI sessions under a live GFS2 mount.** The repair
  path hard-stops and points at cluster maintenance-mode.
- **Never writes compute VLANs into netplan** — see below.
- **Never gives a non-management interface a gateway or nameservers.**

---

## File ownership after install

VME Manager writes its own netplan files during host prep and keeps its own
backups beside them:

```
/etc/netplan/
  00-vme-netconfig.yaml      this tool  (base: bonds, VLANs, addresses)
  01-base.yaml               installer or hand-built base, if present
  60-mvm-mgmt.yaml           VME Manager  — mgmt OVS bridge + the host L3
  61-mvm-compute.yaml        VME Manager  — cmpt OVS bridge, L2 only
  mvmbackup-<timestamp>/     VME Manager  — do not delete
```

Netplan merges in lexical order and later files win on any key they redefine, so
VME's `60-`/`61-` files layer on top of the base.

Anything matching `*-mvm-*.yaml` or `mvmbackup-*` is **VME-owned**: `--apply`
leaves it alone, F02 refuses to demote it, and `--doctor` reports its presence as
evidence the host is prepped rather than as a file conflict. `--reconfigure` is
the one mode that writes them, deliberately and with warning.

## The L3 handoff

VME declares its bridges through netplan's native OVS support, and the management
address **moves onto the bridge**:

```yaml
# 60-mvm-mgmt.yaml — written by VME Manager
network:
  bridges:
    mgmt:
      addresses: [192.168.200.3/27]
      interfaces: [bond0.200]
      routes: [{to: default, via: 192.168.200.1}]
      openvswitch: {}
```

So the base file must end up with a **bare** VLAN once prep has run:

```yaml
vlans:
  bond0.200: {id: 200, link: bond0}    # no addresses, no routes, no nameservers
```

Before install the address has to be on `bond0.200` or you have no way in. After
install it belongs to the bridge. A copy left in both places gives two claimants
for one IP. `--doctor` compares every netplan bridge member against every L3
owner and fails on the overlap; **F09** strips the stale keys from the base file
and never touches a VME-owned one.

One consequence worth internalising: **F05 and F06 are runtime-only on a prepped
host.** `netplan apply` rebuilds the bridge from YAML and reverts anything set
with `ovs-vsctl`. Durable changes go in the `openvswitch:` block, or through VME
re-running host prep.

## Compute VLANs are not netplan's business

Tagged VM networks (200, 210, 211, …) are created in **VME Manager** as HVM
Standard Networks — OVS port groups on the `cmpt` bridge. The compute uplink is
handed to VME as a bare untagged trunk.

A kernel VLAN subinterface on the compute uplink consumes those tagged frames
before OVS ever sees them. `--doctor` flags any stray VLAN on the compute device
as a failure; the management VLAN is exempt, because the host needs an IP before
VME Manager exists.

---

## Repair IDs

| id | problem | fix |
|---|---|---|
| F01 | netplan files world-readable | `chmod 0600` |
| F02 | cloud-init still owns networking / multiple netplan files overriding each other | disable cloud-init net config, demote extras (VME files untouched) |
| F03 | bond member MTU differs from the bond | align at runtime |
| F04 | `rp_filter=1` with multi-homed storage NICs dropping return traffic | `rp_filter=2`, `arp_ignore=1`, `arp_announce=2`, socket buffers |
| F05 | OVS created a `type:internal` dummy where the real bond should attach | `del-port` → `add-port` → `fail_mode=standalone` |
| F06 | OVS bridge missing `fail_mode=standalone` | set it |
| F07 | `systemd-networkd-wait-online` unfiltered, stalling boot 120s | drop-in gating only on management |
| F08 | a bond with **zero enslaved members** — an empty shell | rebuild from profile; **refuses over SSH** |
| F09 | an interface enslaved into an OVS bridge still carries L3 | strip those keys from the base file only |

`--fix` applies all; `--fix=F03,F06` applies a subset. F05 and F08 refuse to run
under a live GFS2 mount and prompt before interrupting traffic.

Reported but never auto-fixed: LACP partner state, split aggregators, duplicate
IP (`arping -D`), multiple default routes, faulty multipath paths, full-mesh
iSCSI sessions, dark links, NetworkManager running alongside networkd, missing
`cmpt` bridge.

### On bond MAC addresses

systemd-networkd derives bond MACs from `/etc/machine-id`, not from the first
slave. A locally-administered bond MAC is **normal** and is not evidence of an
empty bond — check the slave count in `/proc/net/bonding/<bond>` instead.

The real hazard is cloning: hosts built from one template share a machine-id and
therefore share bond MACs on the same L2. `--doctor` says so whenever a bond MAC
matches none of its slaves. Fix with `systemd-machine-id-setup` and a reboot.

### Default routes belong to management, and nowhere else

The most common hand-built mistake is giving storage NICs a gateway "so they can
reach the array". That creates competing default routes and pushes host egress
out a storage port. Storage interfaces get an address, an MTU, and nothing else.

`--doctor` compares every default route against the management interface and
fails on any that don't match.

### Multi-homed same-subnet detection

Two interfaces holding addresses in one subnet makes Linux answer ARP for either
address on either NIC, so return traffic can leave the wrong port and MPIO
quietly collapses to a single real path. Reported, with F04 offered.

---

## Console recovery

Every change takes a **verified** backup before touching anything. If the
checksums don't reconcile, nothing is modified at all.

Each backup captures the whole netplan directory, the sysctl file, the
wait-online drop-in, the cloud-init override, `/etc/hosts`, `/etc/resolv.conf`,
`/etc/machine-id`, plus read-only snapshots of iSCSI and multipath config, live
link/addr/route state, `/proc/net/bonding/*`, and the full OVS topology with
fail-modes and port types.

A self-contained restore script is written to **three** locations:

```
/etc/vme-netconfig/restore-latest.sh
/root/vme-restore-<timestamp>.sh
/etc/vme-netconfig/backups/<timestamp>/restore.sh
```

All identical. Each needs no network, no arguments, and no dependency on
`vme-netconfig.sh` — so it runs from an iLO remote console on a host whose
networking you just destroyed. The exact commands print in a boxed card before
every apply. Add `--dry-run` to preview.

```bash
sudo ./vme-netconfig.sh --list-backups      # every restore point + integrity
sudo ./vme-netconfig.sh --rollback          # most recent
sudo ./vme-netconfig.sh --rollback=TS       # a specific one
```

`--list-backups` re-verifies checksums and marks any damaged restore point.

The restore saves current state to `/var/backups/vme-netconfig-preRestore` first,
so a restore is itself undoable. It never reverts `/etc/machine-id`,
`/etc/iscsi/*`, or `/etc/multipath.conf` — those are captured for reference only,
because silently rewriting a machine-id or initiator name would do more damage
than the problem being fixed.

It does not auto-revert OVS. Since VME declares bridges in netplan, restoring the
YAML rebuilds them; the old topology is in `state/ovs.txt` for comparison.

### Dead-man rollback

Beyond the restore script, every apply arms a transient timer:

1. Backup, verify, write.
2. `netplan generate` — abort and restore if it fails.
3. `systemd-run --on-active=180 restore.sh`.
4. Apply, verify, then ask you to type `KEEP`. If your session died, you don't
   type it, and the host reverts on its own.

`--safety-timer 0` disables it. `--yes` auto-confirms — for config-management
runs on console-accessible hosts, not remote first applies.

---

## Testing and simulation

`sim/` builds a mock host tree and runs the tool against it. `SYS_NET` and
`PROC_BONDING` are overridable, so no real hardware is touched.

```bash
bash sim/build_host.sh  /tmp/h1     # mock: bond0 -> mgmt, no cmpt
bash sim/build_host2.sh /tmp/h2     # mock: the repaired target state
bash sim/run_doctor.sh      /tmp/h1
bash sim/run_reconfigure.sh /tmp/h1
bash sim/plan_repair.sh             # render candidate repair topologies
```

Edit the mock to match a real host's reported state and you can dry-run any
repair before touching iLO. This is also how the `set -o pipefail` abort on
`iscsiadm` exit 21 was found — a bug that silently truncated the doctor run on
any host with no iSCSI sessions.

---

## Typical run

```bash
# 1. look at what you have
sudo ./vme-netconfig.sh --discover --probe-links

# 2. build it
sudo ./vme-netconfig.sh --wizard

# 3. clone to the rest of the cluster
scp /etc/vme-netconfig/profile.conf host2:/tmp/
# edit the addresses, then:
sudo ./vme-netconfig.sh --apply --profile /tmp/profile.conf

# 4. verify before installing hpe-vm
sudo ./vme-netconfig.sh --doctor
```

The wizard, `--reconfigure`, and `--show` all print the exact strings the VME
cluster-create wizard asks for:

```
MANAGEMENT NET INTERFACE : bond0.200
COMPUTE NET INTERFACE    : bond1
STORAGE NET INTERFACE    : ens3f0  (MPIO across: ens3f0 ens3f1)
COMPUTE VLANS            : 200,210-211
```

## Order of operations

**New host:**

```
Ubuntu install → --wizard → --doctor
  → apt install -f hpe-vm.deb → iSCSI/multipath setup → hpe-vm (install manager)
  → create cluster in VME Manager UI → --doctor
```

**Repairing a host already in a cluster:**

```
VME Manager: Maintenance Mode on this host
  → tool waits for guests to evacuate and GFS2 to unmount
  → switch side: break any stale LAG, trunk the VM VLANs to the compute port
  → iLO console: --reconfigure --dry-run, then the real run
  → --doctor
  → cluster edit / re-add with the printed interface names
  → exit Maintenance Mode
```

Do the repair from the iLO console, not SSH — the management path is what you
are rebuilding. The tool warns if it sees your session arriving on a NIC it is
about to move.

---

## Files written

| path | purpose |
|---|---|
| `/etc/netplan/00-vme-netconfig.yaml` | base config from `--wizard` / `--apply` |
| `/etc/netplan/60-mvm-mgmt.yaml` | mgmt bridge — **only** written by `--reconfigure` |
| `/etc/netplan/61-mvm-compute.yaml` | cmpt bridge — **only** written by `--reconfigure` |
| `/etc/vme-netconfig/profile.conf` | reusable, editable role assignment |
| `/etc/vme-netconfig/backups/<ts>/` | verified backup + `restore.sh` |
| `/etc/vme-netconfig/restore-latest.sh` | console recovery entry point |
| `/root/vme-restore-<ts>.sh` | second copy where a console operator lands |
| `/etc/sysctl.d/90-vme-netconfig.conf` | rp_filter, ARP, buffers, neigh tables |
| `/etc/systemd/system/systemd-networkd-wait-online.service.d/10-vme-netconfig.conf` | boot gating |
| `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` | stops cloud-init rewriting netplan |
| `/var/log/vme-netconfig.log` | audit trail |
| `/var/log/vme-netconfig-restore.log` | restore audit trail |

## Requirements

Ubuntu 22.04 or 24.04 (24.04 preferred for 9.0.1+ cluster layouts), `netplan`,
`iproute2`, and `python3-yaml` for the bridge/L3 analysis and `--reconfigure`.
Without pyyaml those checks are skipped with a notice rather than guessed.

Recommended: `ethtool`, **`lldpd`** (required for the switch-side report),
`iputils-arping`, `open-iscsi`, `multipath-tools`.

## Known gaps

Everything below is verified in simulation only. Nothing here has been run
against production hardware.

- Whether the VME agent notices the mgmt bridge moving to a different interface
  without re-registration. If it caches the name, the cluster edit is needed
  anyway.
- Whether `netplan apply` fully tears down `cmpt` when `61-mvm-compute.yaml` is
  removed by a restore. Verified at the file level, not for OVS teardown.
- `--reconfigure` writes VME-owned files. VME may rewrite them on its next prep
  run; it should write the same thing, but that has not been observed end to end.
- The Maintenance Mode poller keys on the GFS2 unmount and `virsh` guest count.
  If a cluster layout keeps the mount during Maintenance Mode, the poller would
  wait out its timeout rather than proceed — it fails closed, but it would be the
  wrong signal.

## Corrections worth knowing

Assumptions this tool used to hold and no longer does, recorded because they are
easy to re-derive from older VME material:

- **Pacemaker/corosync.** Removed. VME 9.0+ manages GFS2 consistency itself via
  heartbeat datastores and its own HA. `pcs node standby` and
  `pcs property set maintenance-mode=true` do not apply and the commands are not
  present on a 9.0+ host.
- **A locally-administered bond MAC means an empty bond.** False.
  systemd-networkd derives bond MACs from `/etc/machine-id`. Check the slave
  count instead.
- **One authoritative netplan file.** True only before host prep. Afterwards VME
  owns `60-`/`61-` and layers them on top.
- **`ovs-vsctl` repairs are durable.** Only on an unprepped host. VME declares
  its bridges in netplan, so `netplan apply` reverts runtime OVS changes.

MIT.

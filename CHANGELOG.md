# Changelog

All notable changes to `vme-netconfig`. Versions follow semver loosely; the
minor number bumps whenever behaviour changes.

## [2.13.0] — Maintenance Mode does not unmount GFS2

**Fixed**
- The Maintenance Mode poller waited for the GFS2 mount to clear. It does not
  clear: a parked host stays a member of the storage cluster with the LUN
  mounted, so the wait never ended. Observed on hpevmess03 (VME 9.0). The poller
  now watches guest count via `virsh` only, which is the signal that actually
  moves.
- A mounted GFS2 filesystem no longer aborts `--reconfigure`. It is the normal
  state of a parked host, and blocking on it made the mode unusable on exactly
  the hosts it was written for.

**Added**
- Storage path analysis after NIC selection. Traces each live iSCSI session to
  the interface carrying it and compares that against the interfaces about to be
  rebuilt. Overlap is a hard refusal; no overlap is reported as such.
- Typed `MAINTENANCE` confirmation when GFS2 is mounted, with an explicit note
  that whether VME's GFS2 cluster/lock traffic rides the management network on
  9.0+ is unknown to this tool.

## [2.12.0] — switch-side visibility

**Added**
- `--doctor` now reports the switch side from LLDP: per bond member it shows the
  neighbour chassis, port, and any advertised VLANs, then states whether the bond
  lands on **one** switch or **two**. That single fact decides whether LACP is
  even possible, and it is the prerequisite for choosing a bond mode.
- Per-mode switch requirements printed alongside: LACP needs a LAG on the peer
  ports; XOR needs a static aggregation and fails *silently* because it does not
  negotiate; active-backup needs no switch config at all.

**Fixed**
- `set -e` abort in `discover_nics`. A trailing `[[ -n "$peer" ]] && assign`
  returns 1 when a NIC has no LLDP neighbour; as the last statement in the loop
  it made the function return non-zero and killed the run. Only reproducible
  when `lldpd` **is** installed and the final NIC has no neighbour — i.e. on real
  hardware, not a bare test box.

## [2.11.0] — converged repair

**Added**
- `--reconfigure` supports HPE's four-NIC converged reference design (Network
  Considerations, *Four NICs with LACP/XOR bonds and MPIO for storage traffic*).
  When no NICs remain after the management bond it offers converged as the
  documented answer rather than failing.
- Converged renders one bond: management on a tagged VLAN feeding `mgmt`, the
  untagged bond feeding `cmpt`. No phantom second bond.

**Changed**
- Refuses converged with an untagged management VLAN — the untagged bond becomes
  the `cmpt` port and an OVS port belongs to one bridge. Enforced independently
  in the wizard and the YAML editor.
- The "no spare NICs" guidance now cites the HPE design instead of framing
  convergence as a compromise.

## [2.10.0] — findings from a production run

**Added**
- `arp_ignore` / `arp_announce` are checked independently of `rp_filter`. A host
  with several addressed interfaces answers ARP for any local address out any
  NIC, which silently collapses MPIO and reads as a duplicate IP.
- The per-route default-gateway check falls back to the `mgmt` OVS bridge when no
  profile exists, instead of silently no-opping on hosts this tool did not build.

**Changed**
- The duplicate-IP finding no longer claims another host owns the address.
  `arping -D` cannot distinguish a real conflict from a multi-homed self-answer,
  so the output now says how to tell them apart.

## [2.9.0] — Maintenance Mode

**Added**
- `--reconfigure` offers to **wait** for Maintenance Mode. Since parking a host
  evacuates guests and drops it out of the storage cluster, the GFS2 unmount is
  the green light — the tool polls for it and continues on its own.
- `--maint-timeout N` (default 900s). Reminder at the end that the host is still
  parked.

## [2.8.0] — VME 9.0+ correction

**Removed**
- All pacemaker/corosync assumptions. VME 9.0+ manages GFS2 consistency itself
  via heartbeat datastores and its own HA; `pcs node standby` and
  `pcs property set maintenance-mode=true` do not exist on a 9.0+ host. Guidance
  now points at Maintenance Mode in VME Manager.

## [2.7.0] — cluster guard

**Added**
- `--reconfigure` refuses to run when GFS2 is mounted or guests are running,
  because `netplan apply` bounces the bonds. `--force` overrides.

## [2.6.0] — console recovery

**Added**
- Verified, checksummed backups. If the manifest does not reconcile, nothing is
  changed at all.
- A self-contained restore script written to three locations, needing no network,
  no arguments, and no dependency on this script — runs from an iLO console on a
  host whose networking you just destroyed.
- `--list-backups` (re-verifies integrity, flags damaged points) and
  `--rollback[=TIMESTAMP]`.
- Backups capture netplan, sysctl, wait-online drop-in, cloud-init override,
  hosts, resolv.conf, machine-id, plus read-only snapshots of iSCSI/multipath
  config, link/addr/route state, bonding, and full OVS topology.

## [2.5.0] — `--reconfigure`

**Added**
- New mode for hosts where prep has already run and the uplinks are wrong. Any
  NIC carrying an IP is protected as storage; existing management L3 is reused
  rather than retyped.

## [2.4.0] — testability

**Added**
- `SYS_NET` and `PROC_BONDING` are overridable, plus a `sim/` harness that builds
  a mock host tree. No hardware needed.
- `--doctor` flags a `mgmt` bridge with no `cmpt`.

**Fixed**
- `set -o pipefail` abort: `iscsiadm` exits 21 when there are no sessions, which
  silently truncated the doctor run mid-way. Eight pipelines had the same
  exposure. Found by the simulator.

## [2.3.0] — the L3 handoff

**Added**
- Netplan OVS introspection. VME declares its bridges through netplan's native
  OVS support and moves the management address onto the bridge, so an interface
  enslaved into a bridge must end up bare.
- **F09** strips leftover L3 from an enslaved interface, base file only.
- `--wizard` / `--apply` refuse once netplan declares OVS bridges.

**Changed**
- F05/F06 are documented as runtime-only on a prepped host: `netplan apply`
  rebuilds the bridge from YAML and reverts `ovs-vsctl` changes.

## [2.2.0] — file ownership

**Added**
- `*-mvm-*.yaml` and `mvmbackup-*` are treated as VME-owned and never demoted or
  moved. Previously F02 would have moved a working host's `60-`/`61-` files aside.
- Bond-of-one, with automatic degrade to active-backup for single-member bonds.
- Default routes are checked against the management interface; the renderer
  cannot emit a gateway or nameservers on a non-management interface.

## [2.1.0] — single-port roles

**Added**
- Each role independently uses a bond or a single unbonded port.
- **F08** rebuilds a bond with zero enslaved members; refuses over SSH.
- Same-subnet multi-homing detection.

**Changed**
- Compute VLANs are never written into netplan — they are OVS port groups on
  `cmpt`, created in VME Manager.
- Corrected: a locally-administered bond MAC is **normal**. systemd-networkd
  derives bond MACs from `/etc/machine-id`; check the slave count instead.

## [2.0.0] — initial

Wizard, profile-driven apply, doctor with F01–F07, HPE-derived topologies and
bond parameters, dead-man rollback.

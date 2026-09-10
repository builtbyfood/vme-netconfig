#!/usr/bin/env bash
#
# vme-netconfig.sh - HPE Morpheus VM Essentials post-OS network configurator
#
#   Target:  Morpheus VME / HVM 9.0.1 and later on Ubuntu 22.04 / 24.04
#   Stage:   AFTER Ubuntu install, BEFORE `hpe-vm` appliance install
#   Author:  builtbyfood
#   License: MIT
#
# What it does
#   1. Discovers physical NICs (driver, speed, PCI, NUMA, MAC, carrier, LLDP peer)
#   2. Assigns roles: management / compute / compute-2 (DMZ) / iSCSI-MPIO / unused
#   3. Renders a single authoritative netplan file using HPE-recommended settings
#   4. Applies it with a dead-man rollback so you cannot lock yourself out
#   5. Doctors an existing (or broken) host and optionally repairs it
#
# What it deliberately does NOT do
#   * It never creates the OVS `mgmt` / `cmpt` bridges. VME Manager owns those.
#     Pre-creating them is the #1 cause of a wedged install.
#   * It never bonds iSCSI NICs. HPE recommends MPIO for iSCSI/FC GFS2 datastores.
#   * It never touches iSCSI sessions while GFS2 is mounted (see --doctor output).
#
# HPE reference topologies encoded here (VME Deployment Guide, Network
# Considerations -> Example Network Configurations):
#   * 6+ NICs : separate mgmt bond + compute bond + 2x MPIO storage  ("decoupled")
#   * 4  NICs : converged mgmt+compute bond + 2x MPIO storage        ("converged")
#   * Bond types: LACP 802.3ad (MLAG on switch) or balance-xor (no MLAG)
#   * MTU 9000 on bond members, the bond, its VLANs, and storage NICs
#
set -o errexit
set -o nounset
set -o pipefail

VERSION="2.13.0"
PROG="${0##*/}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# Filesystem roots. Overridable so the tool can be exercised against a mock host
# tree in tests and demos; both default to the real kernel interfaces.
SYS_NET="${SYS_NET:-/sys/class/net}"
PROC_BONDING="${PROC_BONDING:-/proc/net/bonding}"

STATE_DIR="/etc/vme-netconfig"
PROFILE_FILE="${STATE_DIR}/profile.conf"
BACKUP_ROOT="${STATE_DIR}/backups"
NETPLAN_DIR="/etc/netplan"
NETPLAN_OUT="${NETPLAN_DIR}/00-vme-netconfig.yaml"
SYSCTL_OUT="/etc/sysctl.d/90-vme-netconfig.conf"
CLOUDINIT_OFF="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
WAITONLINE_DROPIN="/etc/systemd/system/systemd-networkd-wait-online.service.d/10-vme-netconfig.conf"
LOG_FILE="/var/log/vme-netconfig.log"

# Netplan files and directories that VME Manager creates and owns after host
# prep. Touching these breaks a working host - never demote, move, or delete.
# Observed on 9.x: 60-mvm-mgmt.yaml, 61-mvm-compute.yaml, mvmbackup-<ts>/
VME_OWNED_GLOBS=( '*-mvm-*.yaml' 'mvmbackup-*' )
ROLLBACK_UNIT="vme-netconfig-rollback"

# ---------------------------------------------------------------------------
# Runtime flags
# ---------------------------------------------------------------------------
MODE=""                  # wizard | apply | doctor | discover | show
DRY_RUN="no"
ASSUME_YES="no"
DO_FIX="no"
FIX_ONLY=""              # comma list of fix ids, empty = all safe fixes
SAFETY_TIMER="180"       # seconds; 0 disables the dead-man rollback
PROBE_LINKS="no"
IN_PROFILE=""
ROLLBACK_TS=""
MAINT_TIMEOUT="900"
WAS_PARKED="no"
FORCE="no"
NO_SYSCTL="no"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_C=$'\033[36m'; C_DIM=$'\033[2m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_DIM=""
fi

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
_logfile() { [[ -w "$(dirname "$LOG_FILE")" ]] 2>/dev/null && printf '%s %s\n' "$(_ts)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

hdr()  { printf '\n%s%s== %s%s\n' "$C_B" "$C_C" "$*" "$C_RST"; _logfile "== $*"; }
info() { printf '   %s\n' "$*"; _logfile "INFO $*"; }
ok()   { printf '   %s[ ok ]%s %s\n' "$C_G" "$C_RST" "$*"; _logfile "OK   $*"; }
warn() { printf '   %s[warn]%s %s\n' "$C_Y" "$C_RST" "$*"; _logfile "WARN $*"; }
bad()  { printf '   %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$*"; _logfile "FAIL $*"; }
note() { printf '   %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
die()  { printf '\n%s[ABORT]%s %s\n\n' "$C_R" "$C_RST" "$*" >&2; _logfile "ABORT $*"; exit 1; }

run() {
  # run <cmd...>  -- honours DRY_RUN
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '   %s(dry-run)%s %s\n' "$C_DIM" "$C_RST" "$*"
    return 0
  fi
  _logfile "RUN  $*"
  "$@"
}

ask() {
  local prompt="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -r -p "   ${prompt} [${def}]: " ans || true
    printf '%s' "${ans:-$def}"
  else
    read -r -p "   ${prompt}: " ans || true
    printf '%s' "$ans"
  fi
}

ask_yn() {
  local prompt="$1" def="${2:-n}" ans
  if [[ "$ASSUME_YES" == "yes" ]]; then printf 'y'; return 0; fi
  while true; do
    read -r -p "   ${prompt} (y/n) [${def}]: " ans || true
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes) printf 'y'; return 0 ;;
      n|no)  printf 'n'; return 0 ;;
    esac
  done
}


is_vme_owned() {
  # is_vme_owned <path>  -> true if VME Manager owns this netplan artifact
  local base="${1##*/}" g
  for g in "${VME_OWNED_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$base" == $g ]] && return 0
  done
  return 1
}

need_root() { [[ "$(id -u)" -eq 0 ]] || die "must run as root (try: sudo $PROG ...)"; }

# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------
valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a o <<<"$ip"
  for x in "${o[@]}"; do [[ "$x" -le 255 ]] || return 1; done
  return 0
}

valid_cidr() {
  local c="$1"
  [[ "$c" == */* ]] || return 1
  valid_ip "${c%%/*}" || return 1
  local m="${c##*/}"
  [[ "$m" =~ ^[0-9]{1,2}$ ]] && [[ "$m" -ge 1 ]] && [[ "$m" -le 32 ]]
}

valid_vlan() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 0 ]] && [[ "$v" -le 4094 ]]
}

valid_mtu() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] && [[ "$m" -ge 1280 ]] && [[ "$m" -le 9216 ]]
}


# ---------------------------------------------------------------------------
# Netplan introspection
#
# VME Manager declares its bridges through netplan's native OVS support:
#
#   network:
#     bridges:
#       mgmt:
#         addresses: [192.168.200.3/27]
#         interfaces: [bond0.200]
#         routes: [{to: default, via: 192.168.200.1}]
#         openvswitch: {}
#
# So the bridges are netplan objects, not hand-built ovs-vsctl state. Two
# consequences drive everything below:
#
#   1. The L3 config MOVES from the enslaved interface onto the bridge. Whatever
#      file still carries addresses/routes/nameservers on bond0.200 is now a
#      duplicate that fights the bridge for the same address.
#   2. Runtime ovs-vsctl repairs (F05/F06) are transient. `netplan apply` rebuilds
#      the bridge from the file, so a durable fix belongs in the YAML.
# ---------------------------------------------------------------------------
have_pyyaml() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1
}

netplan_bridge_members() {
  # prints: <bridge>\t<member>\t<file>
  have_pyyaml || return 0
  python3 - "$NETPLAN_DIR" <<'PYEOF' 2>/dev/null || true
import sys, glob, os, yaml
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.yaml"))):
    try:
        d = yaml.safe_load(open(f)) or {}
    except Exception:
        continue
    for br, cfg in ((d.get("network") or {}).get("bridges") or {}).items():
        for m in (cfg or {}).get("interfaces") or []:
            print("%s\t%s\t%s" % (br, m, os.path.basename(f)))
PYEOF
}

netplan_l3_owners() {
  # prints: <iface>\t<file>\t<keys>   for anything carrying L3 config
  have_pyyaml || return 0
  python3 - "$NETPLAN_DIR" <<'PYEOF' 2>/dev/null || true
import sys, glob, os, yaml
L3 = ("addresses", "routes", "nameservers", "gateway4", "gateway6")
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.yaml"))):
    try:
        d = yaml.safe_load(open(f)) or {}
    except Exception:
        continue
    net = d.get("network") or {}
    for sec in ("ethernets", "bonds", "vlans", "bridges"):
        for name, cfg in (net.get(sec) or {}).items():
            keys = [k for k in L3 if (cfg or {}).get(k)]
            if keys:
                print("%s\t%s\t%s" % (name, os.path.basename(f), ",".join(keys)))
PYEOF
}

# ---------------------------------------------------------------------------
# NIC discovery
# ---------------------------------------------------------------------------
declare -a NICS=()
declare -A NIC_MAC NIC_PERM NIC_DRV NIC_SPD NIC_PCI NIC_NUMA NIC_CARR NIC_IP \
           NIC_LLDP NIC_STATE NIC_MTU NIC_ENSLAVED NIC_FW

is_physical_nic() {
  local n="$1"
  [[ "$n" == "lo" ]] && return 1
  [[ -e "${SYS_NET}/${n}/device" ]] || return 1
  # skip OVS internal / virtual constructs that still expose a device link
  [[ -d "${SYS_NET}/${n}/bonding" ]] && return 1
  [[ -d "${SYS_NET}/${n}/bridge" ]] && return 1
  [[ -e "${SYS_NET}/${n}/tun_flags" ]] && return 1
  case "$n" in
    veth*|docker*|virbr*|vnet*|ovs-system|tap*|wg*|br-*) return 1 ;;
  esac
  return 0
}


require_cmds() {
  local missing=""
  local c
  for c in ip awk sed grep sort; do
    command -v "$c" >/dev/null 2>&1 || missing="${missing} ${c}"
  done
  [[ -n "$missing" ]] && die "missing required commands:${missing}"
  for c in ethtool lldpctl arping; do
    command -v "$c" >/dev/null 2>&1 || note "optional tool '${c}' not installed - some detail will be omitted"
  done
  return 0
}

discover_nics() {
  require_cmds
  NICS=()
  local n
  for n in $(ls -1 ${SYS_NET} 2>/dev/null | sort -V); do
    is_physical_nic "$n" || continue
    NICS+=("$n")
  done
  [[ ${#NICS[@]} -gt 0 ]] || die "no physical NICs detected under /sys/class/net"

  if [[ "$PROBE_LINKS" == "yes" ]]; then
    info "probing link state (bringing admin-down NICs up for carrier detect)..."
    for n in "${NICS[@]}"; do
      [[ "$(cat "${SYS_NET}/${n}/operstate" 2>/dev/null)" == "down" ]] \
        && ip link set dev "$n" up 2>/dev/null || true
    done
    sleep 4
  fi

  for n in "${NICS[@]}"; do
    NIC_MAC[$n]="$(cat "${SYS_NET}/${n}/address" 2>/dev/null || echo '?')"
    NIC_MTU[$n]="$(cat "${SYS_NET}/${n}/mtu" 2>/dev/null || echo '?')"
    NIC_STATE[$n]="$(cat "${SYS_NET}/${n}/operstate" 2>/dev/null || echo '?')"
    NIC_CARR[$n]="$(cat "${SYS_NET}/${n}/carrier" 2>/dev/null || echo '0')"
    local spd; spd="$(cat "${SYS_NET}/${n}/speed" 2>/dev/null || echo '')"
    if [[ -n "$spd" && "$spd" -gt 0 ]] 2>/dev/null; then
      if [[ "$spd" -ge 1000 ]]; then NIC_SPD[$n]="$((spd/1000))G"; else NIC_SPD[$n]="${spd}M"; fi
    else
      NIC_SPD[$n]="-"
    fi
    NIC_DRV[$n]="$(basename "$(readlink -f "${SYS_NET}/${n}/device/driver" 2>/dev/null || echo '?')")"
    NIC_PCI[$n]="$(basename "$(readlink -f "${SYS_NET}/${n}/device" 2>/dev/null || echo '?')")"
    NIC_NUMA[$n]="$(cat "${SYS_NET}/${n}/device/numa_node" 2>/dev/null || echo '-')"
    NIC_IP[$n]="$(ip -o -4 addr show dev "$n" 2>/dev/null | awk '{print $4}' | paste -sd, - )"
    NIC_ENSLAVED[$n]="$(basename "$(readlink -f "${SYS_NET}/${n}/master" 2>/dev/null || echo '')")"
    [[ "${NIC_ENSLAVED[$n]}" == "." || "${NIC_ENSLAVED[$n]}" == "/" ]] && NIC_ENSLAVED[$n]=""
    NIC_PERM[$n]=""
    NIC_FW[$n]=""
    if command -v ethtool >/dev/null 2>&1; then
      NIC_PERM[$n]="$(ethtool -P "$n" 2>/dev/null | awk '{print $NF}')"
      NIC_FW[$n]="$(ethtool -i "$n" 2>/dev/null | awk -F': ' '/^firmware-version/{print $2}')"
    fi
    NIC_LLDP[$n]="-"
    if command -v lldpctl >/dev/null 2>&1; then
      local peer port
      peer="$(lldpctl -f keyvalue "$n" 2>/dev/null | awk -F= '/\.chassis\.name=/{print $2; exit}')"
      port="$(lldpctl -f keyvalue "$n" 2>/dev/null | awk -F= '/\.port\.descr=/{print $2; exit}')"
      if [[ -n "${peer:-}" ]]; then NIC_LLDP[$n]="${peer}${port:+ / $port}"; fi
    fi
  done
  return 0
}

print_nic_table() {
  printf '\n  %-3s %-14s %-8s %-6s %-12s %-4s %-5s %-18s %-16s %s\n' \
    "#" "IFACE" "STATE" "SPEED" "DRIVER" "NUMA" "MTU" "MAC" "IPv4" "LLDP PEER"
  printf '  %s\n' "$(printf '%.0s-' {1..118})"
  local i=1 n st
  for n in "${NICS[@]}"; do
    if [[ "${NIC_CARR[$n]}" == "1" ]]; then st="up/link"
    elif [[ "${NIC_STATE[$n]}" == "up" ]]; then st="up/NOLINK"
    else st="${NIC_STATE[$n]}"; fi
    printf '  %-3s %-14s %-8s %-6s %-12s %-4s %-5s %-18s %-16s %s\n' \
      "$i" "$n" "$st" "${NIC_SPD[$n]}" "${NIC_DRV[$n]}" "${NIC_NUMA[$n]}" \
      "${NIC_MTU[$n]}" "${NIC_MAC[$n]}" "${NIC_IP[$n]:--}" "${NIC_LLDP[$n]}"
    i=$((i+1))
  done
  printf '\n'
  local up=0
  for n in "${NICS[@]}"; do [[ "${NIC_CARR[$n]}" == "1" ]] && up=$((up+1)); done
  note "${#NICS[@]} physical NICs, ${up} with carrier."
  note "Pair NICs across two cards/PCI roots for each bond so a card loss is survivable."
}

nic_by_index() {
  # nic_by_index "1 3 5" -> "ens1f0 ens1f1 ens2f0"
  local out=() idx
  for idx in $1; do
    [[ "$idx" =~ ^[0-9]+$ ]] || { printf '__BAD__'; return 1; }
    [[ "$idx" -ge 1 && "$idx" -le ${#NICS[@]} ]] || { printf '__BAD__'; return 1; }
    out+=("${NICS[$((idx-1))]}")
  done
  printf '%s' "${out[*]}"
}

current_uplink() {
  ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -1
}

ssh_uplink() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 0
  local cip="${SSH_CONNECTION%% *}"
  ip -o -4 route get "$cip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1
}

# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------
VME_TOPOLOGY=""; BOND_MODE=""
MGMT_LINK_MODE="bond"; COMPUTE_LINK_MODE="bond"; COMPUTE2_LINK_MODE="bond"
MGMT_BOND="bond0"; MGMT_MEMBERS=""; MGMT_VLAN="0"; MGMT_ADDR=""; MGMT_GW=""
MGMT_DNS=""; MGMT_SEARCH=""; MGMT_MTU="1500"
COMPUTE_BOND="bond1"; COMPUTE_MEMBERS=""; COMPUTE_MTU="9000"; COMPUTE_VLANS=""
COMPUTE2_BOND="bond2"; COMPUTE2_MEMBERS=""; COMPUTE2_MTU="9000"; COMPUTE2_VLANS=""
ISCSI_ENABLED="no"; ISCSI_NICS=""; ISCSI_ADDRS=""; ISCSI_VLANS=""; ISCSI_MTU="9000"
ISCSI_PORTALS=""
HOST_LABEL="$(hostname -s 2>/dev/null || echo host)"

load_profile() {
  local f="$1"
  [[ -r "$f" ]] || die "profile not readable: $f"
  # shellcheck disable=SC1090
  source "$f"
  info "loaded profile: $f"
}

save_profile() {
  mkdir -p "$STATE_DIR"
  local f="${1:-$PROFILE_FILE}"
  cat >"$f" <<EOF
# vme-netconfig profile  --  generated $(_ts) by ${PROG} v${VERSION}
# Host: ${HOST_LABEL}
# Re-apply non-interactively with:  sudo ${PROG} --apply --profile ${f}

VME_TOPOLOGY="${VME_TOPOLOGY}"
BOND_MODE="${BOND_MODE}"

# --- management ---
MGMT_LINK_MODE="${MGMT_LINK_MODE}"
MGMT_BOND="${MGMT_BOND}"
MGMT_MEMBERS="${MGMT_MEMBERS}"
MGMT_VLAN="${MGMT_VLAN}"
MGMT_ADDR="${MGMT_ADDR}"
MGMT_GW="${MGMT_GW}"
MGMT_DNS="${MGMT_DNS}"
MGMT_SEARCH="${MGMT_SEARCH}"
MGMT_MTU="${MGMT_MTU}"

# --- compute (VM traffic trunk) ---
COMPUTE_LINK_MODE="${COMPUTE_LINK_MODE}"
COMPUTE_BOND="${COMPUTE_BOND}"
COMPUTE_MEMBERS="${COMPUTE_MEMBERS}"
COMPUTE_MTU="${COMPUTE_MTU}"
COMPUTE_VLANS="${COMPUTE_VLANS}"

# --- second compute uplink (DMZ / physically segmented) ---
COMPUTE2_LINK_MODE="${COMPUTE2_LINK_MODE}"
COMPUTE2_BOND="${COMPUTE2_BOND}"
COMPUTE2_MEMBERS="${COMPUTE2_MEMBERS}"
COMPUTE2_MTU="${COMPUTE2_MTU}"
COMPUTE2_VLANS="${COMPUTE2_VLANS}"

# --- iSCSI (MPIO, never bonded) ---
ISCSI_ENABLED="${ISCSI_ENABLED}"
ISCSI_NICS="${ISCSI_NICS}"
ISCSI_ADDRS="${ISCSI_ADDRS}"
ISCSI_VLANS="${ISCSI_VLANS}"
ISCSI_MTU="${ISCSI_MTU}"
ISCSI_PORTALS="${ISCSI_PORTALS}"
EOF
  chmod 0600 "$f"
  ok "profile saved: $f"
}


# --- role -> kernel device name -----------------------------------------
# A role is either a bond over 2+ NICs or a single unbonded port.
mgmt_dev() {
  if [[ "$MGMT_LINK_MODE" == "single" ]]; then printf '%s' "${MGMT_MEMBERS%% *}"
  else printf '%s' "$MGMT_BOND"; fi
}
mgmt_l3dev() {
  local d; d="$(mgmt_dev)"
  if [[ "$MGMT_VLAN" != "0" ]]; then printf '%s.%s' "$d" "$MGMT_VLAN"; else printf '%s' "$d"; fi
}
compute_dev() {
  if [[ "$VME_TOPOLOGY" == "converged" ]]; then mgmt_dev; return; fi
  if [[ "$COMPUTE_LINK_MODE" == "single" ]]; then printf '%s' "${COMPUTE_MEMBERS%% *}"
  else printf '%s' "$COMPUTE_BOND"; fi
}
compute2_dev() {
  [[ -n "$COMPUTE2_MEMBERS" ]] || return 0
  if [[ "$COMPUTE2_LINK_MODE" == "single" ]]; then printf '%s' "${COMPUTE2_MEMBERS%% *}"
  else printf '%s' "$COMPUTE2_BOND"; fi
}
link_mode_for() {
  # link_mode_for "<members>" -> bond | single
  local cnt=0 x
  for x in $1; do cnt=$((cnt+1)); done
  [[ "$cnt" -le 1 ]] && printf 'single' || printf 'bond'
}

mac_of() { printf '%s' "${NIC_PERM[$1]:-${NIC_MAC[$1]:-}}"; }

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
wizard() {
  hdr "Step 1 - discovered network interfaces"
  print_nic_table

  local up_now ssh_if
  up_now="$(current_uplink || true)"
  ssh_if="$(ssh_uplink || true)"
  [[ -n "$up_now" ]] && note "Default route currently via: ${up_now}"
  if [[ -n "$ssh_if" ]]; then
    warn "Your SSH session arrives on '${ssh_if}'. If that NIC becomes a bond member the"
    warn "session will drop briefly during apply. A ${SAFETY_TIMER}s dead-man rollback is armed."
  fi

  hdr "Step 2 - topology"
  cat <<'EOT'
   HPE reference designs:
     1) decoupled  - separate management bond + compute bond (+ MPIO storage)
                     needs 6+ NICs. Best isolation and throughput.
     2) converged  - one bond carries management VLAN and the compute trunk
                     (+ MPIO storage). For 4-NIC hosts.
EOT
  local t
  while true; do
    t="$(ask 'Topology (1=decoupled, 2=converged)' '1')"
    case "$t" in
      1) VME_TOPOLOGY="decoupled"; break ;;
      2) VME_TOPOLOGY="converged"; break ;;
    esac
  done
  ok "topology: ${VME_TOPOLOGY}"

  hdr "Step 3 - bond mode (ignored for any role that uses a single port)"
  cat <<'EOT'
     1) lacp           802.3ad, layer3+4 hash, fast LACPDU. Requires switch
                       MLAG/LAG config on the peer ports. HPE default choice.
     2) xor            balance-xor, layer3+4 hash. No switch LAG needed.
     3) active-backup  single active link. Safest when switch config is unknown.
EOT
  local b
  while true; do
    b="$(ask 'Bond mode (1=lacp, 2=xor, 3=active-backup)' '1')"
    case "$b" in
      1) BOND_MODE="lacp"; break ;;
      2) BOND_MODE="xor"; break ;;
      3) BOND_MODE="active-backup"; break ;;
    esac
  done
  ok "bond mode: ${BOND_MODE}"
  if [[ "$BOND_MODE" == "lacp" ]]; then
    note "Confirm the peer switch ports are in a LAG/MLAG *before* apply. Half-configured"
    note "LACP shows as an aggregator that never forms and looks like flapping."
  fi

  # ---- management -------------------------------------------------------
  hdr "Step 4 - management bond (${MGMT_BOND})"
  note "This carries the host IP, VME Manager agent traffic, and cluster heartbeat."
  local sel
  note "Pick ONE NIC for a single unbonded management port, or TWO+ to bond them."
  while true; do
    sel="$(ask 'Management NIC number(s), space separated')"
    MGMT_MEMBERS="$(nic_by_index "$sel" || true)"
    [[ "$MGMT_MEMBERS" != "__BAD__" && -n "$MGMT_MEMBERS" ]] && break
    warn "invalid selection"
  done
  MGMT_LINK_MODE="$(link_mode_for "$MGMT_MEMBERS")"
  if [[ "$MGMT_LINK_MODE" == "single" ]]; then
    note "A bond over a single NIC is still worth doing: VME records the interface"
    note "name in the cluster, so adding a second link later means editing netplan"
    note "instead of re-pointing the cluster at a different device."
    [[ "$(ask_yn 'Wrap this single NIC in a bond?' 'y')" == "y" ]] && MGMT_LINK_MODE="bond"
  fi
  if [[ "$MGMT_LINK_MODE" == "bond" ]]; then
    MGMT_BOND="$(ask 'Management bond name' "$MGMT_BOND")"
    ok "management: ${MGMT_BOND} <- ${MGMT_MEMBERS}"
  else
    warn "Single management port: no link redundancy. A cable, optic, or switch-port"
    warn "failure takes this host out of the cluster. Fine for a lab, think hard in prod."
    ok "management: ${MGMT_MEMBERS} (unbonded)"
  fi

  while true; do
    MGMT_VLAN="$(ask 'Management VLAN id (0 = untagged / native on the bond)' "$MGMT_VLAN")"
    valid_vlan "$MGMT_VLAN" && break || warn "vlan must be 0-4094"
  done
  if [[ "$VME_TOPOLOGY" == "converged" && "$MGMT_VLAN" == "0" ]]; then
    warn "Converged topology with an untagged management VLAN means the compute trunk"
    warn "and the host IP share the native VLAN. HPE's 4-NIC example tags management"
    warn "(e.g. bond0.2) and hands the untagged bond to compute. Strongly recommended."
    [[ "$(ask_yn 'Continue with untagged management anyway?' 'n')" == "y" ]] \
      || { MGMT_VLAN="$(ask 'Management VLAN id' '2')"; }
  fi

  while true; do
    MGMT_ADDR="$(ask 'Management IPv4 address in CIDR (e.g. 10.10.10.21/24)' "$MGMT_ADDR")"
    valid_cidr "$MGMT_ADDR" && break || warn "must be address/prefix"
  done
  while true; do
    MGMT_GW="$(ask 'Default gateway' "$MGMT_GW")"
    valid_ip "$MGMT_GW" && break || warn "invalid IPv4"
  done
  MGMT_DNS="$(ask 'DNS servers (space separated)' "${MGMT_DNS:-}")"
  MGMT_SEARCH="$(ask 'DNS search domains (space separated)' "${MGMT_SEARCH:-}")"
  while true; do
    MGMT_MTU="$(ask 'Management MTU (1500 unless the whole mgmt path is jumbo-clean)' "$MGMT_MTU")"
    valid_mtu "$MGMT_MTU" && break || warn "mtu 1280-9216"
  done

  # ---- compute ---------------------------------------------------------
  hdr "Step 5 - compute uplink"
  if [[ "$VME_TOPOLOGY" == "converged" ]]; then
    COMPUTE_BOND="$MGMT_BOND"
    COMPUTE_MEMBERS="$MGMT_MEMBERS"
    COMPUTE_MTU="$MGMT_MTU"
    COMPUTE_LINK_MODE="$MGMT_LINK_MODE"
    ok "converged: compute uses $(mgmt_dev) (same link as management)"
    note "VME cluster wizard: MANAGEMENT = $(mgmt_l3dev), COMPUTE = $(mgmt_dev)"
    if [[ "$MGMT_MTU" -lt 1550 ]]; then
      warn "MTU ${MGMT_MTU} on a converged bond leaves no room for VXLAN overlay headers."
      warn "Guest MTU 1500 needs >=1550 on the uplink. 9000 is the safe answer."
      local nm; nm="$(ask 'Raise converged bond MTU to' '9000')"
      if valid_mtu "$nm"; then MGMT_MTU="$nm"; COMPUTE_MTU="$nm"; ok "MTU set to ${nm}"; fi
    fi
  else
    note "Pick ONE NIC for a single unbonded VM-traffic port, or TWO+ to bond them."
    while true; do
      sel="$(ask 'Compute NIC number(s)')"
      COMPUTE_MEMBERS="$(nic_by_index "$sel" || true)"
      [[ "$COMPUTE_MEMBERS" != "__BAD__" && -n "$COMPUTE_MEMBERS" ]] && break
      warn "invalid selection"
    done
    COMPUTE_LINK_MODE="$(link_mode_for "$COMPUTE_MEMBERS")"
    if [[ "$COMPUTE_LINK_MODE" == "single" ]]; then
      warn "Single compute port: VM traffic has no link redundancy."
      note "Wrapping it in a bond now lets you add a second link later without"
      note "changing the interface name the cluster is pinned to."
      [[ "$(ask_yn 'Wrap this single NIC in a bond?' 'y')" == "y" ]] && COMPUTE_LINK_MODE="bond"
    fi
    [[ "$COMPUTE_LINK_MODE" == "bond" ]] && COMPUTE_BOND="$(ask 'Compute bond name' "$COMPUTE_BOND")"
    local dup=""
    for x in $COMPUTE_MEMBERS; do
      for y in $MGMT_MEMBERS; do [[ "$x" == "$y" ]] && dup="$x"; done
    done
    [[ -n "$dup" ]] && die "NIC ${dup} assigned to both management and compute"
    while true; do
      COMPUTE_MTU="$(ask 'Compute MTU (9000 recommended; overlay needs headroom)' "$COMPUTE_MTU")"
      valid_mtu "$COMPUTE_MTU" && break || warn "mtu 1280-9216"
    done
    [[ "$COMPUTE_MTU" -lt 1550 ]] && warn "MTU < 1550 will break 1500-byte guests over VXLAN overlay"
    ok "compute: $(compute_dev) <- ${COMPUTE_MEMBERS} @ MTU ${COMPUTE_MTU}"
  fi
  note "Tagged VM VLANs ride the compute uplink as an untagged trunk. VME Manager"
  note "creates them as OVS port groups on 'cmpt' (HVM Standard Networks in the UI)."
  note "They are recorded here for the cluster wizard - never written into netplan."
  COMPUTE_VLANS="$(ask 'Compute VLAN ids/range (e.g. 200,210-211)' "${COMPUTE_VLANS:-}")"

  # ---- second compute --------------------------------------------------
  hdr "Step 6 - second compute uplink (DMZ / physical segmentation)"
  note "Use this when DMZ or PCI traffic must ride physically separate NICs and switches"
  note "rather than just a different VLAN on the same trunk."
  if [[ "$(ask_yn 'Configure a second compute uplink?' 'n')" == "y" ]]; then
    while true; do
      sel="$(ask 'Second compute NIC number(s)')"
      COMPUTE2_MEMBERS="$(nic_by_index "$sel" || true)"
      [[ "$COMPUTE2_MEMBERS" != "__BAD__" && -n "$COMPUTE2_MEMBERS" ]] && break
      warn "invalid selection"
    done
    COMPUTE2_LINK_MODE="$(link_mode_for "$COMPUTE2_MEMBERS")"
    [[ "$COMPUTE2_LINK_MODE" == "bond" ]] && COMPUTE2_BOND="$(ask 'Second compute bond name' "$COMPUTE2_BOND")"
    for x in $COMPUTE2_MEMBERS; do
      for y in $MGMT_MEMBERS $COMPUTE_MEMBERS; do
        [[ "$x" == "$y" ]] && die "NIC ${x} already assigned"
      done
    done
    while true; do
      COMPUTE2_MTU="$(ask 'Second compute MTU' "$COMPUTE2_MTU")"
      valid_mtu "$COMPUTE2_MTU" && break || warn "mtu 1280-9216"
    done
    COMPUTE2_VLANS="$(ask 'Second compute VLAN ids/range' "${COMPUTE2_VLANS:-}")"
    ok "second compute: $(compute2_dev) <- ${COMPUTE2_MEMBERS}"
    note "VME will need a second OVS bridge for this. Add it as an additional compute"
    note "interface when creating/editing the cluster; do not hand-build the bridge."
  else
    COMPUTE2_MEMBERS=""
  fi

  # ---- iSCSI -----------------------------------------------------------
  hdr "Step 7 - iSCSI storage (MPIO)"
  note "HPE recommends MPIO, not bonding, for iSCSI/FC LUNs backing GFS2 datastores."
  note "Each NIC gets its own subnet and reaches one portal. No gateway, no DNS."
  if [[ "$(ask_yn 'Configure iSCSI interfaces?' 'y')" == "y" ]]; then
    ISCSI_ENABLED="yes"
    while true; do
      sel="$(ask 'iSCSI NIC numbers (2 for dual-path MPIO)')"
      ISCSI_NICS="$(nic_by_index "$sel" || true)"
      [[ "$ISCSI_NICS" != "__BAD__" && -n "$ISCSI_NICS" ]] && break
      warn "invalid selection"
    done
    for x in $ISCSI_NICS; do
      for y in $MGMT_MEMBERS $COMPUTE_MEMBERS $COMPUTE2_MEMBERS; do
        [[ "$x" == "$y" ]] && die "NIC ${x} already assigned"
      done
    done
    local cnt=0; for x in $ISCSI_NICS; do cnt=$((cnt+1)); done
    [[ "$cnt" -eq 1 ]] && warn "single iSCSI NIC = no multipath redundancy"
    ISCSI_ADDRS=""; ISCSI_VLANS=""
    local a v
    for x in $ISCSI_NICS; do
      while true; do
        a="$(ask "  ${x} iSCSI address in CIDR")"
        valid_cidr "$a" && break || warn "must be address/prefix"
      done
      while true; do
        v="$(ask "  ${x} VLAN id (0 = access port, already on the storage VLAN)" '0')"
        valid_vlan "$v" && break || warn "vlan 0-4094"
      done
      ISCSI_ADDRS="${ISCSI_ADDRS}${ISCSI_ADDRS:+ }${a}"
      ISCSI_VLANS="${ISCSI_VLANS}${ISCSI_VLANS:+ }${v}"
    done
    while true; do
      ISCSI_MTU="$(ask 'iSCSI MTU (9000 strongly recommended)' "$ISCSI_MTU")"
      valid_mtu "$ISCSI_MTU" && break || warn "mtu 1280-9216"
    done
    ISCSI_PORTALS="$(ask 'Portal IPs for post-apply reachability test (space separated, optional)' "${ISCSI_PORTALS:-}")"
    # distinct-subnet sanity check
    local -a nets=()
    for a in $ISCSI_ADDRS; do
      nets+=("$(printf '%s' "${a%%/*}" | cut -d. -f1-3)")
    done
    local i j
    for ((i=0;i<${#nets[@]};i++)); do
      for ((j=i+1;j<${#nets[@]};j++)); do
        if [[ "${nets[$i]}" == "${nets[$j]}" ]]; then
          warn "two iSCSI NICs share subnet ${nets[$i]}.0 - Linux will ARP for both out one NIC."
          warn "rp_filter/arp_ignore hardening will be written, but separate subnets are better."
        fi
      done
    done
    ok "iSCSI: ${ISCSI_NICS}"
  else
    ISCSI_ENABLED="no"; ISCSI_NICS=""
  fi

  # ---- unused ----------------------------------------------------------
  local unused="" n assigned
  for n in "${NICS[@]}"; do
    assigned="no"
    for y in $MGMT_MEMBERS $COMPUTE_MEMBERS $COMPUTE2_MEMBERS $ISCSI_NICS; do
      [[ "$n" == "$y" ]] && assigned="yes"
    done
    [[ "$assigned" == "no" ]] && unused="${unused}${unused:+ }${n}"
  done
  [[ -n "$unused" ]] && { hdr "Unassigned NICs"; note "$unused (will be left down and unconfigured)"; }

  hdr "Step 8 - review"
  print_plan
  [[ "$(ask_yn 'Write this configuration?' 'y')" == "y" ]] || die "cancelled by user"
  save_profile "$PROFILE_FILE"
}

print_plan() {
  local md cd c2
  md="$(mgmt_dev)"; cd="$(compute_dev)"; c2="$(compute2_dev || true)"
  printf '   %-22s %s\n' "topology:"  "${VME_TOPOLOGY}"
  if [[ "$MGMT_LINK_MODE" == "bond" || "$COMPUTE_LINK_MODE" == "bond" ]]; then
    printf '   %-22s %s\n' "bond mode:" "${BOND_MODE}"
  fi
  printf '   %-22s %s [%s]  <- %s  (mtu %s)\n' "management uplink:" "$md" "$MGMT_LINK_MODE" "${MGMT_MEMBERS}" "${MGMT_MTU}"
  printf '   %-22s %s = %s  gw %s\n' "management L3:" "$(mgmt_l3dev)" "${MGMT_ADDR}" "${MGMT_GW}"
  [[ -n "$MGMT_DNS" ]] && printf '   %-22s %s\n' "dns:" "${MGMT_DNS} ${MGMT_SEARCH}"
  if [[ "$VME_TOPOLOGY" == "converged" ]]; then
    printf '   %-22s %s (converged with management, no L3)\n' "compute uplink:" "$cd"
  else
    printf '   %-22s %s [%s]  <- %s  (mtu %s)\n' "compute uplink:" "$cd" "$COMPUTE_LINK_MODE" "${COMPUTE_MEMBERS}" "${COMPUTE_MTU}"
  fi
  printf '   %-22s %s  (created in VME as OVS port groups on cmpt, NOT in netplan)\n' \
    "compute VLANs:" "${COMPUTE_VLANS:-<none set>}"
  [[ -n "$COMPUTE2_MEMBERS" ]] && {
    printf '   %-22s %s [%s]  <- %s  (mtu %s)\n' "compute-2 uplink:" "$c2" "$COMPUTE2_LINK_MODE" "${COMPUTE2_MEMBERS}" "${COMPUTE2_MTU}"
    printf '   %-22s %s\n' "compute-2 VLANs:" "${COMPUTE2_VLANS:--}"
  }
  if [[ "$ISCSI_ENABLED" == "yes" ]]; then
    local -a in=() ia=() iv=(); local i
    read -r -a in <<<"$ISCSI_NICS"; read -r -a ia <<<"$ISCSI_ADDRS"; read -r -a iv <<<"$ISCSI_VLANS"
    for ((i=0;i<${#in[@]};i++)); do
      local dv="${in[$i]}"
      [[ "${iv[$i]:-0}" != "0" ]] && dv="${in[$i]}.${iv[$i]}"
      printf '   %-22s %s = %s  (mtu %s, no gw, unbonded)\n' "iscsi path $((i+1)):" "$dv" "${ia[$i]}" "${ISCSI_MTU}"
    done
  fi
  printf '\n'
  note "VME cluster wizard answers:"
  note "  MANAGEMENT NET INTERFACE : $(mgmt_l3dev)"
  note "  COMPUTE NET INTERFACE    : ${cd}"
  [[ -n "$COMPUTE2_MEMBERS" ]] && note "  COMPUTE NET INTERFACE (2): ${c2}"
  if [[ "$ISCSI_ENABLED" == "yes" ]]; then
    note "  STORAGE NET INTERFACE    : $(printf '%s' "$ISCSI_NICS" | awk '{print $1}') (MPIO across: ${ISCSI_NICS})"
  fi
  note "  COMPUTE VLANS            : ${COMPUTE_VLANS:-<none set>}"
}

# ---------------------------------------------------------------------------
# Netplan rendering
# ---------------------------------------------------------------------------
bond_params_yaml() {
  # $1 = indent, $2 = member count (optional)
  local ind="$1" nmem="${2:-2}" mode="$BOND_MODE"
  # LACP over a single link negotiates with nothing useful and some switches will
  # not form a one-port LAG at all. Degrade to active-backup and say so.
  if [[ "$nmem" -le 1 && "$mode" != "active-backup" ]]; then
    printf '%s# single-member bond: %s degraded to active-backup\n' "$ind" "$mode" >&2
    mode="active-backup"
  fi
  case "$mode" in
    lacp)
      cat <<EOF
${ind}parameters:
${ind}  mode: 802.3ad
${ind}  lacp-rate: fast
${ind}  transmit-hash-policy: layer3+4
${ind}  mii-monitor-interval: 100
${ind}  ad-select: bandwidth
${ind}  up-delay: 200
${ind}  down-delay: 200
${ind}  min-links: 1
EOF
      ;;
    xor)
      cat <<EOF
${ind}parameters:
${ind}  mode: balance-xor
${ind}  transmit-hash-policy: layer3+4
${ind}  mii-monitor-interval: 100
${ind}  up-delay: 200
${ind}  down-delay: 200
EOF
      ;;
    active-backup)
      cat <<EOF
${ind}parameters:
${ind}  mode: active-backup
${ind}  mii-monitor-interval: 100
${ind}  up-delay: 200
${ind}  down-delay: 200
${ind}  fail-over-mac-policy: active
EOF
      ;;
  esac
}

yaml_list() {
  # yaml_list "a b c" -> [a, b, c]
  local out="" x
  for x in $1; do out="${out}${out:+, }${x}"; done
  printf '[%s]' "$out"
}

render_netplan() {
  local f="$1"
  local n a v i
  local -a in=() ia=() iv=()
  local have_bonds="no"
  [[ "$MGMT_LINK_MODE" == "bond" ]] && have_bonds="yes"
  [[ "$VME_TOPOLOGY" == "decoupled" && "$COMPUTE_LINK_MODE" == "bond" ]] && have_bonds="yes"
  [[ -n "$COMPUTE2_MEMBERS" && "$COMPUTE2_LINK_MODE" == "bond" ]] && have_bonds="yes"

  _eth_head() {
    printf '    %s:\n' "$1"
    printf '      match:\n        macaddress: "%s"\n' "$(mac_of "$1")"
    printf '      set-name: %s\n' "$1"
    printf '      dhcp4: no\n      dhcp6: no\n      accept-ra: no\n'
    printf '      mtu: %s\n' "$2"
  }
  _l3_block() {
    printf '      addresses: [%s]\n' "$MGMT_ADDR"
    printf '      routes:\n        - to: default\n          via: %s\n' "$MGMT_GW"
    if [[ -n "$MGMT_DNS" ]]; then
      printf '      nameservers:\n        addresses: %s\n' "$(yaml_list "$MGMT_DNS")"
      [[ -n "$MGMT_SEARCH" ]] && printf '        search: %s\n' "$(yaml_list "$MGMT_SEARCH")"
    fi
    printf '      optional: false\n'
  }
  _passive_block() {
    printf '      link-local: []\n      optional: true\n'
  }

  {
  cat <<EOF
# Managed by ${PROG} v${VERSION} - generated $(_ts)
#
# Authoritative VME host network definition. Edit the profile at
# ${PROFILE_FILE} and re-run instead of hand-editing this file.
#
# TWO THINGS THIS FILE DELIBERATELY OMITS:
#
#  1. The OVS bridges 'mgmt' and 'cmpt'. VME Manager creates and owns them
#     during host prep and migrates the management IP onto the mgmt bridge's
#     internal port. Pre-creating them wedges the install.
#
#  2. The compute VLANs. Tagged VM networks (VLAN 210, 211, ...) are created
#     in VME Manager as HVM Standard Networks - OVS port groups on 'cmpt'.
#     Defining an OS-level VLAN subinterface on the compute uplink here would
#     steal that tagged traffic before OVS ever sees it. The compute uplink is
#     handed to VME as an untagged trunk and nothing else.
#
# The only VLAN subinterface this file creates is the management one, because
# the host needs an IP before VME Manager exists to move it.
network:
  version: 2
  renderer: networkd
  ethernets:
EOF

  # ---- management ------------------------------------------------------
  for n in $MGMT_MEMBERS; do
    _eth_head "$n" "$MGMT_MTU"
    if [[ "$MGMT_LINK_MODE" == "single" && "$MGMT_VLAN" == "0" ]]; then
      _l3_block
    else
      _passive_block
    fi
  done

  # ---- compute ---------------------------------------------------------
  if [[ "$VME_TOPOLOGY" == "decoupled" ]]; then
    for n in $COMPUTE_MEMBERS; do
      _eth_head "$n" "$COMPUTE_MTU"
      _passive_block
    done
  fi
  for n in $COMPUTE2_MEMBERS; do
    _eth_head "$n" "$COMPUTE2_MTU"
    _passive_block
  done

  # ---- iSCSI: standalone, MPIO, no gateway, no DNS ---------------------
  if [[ "$ISCSI_ENABLED" == "yes" ]]; then
    read -r -a in <<<"$ISCSI_NICS"; read -r -a ia <<<"$ISCSI_ADDRS"; read -r -a iv <<<"$ISCSI_VLANS"
    for ((i=0;i<${#in[@]};i++)); do
      n="${in[$i]}"; a="${ia[$i]}"; v="${iv[$i]:-0}"
      _eth_head "$n" "$ISCSI_MTU"
      printf '      link-local: []\n      optional: true\n'
      [[ "$v" == "0" ]] && printf '      addresses: [%s]\n' "$a"
    done
  fi

  # ---- bonds -----------------------------------------------------------
  if [[ "$have_bonds" == "yes" ]]; then
    printf '  bonds:\n'
    if [[ "$MGMT_LINK_MODE" == "bond" ]]; then
      printf '    %s:\n' "$MGMT_BOND"
      printf '      interfaces: %s\n' "$(yaml_list "$MGMT_MEMBERS")"
      printf '      dhcp4: no\n      dhcp6: no\n      accept-ra: no\n'
      printf '      mtu: %s\n' "$MGMT_MTU"
      if [[ "$MGMT_VLAN" == "0" ]]; then _l3_block; else _passive_block; fi
      bond_params_yaml '      ' "$(wc -w <<<"$MGMT_MEMBERS")"
    fi
    if [[ "$VME_TOPOLOGY" == "decoupled" && "$COMPUTE_LINK_MODE" == "bond" ]]; then
      printf '    %s:\n' "$COMPUTE_BOND"
      printf '      interfaces: %s\n' "$(yaml_list "$COMPUTE_MEMBERS")"
      printf '      dhcp4: no\n      dhcp6: no\n      accept-ra: no\n'
      printf '      mtu: %s\n' "$COMPUTE_MTU"
      _passive_block
      bond_params_yaml '      ' "$(wc -w <<<"$COMPUTE_MEMBERS")"
    fi
    if [[ -n "$COMPUTE2_MEMBERS" && "$COMPUTE2_LINK_MODE" == "bond" ]]; then
      printf '    %s:\n' "$COMPUTE2_BOND"
      printf '      interfaces: %s\n' "$(yaml_list "$COMPUTE2_MEMBERS")"
      printf '      dhcp4: no\n      dhcp6: no\n      accept-ra: no\n'
      printf '      mtu: %s\n' "$COMPUTE2_MTU"
      _passive_block
      bond_params_yaml '      ' "$(wc -w <<<"$COMPUTE2_MEMBERS")"
    fi
  fi

  # ---- vlans (management only, plus tagged iSCSI paths) ----------------
  local need_vlans="no"
  [[ "$MGMT_VLAN" != "0" ]] && need_vlans="yes"
  if [[ "$ISCSI_ENABLED" == "yes" ]]; then
    for v in $ISCSI_VLANS; do [[ "$v" != "0" ]] && need_vlans="yes"; done
  fi

  if [[ "$need_vlans" == "yes" ]]; then
    printf '  vlans:\n'
    if [[ "$MGMT_VLAN" != "0" ]]; then
      printf '    %s:\n' "$(mgmt_l3dev)"
      printf '      id: %s\n' "$MGMT_VLAN"
      printf '      link: %s\n' "$(mgmt_dev)"
      printf '      mtu: %s\n' "$MGMT_MTU"
      printf '      dhcp4: no\n      dhcp6: no\n      accept-ra: no\n'
      _l3_block
    fi
    if [[ "$ISCSI_ENABLED" == "yes" ]]; then
      for ((i=0;i<${#in[@]};i++)); do
        n="${in[$i]}"; a="${ia[$i]}"; v="${iv[$i]:-0}"
        [[ "$v" == "0" ]] && continue
        printf '    %s.%s:\n' "$n" "$v"
        printf '      id: %s\n' "$v"
        printf '      link: %s\n' "$n"
        printf '      mtu: %s\n' "$ISCSI_MTU"
        printf '      dhcp4: no\n      dhcp6: no\n      accept-ra: no\n'
        printf '      link-local: []\n'
        printf '      addresses: [%s]\n' "$a"
        printf '      optional: true\n'
      done
    fi
  fi
  } > "$f"

  unset -f _eth_head _l3_block _passive_block
  chmod 0600 "$f"
}

render_sysctl() {
  local f="$1" n v i
  local -a in=() iv=()
  {
    printf '# Managed by %s v%s - generated %s\n' "$PROG" "$VERSION" "$(_ts)"
    printf '# Reverse-path and ARP hardening so multi-homed storage NICs behave.\n\n'
    printf 'net.ipv4.conf.all.rp_filter = 2\n'
    printf 'net.ipv4.conf.default.rp_filter = 2\n'
    if [[ "$ISCSI_ENABLED" == "yes" ]]; then
      read -r -a in <<<"$ISCSI_NICS"; read -r -a iv <<<"$ISCSI_VLANS"
      for ((i=0;i<${#in[@]};i++)); do
        n="${in[$i]}"; v="${iv[$i]:-0}"
        [[ "$v" != "0" ]] && n="${n}.${v}"
        # sysctl keys cannot mix '.' separators with dotted interface names;
        # when the ifname contains a dot, use the all-slash path form.
        if [[ "$n" == *.* ]]; then
          printf 'net/ipv4/conf/%s/rp_filter = 2\n' "$n"
          printf 'net/ipv4/conf/%s/arp_ignore = 1\n' "$n"
          printf 'net/ipv4/conf/%s/arp_announce = 2\n' "$n"
        else
          printf 'net.ipv4.conf.%s.rp_filter = 2\n' "$n"
          printf 'net.ipv4.conf.%s.arp_ignore = 1\n' "$n"
          printf 'net.ipv4.conf.%s.arp_announce = 2\n' "$n"
        fi
      done
    fi
    printf '\n# Larger socket buffers help iSCSI and live migration on 10G+.\n'
    printf 'net.core.rmem_max = 16777216\n'
    printf 'net.core.wmem_max = 16777216\n'
    printf 'net.ipv4.tcp_rmem = 4096 87380 16777216\n'
    printf 'net.ipv4.tcp_wmem = 4096 65536 16777216\n'
    printf 'net.core.netdev_max_backlog = 250000\n'
    printf '\n# ARP table headroom for a large flat compute VLAN.\n'
    printf 'net.ipv4.neigh.default.gc_thresh1 = 4096\n'
    printf 'net.ipv4.neigh.default.gc_thresh2 = 8192\n'
    printf 'net.ipv4.neigh.default.gc_thresh3 = 16384\n'
  } > "$f"
  chmod 0644 "$f"
}

write_waitonline_dropin() {
  local m; m="$(mgmt_l3dev)"
  mkdir -p "$(dirname "$WAITONLINE_DROPIN")"
  cat >"$WAITONLINE_DROPIN" <<EOF
# Managed by ${PROG} v${VERSION}
# Only the management interface gates boot. Compute and storage links are
# 'optional' so a down switch port cannot hang the host for 2 minutes.
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --interface=${m} --timeout=60
EOF
}

disable_cloudinit_net() {
  mkdir -p "$(dirname "$CLOUDINIT_OFF")"
  printf 'network: {config: disabled}\n' >"$CLOUDINIT_OFF"
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
BACKUP_DIR=""

make_backup() {
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="${BACKUP_ROOT}/${ts}"
  mkdir -p "$BACKUP_DIR/netplan" "$BACKUP_DIR/state" "$BACKUP_DIR/rootfs"

  # ---- configuration that we may modify -------------------------------
  local f
  for f in "${NETPLAN_DIR}"/*.yaml; do
    [[ -e "$f" ]] && cp -a "$f" "$BACKUP_DIR/netplan/"
  done
  for f in "$SYSCTL_OUT" "$WAITONLINE_DROPIN" "$CLOUDINIT_OFF" "$PROFILE_FILE" \
           /etc/hosts /etc/resolv.conf /etc/machine-id; do
    [[ -e "$f" ]] && { mkdir -p "$BACKUP_DIR/rootfs$(dirname "$f")"; cp -a "$f" "$BACKUP_DIR/rootfs$f"; }
  done
  # configs we never touch, captured so a restore can prove they are unchanged
  for f in /etc/iscsi/iscsid.conf /etc/iscsi/initiatorname.iscsi /etc/multipath.conf; do
    [[ -e "$f" ]] && { mkdir -p "$BACKUP_DIR/rootfs$(dirname "$f")"; cp -a "$f" "$BACKUP_DIR/rootfs$f"; }
  done

  # ---- live runtime state (forensics, not restored automatically) ------
  {
    printf '# vme-netconfig backup %s on %s\n\n' "$ts" "$(hostname -f 2>/dev/null || hostname)"
    printf '## ip -details link\n';  ip -details link show 2>/dev/null || true
    printf '\n## ip -4 addr\n';      ip -4 addr show 2>/dev/null || true
    printf '\n## ip route\n';        ip route show 2>/dev/null || true
    printf '\n## ip rule\n';         ip rule show 2>/dev/null || true
    printf '\n## bonding\n'
    for f in "${PROC_BONDING}"/*; do [[ -e "$f" ]] && { printf -- '--- %s\n' "${f##*/}"; cat "$f"; }; done
    printf '\n## netplan merged config\n'; netplan get 2>/dev/null || true
  } > "$BACKUP_DIR/state/network.txt" 2>&1

  if command -v ovs-vsctl >/dev/null 2>&1; then
    { printf '## ovs-vsctl show\n'; ovs-vsctl show 2>/dev/null || true
      printf '\n## bridge -> ports\n'
      local br p
      for br in $(ovs-vsctl list-br 2>/dev/null || true); do
        printf 'bridge %s fail_mode=%s\n' "$br" "$(ovs-vsctl get bridge "$br" fail_mode 2>/dev/null | tr -d '"[]')"
        for p in $(ovs-vsctl list-ports "$br" 2>/dev/null || true); do
          printf '  port %s type=%s\n' "$p" "$(ovs-vsctl get interface "$p" type 2>/dev/null | tr -d '"')"
        done
      done
    } > "$BACKUP_DIR/state/ovs.txt" 2>&1
  fi

  # ---- manifest + integrity -------------------------------------------
  ( cd "$BACKUP_DIR" && find netplan rootfs -type f -print0 2>/dev/null \
      | xargs -0 sha256sum 2>/dev/null ) > "$BACKUP_DIR/MANIFEST.sha256" || true

  rc_write_restore_script "$BACKUP_DIR" "$ts"

  # ---- verify before anyone relies on it ------------------------------
  local nfiles; nfiles="$(wc -l < "$BACKUP_DIR/MANIFEST.sha256" 2>/dev/null || echo 0)"
  if ! ( cd "$BACKUP_DIR" && sha256sum -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1; then
    die "backup verification FAILED at ${BACKUP_DIR} - refusing to change anything"
  fi
  [[ "$nfiles" -gt 0 ]] || die "backup captured no files - refusing to proceed"

  # ---- make it findable from a console with no network ----------------
  ln -sfn "$BACKUP_DIR" "${STATE_DIR}/LATEST"
  cp -f "$BACKUP_DIR/restore.sh" "${STATE_DIR}/restore-latest.sh" 2>/dev/null || true
  chmod 0755 "${STATE_DIR}/restore-latest.sh" 2>/dev/null || true
  # second copy where a console operator actually lands
  cp -f "$BACKUP_DIR/restore.sh" "/root/vme-restore-${ts}.sh" 2>/dev/null || true
  chmod 0755 "/root/vme-restore-${ts}.sh" 2>/dev/null || true

  ok "backup verified: ${nfiles} files at ${BACKUP_DIR}"
  print_console_card "$ts"
}

print_console_card() {
  local ts="$1"
  cat <<EOF

${C_B}${C_Y}+--------------------------------------------------------------------+
|  WRITE THIS DOWN BEFORE CONTINUING - iLO / console recovery        |
+--------------------------------------------------------------------+${C_RST}
   If you lose the network, open the iLO remote console, log in as root
   (or any sudoer), and run ANY ONE of these:

       ${C_B}sudo ${STATE_DIR}/restore-latest.sh${C_RST}
       ${C_B}sudo /root/vme-restore-${ts}.sh${C_RST}
       ${C_B}sudo ${BACKUP_ROOT}/${ts}/restore.sh${C_RST}

   All three are the same script. It needs no network and no arguments.
   It restores every netplan file exactly as it was, reverts sysctl and
   boot-gating changes, then re-applies networking.

   To see what it would do without doing it:
       ${C_B}sudo ${STATE_DIR}/restore-latest.sh --dry-run${C_RST}

   Other restore points:  ${C_B}sudo ${PROG} --list-backups${C_RST}

EOF
}

rc_write_restore_script() {
  local d="$1" ts="$2"
  cat > "$d/restore.sh" <<EOF
#!/usr/bin/env bash
# vme-netconfig restore point ${ts}
# Self-contained. No network, no arguments, no dependency on vme-netconfig.sh.
# Safe to run repeatedly.
set -u
BK="${d}"
NETPLAN_DIR="${NETPLAN_DIR}"
LOG="/var/log/vme-netconfig-restore.log"
DRY="no"
[[ "\${1:-}" == "--dry-run" ]] && DRY="yes"

say() { printf '%s %s\n' "\$(date '+%H:%M:%S')" "\$*" | tee -a "\$LOG"; }
do_() { if [[ "\$DRY" == "yes" ]]; then printf '   would: %s\n' "\$*"; else "\$@"; fi; }

[[ \$(id -u) -eq 0 ]] || { echo "must be root"; exit 1; }
[[ -d "\$BK" ]] || { echo "backup directory missing: \$BK"; exit 1; }

say "=== vme-netconfig restore ${ts} (dry-run=\$DRY) ==="

if ! ( cd "\$BK" && sha256sum -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1; then
  say "WARNING: backup checksums do not verify. Contents may be damaged."
  read -r -p "Continue anyway? (yes/no) " a
  [[ "\$a" == "yes" ]] || exit 1
fi

# 1. netplan: remove everything present now, restore exactly what was captured
say "restoring netplan from \$BK/netplan"
if [[ "\$DRY" == "yes" ]]; then
  echo "   current:"; ls -1 "\$NETPLAN_DIR"/*.yaml 2>/dev/null | sed 's/^/     /'
  echo "   restore:"; ls -1 "\$BK/netplan"/*.yaml 2>/dev/null | sed 's/^/     /'
else
  mkdir -p /var/backups/vme-netconfig-preRestore
  cp -a "\$NETPLAN_DIR"/*.yaml /var/backups/vme-netconfig-preRestore/ 2>/dev/null
  rm -f "\$NETPLAN_DIR"/*.yaml
  cp -a "\$BK/netplan/." "\$NETPLAN_DIR"/ 2>/dev/null
  chmod 0600 "\$NETPLAN_DIR"/*.yaml 2>/dev/null
fi

# 2. other config files captured under etc/
while IFS= read -r -d '' rel; do
  case "/\$rel" in
    /etc/machine-id|/etc/iscsi/*|/etc/multipath.conf) continue ;;  # never auto-revert
  esac
  say "restoring /\$rel"
  do_ mkdir -p "\$(dirname "/\$rel")"
  do_ cp -a "\$BK/rootfs/\$rel" "/\$rel"
done < <( cd "\$BK/rootfs" 2>/dev/null && find . -type f -printf '%P\0' 2>/dev/null )

# 3. files this tool may have CREATED that predate nothing - remove if absent from backup
for f in "${SYSCTL_OUT}" "${WAITONLINE_DROPIN}"; do
  rel="\${f#/}"
  if [[ -e "\$f" && ! -e "\$BK/rootfs/\$rel" ]]; then
    say "removing \$f (did not exist at backup time)"
    do_ rm -f "\$f"
  fi
done

# 4. re-apply
say "reloading systemd and applying netplan"
do_ systemctl daemon-reload
if [[ -f "${SYSCTL_OUT}" ]]; then do_ sysctl -p "${SYSCTL_OUT}" >/dev/null 2>&1; fi
do_ netplan apply
do_ systemctl restart systemd-networkd
sleep 5

say "--- result ---"
ip -br -4 addr show 2>/dev/null | tee -a "\$LOG"
ip -4 route show 2>/dev/null | tee -a "\$LOG"
say "=== restore complete. Previous state saved to /var/backups/vme-netconfig-preRestore ==="
say "OVS topology at backup time is recorded in \$BK/state/ovs.txt (not auto-reverted:"
say "netplan-declared bridges rebuild themselves from the restored YAML)."
EOF
  chmod 0755 "$d/restore.sh"
}

arm_deadman() {
  [[ "${SAFETY_TIMER:-0}" -gt 0 ]] || return 0
  command -v systemd-run >/dev/null 2>&1 || { warn "systemd-run missing, no dead-man rollback"; return 0; }
  systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemd-run --unit="${ROLLBACK_UNIT}" --on-active="${SAFETY_TIMER}" \
    "${BACKUP_DIR}/rollback.sh" >/dev/null 2>&1 \
    && ok "dead-man rollback armed: fires in ${SAFETY_TIMER}s unless confirmed" \
    || warn "could not arm dead-man rollback"
}

disarm_deadman() {
  systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl stop "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
}

preflight() {
  hdr "Preflight"
  local osid osver
  osid="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}")"
  osver="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-?}")"
  if [[ "$osid" != "ubuntu" ]]; then
    warn "OS is '${osid}', not ubuntu. VME supports Ubuntu 22.04/24.04 only."
    [[ "$FORCE" == "yes" ]] || die "re-run with --force to proceed anyway"
  else
    case "$osver" in
      24.04) ok "Ubuntu ${osver} (supports the newest VME cluster layouts)" ;;
      22.04) ok "Ubuntu ${osver}"
             note "22.04 cannot use the latest cluster layouts. 24.04 preferred for 9.0.1+." ;;
      *)     warn "Ubuntu ${osver} is not a VME-supported release" ;;
    esac
  fi

  command -v netplan >/dev/null 2>&1 || die "netplan not found"
  ok "netplan present: $(netplan --version 2>/dev/null | head -1)"

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    warn "NetworkManager is active. This script renders for systemd-networkd."
    warn "Mixed renderers cause interfaces to be claimed twice."
  fi

  local declared; declared="$(netplan_bridge_members | cut -f1 | sort -u | paste -sd' ' - 2>/dev/null || true)"
  if [[ -n "${declared:-}" ]]; then
    warn "netplan already declares OVS bridges: ${declared}"
    warn "VME Manager has run host prep here. A fresh base apply can strand the"
    warn "management address between the bridge and the interface it enslaves."
    [[ "$FORCE" == "yes" ]] || die "use --doctor on a prepped host, or --force if you mean it"
  fi
  if command -v ovs-vsctl >/dev/null 2>&1 && ovs-vsctl list-br 2>/dev/null | grep -qE '^(mgmt|cmpt)$'; then
    if dpkg -l hpe-vm 2>/dev/null | grep -q '^ii'; then
      warn "OVS mgmt/cmpt bridges already exist and hpe-vm is installed."
      warn "This host is already prepped. Use --doctor rather than a fresh apply."
      [[ "$FORCE" == "yes" ]] || die "re-run with --force if you really mean to re-lay the base config"
    else
      bad "OVS mgmt/cmpt bridges exist but hpe-vm is NOT installed."
      bad "These were hand-created. VME Manager must own them - delete before install."
      note "  ovs-vsctl --if-exists del-br cmpt; ovs-vsctl --if-exists del-br mgmt"
      [[ "$FORCE" == "yes" ]] || die "clean the bridges then re-run"
    fi
  else
    ok "no pre-existing OVS mgmt/cmpt bridges (correct for pre-install)"
  fi

  if ! lsmod 2>/dev/null | grep -q '^bonding' && ! modprobe bonding 2>/dev/null; then
    warn "bonding module could not be loaded"
  fi
  if ! lsmod 2>/dev/null | grep -q '^8021q' && ! modprobe 8021q 2>/dev/null; then
    warn "8021q module could not be loaded"
  fi
}

apply_config() {
  hdr "Applying"
  make_backup

  # neutralise cloud-init's competing netplan
  if [[ -f "${NETPLAN_DIR}/50-cloud-init.yaml" ]]; then
    run mv "${NETPLAN_DIR}/50-cloud-init.yaml" "${BACKUP_DIR}/50-cloud-init.yaml.disabled"
    ok "moved 50-cloud-init.yaml aside (backed up)"
  fi
  if [[ "$DRY_RUN" == "no" ]]; then disable_cloudinit_net; fi
  ok "cloud-init network config disabled"

  # any other netplan file is a conflict risk
  local other
  for other in "${NETPLAN_DIR}"/*.yaml; do
    [[ -e "$other" ]] || continue
    [[ "$other" == "$NETPLAN_OUT" ]] && continue
    if is_vme_owned "$other"; then
      ok "leaving VME-owned file alone: ${other##*/}"
      continue
    fi
    warn "additional netplan file present: ${other}"
    if [[ "$(ask_yn "  disable ${other##*/}?" 'y')" == "y" ]]; then
      run mv "$other" "${BACKUP_DIR}/${other##*/}.disabled"
    fi
  done

  if [[ "$DRY_RUN" == "yes" ]]; then
    hdr "Rendered netplan (dry-run, not written)"
    render_netplan /dev/stdout
    hdr "Rendered sysctl (dry-run, not written)"
    render_sysctl /dev/stdout
    return 0
  fi

  render_netplan "$NETPLAN_OUT"
  ok "wrote ${NETPLAN_OUT} (0600)"

  if [[ "$NO_SYSCTL" == "no" ]]; then
    render_sysctl "$SYSCTL_OUT"
    ok "wrote ${SYSCTL_OUT}"
  fi
  write_waitonline_dropin
  ok "wrote wait-online drop-in (mgmt gates boot, others optional)"

  hdr "Validating"
  if ! netplan generate 2>&1 | sed 's/^/   /'; then
    bad "netplan generate failed - restoring backup"
    "${BACKUP_DIR}/rollback.sh" >/dev/null 2>&1 || true
    die "configuration rejected, nothing changed"
  fi
  ok "netplan generate passed"

  hdr "Committing"
  arm_deadman
  systemctl daemon-reload >/dev/null 2>&1 || true
  if ! netplan apply 2>&1 | sed 's/^/   /'; then
    warn "netplan apply reported errors"
  fi
  [[ "$NO_SYSCTL" == "no" ]] && sysctl -p "$SYSCTL_OUT" >/dev/null 2>&1 || true
  sleep 6

  post_apply_verify

  if [[ "${SAFETY_TIMER:-0}" -gt 0 ]]; then
    printf '\n'
    if [[ "$ASSUME_YES" == "yes" ]]; then
      disarm_deadman; ok "dead-man rollback disarmed (--yes)"
    else
      warn "You have ${SAFETY_TIMER}s to confirm or the host reverts to the previous config."
      local a; a="$(ask 'Type KEEP to make this permanent' '')"
      if [[ "$a" == "KEEP" ]]; then
        disarm_deadman; ok "confirmed - configuration retained"
      else
        warn "not confirmed - rollback will fire on schedule"
      fi
    fi
  fi
}

post_apply_verify() {
  hdr "Post-apply verification"
  local m md; m="$(mgmt_l3dev)"; md="$(mgmt_dev)"

  ip link show "$md" >/dev/null 2>&1 && ok "${md} exists" || bad "${md} missing"
  ip -o -4 addr show dev "$m" 2>/dev/null | grep -q "${MGMT_ADDR%%/*}" \
    && ok "${m} carries ${MGMT_ADDR}" || bad "${m} does not carry ${MGMT_ADDR}"

  [[ "$MGMT_LINK_MODE" == "bond" ]] && check_bond_health "$MGMT_BOND"
  [[ "$VME_TOPOLOGY" == "decoupled" && "$COMPUTE_LINK_MODE" == "bond" ]] && check_bond_health "$COMPUTE_BOND"
  [[ -n "$COMPUTE2_MEMBERS" && "$COMPUTE2_LINK_MODE" == "bond" ]] && check_bond_health "$COMPUTE2_BOND"
  if [[ "$VME_TOPOLOGY" == "decoupled" ]]; then
    local cd; cd="$(compute_dev)"
    if [[ "$(cat "${SYS_NET}/${cd}/operstate" 2>/dev/null)" == "up" ]]; then
      ok "compute uplink ${cd} is up"
    else
      bad "compute uplink ${cd} is not up - VME cannot build cmpt on a dead link"
    fi
  fi

  if ping -c2 -W2 "$MGMT_GW" >/dev/null 2>&1; then
    ok "gateway ${MGMT_GW} reachable"
  else
    bad "gateway ${MGMT_GW} NOT reachable"
  fi

  if [[ "$ISCSI_ENABLED" == "yes" && -n "$ISCSI_PORTALS" ]]; then
    local -a in=(); read -r -a in <<<"$ISCSI_NICS"
    local p n payload=$(( ISCSI_MTU - 28 ))
    for p in $ISCSI_PORTALS; do
      local reached="no"
      for n in "${in[@]}"; do
        if ping -c1 -W2 -I "$n" "$p" >/dev/null 2>&1; then
          reached="yes"
          if ping -c1 -W2 -M do -s "$payload" -I "$n" "$p" >/dev/null 2>&1; then
            ok "portal ${p} via ${n}: reachable, jumbo ${ISCSI_MTU} clean"
          else
            bad "portal ${p} via ${n}: reachable but MTU ${ISCSI_MTU} FAILS end-to-end"
            note "  switch/target MTU is smaller. Existence is not reachability - fix the path."
          fi
        fi
      done
      [[ "$reached" == "no" ]] && bad "portal ${p} unreachable from every iSCSI NIC"
    done
  fi
}

check_bond_health() {
  local b="$1" pf="${PROC_BONDING}/$1"
  [[ -r "$pf" ]] || { bad "${b}: no ${PROC_BONDING} entry"; return 0; }
  local mode; mode="$(awk -F': ' '/^Bonding Mode/{print $2; exit}' "$pf")"
  local slaves; slaves="$(grep -c '^Slave Interface:' "$pf" || true)"
  local up; up="$(awk '/^Slave Interface:/{s=1} /^MII Status: up/{if(s){c++; s=0}} END{print c+0}' "$pf")"
  info "${b}: mode='${mode}' slaves=${slaves} up=${up}"
  [[ "$up" -eq "$slaves" && "$slaves" -gt 0 ]] && ok "${b}: all members up" || bad "${b}: ${up}/${slaves} members up"

  if grep -q '802.3ad' "$pf"; then
    local partner aggs
    partner="$(awk -F': ' '/Partner Mac Address/{print $2; exit}' "$pf" | tr -d ' ')"
    if [[ -z "$partner" || "$partner" == "00:00:00:00:00:00" ]]; then
      bad "${b}: LACP partner MAC is null - switch side is NOT in a LAG"
      note "  the bond will look 'up' and blackhole half the traffic. Fix the switch."
    else
      ok "${b}: LACP partner ${partner}"
    fi
    aggs="$(grep -c 'Aggregator ID' "$pf" || true)"
    local distinct
    distinct="$(grep 'Aggregator ID' "$pf" | awk -F': ' '{print $2}' | sort -u | wc -l)"
    if [[ "$distinct" -gt 1 ]]; then
      bad "${b}: members landed in ${distinct} different aggregators - split LAG on the switch"
    fi
  fi

  # MTU consistency across members
  local bm mm s bad_mtu=""
  bm="$(cat "${SYS_NET}/${b}/mtu" 2>/dev/null || echo 0)"
  for s in $(awk -F': ' '/^Slave Interface:/{print $2}' "$pf"); do
    mm="$(cat "${SYS_NET}/${s}/mtu" 2>/dev/null || echo 0)"
    [[ "$mm" != "$bm" ]] && bad_mtu="${bad_mtu} ${s}(${mm})"
  done
  [[ -n "$bad_mtu" ]] && bad "${b}: MTU ${bm} but members differ:${bad_mtu}" || ok "${b}: MTU ${bm} consistent"
}


# ---------------------------------------------------------------------------
# Reconfigure mode - repair the uplinks of an ALREADY-PREPPED host
#
# Unlike --wizard (which lays a greenfield base before hpe-vm exists), this mode
# assumes VME host prep has already run. It touches exactly three things:
#   * the bond/VLAN definitions for the NICs you nominate for mgmt and compute
#   * 60-mvm-mgmt.yaml   - repoint the mgmt bridge at the right interface
#   * 61-mvm-compute.yaml - create the cmpt bridge if it is missing
#
# Everything else in the base netplan is preserved verbatim. Any NIC that
# already carries an IP is treated as storage: it is protected, never offered
# as a candidate, and never rewritten.
# ---------------------------------------------------------------------------
RC_PROTECTED=""
RC_CANDIDATES=()

rc_classify_nics() {
  RC_PROTECTED=""; RC_CANDIDATES=()
  local n addrs
  for n in "${NICS[@]}"; do
    addrs="$(ip -o -4 addr show dev "$n" 2>/dev/null | wc -l)"
    if [[ "$addrs" -gt 0 ]]; then
      RC_PROTECTED="${RC_PROTECTED}${RC_PROTECTED:+ }${n}"
    else
      RC_CANDIDATES+=("$n")
    fi
  done
}

rc_print_candidates() {
  printf '\n  %-3s %-14s %-8s %-6s %-12s %-18s %s\n' "#" "IFACE" "STATE" "SPEED" "DRIVER" "MAC" "CURRENT ROLE"
  printf '  %s\n' "$(printf '%.0s-' {1..92})"
  local i=1 n role st
  for n in "${RC_CANDIDATES[@]}"; do
    role="$(basename "$(readlink -f "${SYS_NET}/${n}/master" 2>/dev/null || echo '')")"
    [[ "$role" == "." || -z "$role" ]] && role="unassigned" || role="member of ${role}"
    if [[ "${NIC_CARR[$n]}" == "1" ]]; then st="up/link"; else st="${NIC_STATE[$n]}"; fi
    printf '  %-3s %-14s %-8s %-6s %-12s %-18s %s\n' \
      "$i" "$n" "$st" "${NIC_SPD[$n]}" "${NIC_DRV[$n]}" "${NIC_MAC[$n]}" "$role"
    i=$((i+1))
  done
  printf '\n'
  if [[ -n "$RC_PROTECTED" ]]; then
    note "PROTECTED (carry an IP - treated as storage, will not be touched):"
    local n2
    for n2 in $RC_PROTECTED; do
      note "  ${n2}  $(ip -o -4 addr show dev "$n2" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
    done
    printf '\n'
  fi
}

rc_nic_by_index() {
  local out=() idx
  for idx in $1; do
    [[ "$idx" =~ ^[0-9]+$ ]] || { printf '__BAD__'; return 1; }
    [[ "$idx" -ge 1 && "$idx" -le ${#RC_CANDIDATES[@]} ]] || { printf '__BAD__'; return 1; }
    out+=("${RC_CANDIDATES[$((idx-1))]}")
  done
  printf '%s' "${out[*]}"
}

rc_pick_base_file() {
  local -a cand=() f
  for f in "${NETPLAN_DIR}"/*.yaml; do
    [[ -e "$f" ]] || continue
    is_vme_owned "$f" && continue
    cand+=("$f")
  done
  if [[ ${#cand[@]} -eq 0 ]]; then
    printf '%s' "$NETPLAN_OUT"; return 0
  elif [[ ${#cand[@]} -eq 1 ]]; then
    printf '%s' "${cand[0]}"; return 0
  fi
  hdr "Which file holds the base configuration?" >&2
  local i=1
  for f in "${cand[@]}"; do printf '   %s) %s\n' "$i" "${f##*/}" >&2; i=$((i+1)); done
  local pick
  while true; do
    pick="$(ask 'File number' '1')"
    [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 && "$pick" -le ${#cand[@]} ]] && break
  done
  printf '%s' "${cand[$((pick-1))]}"
}

rc_read_mgmt_l3() {
  # echo JSON of the mgmt bridge's existing L3, or {} if none
  have_pyyaml || { printf '{}'; return 0; }
  python3 - "$NETPLAN_DIR" <<'PYEOF' 2>/dev/null || printf '{}'
import sys, glob, os, yaml, json
out = {}
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.yaml"))):
    try: d = yaml.safe_load(open(f)) or {}
    except Exception: continue
    br = ((d.get("network") or {}).get("bridges") or {}).get("mgmt")
    if isinstance(br, dict):
        for k in ("addresses", "routes", "nameservers", "mtu"):
            if br.get(k): out[k] = br[k]
print(json.dumps(out))
PYEOF
}

rc_readiness() {
  # Only guest evacuation is pollable. Maintenance Mode does NOT unmount GFS2 -
  # the host stays a member of the storage cluster with the LUN mounted, so
  # waiting for that unmount waits forever. Observed on hpevmess03 (VME 9.0).
  local vms=""
  command -v virsh >/dev/null 2>&1 && vms="$( { virsh list --name 2>/dev/null || true; } | grep -c . || true )"
  if [[ -n "${vms:-}" && "${vms:-0}" -gt 0 ]]; then
    printf '%s guests still running' "$vms"
  else
    printf 'clear'
  fi
}

rc_storage_path() {
  # Which interfaces actually carry the iSCSI sessions? One per line.
  command -v iscsiadm >/dev/null 2>&1 || return 0
  local portal dev
  for portal in $( { iscsiadm -m session 2>/dev/null || true; } \
                   | awk '{print $3}' | cut -d, -f1 | sed 's/:[0-9]*$//' | sort -u ); do
    [[ -n "$portal" ]] || continue
    dev="$(ip -o route get "$portal" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
    if [[ -n "${dev:-}" ]]; then printf '%s\n' "$dev"; fi
  done | sort -u
  return 0
}

rc_storage_path_check() {
  # Runs after NIC selection: does the rebuild touch the LIVE storage path?
  hdr "Storage path impact"
  local mounted="no"
  { mount 2>/dev/null || true; } | grep -q 'type gfs2' && mounted="yes"
  if [[ "$mounted" == "no" ]]; then
    ok "no GFS2 mount - nothing to protect"
    return 0
  fi

  local -a rebuild=()
  local x
  for x in $MGMT_MEMBERS $COMPUTE_MEMBERS "$MGMT_BOND" "$COMPUTE_BOND"; do
    [[ -n "$x" ]] && rebuild+=("$x")
  done
  [[ "$MGMT_VLAN" != "0" ]] && rebuild+=("${MGMT_BOND}.${MGMT_VLAN}")

  local spath; spath="$(rc_storage_path)"
  if [[ -z "$spath" ]]; then
    warn "GFS2 is mounted but no iSCSI session could be traced to an interface."
    warn "Cannot prove the storage path is clear of the rebuild. Treat as risky."
  else
    info "iSCSI sessions currently ride: $(printf '%s' "$spath" | tr '\n' ' ')"
    local hit="" d r
    for d in $spath; do
      for r in "${rebuild[@]}"; do
        if [[ "$d" == "$r" ]] && [[ " ${hit} " != *" ${d} "* ]]; then hit="${hit} ${d}"; fi
      done
    done
    if [[ -n "$hit" ]]; then
      bad "The rebuild touches the LIVE storage path:${hit}"
      bad "This will cut iSCSI under a mounted GFS2 filesystem."
      die "refusing - relocate storage or unmount the datastore first"
    fi
    ok "storage path is NOT among the interfaces being rebuilt"
  fi

  printf '\n'
  warn "GFS2 stays mounted in Maintenance Mode. That is expected, not a fault."
  warn "What this rebuild interrupts is management and compute connectivity."
  note "     Whether VME's GFS2 cluster/lock traffic rides the management network"
  note "     on 9.0+ is NOT something this tool can determine. If it does, bouncing"
  note "     the bond may make the cluster consider this host absent even though"
  note "     its storage path stays intact."
  note "     Have the iLO console open before you continue."
  printf '\n'
  if [[ "$ASSUME_YES" == "yes" ]]; then
    warn "--yes given: proceeding without typed confirmation"
    return 0
  fi
  local a; a="$(ask 'Type MAINTENANCE to confirm the host is parked and proceed' '')"
  [[ "$a" == "MAINTENANCE" ]] || die "not confirmed - cancelled"
  ok "confirmed"
  return 0
}

rc_wait_for_maintenance() {
  # Poll for guest evacuation only. GFS2 stays mounted throughout Maintenance
  # Mode, so it is not a settling signal.
  local timeout="${1:-900}" interval=10 elapsed=0 why last=""
  hdr "Waiting for guests to evacuate"
  info "In VME Manager: cluster detail page -> this host -> Maintenance Mode."
  info "Watching virsh for running guests to reach zero."
  note "The GFS2 mount stays put - that is expected and is not waited on."
  note "Ctrl-C to abort. Timeout ${timeout}s."
  while [[ "$elapsed" -lt "$timeout" ]]; do
    why="$(rc_readiness)"
    if [[ "$why" == "clear" ]]; then
      printf '\n'; ok "guests evacuated (${elapsed}s)"
      return 0
    fi
    if [[ "$why" != "$last" ]]; then
      printf '\n   %s[%4ss]%s %s' "$C_DIM" "$elapsed" "$C_RST" "$why"
      last="$why"
    else
      printf '.'
    fi
    sleep "$interval"; elapsed=$((elapsed+interval))
  done
  printf '\n'
  bad "guests still present after ${timeout}s: $(rc_readiness)"
  return 1
}

rc_cluster_guard() {
  # --reconfigure bounces bonds and bridges. On a live clustered host that is a
  # fencing event, not an outage. Refuse unless the node is already parked.
  local blocked="no"

  if { mount 2>/dev/null || true; } | grep -q 'type gfs2'; then
    info "GFS2 is mounted. Maintenance Mode does not unmount it - the host stays a"
    info "member of the storage cluster. That is normal and is not a blocker here;"
    info "the storage path is analysed against your NIC selection later on."
  fi

  # Morpheus VME 9.0+ manages GFS2 consistency itself through heartbeat datastores
  # and its own HA - there is no pacemaker/corosync layer to interrogate. The
  # observable local signals are the mount, the agent, and running guests.
  if systemctl is-active --quiet morpheus-node 2>/dev/null \
     || systemctl is-active --quiet hpe-vm 2>/dev/null; then
    info "VME node agent is running - the cluster considers this host live"
  fi

  local vms=""
  command -v virsh >/dev/null 2>&1 && vms="$( { virsh list --name 2>/dev/null || true; } | grep -c . || true )"
  if [[ -n "${vms:-}" && "${vms:-0}" -gt 0 ]]; then
    bad "${vms} running VMs on this host - they will lose networking."
    blocked="yes"
  fi

  if [[ "$blocked" == "yes" ]]; then
    printf '\n'
    if [[ "$ASSUME_YES" != "yes" && "$FORCE" != "yes" ]]; then
      info "Maintenance Mode migrates the guests off this host. It does NOT unmount"
      info "GFS2 - the host stays in the storage cluster. Guest count reaching zero"
      info "is the signal, so that is what gets polled."
      if [[ "$(ask_yn 'Set Maintenance Mode now and have me wait for it?' 'y')" == "y" ]]; then
        if rc_wait_for_maintenance "${MAINT_TIMEOUT:-900}"; then
          blocked="no"; WAS_PARKED="yes"
        else
          die "host never parked - check Maintenance Mode status in VME Manager"
        fi
      fi
    fi
  fi

  if [[ "$blocked" == "yes" ]]; then
    printf '\n'
    warn "Evacuate this host before running this:"
    note "  Cluster detail page -> the host -> Maintenance Mode"
    note "  Wait for running guests to reach zero (virsh list), then re-run."
    printf '\n'
    if [[ "$FORCE" == "yes" ]]; then
      warn "--force given: proceeding anyway. This is your fencing event."
    else
      die "refusing to rebuild uplinks while guests are running here (--force to override)"
    fi
  else
    ok "no running guests on this host"
  fi
}

reconfigure() {
  need_root
  have_pyyaml || die "this mode needs python3-yaml (apt install python3-yaml)"
  mkdir -p "$STATE_DIR" "$BACKUP_ROOT"

  hdr "Reconfigure uplinks on a prepped host"
  note "Storage interfaces are protected. Only the NICs you nominate for management"
  note "and compute are rewritten, plus the two VME bridge files."

  VME_TOPOLOGY="decoupled"
  rc_cluster_guard
  discover_nics
  rc_classify_nics
  [[ ${#RC_CANDIDATES[@]} -ge 2 ]] || die "need at least 2 unaddressed NICs; found ${#RC_CANDIDATES[@]}"
  rc_print_candidates

  local base_file; base_file="$(rc_pick_base_file)"
  ok "base file: ${base_file##*/}"

  local ssh_if; ssh_if="$(ssh_uplink || true)"
  if [[ -n "$ssh_if" ]]; then
    warn "Your SSH session arrives on '${ssh_if}'. This mode rebuilds the management"
    warn "path. Run it from iLO/console, not over the link you are about to move."
    [[ "$(ask_yn 'Continue anyway?' 'n')" == "y" ]] || die "cancelled - rerun from console"
  fi

  # --- bond mode -------------------------------------------------------
  hdr "Bond mode"
  local b
  while true; do
    b="$(ask 'Bond mode (1=active-backup, 2=lacp, 3=xor)' '1')"
    case "$b" in 1) BOND_MODE="active-backup"; break ;; 2) BOND_MODE="lacp"; break ;; 3) BOND_MODE="xor"; break ;; esac
  done
  ok "bond mode: ${BOND_MODE}"

  # --- management ------------------------------------------------------
  hdr "Management uplink"
  local sel
  MGMT_BOND="$(ask 'Management bond name' 'bond0')"
  while true; do
    sel="$(ask 'NIC number(s) for the management bond')"
    MGMT_MEMBERS="$(rc_nic_by_index "$sel" || true)"
    [[ "$MGMT_MEMBERS" != "__BAD__" && -n "$MGMT_MEMBERS" ]] && break
    warn "invalid selection"
  done
  MGMT_LINK_MODE="bond"
  ok "${MGMT_BOND} <- ${MGMT_MEMBERS}"

  if [[ "$(ask_yn 'Is management delivered on a TAGGED VLAN?' 'y')" == "y" ]]; then
    while true; do
      MGMT_VLAN="$(ask 'Management VLAN id')"
      valid_vlan "$MGMT_VLAN" && [[ "$MGMT_VLAN" != "0" ]] && break
      warn "vlan must be 1-4094"
    done
    warn "The switch ports for ${MGMT_MEMBERS} must tag VLAN ${MGMT_VLAN}."
    warn "If they deliver management untagged today, change the switch FIRST."
  else
    MGMT_VLAN="0"
    note "Management stays untagged; the mgmt bridge will enslave ${MGMT_BOND} directly."
    note "That leaves ${MGMT_BOND} unavailable as a compute trunk - a port belongs to one bridge."
  fi
  while true; do
    MGMT_MTU="$(ask 'Management MTU' '1500')"
    valid_mtu "$MGMT_MTU" && break
  done

  local l3; l3="$(rc_read_mgmt_l3)"
  if [[ "$l3" == "{}" ]]; then
    warn "No existing mgmt bridge L3 found - enter it."
    while true; do MGMT_ADDR="$(ask 'Management IPv4 CIDR')"; valid_cidr "$MGMT_ADDR" && break; done
    while true; do MGMT_GW="$(ask 'Default gateway')"; valid_ip "$MGMT_GW" && break; done
    MGMT_DNS="$(ask 'DNS servers (space separated)' '')"
    MGMT_SEARCH="$(ask 'DNS search domains' '')"
  else
    ok "reusing existing mgmt bridge L3:"
    printf '%s' "$l3" | python3 -c 'import sys,json;[print("     %s: %s"%(k,v)) for k,v in json.load(sys.stdin).items()]'
  fi

  # --- compute ---------------------------------------------------------
  hdr "Compute uplink (cmpt)"
  local remaining=0 c
  for c in "${RC_CANDIDATES[@]}"; do
    local used="no" y
    for y in $MGMT_MEMBERS; do [[ "$c" == "$y" ]] && used="yes"; done
    [[ "$used" == "no" ]] && remaining=$((remaining+1))
  done

  if [[ "$remaining" -eq 0 ]]; then
    warn "No NICs left after the management bond."
    note "HPE's four-NIC reference design converges management and compute onto the"
    note "same trunk: the bond carries the management VLAN plus the compute VLANs,"
    note "with the remaining two NICs doing storage MPIO. That is what this host is"
    note "cabled for, so converging is the documented answer rather than a compromise."
    [[ "$(ask_yn 'Converge compute onto the management bond?' 'y')" == "y" ]] \
      || die "no NICs available for a separate compute bond"
    VME_TOPOLOGY="converged"
  else
    if [[ "$(ask_yn 'Converge compute onto the management bond (4-NIC design)?' 'n')" == "y" ]]; then
      VME_TOPOLOGY="converged"
    fi
  fi

  if [[ "$VME_TOPOLOGY" == "converged" ]]; then
    if [[ "$MGMT_VLAN" == "0" ]]; then
      bad "Converged requires a TAGGED management VLAN."
      note "     The untagged bond becomes the cmpt trunk. An OVS port belongs to one"
      note "     bridge, so management cannot also sit on the untagged bond - it has"
      note "     to ride a VLAN subinterface."
      while true; do
        MGMT_VLAN="$(ask 'Management VLAN id')"
        valid_vlan "$MGMT_VLAN" && [[ "$MGMT_VLAN" != "0" ]] && break
        warn "vlan must be 1-4094"
      done
      warn "The switch ports for ${MGMT_MEMBERS} must tag VLAN ${MGMT_VLAN}."
    fi
    COMPUTE_BOND="$MGMT_BOND"
    COMPUTE_MEMBERS="$MGMT_MEMBERS"
    COMPUTE_MTU="$MGMT_MTU"
    COMPUTE_LINK_MODE="$MGMT_LINK_MODE"
    ok "converged: ${MGMT_BOND} carries mgmt (VLAN ${MGMT_VLAN}) and the compute trunk"
    note "mgmt bridge  <- ${MGMT_BOND}.${MGMT_VLAN}"
    note "cmpt bridge  <- ${MGMT_BOND} (untagged)"
    warn "How VME plumbs these two bridges onto one bond is its business, not ours."
    warn "Let host prep build cmpt from the cluster wizard rather than hand-building."
  else
    COMPUTE_BOND="$(ask 'Compute bond name' 'bond1')"
    while true; do
      sel="$(ask 'NIC number(s) for the compute bond')"
      COMPUTE_MEMBERS="$(rc_nic_by_index "$sel" || true)"
      [[ "$COMPUTE_MEMBERS" != "__BAD__" && -n "$COMPUTE_MEMBERS" ]] && break
      warn "invalid selection"
    done
    local x y
    for x in $COMPUTE_MEMBERS; do
      for y in $MGMT_MEMBERS; do [[ "$x" == "$y" ]] && die "NIC ${x} cannot serve both bonds"; done
    done
    COMPUTE_LINK_MODE="bond"
    while true; do
      COMPUTE_MTU="$(ask 'Compute MTU (9000 gives VXLAN overlay headroom)' '9000')"
      valid_mtu "$COMPUTE_MTU" && break
    done
    [[ "$COMPUTE_MTU" -lt 1550 ]] && warn "MTU < 1550 breaks 1500-byte guests over VXLAN overlay"
    ok "${COMPUTE_BOND} <- ${COMPUTE_MEMBERS} @ MTU ${COMPUTE_MTU}"
    warn "The switch ports for ${COMPUTE_MEMBERS} must trunk those VLANs."
  fi
  COMPUTE_VLANS="$(ask 'Compute VLAN ids/range (recorded for the cluster wizard)' '')"

  rc_storage_path_check

  # --- review ----------------------------------------------------------
  hdr "Review"
  COMPUTE2_MEMBERS=""
  printf '   %-24s %s\n' "base file:"    "${base_file}"
  printf '   %-24s %s <- %s (mtu %s, %s)\n' "management bond:" "$MGMT_BOND" "$MGMT_MEMBERS" "$MGMT_MTU" "$BOND_MODE"
  printf '   %-24s %s\n' "mgmt bridge enslaves:" "$(mgmt_l3dev)"
  if [[ "$VME_TOPOLOGY" == "converged" ]]; then
    printf '   %-24s %s (converged - same bond as management)\n' "compute bond:" "$COMPUTE_BOND"
  else
    printf '   %-24s %s <- %s (mtu %s, %s)\n' "compute bond:" "$COMPUTE_BOND" "$COMPUTE_MEMBERS" "$COMPUTE_MTU" "$BOND_MODE"
  fi
  printf '   %-24s %s\n' "cmpt bridge enslaves:" "$COMPUTE_BOND"
  printf '   %-24s %s\n' "untouched (storage):" "${RC_PROTECTED:-none}"
  printf '\n'
  note "VME cluster: MANAGEMENT NET INTERFACE = $(mgmt_l3dev), COMPUTE NET INTERFACE = ${COMPUTE_BOND}"
  printf '\n'
  warn "VME Manager owns 60-mvm-mgmt.yaml and 61-mvm-compute.yaml. Writing them here is"
  warn "a deliberate override. The blessed path is to re-add the host to the cluster and"
  warn "let host prep regenerate them; this mode is for fixing a host in place."
  [[ "$(ask_yn 'Write and apply?' 'n')" == "y" ]] || die "cancelled"

  rc_apply "$base_file" "$l3"
}

rc_apply() {
  local base_file="$1" l3json="$2"
  hdr "Applying"
  make_backup

  local mgmt_file="${NETPLAN_DIR}/60-mvm-mgmt.yaml"
  local cmpt_file="${NETPLAN_DIR}/61-mvm-compute.yaml"
  local cfg
  cfg="$(python3 -c '
import json,sys
print(json.dumps({
 "base": sys.argv[1], "mgmt_file": sys.argv[2], "cmpt_file": sys.argv[3],
 "mgmt_bond": sys.argv[4], "mgmt_members": sys.argv[5].split(),
 "mgmt_vlan": int(sys.argv[6]), "mgmt_mtu": int(sys.argv[7]),
 "cmpt_bond": sys.argv[8], "cmpt_members": sys.argv[9].split(),
 "cmpt_mtu": int(sys.argv[10]), "bond_mode": sys.argv[11],
 "l3": json.loads(sys.argv[12]),
 "fallback": {"addresses": sys.argv[13], "gw": sys.argv[14],
              "dns": sys.argv[15].split(), "search": sys.argv[16].split()},
}))' "$base_file" "$mgmt_file" "$cmpt_file" "$MGMT_BOND" "$MGMT_MEMBERS" \
     "$MGMT_VLAN" "$MGMT_MTU" "$COMPUTE_BOND" "$COMPUTE_MEMBERS" "$COMPUTE_MTU" \
     "$BOND_MODE" "$l3json" "${MGMT_ADDR:-}" "${MGMT_GW:-}" "${MGMT_DNS:-}" "${MGMT_SEARCH:-}")"

  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s' "$cfg" | python3 "$STATE_DIR/rc_edit.py" --dry-run 2>/dev/null \
      || { rc_write_editor; printf '%s' "$cfg" | python3 "$STATE_DIR/rc_edit.py" --dry-run; }
    return 0
  fi

  rc_write_editor
  printf '%s' "$cfg" | python3 "$STATE_DIR/rc_edit.py" || die "YAML edit failed - nothing applied"
  chmod 0600 "$base_file" "$mgmt_file" "$cmpt_file" 2>/dev/null || true

  hdr "Validating"
  if ! netplan generate 2>&1 | sed 's/^/   /'; then
    bad "netplan generate failed - restoring backup"
    "${BACKUP_DIR}/rollback.sh" >/dev/null 2>&1 || true
    die "configuration rejected, nothing changed"
  fi
  ok "netplan generate passed"

  hdr "Committing"
  arm_deadman
  netplan apply 2>&1 | sed 's/^/   /' || warn "netplan apply reported errors"
  sleep 8

  hdr "Verification"
  local m; m="$(mgmt_l3dev)"
  ip link show "$MGMT_BOND"    >/dev/null 2>&1 && ok "${MGMT_BOND} exists"    || bad "${MGMT_BOND} missing"
  ip link show "$COMPUTE_BOND" >/dev/null 2>&1 && ok "${COMPUTE_BOND} exists" || bad "${COMPUTE_BOND} missing"
  [[ "$MGMT_VLAN" != "0" ]] && { ip link show "$m" >/dev/null 2>&1 && ok "${m} exists" || bad "${m} missing"; }
  if command -v ovs-vsctl >/dev/null 2>&1; then
    ovs-vsctl list-br 2>/dev/null | grep -qx mgmt && ok "mgmt bridge present" || bad "mgmt bridge missing"
    ovs-vsctl list-br 2>/dev/null | grep -qx cmpt && ok "cmpt bridge present" || bad "cmpt bridge missing"
    ovs-vsctl list-ports mgmt 2>/dev/null | grep -qx "$m" && ok "mgmt enslaves ${m}" || bad "mgmt does not enslave ${m}"
    ovs-vsctl list-ports cmpt 2>/dev/null | grep -qx "$COMPUTE_BOND" && ok "cmpt enslaves ${COMPUTE_BOND}" || bad "cmpt does not enslave ${COMPUTE_BOND}"
  fi
  local n
  for n in $RC_PROTECTED; do
    ip -o -4 addr show dev "$n" 2>/dev/null | grep -q 'inet ' \
      && ok "storage ${n} still addressed" || bad "storage ${n} LOST its address"
  done
  ping -c2 -W2 "$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)" >/dev/null 2>&1 \
    && ok "gateway reachable" || bad "gateway NOT reachable"

  if [[ "${SAFETY_TIMER:-0}" -gt 0 ]]; then
    printf '\n'
    if [[ "$ASSUME_YES" == "yes" ]]; then
      disarm_deadman; ok "dead-man rollback disarmed (--yes)"
    else
      warn "${SAFETY_TIMER}s to confirm or the host reverts."
      local a; a="$(ask 'Type KEEP to make this permanent' '')"
      if [[ "$a" == "KEEP" ]]; then disarm_deadman; ok "confirmed"
      else warn "not confirmed - rollback will fire"; fi
    fi
  fi

  hdr "Next"
  if [[ "${WAS_PARKED:-no}" == "yes" ]]; then
    warn "This host is still in MAINTENANCE MODE. Take it out only after --doctor is clean."
  fi
  info "Re-add this host to the cluster (or edit it) with:"
  info "  MANAGEMENT NET INTERFACE : $(mgmt_l3dev)"
  info "  COMPUTE NET INTERFACE    : ${COMPUTE_BOND}"
  info "  COMPUTE VLANS            : ${COMPUTE_VLANS:-<set these>}"
  info "Then run: sudo ${PROG} --doctor"
}

rc_write_editor() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_DIR/rc_edit.py" <<'PYEOF'
import sys, json, os, yaml

DRY = "--dry-run" in sys.argv
c = json.load(sys.stdin)
L3 = ("addresses", "routes", "nameservers", "gateway4", "gateway6")

def params(mode):
    if mode == "lacp":
        return {"mode": "802.3ad", "lacp-rate": "fast",
                "transmit-hash-policy": "layer3+4", "mii-monitor-interval": 100}
    if mode == "xor":
        return {"mode": "balance-xor", "transmit-hash-policy": "layer3+4",
                "mii-monitor-interval": 100}
    return {"mode": "active-backup", "mii-monitor-interval": 100,
            "fail-over-mac-policy": "active"}

def load(p):
    if os.path.exists(p):
        return yaml.safe_load(open(p)) or {}
    return {}

def dump(p, d):
    if DRY:
        print("----- %s -----" % p); print(yaml.safe_dump(d, default_flow_style=False, sort_keys=True)); return
    with open(p, "w") as fh:
        yaml.safe_dump(d, fh, default_flow_style=False, sort_keys=True)
    os.chmod(p, 0o600)

# ---------------- base file ----------------
doc = load(c["base"])
net = doc.setdefault("network", {})
net["version"] = 2
net.setdefault("renderer", "networkd")
eth = net.setdefault("ethernets", {})
bonds = net.setdefault("bonds", {})
vlans = net.setdefault("vlans", {})

owned = set(c["mgmt_members"]) | set(c["cmpt_members"])
mgmt_l3dev = "%s.%d" % (c["mgmt_bond"], c["mgmt_vlan"]) if c["mgmt_vlan"] else c["mgmt_bond"]
if c["cmpt_bond"] == c["mgmt_bond"] and not c["mgmt_vlan"]:
    sys.exit("converged requires a tagged management VLAN: %s cannot be a port on "
             "both the mgmt and cmpt bridges" % c["mgmt_bond"])

changes = []

# member ethernets: set MTU, strip any L3, never invent entries for other NICs
for grp, mtu in ((c["mgmt_members"], c["mgmt_mtu"]), (c["cmpt_members"], c["cmpt_mtu"])):
    for n in grp:
        e = eth.get(n)
        if not isinstance(e, dict):
            e = {}
        for k in L3:
            if k in e:
                del e[k]; changes.append("%s: dropped %s" % (n, k))
        e["dhcp4"] = False
        e["mtu"] = mtu
        eth[n] = e

# strip reassigned NICs out of any bond that is not one of ours
for bname, bcfg in list(bonds.items()):
    if bname in (c["mgmt_bond"], c["cmpt_bond"]):
        continue
    ifs = [i for i in (bcfg or {}).get("interfaces", []) if i not in owned]
    if ifs != (bcfg or {}).get("interfaces", []):
        if ifs:
            bcfg["interfaces"] = ifs
            changes.append("%s: members reduced to %s" % (bname, ifs))
        else:
            del bonds[bname]
            changes.append("%s: removed (no members left)" % bname)
            for vn in [v for v in vlans if (vlans[v] or {}).get("link") == bname]:
                del vlans[vn]; changes.append("%s: removed (parent gone)" % vn)

converged = c["cmpt_bond"] == c["mgmt_bond"]
bonds[c["mgmt_bond"]] = {"interfaces": c["mgmt_members"], "mtu": c["mgmt_mtu"],
                         "dhcp4": False, "parameters": params(c["bond_mode"])}
changes.append("%s: %s%s" % (c["mgmt_bond"], c["mgmt_members"],
                             " (converged mgmt+compute)" if converged else ""))
if not converged:
    bonds[c["cmpt_bond"]] = {"interfaces": c["cmpt_members"], "mtu": c["cmpt_mtu"],
                             "dhcp4": False, "parameters": params(c["bond_mode"])}
    changes.append("%s: %s" % (c["cmpt_bond"], c["cmpt_members"]))

# drop stale VLANs on our bonds, then create the mgmt one (bare - bridge owns L3)
for vn in [v for v in list(vlans) if (vlans[v] or {}).get("link") in (c["mgmt_bond"], c["cmpt_bond"])]:
    if vn != mgmt_l3dev:
        del vlans[vn]; changes.append("%s: removed (stale)" % vn)
if c["mgmt_vlan"]:
    vlans[mgmt_l3dev] = {"id": c["mgmt_vlan"], "link": c["mgmt_bond"], "mtu": c["mgmt_mtu"]}
    changes.append("%s: created bare (no L3)" % mgmt_l3dev)
if not vlans:
    del net["vlans"]

dump(c["base"], doc)

# ---------------- 60-mvm-mgmt.yaml ----------------
l3 = c["l3"] or {}
if not l3.get("addresses"):
    fb = c["fallback"]
    l3 = {"addresses": [fb["addresses"]]}
    if fb["gw"]:
        l3["routes"] = [{"to": "default", "via": fb["gw"]}]
    if fb["dns"]:
        ns = {"addresses": fb["dns"]}
        if fb["search"]:
            ns["search"] = fb["search"]
        l3["nameservers"] = ns
mdoc = load(c["mgmt_file"])
mnet = mdoc.setdefault("network", {}); mnet["version"] = 2
br = mnet.setdefault("bridges", {}).setdefault("mgmt", {})
br["interfaces"] = [mgmt_l3dev]
br["openvswitch"] = {}
for k, v in l3.items():
    br[k] = v
dump(c["mgmt_file"], mdoc)
changes.append("mgmt bridge -> %s" % mgmt_l3dev)

# ---------------- 61-mvm-compute.yaml ----------------
cdoc = load(c["cmpt_file"])
cnet = cdoc.setdefault("network", {}); cnet["version"] = 2
cbr = cnet.setdefault("bridges", {}).setdefault("cmpt", {})
cbr["interfaces"] = [c["cmpt_bond"]]
cbr["openvswitch"] = {}
for k in L3:
    cbr.pop(k, None)
dump(c["cmpt_file"], cdoc)
changes.append("cmpt bridge -> %s" % c["cmpt_bond"])

for ch in changes:
    print("   %s" % ch)
PYEOF
}

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------
D_PASS=0; D_WARN=0; D_FAIL=0
declare -a AVAILABLE_FIXES=()

d_ok()   { ok   "$*"; D_PASS=$((D_PASS+1)); }
d_warn() { warn "$*"; D_WARN=$((D_WARN+1)); }
d_bad()  { bad  "$*"; D_FAIL=$((D_FAIL+1)); }
d_fix()  { AVAILABLE_FIXES+=("$1"); note "     fix id: $1 - $2"; }

fix_wanted() {
  local id="$1"
  [[ "$DO_FIX" == "yes" ]] || return 1
  [[ -z "$FIX_ONLY" ]] && return 0
  [[ ",${FIX_ONLY}," == *",${id},"* ]]
}

doctor() {
  hdr "VME host network doctor  (host: ${HOST_LABEL})"
  discover_nics

  # --- 0. renderer / file hygiene ---------------------------------------
  hdr "netplan hygiene"
  local files=() f
  for f in "${NETPLAN_DIR}"/*.yaml; do [[ -e "$f" ]] && files+=("$f"); done
  local -a vme_files=() other_files=()
  for f in "${files[@]}"; do
    if is_vme_owned "$f"; then vme_files+=("$f"); else other_files+=("$f"); fi
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    d_bad "no netplan files at all"
  else
    if [[ ${#vme_files[@]} -gt 0 ]]; then
      d_ok "VME-owned netplan files present (host is already prepped):"
      for f in "${vme_files[@]}"; do note "     ${f##*/}  [VME Manager owns this - do not edit]"; done
      note "     These load after the base file and win on any key they redefine."
    fi
    if [[ ${#other_files[@]} -gt 1 ]]; then
      d_warn "${#other_files[@]} non-VME netplan files - later files override earlier keys:"
      for f in "${other_files[@]}"; do note "     ${f##*/}"; done
      d_fix F02 "demote the extras (VME-owned files are never touched)"
    elif [[ ${#other_files[@]} -eq 1 ]]; then
      d_ok "single base netplan file: ${other_files[0]##*/}"
    fi
  fi

  for f in "${files[@]}"; do
    local perm; perm="$(stat -c '%a' "$f" 2>/dev/null || echo 600)"
    if [[ "$perm" != "600" ]]; then
      d_warn "${f##*/} is mode ${perm} (netplan warns; may contain secrets)"
      d_fix F01 "chmod 0600 all netplan files"
    fi
  done
  [[ ${#files[@]} -gt 0 ]] && [[ "$(stat -c '%a' "${files[0]}")" == "600" ]] && d_ok "netplan file permissions correct"

  if [[ -f "${NETPLAN_DIR}/50-cloud-init.yaml" ]] && [[ ! -f "$CLOUDINIT_OFF" ]]; then
    d_warn "cloud-init still owns network config - it will rewrite netplan on reboot"
    d_fix F02 "write ${CLOUDINIT_OFF} and disable the cloud-init netplan file"
  else
    d_ok "cloud-init network config neutralised"
  fi

  if netplan generate >/dev/null 2>&1; then
    d_ok "netplan generate parses cleanly"
  else
    d_bad "netplan generate FAILS - config is invalid"
    netplan generate 2>&1 | sed 's/^/       /' || true
  fi

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    d_warn "NetworkManager active alongside systemd-networkd"
    note "     if netplan renderer is networkd, NM will fight it for the same links"
  else
    d_ok "NetworkManager not active"
  fi

  # --- 1. bonds ----------------------------------------------------------
  hdr "bonds"
  local b bonds=()
  for b in ${PROC_BONDING}/*; do [[ -e "$b" ]] && bonds+=("$(basename "$b")"); done
  if [[ ${#bonds[@]} -eq 0 ]]; then
    d_warn "no bonds configured - VME hosts should have redundant uplinks"
  fi
  for b in "${bonds[@]}"; do
    printf '\n'
    check_bond_health_doctor "$b"
  done

  doctor_switch_side

  # --- 2. addressing / routing -------------------------------------------
  hdr "addressing and routing"
  local defcount; defcount="$(ip -4 route show default 2>/dev/null | wc -l)"
  if [[ "$defcount" -eq 0 ]]; then
    d_bad "no default route"
  elif [[ "$defcount" -gt 1 ]]; then
    d_warn "${defcount} default routes - asymmetric egress and agent flapping likely"
    ip -4 route show default | sed 's/^/       /'
  else
    d_ok "single default route: $(ip -4 route show default | head -1)"
  fi

  # A default route on anything but the management path is the single most common
  # hand-built mistake: storage NICs given a gateway "so they can reach the array".
  # It creates competing default routes and sends host egress out a storage port.
  local mgmt_expected=""
  if [[ -r "$PROFILE_FILE" ]]; then
    ( set +u; . "$PROFILE_FILE" ) >/dev/null 2>&1 || true
    mgmt_expected="$(mgmt_l3dev 2>/dev/null || true)"
  fi
  # No profile on a host we did not build. The mgmt OVS bridge is just as good a
  # source of truth - without this fallback the per-route check silently no-ops.
  if [[ -z "$mgmt_expected" ]]; then
    if ip -o -4 addr show dev mgmt 2>/dev/null | grep -q 'inet '; then
      mgmt_expected="mgmt"
      note "no profile - treating the 'mgmt' bridge as the management path"
    fi
  fi
  local rif
  while read -r rif; do
    [[ -z "${rif:-}" ]] && continue
    if [[ -n "$mgmt_expected" && "$rif" != "$mgmt_expected" ]]; then
      d_bad "default route via ${rif}, but management is ${mgmt_expected}"
      note "     Storage and compute interfaces must have addresses and NO gateway."
      note "     Remove the 'routes: - to: default' block from ${rif} in netplan."
    fi
  done < <(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

  # nameservers on a storage NIC are harmless but signal a copy-paste config
  if [[ -r "$PROFILE_FILE" ]] && [[ "${ISCSI_ENABLED:-no}" == "yes" ]]; then
    local sn
    for sn in ${ISCSI_NICS:-}; do
      if ip -4 route show dev "$sn" 2>/dev/null | grep -q '^default'; then
        d_bad "storage NIC ${sn} carries a default route - remove it"
      fi
    done
  fi

  local gw; gw="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)"
  if [[ -n "$gw" ]]; then
    ping -c2 -W2 "$gw" >/dev/null 2>&1 && d_ok "gateway ${gw} reachable" || d_bad "gateway ${gw} NOT reachable"
  fi

  # duplicate IP detection on the management address
  local mif mip
  mif="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
  mip="$(ip -o -4 addr show dev "${mif:-lo}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  if [[ -n "${mip:-}" ]] && command -v arping >/dev/null 2>&1; then
    if arping -D -q -c 2 -I "$mif" "$mip" >/dev/null 2>&1; then
      d_ok "no duplicate address for ${mip}"
    else
      d_bad "arping -D says something else answers for ${mip} on ${mif}"
      note "     This is NOT proof of another host. With arp_ignore=0 a multi-homed"
      note "     host answers for its own address out a different NIC in the same"
      note "     broadcast domain and trips this same check."
      note "     Confirm before acting: run 'arping -D -I <nic> ${mip}' from a"
      note "     DIFFERENT host, and compare the replying MAC against this host's"
      note "     own NICs (ip -br link). Same MAC = self-answer, fix with F04."
      note "     Different MAC = a real address conflict, fix the other host."
    fi
  fi

  # --- 2b. multi-homed same-subnet detection -----------------------------
  local -A _subnets=()
  local ifn cidr net dupmsg=""
  while read -r ifn cidr; do
    [[ -z "${ifn:-}" ]] && continue
    net="$(printf '%s' "$cidr" | awk -F/ '{split($1,a,"."); print a[1]"."a[2]"."a[3]"/"$2}')"
    if [[ -n "${_subnets[$net]:-}" ]]; then
      dupmsg="${dupmsg} ${net}(${_subnets[$net]},${ifn})"
    else
      _subnets[$net]="$ifn"
    fi
  done < <(ip -o -4 addr show 2>/dev/null | awk '$2!="lo"{print $2, $4}')
  if [[ -n "$dupmsg" ]]; then
    d_warn "multiple interfaces share a subnet:${dupmsg}"
    note "     Linux answers ARP for any local address on any interface, so return"
    note "     traffic can leave the wrong NIC and MPIO collapses to one real path."
    note "     Separate subnets per storage path is the clean fix; F04 hardens the rest."
    d_fix F04 "rp_filter=2 + arp_ignore=1 + arp_announce=2"
  else
    d_ok "no two interfaces share an IPv4 subnet"
  fi

  # --- 3. MTU ------------------------------------------------------------
  hdr "MTU"
  local n misaligned=""
  for n in $(ls -1 ${SYS_NET} | grep -v '^lo$'); do
    local mtu master
    mtu="$(cat "${SYS_NET}/${n}/mtu" 2>/dev/null || echo 0)"
    master="$(basename "$(readlink -f "${SYS_NET}/${n}/master" 2>/dev/null || echo '')")"
    if [[ -n "$master" && "$master" != "." && -e "${SYS_NET}/${master}/mtu" ]]; then
      local pmtu; pmtu="$(cat "${SYS_NET}/${master}/mtu")"
      [[ "$mtu" != "$pmtu" ]] && misaligned="${misaligned} ${n}=${mtu}/${master}=${pmtu}"
    fi
  done
  if [[ -n "$misaligned" ]]; then
    d_bad "MTU mismatch between members and their master:${misaligned}"
    d_fix F03 "set every member MTU to its master's MTU (runtime; also fix netplan)"
  else
    d_ok "member/master MTUs aligned"
  fi

  # VLAN child must not exceed parent
  for n in $(ls -1 ${SYS_NET} | grep -v '^lo$'); do
    [[ "$n" == *.* ]] || continue
    local parent="${n%.*}" cm pm
    [[ -e "${SYS_NET}/${parent}/mtu" ]] || continue
    cm="$(cat "${SYS_NET}/${n}/mtu")"; pm="$(cat "${SYS_NET}/${parent}/mtu")"
    [[ "$cm" -gt "$pm" ]] && d_bad "VLAN ${n} MTU ${cm} exceeds parent ${parent} MTU ${pm}"
  done

  # overlay headroom
  for b in "${bonds[@]}"; do
    local bm; bm="$(cat "${SYS_NET}/${b}/mtu" 2>/dev/null || echo 0)"
    if [[ "$bm" -lt 1550 && "$bm" -gt 0 ]]; then
      d_warn "${b} MTU ${bm}: no headroom for VXLAN overlay (1500 guest + 50 header = 1550)"
    fi
  done

  # --- 4. OVS ------------------------------------------------------------
  hdr "Open vSwitch"
  if ! command -v ovs-vsctl >/dev/null 2>&1; then
    d_warn "ovs-vsctl not installed - host is pre-hpe-vm (expected before install)"
  elif ! systemctl is-active --quiet ovs-vswitchd 2>/dev/null && ! systemctl is-active --quiet openvswitch-switch 2>/dev/null; then
    d_warn "OVS installed but not running"
  else
    local brs; brs="$(ovs-vsctl list-br 2>/dev/null || true)"
    if [[ -z "$brs" ]]; then
      d_ok "no OVS bridges yet (correct for a host not yet added to a cluster)"
    else
      info "bridges: $(printf '%s' "$brs" | tr '\n' ' ')"
      local br
      for br in $brs; do
        printf '\n'
        doctor_ovs_bridge "$br"
      done
    fi
  fi

  # --- 4a. netplan-declared OVS bridges and L3 ownership ------------------
  if have_pyyaml; then
    local brmap; brmap="$(netplan_bridge_members)"
    if [[ -n "$brmap" ]]; then
      local l3; l3="$(netplan_l3_owners)"
      local br mem bfile ifc ifile keys hit
      while IFS=$'\t' read -r br mem bfile; do
        [[ -z "${br:-}" ]] && continue
        info "netplan bridge '${br}' enslaves '${mem}' (from ${bfile})"
        hit=""
        while IFS=$'\t' read -r ifc ifile keys; do
          [[ "$ifc" == "$mem" ]] && hit="${ifile}:${keys}"
        done <<<"$l3"
        if [[ -n "$hit" ]]; then
          d_bad "${mem} is enslaved into bridge '${br}' but STILL carries L3 in ${hit}"
          note "     Once VME builds the bridge, the address, default route and DNS live"
          note "     on the bridge. A leftover copy on the enslaved interface duplicates"
          note "     the address and gives you two claimants for the same IP."
          d_fix F09 "strip L3 keys from ${mem} in the base netplan file"
        else
          d_ok "${mem} correctly carries no L3 (bridge '${br}' owns it)"
        fi
      done <<<"$brmap"
      d_warn "OVS bridges here are netplan-declared, so F05/F06 are RUNTIME-only fixes."
      note "     'netplan apply' rebuilds the bridge from the YAML and reverts them."
      note "     For a durable change, edit the openvswitch: block in the VME file"
      note "     (or have VME re-run host prep) rather than relying on ovs-vsctl."
    fi
  else
    d_warn "python3-yaml unavailable - skipping netplan bridge/L3 ownership analysis"
    note "     install with: apt install python3-yaml"
  fi

  # --- 4a2. is there a compute path at all? ------------------------------
  local all_brs=""
  command -v ovs-vsctl >/dev/null 2>&1 && all_brs="$(ovs-vsctl list-br 2>/dev/null | tr '\n' ' ')"
  all_brs="${all_brs} $(netplan_bridge_members | cut -f1 | sort -u | tr '\n' ' ')"
  if [[ "$all_brs" == *mgmt* && "$all_brs" != *cmpt* ]]; then
    d_bad "management bridge exists but there is NO compute bridge (cmpt)"
    note "     Host prep built the management path and stopped. Without cmpt there is"
    note "     nowhere to attach VM ports, so this host can join a cluster but cannot"
    note "     run workloads. VME creates cmpt when you give the cluster a COMPUTE NET"
    note "     INTERFACE - it is not something to build by hand with ovs-vsctl."
    local free="" n a
    for n in "${NICS[@]}"; do
      a="$(ip -o -4 addr show dev "$n" 2>/dev/null | wc -l)"
      [[ -n "$(basename "$(readlink -f "${SYS_NET}/${n}/master" 2>/dev/null || echo '')")" ]] && continue
      [[ "$a" -gt 0 ]] && continue
      free="${free} ${n}"
    done
    if [[ -n "$free" ]]; then
      note "     Unassigned NICs available for a dedicated compute uplink:${free}"
    else
      note "     No UNUSED NICs - which is expected on a four-NIC host."
      note "     HPE's four-NIC reference design (Network Considerations, 'Four NICs"
      note "     with LACP/XOR bonds and MPIO for storage traffic') converges mgmt and"
      note "     compute onto one bonded trunk, with the other two NICs on storage"
      note "     MPIO. Management rides a tagged VLAN on that bond; the untagged bond"
      note "     becomes the compute trunk. This host is already cabled that way."
      note "     Run --reconfigure and accept the converged option; let VME host prep"
      note "     create cmpt from the cluster wizard rather than building it by hand."
      note "     Splitting the bond instead would cost link redundancy on both paths."
    fi
  fi

  # --- 4b. OS-level VLANs on the compute uplink --------------------------
  if [[ -r "$PROFILE_FILE" ]]; then
    ( set +u; . "$PROFILE_FILE" ) >/dev/null 2>&1 || true
    local cdev; cdev="$(compute_dev 2>/dev/null || true)"
    if [[ -n "${cdev:-}" ]]; then
      local vn stolen=""
      for vn in $(ls -1 ${SYS_NET} 2>/dev/null | grep -F "${cdev}." || true); do
        [[ "$vn" == "$(mgmt_l3dev)" ]] && continue
        stolen="${stolen} ${vn}"
      done
      if [[ -n "$stolen" ]]; then
        d_bad "OS-level VLAN subinterfaces on the compute uplink:${stolen}"
        note "     VME creates compute VLANs as OVS port groups on 'cmpt'. A kernel VLAN"
        note "     on the same uplink consumes those tagged frames before OVS sees them."
        note "     Remove them from netplan; define the VLANs in VME Manager instead."
      else
        d_ok "no stray OS-level VLANs on the compute uplink (${cdev})"
      fi
    fi
  fi

  # --- 5. iSCSI ----------------------------------------------------------
  hdr "iSCSI / multipath"
  if command -v iscsiadm >/dev/null 2>&1; then
    local sess; sess="$( { iscsiadm -m session 2>/dev/null || true; } | wc -l )"
    if [[ "$sess" -gt 0 ]]; then
      d_ok "${sess} active iSCSI sessions"
      { iscsiadm -m session 2>/dev/null || true; } | sed 's/^/       /'
      # cartesian session detection: sessions should be paths, not NIC x portal mesh
      local ifaces portals expected
      ifaces="$( { iscsiadm -m session -P1 2>/dev/null || true; } | awk -F': ' '/Iface Name/{print $2}' | sort -u | wc -l )"
      portals="$( { iscsiadm -m session 2>/dev/null || true; } | awk '{print $3}' | cut -d, -f1 | sort -u | wc -l )"
      if [[ "$ifaces" -gt 1 && "$portals" -gt 1 ]]; then
        expected=$(( ifaces > portals ? ifaces : portals ))
        if [[ "$sess" -gt "$expected" ]]; then
          d_warn "${sess} sessions from ${ifaces} ifaces x ${portals} portals looks like a full mesh."
          note "     MPIO wants one session per NIC->portal pair, not every combination."
        fi
      fi
    else
      d_warn "no iSCSI sessions (fine if using local or NFS storage)"
    fi
  else
    d_warn "open-iscsi not installed"
  fi

  if command -v multipath >/dev/null 2>&1 && multipath -ll >/dev/null 2>&1; then
    local maps; maps="$( { multipath -ll 2>/dev/null || true; } | grep -c 'dm-' || true )"
    [[ "$maps" -gt 0 ]] && d_ok "${maps} multipath maps" || d_warn "multipathd running but no maps"
    if multipath -ll 2>/dev/null | grep -qE 'failed|faulty'; then
      d_bad "multipath reports failed/faulty paths"
      { multipath -ll 2>/dev/null || true; } | grep -E 'failed|faulty' | sed 's/^/       /' || true
    fi
  fi

  if { mount 2>/dev/null || true; } | grep -q 'type gfs2'; then
    d_warn "GFS2 is mounted on this host."
    note "     NEVER change iSCSI sessions or NIC config under a live GFS2 mount."
    note "     VME 9.0+ manages GFS2 consistency itself - there is no pacemaker layer."
    note "     Park the host via Maintenance Mode on the cluster detail page in VME"
    note "     Manager, let workloads evacuate, make the change, then bring it back."
  fi

  # --- 6. sysctl ---------------------------------------------------------
  hdr "kernel tunables"
  local rp; rp="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')"
  if [[ "$rp" == "1" ]]; then
    d_warn "rp_filter=1 (strict) with multi-homed storage NICs drops return traffic"
    d_fix F04 "write ${SYSCTL_OUT} with rp_filter=2 and ARP hardening"
  else
    d_ok "rp_filter=${rp}"
  fi

  # rp_filter says nothing about ARP behaviour. A host with several NICs in one
  # broadcast domain will answer ARP for ANY local address out ANY interface
  # unless arp_ignore is raised - which looks exactly like a duplicate IP.
  local ai aa
  ai="$(sysctl -n net.ipv4.conf.all.arp_ignore 2>/dev/null || echo '?')"
  aa="$(sysctl -n net.ipv4.conf.all.arp_announce 2>/dev/null || echo '?')"
  if [[ "$ai" == "0" || "$aa" == "0" ]]; then
    local naddr; naddr="$( { ip -o -4 addr show 2>/dev/null || true; } | awk '$2!="lo"' | wc -l )"
    if [[ "$naddr" -gt 2 ]]; then
      d_warn "arp_ignore=${ai} arp_announce=${aa} on a host with ${naddr} addressed interfaces"
      note "     Linux will answer ARP for any local address on any interface. If two"
      note "     of those interfaces share a broadcast domain, the host answers for"
      note "     its own address out the wrong NIC - which reads as a duplicate IP"
      note "     and can silently collapse MPIO onto one path."
      d_fix F04 "arp_ignore=1, arp_announce=2 (and rp_filter=2)"
    else
      d_ok "arp_ignore=${ai} arp_announce=${aa} (few enough interfaces to be safe)"
    fi
  else
    d_ok "arp_ignore=${ai} arp_announce=${aa}"
  fi

  if [[ -f "$WAITONLINE_DROPIN" ]]; then
    d_ok "wait-online drop-in present"
  else
    d_warn "systemd-networkd-wait-online has no interface filter - boot can stall 120s"
    d_fix F07 "write a wait-online drop-in gating only on the management interface"
  fi

  # --- 7. NIC link state -------------------------------------------------
  hdr "physical links"
  local nolink=""
  for n in "${NICS[@]}"; do
    if [[ "${NIC_STATE[$n]}" == "up" && "${NIC_CARR[$n]}" != "1" ]]; then
      nolink="${nolink} ${n}"
    fi
  done
  [[ -n "$nolink" ]] && d_warn "admin-up but no carrier:${nolink}" || d_ok "no dark links among admin-up NICs"

  # --- 8. hpe-vm ---------------------------------------------------------
  hdr "VME state"
  if dpkg -l hpe-vm 2>/dev/null | grep -q '^ii'; then
    d_ok "hpe-vm installed: $(dpkg-query -W -f='${Version}' hpe-vm 2>/dev/null)"
  else
    d_ok "hpe-vm not installed - this host is at the correct pre-install stage"
  fi

  # --- summary -----------------------------------------------------------
  hdr "Summary"
  printf '   %spass %s%s   %swarn %s%s   %sfail %s%s\n\n' \
    "$C_G" "$D_PASS" "$C_RST" "$C_Y" "$D_WARN" "$C_RST" "$C_R" "$D_FAIL" "$C_RST"
  if [[ ${#AVAILABLE_FIXES[@]} -gt 0 ]]; then
    local uniq; uniq="$(printf '%s\n' "${AVAILABLE_FIXES[@]}" | sort -u | paste -sd, -)"
    if [[ "$DO_FIX" == "yes" ]]; then
      apply_fixes
    else
      info "repairable items: ${uniq}"
      info "run:  sudo ${PROG} --doctor --fix            (all safe fixes)"
      info "or:   sudo ${PROG} --doctor --fix=${uniq%%,*}      (one fix)"
    fi
  else
    ok "nothing to repair"
  fi
  [[ "$D_FAIL" -gt 0 ]] && return 1 || return 0
}

doctor_switch_side() {
  hdr "switch side (from LLDP)"
  if ! command -v lldpctl >/dev/null 2>&1; then
    d_warn "lldpd not installed - cannot see what these NICs are plugged into"
    note "     apt install lldpd    then re-run. This is the single most useful"
    note "     thing you can add before choosing a bond mode: it tells you whether"
    note "     the two bond members land on ONE switch or TWO."
    return 0
  fi

  local b bonds=() slave chassis port vlans
  for b in "${PROC_BONDING}"/*; do [[ -e "$b" ]] && bonds+=("$(basename "$b")"); done
  [[ ${#bonds[@]} -eq 0 ]] && { d_warn "no bonds to inspect"; return 0; }

  for b in "${bonds[@]}"; do
    local mode; mode="$(awk -F': ' '/^Bonding Mode/{print $2; exit}' "${PROC_BONDING}/${b}")"
    info "${b} (${mode})"
    local -a seen=()
    for slave in $(awk -F': ' '/^Slave Interface:/{print $2}' "${PROC_BONDING}/${b}"); do
      chassis="$(lldpctl -f keyvalue "$slave" 2>/dev/null | awk -F= '/\.chassis\.name=/{print $2; exit}')"
      port="$(lldpctl -f keyvalue "$slave" 2>/dev/null | awk -F= '/\.port\.(descr|ifname)=/{print $2; exit}')"
      vlans="$(lldpctl -f keyvalue "$slave" 2>/dev/null | awk -F= '/\.vlan\.vlan-id=/{print $2}' | paste -sd, -)"
      if [[ -z "${chassis:-}" ]]; then
        d_warn "  ${slave}: no LLDP neighbour (switch not sending LLDP, or link down)"
      else
        info "  ${slave} -> ${chassis} ${port:+port ${port}}${vlans:+  vlans seen: ${vlans}}"
        seen+=("$chassis")
      fi
    done

    # one switch or two? this is what decides whether LACP is even possible
    local uniq; uniq="$(printf '%s\n' "${seen[@]:-}" | grep -v '^$' | sort -u | wc -l)"
    if [[ "$uniq" -ge 2 ]]; then
      d_warn "  ${b} spans ${uniq} switches."
      note "       LACP across two chassis needs MLAG / stacking / VSF / IRF / vPC."
      note "       Plain balance-xor across two INDEPENDENT switches means the same"
      note "       source MAC appears on ports of both - the switches will log MAC"
      note "       moves, and some will err-disable the port on a mac-move threshold."
      note "       If the pair is not stacked, active-backup is the only mode that is"
      note "       unambiguously safe; it costs you half the aggregate bandwidth."
    elif [[ "$uniq" -eq 1 ]]; then
      ok "  ${b} lands on a single switch (${seen[0]})"
      note "       A static port-channel or LACP LAG on those ports is straightforward."
    fi

    case "$mode" in
      *802.3ad*)
        note "       LACP: the peer ports MUST be in a LAG. Check the partner MAC above." ;;
      *"load balancing (xor)"*|*balance-xor*)
        note "       XOR: transmits across all members from one MAC. The peer ports need"
        note "       to be a static aggregation, or you get MAC flapping. XOR does NOT"
        note "       negotiate, so a mismatch is silent - no partner state to inspect." ;;
      *active-backup*)
        note "       active-backup: needs NO switch aggregation. One link carries traffic."
        note "       Safe anywhere, including across unstacked switches. Half the bandwidth." ;;
    esac
  done
}

check_bond_health_doctor() {
  local b="$1"
  local pf="${PROC_BONDING}/$1"
  local slaves=0
  [[ -r "$pf" ]] && slaves="$(grep -c '^Slave Interface:' "$pf" || true)"

  if [[ "$slaves" -eq 0 ]]; then
    d_bad "${b} has ZERO enslaved members - it is an empty shell carrying no traffic"
    note "     Anything relying on ${b} (an OVS bridge port, a VLAN child) is dark."
    d_fix F08 "rebuild ${b} from the saved profile (console only, refuses over SSH)"
  fi

  # A bond MAC that matches no slave is NORMAL here, not a fault: systemd-networkd
  # derives bond MACs from /etc/machine-id. Do not read a locally-administered
  # bond MAC as evidence of an empty bond - check the slave count instead.
  local bmac smac matched="no" s
  bmac="$(cat "${SYS_NET}/${b}/address" 2>/dev/null || echo '')"
  for s in $(awk -F': ' '/^Slave Interface:/{print $2}' "$pf" 2>/dev/null); do
    smac="$(cat "${SYS_NET}/${s}/address" 2>/dev/null || echo '')"
    [[ "$bmac" == "$smac" ]] && matched="yes"
  done
  if [[ "$slaves" -gt 0 && "$matched" == "no" ]]; then
    info "${b} MAC ${bmac} is machine-id derived, not inherited from a slave (normal)"
    note "     If this host was cloned from a template, every clone shares that MAC."
    note "     Check: cmp /etc/machine-id across hosts. Fix: systemd-machine-id-setup + reboot."
  fi

  check_bond_health "$b"
  # is this bond wrongly enslaved into an OVS bridge at the kernel level?
  if command -v ovs-vsctl >/dev/null 2>&1; then
    local br
    br="$(ovs-vsctl port-to-br "$b" 2>/dev/null || true)"
    if [[ -n "$br" ]]; then
      info "${b} is an OVS port on bridge '${br}'"
      # a bond that is an OVS port must not also carry the host L3
      if ip -o -4 addr show dev "$b" 2>/dev/null | grep -q 'inet '; then
        d_bad "${b} is BOTH an OVS port on '${br}' AND holds an IP directly."
        note "     This is the MAC-flooding pattern: the address must live on the bridge"
        note "     internal port or on a VLAN subinterface, never on the enslaved bond."
      fi
    fi
  fi
}

doctor_ovs_bridge() {
  local br="$1"
  info "bridge ${br}"
  local fm; fm="$(ovs-vsctl get bridge "$br" fail_mode 2>/dev/null | tr -d '"[]' )"
  if [[ "$fm" != "standalone" ]]; then
    d_bad "${br}: fail_mode='${fm:-unset}'. Without standalone the bridge blackholes"
    note "     traffic whenever no controller is present - which is always, here."
    d_fix F06 "ovs-vsctl set bridge ${br} fail_mode=standalone"
  else
    d_ok "${br}: fail_mode=standalone"
  fi

  local ports p type
  ports="$(ovs-vsctl list-ports "$br" 2>/dev/null || true)"
  [[ -z "$ports" ]] && { d_warn "${br}: no ports"; return 0; }
  for p in $ports; do
    type="$(ovs-vsctl get interface "$p" type 2>/dev/null | tr -d '"' )"
    # the classic broken-fresh-install signature: a bond/physical name that OVS
    # created as an internal port because the real device was never attached.
    if [[ "$type" == "internal" && "$p" != "$br" ]]; then
      if [[ -d "${SYS_NET}/${p}/bonding" ]] || is_physical_nic "$p" 2>/dev/null; then
        d_bad "${br}: port '${p}' is type:internal but a real device of that name exists."
        note "     OVS made a dummy port instead of attaching the bond. Classic fresh-VME defect."
        d_fix F05 "del-port ${br} ${p}; add-port ${br} ${p}; set fail_mode=standalone"
      else
        d_warn "${br}: port '${p}' is type:internal and no matching kernel device exists"
        d_fix F05 "recreate ${p} as a real port on ${br}"
      fi
    fi
    local link; link="$(cat "${SYS_NET}/${p}/operstate" 2>/dev/null || echo 'absent')"
    [[ "$link" == "down" ]] && d_warn "${br}: port ${p} is operstate down"
  done
  d_ok "${br}: ${ports//$'\n'/ }"
}

apply_fixes() {
  hdr "Applying repairs"
  local id
  for id in $(printf '%s\n' "${AVAILABLE_FIXES[@]}" | sort -u); do
    fix_wanted "$id" || { note "skipping ${id} (not selected)"; continue; }
    case "$id" in
      F01) fix_netplan_perms ;;
      F02) fix_cloudinit ;;
      F03) fix_mtu ;;
      F04) fix_sysctl ;;
      F05) fix_ovs_internal_port ;;
      F06) fix_ovs_failmode ;;
      F07) fix_waitonline ;;
      F08) fix_empty_bond ;;
      F09) fix_duplicate_l3 ;;
      *)   warn "unknown fix ${id}" ;;
    esac
  done
  info "re-run --doctor to confirm."
}

fix_netplan_perms() {
  info "[F01] tightening netplan file permissions"
  run chmod 0600 "${NETPLAN_DIR}"/*.yaml
  ok "F01 done"
}

fix_cloudinit() {
  info "[F02] neutralising cloud-init network config and extra netplan files"
  make_backup
  [[ "$DRY_RUN" == "no" ]] && disable_cloudinit_net
  local f
  for f in "${NETPLAN_DIR}"/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$NETPLAN_OUT" ]] && continue
    if is_vme_owned "$f"; then ok "  keeping VME-owned ${f##*/}"; continue; fi
    run mv "$f" "${BACKUP_DIR}/${f##*/}.disabled"
  done
  ok "F02 done (originals in ${BACKUP_DIR})"
}

fix_mtu() {
  info "[F03] aligning member MTUs to their master"
  local n master pmtu
  for n in $(ls -1 ${SYS_NET} | grep -v '^lo$'); do
    master="$(basename "$(readlink -f "${SYS_NET}/${n}/master" 2>/dev/null || echo '')")"
    [[ -n "$master" && "$master" != "." && -e "${SYS_NET}/${master}/mtu" ]] || continue
    pmtu="$(cat "${SYS_NET}/${master}/mtu")"
    [[ "$(cat "${SYS_NET}/${n}/mtu")" == "$pmtu" ]] && continue
    run ip link set dev "$n" mtu "$pmtu"
    ok "  ${n} -> mtu ${pmtu}"
  done
  warn "runtime only. Update netplan (or re-run --apply) so it survives reboot."
}

fix_sysctl() {
  info "[F04] writing ${SYSCTL_OUT}"
  [[ -r "$PROFILE_FILE" ]] && load_profile "$PROFILE_FILE" || true
  if [[ "$DRY_RUN" == "no" ]]; then
    render_sysctl "$SYSCTL_OUT"
    sysctl -p "$SYSCTL_OUT" >/dev/null 2>&1 || true
  fi
  ok "F04 done"
}

fix_ovs_failmode() {
  info "[F05/F06] setting fail_mode=standalone on OVS bridges"
  local br
  for br in $(ovs-vsctl list-br 2>/dev/null || true); do
    local fm; fm="$(ovs-vsctl get bridge "$br" fail_mode 2>/dev/null | tr -d '"[]')"
    [[ "$fm" == "standalone" ]] && continue
    run ovs-vsctl set bridge "$br" fail_mode=standalone
    ok "  ${br} -> standalone"
  done
}

fix_ovs_internal_port() {
  info "[F05] re-attaching real devices that OVS created as internal ports"
  warn "This briefly interrupts traffic on the affected bridge."
  if [[ "$ASSUME_YES" != "yes" ]]; then
    [[ "$(ask_yn 'proceed?' 'n')" == "y" ]] || { warn "F05 skipped"; return 0; }
  fi
  if mount | grep -q 'type gfs2'; then
    die "GFS2 is mounted. Put this host in Maintenance Mode in VME Manager first."
  fi
  local br p type
  for br in $(ovs-vsctl list-br 2>/dev/null || true); do
    for p in $(ovs-vsctl list-ports "$br" 2>/dev/null || true); do
      type="$(ovs-vsctl get interface "$p" type 2>/dev/null | tr -d '"')"
      [[ "$type" == "internal" ]] || continue
      [[ "$p" == "$br" ]] && continue
      if [[ -d "${SYS_NET}/${p}/bonding" ]] || is_physical_nic "$p" 2>/dev/null; then
        info "  ${br}: rebuilding port ${p}"
        run ovs-vsctl --if-exists del-port "$br" "$p"
        run ovs-vsctl add-port "$br" "$p"
        run ip link set dev "$p" up
        ok "  ${br}/${p} reattached"
      fi
    done
    run ovs-vsctl set bridge "$br" fail_mode=standalone
  done
}

fix_empty_bond() {
  info "[F08] rebuilding empty bonds from the saved profile"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    bad "F08 refuses to run over SSH."
    note "     Enslaving NICs into a bond that an OVS bridge already depends on will"
    note "     drop the management path mid-operation. Do this from iLO/console."
    return 0
  fi
  [[ -r "$PROFILE_FILE" ]] || { bad "no profile at ${PROFILE_FILE} - cannot know intended members"; return 0; }
  if mount | grep -q 'type gfs2'; then
    die "GFS2 is mounted. Put this host in Maintenance Mode in VME Manager first."
  fi
  load_profile "$PROFILE_FILE"
  warn "This re-applies the full netplan and restarts networking."
  if [[ "$ASSUME_YES" != "yes" ]]; then
    [[ "$(ask_yn 'proceed?' 'n')" == "y" ]] || { warn "F08 skipped"; return 0; }
  fi
  make_backup
  [[ "$DRY_RUN" == "no" ]] && render_netplan "$NETPLAN_OUT"
  run netplan apply
  sleep 5
  local b
  for b in $MGMT_BOND $COMPUTE_BOND $COMPUTE2_BOND; do
    [[ -r "${PROC_BONDING}/${b}" ]] || continue
    local c; c="$(grep -c '^Slave Interface:' "${PROC_BONDING}/${b}" || true)"
    [[ "$c" -gt 0 ]] && ok "  ${b}: ${c} members enslaved" || bad "  ${b}: still empty"
  done
  warn "If this bond is an OVS port, re-run --doctor --fix=F05,F06 to reattach it."
}

fix_duplicate_l3() {
  info "[F09] removing leftover L3 from interfaces now owned by an OVS bridge"
  have_pyyaml || { bad "needs python3-yaml (apt install python3-yaml)"; return 0; }
  local brmap; brmap="$(netplan_bridge_members)"
  [[ -n "$brmap" ]] || { ok "no netplan bridges - nothing to reconcile"; return 0; }
  warn "This edits the base netplan file. VME-owned files are never modified."
  if [[ "$ASSUME_YES" != "yes" ]]; then
    [[ "$(ask_yn 'proceed?' 'n')" == "y" ]] || { warn "F09 skipped"; return 0; }
  fi
  make_backup
  local members; members="$(printf '%s' "$brmap" | cut -f2 | sort -u | paste -sd, -)"
  local protected; protected="$(printf '%s ' "${VME_OWNED_GLOBS[@]}")"
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "(dry-run) would strip L3 from: ${members}"
    return 0
  fi
  python3 - "$NETPLAN_DIR" "$members" "$protected" <<'PYEOF'
import sys, glob, os, fnmatch, yaml
d_dir, members, protected = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split()
L3 = ("addresses", "routes", "nameservers", "gateway4", "gateway6")
for f in sorted(glob.glob(os.path.join(d_dir, "*.yaml"))):
    base = os.path.basename(f)
    if any(fnmatch.fnmatch(base, g) for g in protected):
        continue
    try:
        doc = yaml.safe_load(open(f)) or {}
    except Exception as e:
        print("   skip %s (unparseable: %s)" % (base, e)); continue
    net = doc.get("network") or {}
    changed = []
    for sec in ("ethernets", "bonds", "vlans"):
        for name, cfg in (net.get(sec) or {}).items():
            if name not in members or not isinstance(cfg, dict):
                continue
            for k in L3:
                if k in cfg:
                    del cfg[k]
                    changed.append("%s.%s" % (name, k))
    if changed:
        with open(f, "w") as fh:
            yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=True)
        os.chmod(f, 0o600)
        print("   %s: removed %s" % (base, ", ".join(changed)))
    else:
        print("   %s: nothing to remove" % base)
PYEOF
  ok "F09 done - run 'netplan generate' then 'netplan apply' to commit"
  warn "Verify the bridge still holds the address before rebooting:"
  note "  ip -4 addr show dev mgmt"
}

fix_waitonline() {
  info "[F07] writing wait-online drop-in"
  [[ -r "$PROFILE_FILE" ]] && load_profile "$PROFILE_FILE" || \
    { warn "no profile; using current default-route interface"; \
      MGMT_BOND="$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"; MGMT_VLAN=0; }
  if [[ "$DRY_RUN" == "no" ]]; then
    write_waitonline_dropin
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  ok "F07 done"
}

list_backups() {
  hdr "Restore points"
  [[ -d "$BACKUP_ROOT" ]] || { info "none yet at ${BACKUP_ROOT}"; return 0; }
  local d n verified latest=""
  [[ -L "${STATE_DIR}/LATEST" ]] && latest="$(readlink -f "${STATE_DIR}/LATEST")"
  printf '\n  %-18s %-7s %-9s %s\n' "TIMESTAMP" "FILES" "INTEGRITY" "RESTORE COMMAND"
  printf '  %s\n' "$(printf '%.0s-' {1..86})"
  for d in "$BACKUP_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    n="$(wc -l < "$d/MANIFEST.sha256" 2>/dev/null || echo 0)"
    if ( cd "$d" && sha256sum -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1; then
      verified="${C_G}ok${C_RST}"
    else
      verified="${C_R}DAMAGED${C_RST}"
    fi
    printf '  %-18s %-7s %-20s %s%s\n' "${d##*/}" "$n" "$verified" "sudo ${d}/restore.sh" \
      "$( [[ "$(readlink -f "$d")" == "$latest" ]] && printf '   <- latest' )"
  done
  printf '\n'
  note "Any of these can be run from the iLO console with no network and no arguments."
  note "Add --dry-run to see what one would change."
}

rollback_to() {
  local want="${1:-}"
  local d
  if [[ -z "$want" || "$want" == "latest" ]]; then
    d="$(readlink -f "${STATE_DIR}/LATEST" 2>/dev/null || true)"
    [[ -n "$d" && -d "$d" ]] || die "no LATEST restore point; try --list-backups"
  else
    d="${BACKUP_ROOT}/${want}"
    [[ -d "$d" ]] || die "no such restore point: ${want}"
  fi
  hdr "Rolling back to ${d##*/}"
  if ! ( cd "$d" && sha256sum -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1; then
    bad "checksums do not verify for this restore point"
    [[ "$(ask_yn 'continue anyway?' 'n')" == "y" ]] || die "aborted"
  else
    ok "integrity verified"
  fi
  printf '\n'; note "Files that will be restored:"
  ls -1 "$d/netplan" 2>/dev/null | sed 's/^/     netplan\//'
  ( cd "$d/rootfs" 2>/dev/null && find . -type f -printf '     %P\n' 2>/dev/null ) || true
  printf '\n'
  if [[ "$DRY_RUN" == "yes" ]]; then
    "$d/restore.sh" --dry-run
    return 0
  fi
  [[ "$ASSUME_YES" == "yes" ]] || { [[ "$(ask_yn 'Restore now?' 'n')" == "y" ]] || die "cancelled"; }
  "$d/restore.sh"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
cat <<EOF
${PROG} v${VERSION} - HPE Morpheus VM Essentials post-OS network configurator
Run after the Ubuntu install, before installing the hpe-vm appliance.

USAGE
  sudo ${PROG} --wizard                 interactive setup, writes a profile, applies
  sudo ${PROG} --apply --profile FILE   non-interactive apply from a saved profile
  sudo ${PROG} --reconfigure            repair mgmt/cmpt uplinks on an ALREADY-PREPPED host
  sudo ${PROG} --doctor                 audit this host, report problems, suggest fixes
  sudo ${PROG} --doctor --fix           audit and apply all safe repairs
  sudo ${PROG} --doctor --fix=F03,F06   apply only the listed repairs
       ${PROG} --discover               list NICs and exit
       ${PROG} --list-backups           list every restore point and its restore command
  sudo ${PROG} --rollback               restore the most recent backup
  sudo ${PROG} --rollback=TIMESTAMP     restore a specific one
       ${PROG} --show                   print the saved profile and cluster answers

OPTIONS
  --profile FILE     profile to read (default ${PROFILE_FILE})
  --dry-run          render everything, write nothing
  --yes              assume yes; also auto-confirms the dead-man rollback
  --safety-timer N   seconds before automatic rollback (default ${SAFETY_TIMER}, 0 = off)
  --maint-timeout N  seconds to wait for Maintenance Mode to settle (default ${MAINT_TIMEOUT})
  --probe-links      bring admin-down NICs up during discovery to detect carrier
  --no-sysctl        skip the kernel tunables file
  --force            proceed past preflight objections
  --version          print version
  --help             this text

REPAIR IDS
  F01  netplan file permissions (0600)
  F02  disable cloud-init networking / demote competing netplan files
  F03  align member MTU to master MTU
  F04  write rp_filter + ARP + socket-buffer tunables
  F05  re-attach OVS ports that were created as type:internal dummies
  F06  set fail_mode=standalone on OVS bridges
  F07  wait-online drop-in so only management gates boot
  F08  rebuild a bond that has zero enslaved members (console only)
  F09  strip leftover L3 from an interface that an OVS bridge now owns

RECOVERY
  Every change takes a verified, checksummed backup first and writes a
  self-contained restore script to three places:
      ${STATE_DIR}/restore-latest.sh
      /root/vme-restore-<timestamp>.sh
      ${BACKUP_ROOT}/<timestamp>/restore.sh
  Any of them runs from an iLO console with no network and no arguments.
  If the backup cannot be verified, nothing is changed.

DESIGN NOTES
  * OVS 'mgmt' and 'cmpt' bridges are created by VME Manager. This tool refuses
    to create them and flags them if they exist before hpe-vm is installed.
  * iSCSI NICs are never bonded. HPE recommends MPIO for iSCSI/FC GFS2 LUNs.
  * Management is the only interface that gates boot; everything else is
    'optional: true' so a dead switch port cannot stall the host.
  * Nothing is changed under a live GFS2 mount without an explicit refusal.
EOF
}

show_saved() {
  [[ -r "${IN_PROFILE:-$PROFILE_FILE}" ]] || die "no profile at ${IN_PROFILE:-$PROFILE_FILE}"
  load_profile "${IN_PROFILE:-$PROFILE_FILE}"
  hdr "Saved profile"
  print_plan
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wizard)        MODE="wizard" ;;
      --apply)         MODE="apply" ;;
      --doctor)        MODE="doctor" ;;
      --reconfigure)   MODE="reconfigure" ;;
      --list-backups)  MODE="list-backups" ;;
      --rollback)      MODE="rollback" ;;
      --rollback=*)    MODE="rollback"; ROLLBACK_TS="${1#*=}" ;;
      --discover)      MODE="discover" ;;
      --show)          MODE="show" ;;
      --profile)       IN_PROFILE="${2:-}"; shift ;;
      --profile=*)     IN_PROFILE="${1#*=}" ;;
      --dry-run)       DRY_RUN="yes" ;;
      --yes|-y)        ASSUME_YES="yes" ;;
      --fix)           DO_FIX="yes" ;;
      --fix=*)         DO_FIX="yes"; FIX_ONLY="${1#*=}" ;;
      --maint-timeout) MAINT_TIMEOUT="${2:-900}"; shift ;;
      --maint-timeout=*) MAINT_TIMEOUT="${1#*=}" ;;
      --safety-timer)  SAFETY_TIMER="${2:-180}"; shift ;;
      --safety-timer=*) SAFETY_TIMER="${1#*=}" ;;
      --probe-links)   PROBE_LINKS="yes" ;;
      --no-sysctl)     NO_SYSCTL="yes" ;;
      --force)         FORCE="yes" ;;
      --version)       printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      --help|-h)       usage; exit 0 ;;
      *)               usage; die "unknown argument: $1" ;;
    esac
    shift
  done

  [[ -n "$MODE" ]] || { usage; exit 1; }

  case "$MODE" in
    discover)
      discover_nics
      hdr "Physical NICs"
      print_nic_table
      ;;
    show)
      show_saved
      ;;
    doctor)
      need_root
      doctor
      ;;
    reconfigure)
      reconfigure
      ;;
    list-backups)
      list_backups
      ;;
    rollback)
      need_root
      rollback_to "${ROLLBACK_TS:-latest}"
      ;;
    wizard)
      need_root
      mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
      preflight
      discover_nics
      wizard
      apply_config
      hdr "Next steps"
      info "1. Repeat this on every host with the same topology and bond mode."
      info "2. Install the hpe-vm package, then run 'hpe-vm' to deploy the manager."
      info "3. Configure iSCSI/multipath (vme-iscsi-setup) before creating the cluster."
      info "4. In the cluster wizard use the interface names printed above."
      printf '\n'
      print_plan
      ;;
    apply)
      need_root
      mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
      load_profile "${IN_PROFILE:-$PROFILE_FILE}"
      discover_nics
      preflight
      hdr "Plan"
      print_plan
      if [[ "$ASSUME_YES" != "yes" && "$DRY_RUN" != "yes" ]]; then
        [[ "$(ask_yn 'Apply this configuration?' 'n')" == "y" ]] || die "cancelled"
      fi
      apply_config
      ;;
  esac
}

# Allow sourcing for tests without executing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

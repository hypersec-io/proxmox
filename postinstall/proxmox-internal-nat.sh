#!/bin/bash

#############################################
# Proxmox VE Internal NAT Network Configuration
#############################################
#
# Copyright 2025 HyperSec
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#############################################
#
# Purpose:
#   Safe, idempotent Proxmox VE host-side internal VM network (any IPv4 CIDR)
#   with NAT outbound via a WAN bridge (default vmbr0).
#
# Usage:
#   sudo ./proxmox-internal-nat.sh apply --lan-cidr <CIDR> [options]
#   sudo ./proxmox-internal-nat.sh remove [options]
#   sudo ./proxmox-internal-nat.sh status --lan-cidr <CIDR> [options]
#   sudo ./proxmox-internal-nat.sh health --lan-cidr <CIDR> [options]
#
# Commands:
#   apply   - Create internal bridge, enable forwarding, add NAT rules
#   remove  - Remove all configuration and rules
#   status  - Show CONFIG intent vs LIVE runtime state
#   health  - Deeper dataplane checks (routes + nft rules/counters)
#
# Options:
#   --lan-cidr <CIDR>    Network CIDR (e.g., 10.42.0.0/16) - required for apply/status/health
#   --lan-gw <IP>        Gateway IP (default: first usable host in CIDR)
#   --wan-bridge <name>  WAN bridge name (default: vmbr0)
#   --lan-bridge <name>  LAN bridge name (default: vmbr1)
#   --reload             Reload networking after changes (default: no, safer for remote)
#
# Requirements:
#   - Proxmox VE
#   - Root privileges
#   - python3 (for CIDR validation)
#   - nftables
#
# Safety:
#   - Does NOT reload networking unless --reload is passed
#   - Uses isolated nftables tables (won't conflict with pve-firewall)
#   - All files are backed up before modification
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No
#
#############################################

set -e

SCRIPT_NAME="$(basename "$0")"

# Defaults (override via flags)
VM_BR_WAN="vmbr0"
VM_BR_LAN="vmbr1"
LAN_CIDR="10.42.0.0/16"   # network CIDR; gateway defaults to first usable host (e.g. 10.42.0.1)
LAN_GW=""                # if empty, computed as first usable host

IFACES_MAIN="/etc/network/interfaces"
IFACES_D_DIR="/etc/network/interfaces.d"

# Derived after args parsed
IFACES_D_FILE=""
SYSCTL_FILE=""
NAT_HELPER=""
NAT_SERVICE=""

MARKER_BEGIN="# --- managed by ${SCRIPT_NAME}: BEGIN ---"
MARKER_END="# --- managed by ${SCRIPT_NAME}: END ---"

RELOAD_NETWORKING="no"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Must run as root."
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts b
    ts="$(date +%Y%m%d-%H%M%S)"
    b="${f}.bak.${ts}"
    cp -a "$f" "$b"
    log "Backup: ${f} -> ${b}"
  fi
}

# Pretty status helpers
section() { log; log "== $* =="; }
ok() { log "  OK  - $*"; }
warn() { log "  WARN- $*"; }
info() { log "  INFO- $*"; }

iface_up() {
  local ifn="$1"
  # Check for UP flag in angle brackets (bridges with no ports show state UNKNOWN but still have UP flag)
  ip link show "$ifn" 2>/dev/null | grep -qE '<[^>]*UP[^>]*>'
}

has_addr() {
  local ifn="$1"
  local cidr="$2"
  ip -o -4 addr show dev "$ifn" 2>/dev/null | awk '{print $4}' | grep -Fxq "$cidr"
}

ensure_wan_bridge_exists() {
  have_cmd ip || die "ip command not found (unexpected)."
  if ! ip link show "${VM_BR_WAN}" >/dev/null 2>&1; then
    die "${VM_BR_WAN} not found (expected a working Proxmox WAN bridge). Aborting."
  fi
}

ensure_ifaces_d_sourced() {
  # Proxmox usually includes this, but we add it safely if missing.
  if grep -Eq '^\s*source\s+/etc/network/interfaces\.d/\*' "${IFACES_MAIN}"; then
    return 0
  fi

  backup_file "${IFACES_MAIN}"
  {
    printf '\n%s\n' "${MARKER_BEGIN}"
    printf 'source /etc/network/interfaces.d/*\n'
    printf '%s\n' "${MARKER_END}"
  } >> "${IFACES_MAIN}"
  log "Added sourcing line to ${IFACES_MAIN} (marked block)."
}

# CIDR parsing / validation using python3 ipaddress:
# - Accepts any IPv4 CIDR with strict network address (e.g. 10.42.0.0/16, not 10.42.0.5/16)
# - Gateway defaults to first usable host
# - Rejects /31 and /32 for routing (no usable hosts)
CIDR_PREFIXLEN=""
CIDR_NETWORK=""
CIDR_GW=""

calc_cidr() {
  have_cmd python3 || die "python3 not found; required for CIDR parsing."

  local out
  out="$(
    python3 - "${LAN_CIDR}" "${LAN_GW}" <<'PY'
import sys, ipaddress

cidr = sys.argv[1]
gw   = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""

try:
    net = ipaddress.ip_network(cidr, strict=True)
except Exception as e:
    print(f"ERR invalid CIDR: {e}")
    sys.exit(2)

if net.version != 4:
    print("ERR only IPv4 supported")
    sys.exit(3)

# /31 and /32 don't have usable host addresses in the typical sense for a routed LAN
if net.prefixlen >= 31:
    print("ERR CIDR too small for routed LAN (/31 or /32 not supported)")
    sys.exit(4)

hosts = list(net.hosts())
if not hosts:
    print("ERR no usable hosts in CIDR")
    sys.exit(5)

first_host = str(hosts[0])
gw_ip = gw or first_host

try:
    gw_addr = ipaddress.ip_address(gw_ip)
except Exception as e:
    print(f"ERR invalid gateway IP: {e}")
    sys.exit(6)

if gw_addr not in net:
    print("ERR gateway is not inside the CIDR")
    sys.exit(7)

# Disallow network/broadcast explicitly
if gw_addr == net.network_address or gw_addr == net.broadcast_address:
    print("ERR gateway cannot be network or broadcast address")
    sys.exit(8)

print(net.prefixlen)
print(str(net.network_address) + f"/{net.prefixlen}")
print(str(gw_addr))
PY
  )" || {
    printf '%s\n' "$out" >&2
    exit 1
  }

  if echo "$out" | grep -q '^ERR '; then
    printf '%s\n' "$out" >&2
    exit 1
  fi

  CIDR_PREFIXLEN="$(printf '%s\n' "$out" | sed -n '1p')"
  CIDR_NETWORK="$(printf '%s\n' "$out" | sed -n '2p')"
  CIDR_GW="$(printf '%s\n' "$out" | sed -n '3p')"
}

apply_bridge_dropin() {
  mkdir -p "${IFACES_D_DIR}"

  local desired
  desired="$(mktemp)"
  cat > "${desired}" <<EOF
# Internal-only VM bridge for ${CIDR_NETWORK} (no physical ports)
auto ${VM_BR_LAN}
iface ${VM_BR_LAN} inet static
    address ${CIDR_GW}/${CIDR_PREFIXLEN}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

  if [[ -f "${IFACES_D_FILE}" ]] && cmp -s "${desired}" "${IFACES_D_FILE}"; then
    rm -f "${desired}"
    ok "Bridge drop-in already correct: ${IFACES_D_FILE}"
    return 0
  fi

  if [[ -f "${IFACES_D_FILE}" ]]; then
    backup_file "${IFACES_D_FILE}"
  fi
  install -m 0644 "${desired}" "${IFACES_D_FILE}"
  rm -f "${desired}"
  log "Wrote: ${IFACES_D_FILE}"
}

apply_ip_forwarding() {
  if [[ -f "${SYSCTL_FILE}" ]]; then
    ok "Sysctl drop-in already present: ${SYSCTL_FILE}"
  else
    cat > "${SYSCTL_FILE}" <<EOF
# Enable IPv4 forwarding for ${VM_BR_LAN} -> ${VM_BR_WAN} NAT routing
net.ipv4.ip_forward=1
EOF
    chmod 0644 "${SYSCTL_FILE}"
    log "Created: ${SYSCTL_FILE}"
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ok "Applied live: net.ipv4.ip_forward=1"
}

apply_nft_rules_now() {
  have_cmd nft || die "nft not found. Install nftables (expected on Proxmox 9)."

  # Isolated tables/chains to avoid interfering with pve-firewall.
  if ! nft list table ip "pve_${VM_BR_LAN}_nat" >/dev/null 2>&1; then
    nft add table ip "pve_${VM_BR_LAN}_nat"
    log "nft: created table ip pve_${VM_BR_LAN}_nat"
  fi
  if ! nft list chain ip "pve_${VM_BR_LAN}_nat" postrouting >/dev/null 2>&1; then
    nft "add chain ip pve_${VM_BR_LAN}_nat postrouting { type nat hook postrouting priority 100; }"
    log "nft: created chain ip pve_${VM_BR_LAN}_nat postrouting"
  fi

  if ! nft list chain ip "pve_${VM_BR_LAN}_nat" postrouting | grep -Fq "oifname \"${VM_BR_WAN}\" ip saddr ${CIDR_NETWORK} masquerade"; then
    nft add rule ip "pve_${VM_BR_LAN}_nat" postrouting oifname "${VM_BR_WAN}" ip saddr "${CIDR_NETWORK}" masquerade
    log "nft: added masquerade rule (${CIDR_NETWORK} -> ${VM_BR_WAN})"
  else
    ok "nft: masquerade rule already present"
  fi

  if ! nft list table inet "pve_${VM_BR_LAN}_filter" >/dev/null 2>&1; then
    nft add table inet "pve_${VM_BR_LAN}_filter"
    log "nft: created table inet pve_${VM_BR_LAN}_filter"
  fi
  if ! nft list chain inet "pve_${VM_BR_LAN}_filter" forward >/dev/null 2>&1; then
    nft "add chain inet pve_${VM_BR_LAN}_filter forward { type filter hook forward priority 0; policy accept; }"
    log "nft: created chain inet pve_${VM_BR_LAN}_filter forward"
  fi

  if ! nft list chain inet "pve_${VM_BR_LAN}_filter" forward | grep -Fq "iifname \"${VM_BR_LAN}\" oifname \"${VM_BR_WAN}\" accept"; then
    nft add rule inet "pve_${VM_BR_LAN}_filter" forward iifname "${VM_BR_LAN}" oifname "${VM_BR_WAN}" accept
    log "nft: allowed forward ${VM_BR_LAN} -> ${VM_BR_WAN}"
  else
    ok "nft: forward allow ${VM_BR_LAN} -> ${VM_BR_WAN} already present"
  fi

  if ! nft list chain inet "pve_${VM_BR_LAN}_filter" forward | grep -Fq "iifname \"${VM_BR_WAN}\" oifname \"${VM_BR_LAN}\" ct state established,related accept"; then
    nft add rule inet "pve_${VM_BR_LAN}_filter" forward iifname "${VM_BR_WAN}" oifname "${VM_BR_LAN}" ct state established,related accept
    log "nft: allowed return traffic ${VM_BR_WAN} -> ${VM_BR_LAN} (established,related)"
  else
    ok "nft: return allow rule already present"
  fi
}

install_nat_persistence_service() {
  # Avoid editing /etc/nftables.conf; this is isolated and safe alongside Proxmox firewall.
  cat > "${NAT_HELPER}" <<EOF
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

VM_BR_WAN="${VM_BR_WAN}"
VM_BR_LAN="${VM_BR_LAN}"
LAN_NET="${CIDR_NETWORK}"

command -v nft >/dev/null 2>&1

if ! nft list table ip "pve_\${VM_BR_LAN}_nat" >/dev/null 2>&1; then
  nft add table ip "pve_\${VM_BR_LAN}_nat"
fi
if ! nft list chain ip "pve_\${VM_BR_LAN}_nat" postrouting >/dev/null 2>&1; then
  nft "add chain ip pve_\${VM_BR_LAN}_nat postrouting { type nat hook postrouting priority 100; }"
fi
if ! nft list chain ip "pve_\${VM_BR_LAN}_nat" postrouting | grep -Fq "oifname \\"\${VM_BR_WAN}\\" ip saddr \${LAN_NET} masquerade"; then
  nft add rule ip "pve_\${VM_BR_LAN}_nat" postrouting oifname "\${VM_BR_WAN}" ip saddr "\${LAN_NET}" masquerade
fi

if ! nft list table inet "pve_\${VM_BR_LAN}_filter" >/dev/null 2>&1; then
  nft add table inet "pve_\${VM_BR_LAN}_filter"
fi
if ! nft list chain inet "pve_\${VM_BR_LAN}_filter" forward >/dev/null 2>&1; then
  nft "add chain inet pve_\${VM_BR_LAN}_filter forward { type filter hook forward priority 0; policy accept; }"
fi
if ! nft list chain inet "pve_\${VM_BR_LAN}_filter" forward | grep -Fq "iifname \\"\${VM_BR_LAN}\\" oifname \\"\${VM_BR_WAN}\\" accept"; then
  nft add rule inet "pve_\${VM_BR_LAN}_filter" forward iifname "\${VM_BR_LAN}" oifname "\${VM_BR_WAN}" accept
fi
if ! nft list chain inet "pve_\${VM_BR_LAN}_filter" forward | grep -Fq "iifname \\"\${VM_BR_WAN}\\" oifname \\"\${VM_BR_LAN}\\" ct state established,related accept"; then
  nft add rule inet "pve_\${VM_BR_LAN}_filter" forward iifname "\${VM_BR_WAN}" oifname "\${VM_BR_LAN}" ct state established,related accept
fi
EOF
  chmod 0755 "${NAT_HELPER}"
  log "Installed: ${NAT_HELPER}"

  cat > "${NAT_SERVICE}" <<EOF
[Unit]
Description=Proxmox ${VM_BR_LAN} NAT (${CIDR_NETWORK}) out via ${VM_BR_WAN}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NAT_HELPER}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$(basename "${NAT_SERVICE}")"
  log "Enabled: $(basename "${NAT_SERVICE}")"
}

reload_networking_if_requested() {
  if [[ "${RELOAD_NETWORKING}" != "yes" ]]; then
    warn "Networking reload skipped (default safe behaviour)."
    info "If you're on console/IPMI and want ${VM_BR_LAN} up now, run:"
    info "  ifreload -a   (preferred)   OR   systemctl restart networking"
    return 0
  fi

  if have_cmd ifreload; then
    log "Reloading networking with ifreload -a ..."
    ifreload -a
  else
    log "Reloading networking with systemctl restart networking ..."
    systemctl restart networking
  fi
  ok "Networking reloaded."
}

remove_bridge_dropin() {
  if [[ -f "${IFACES_D_FILE}" ]]; then
    backup_file "${IFACES_D_FILE}"
    rm -f "${IFACES_D_FILE}"
    log "Removed: ${IFACES_D_FILE}"
  else
    ok "Bridge drop-in not present: ${IFACES_D_FILE}"
  fi

  # Remove our marked source block if present.
  if grep -Fq "${MARKER_BEGIN}" "${IFACES_MAIN}" && grep -Fq "${MARKER_END}" "${IFACES_MAIN}"; then
    backup_file "${IFACES_MAIN}"
    awk -v b="${MARKER_BEGIN}" -v e="${MARKER_END}" '
      $0==b {inblk=1; next}
      $0==e {inblk=0; next}
      inblk==0 {print}
    ' "${IFACES_MAIN}" > "${IFACES_MAIN}.tmp"
    mv "${IFACES_MAIN}.tmp" "${IFACES_MAIN}"
    log "Removed marked source block from ${IFACES_MAIN}"
  fi
}

remove_ip_forwarding() {
  if [[ -f "${SYSCTL_FILE}" ]]; then
    backup_file "${SYSCTL_FILE}"
    rm -f "${SYSCTL_FILE}"
    log "Removed: ${SYSCTL_FILE}"
  else
    ok "Sysctl drop-in not present: ${SYSCTL_FILE}"
  fi

  # Only revert ip_forward if no other config enables it.
  local other_forward
  other_forward="$(grep -R --line-number --fixed-strings 'net.ipv4.ip_forward=1' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null | grep -vF "${SYSCTL_FILE}" || true)"
  if [[ -z "${other_forward}" ]]; then
    sysctl -w net.ipv4.ip_forward=0 >/dev/null || true
    ok "Applied live: net.ipv4.ip_forward=0 (no other forward=1 config found)"
  else
    warn "Leaving net.ipv4.ip_forward as-is (other forward=1 configs exist)."
  fi
}

remove_nft_rules_now() {
  if ! have_cmd nft; then
    warn "nft not installed; skipping nft rule removal."
    return 0
  fi

  if nft list table inet "pve_${VM_BR_LAN}_filter" >/dev/null 2>&1; then
    nft delete table inet "pve_${VM_BR_LAN}_filter" || true
    log "nft: deleted table inet pve_${VM_BR_LAN}_filter"
  else
    ok "nft: table inet pve_${VM_BR_LAN}_filter not present"
  fi

  if nft list table ip "pve_${VM_BR_LAN}_nat" >/dev/null 2>&1; then
    nft delete table ip "pve_${VM_BR_LAN}_nat" || true
    log "nft: deleted table ip pve_${VM_BR_LAN}_nat"
  else
    ok "nft: table ip pve_${VM_BR_LAN}_nat not present"
  fi
}

remove_nat_persistence_service() {
  local svc
  svc="$(basename "${NAT_SERVICE}")"

  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl disable --now "${svc}" || true
    log "Disabled: ${svc}"
  else
    ok "Service not installed: ${svc}"
  fi

  if [[ -f "${NAT_SERVICE}" ]]; then
    backup_file "${NAT_SERVICE}"
    rm -f "${NAT_SERVICE}"
    log "Removed: ${NAT_SERVICE}"
  fi

  if [[ -f "${NAT_HELPER}" ]]; then
    backup_file "${NAT_HELPER}"
    rm -f "${NAT_HELPER}"
    log "Removed: ${NAT_HELPER}"
  fi

  systemctl daemon-reload
}

status() {
  calc_cidr

  section "Config intent (on disk)"
  info "WAN bridge: ${VM_BR_WAN}"
  info "LAN bridge: ${VM_BR_LAN}"
  info "LAN CIDR  : ${LAN_CIDR}  (network=${CIDR_NETWORK} gw=${CIDR_GW})"

  if grep -Eq '^\s*source\s+/etc/network/interfaces\.d/\*' "${IFACES_MAIN}"; then
    ok "${IFACES_MAIN} sources ${IFACES_D_DIR}/*"
  else
    warn "${IFACES_MAIN} does NOT source ${IFACES_D_DIR}/* (drop-in may not be applied on reload)"
  fi

  if [[ -f "${IFACES_D_FILE}" ]]; then
    ok "Bridge drop-in present: ${IFACES_D_FILE}"
  else
    warn "Bridge drop-in missing: ${IFACES_D_FILE}"
  fi

  if [[ -f "${SYSCTL_FILE}" ]]; then
    ok "Sysctl drop-in present: ${SYSCTL_FILE}"
  else
    warn "Sysctl drop-in missing: ${SYSCTL_FILE}"
  fi

  local svc="pve-${VM_BR_LAN}-nat.service"
  if systemctl list-unit-files | grep -q "^${svc}"; then
    ok "Persistence service installed: ${svc}"
  else
    warn "Persistence service NOT installed: ${svc}"
  fi

  section "Live/runtime state (in-kernel right now)"
  if ip link show "${VM_BR_WAN}" >/dev/null 2>&1; then
    ok "WAN bridge exists: ${VM_BR_WAN}"
    if iface_up "${VM_BR_WAN}"; then
      ok "WAN bridge is UP: ${VM_BR_WAN}"
    else
      warn "WAN bridge is NOT UP: ${VM_BR_WAN}"
    fi
  else
    warn "WAN bridge missing: ${VM_BR_WAN}"
  fi

  if ip link show "${VM_BR_LAN}" >/dev/null 2>&1; then
    ok "LAN bridge exists: ${VM_BR_LAN}"
    if iface_up "${VM_BR_LAN}"; then
      ok "LAN bridge is UP: ${VM_BR_LAN}"
    else
      warn "LAN bridge is NOT UP: ${VM_BR_LAN}"
    fi

    if has_addr "${VM_BR_LAN}" "${CIDR_GW}/${CIDR_PREFIXLEN}"; then
      ok "LAN bridge has expected IPv4: ${CIDR_GW}/${CIDR_PREFIXLEN}"
    else
      warn "LAN bridge does NOT have expected IPv4: ${CIDR_GW}/${CIDR_PREFIXLEN}"
      info "Current IPv4 on ${VM_BR_LAN}:"
      ip -o -4 addr show dev "${VM_BR_LAN}" 2>/dev/null | sed 's/^/    /' || true
    fi
  else
    warn "LAN bridge missing: ${VM_BR_LAN} (likely networking not reloaded yet)"
  fi

  local ipf
  ipf="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "unknown")"
  if [[ "${ipf}" == "1" ]]; then
    ok "IPv4 forwarding is ENABLED (net.ipv4.ip_forward=1)"
  else
    warn "IPv4 forwarding is NOT enabled (net.ipv4.ip_forward=${ipf})"
  fi

  if have_cmd nft; then
    if nft list table ip "pve_${VM_BR_LAN}_nat" >/dev/null 2>&1; then
      ok "nft NAT table present: ip pve_${VM_BR_LAN}_nat"
    else
      warn "nft NAT table missing: ip pve_${VM_BR_LAN}_nat"
    fi

    if nft list table inet "pve_${VM_BR_LAN}_filter" >/dev/null 2>&1; then
      ok "nft filter table present: inet pve_${VM_BR_LAN}_filter"
    else
      warn "nft filter table missing: inet pve_${VM_BR_LAN}_filter"
    fi
  else
    warn "nft not installed (unexpected on Proxmox 9)"
  fi

  if systemctl is-enabled "${svc}" >/dev/null 2>&1; then
    ok "Service enabled: ${svc}"
  else
    warn "Service not enabled: ${svc}"
  fi

  if systemctl is-active "${svc}" >/dev/null 2>&1; then
    ok "Service active (currently): ${svc}"
  else
    info "Service not active (expected for oneshot): ${svc}"
  fi
}

health() {
  calc_cidr

  section "Health (dataplane checks) - LIVE only"
  ip link show "${VM_BR_WAN}" >/dev/null 2>&1 || die "Missing ${VM_BR_WAN}"
  ip link show "${VM_BR_LAN}" >/dev/null 2>&1 || die "Missing ${VM_BR_LAN} (reload networking or apply --reload on console)"

  iface_up "${VM_BR_WAN}" || warn "${VM_BR_WAN} is not UP"
  iface_up "${VM_BR_LAN}" || warn "${VM_BR_LAN} is not UP"
  has_addr "${VM_BR_LAN}" "${CIDR_GW}/${CIDR_PREFIXLEN}" || warn "${VM_BR_LAN} missing ${CIDR_GW}/${CIDR_PREFIXLEN}"

  section "Routes"
  info "Host default route:"
  ip route show default | sed 's/^/  /' || true
  info "Host route for LAN network (${CIDR_NETWORK}):"
  ip route show "${CIDR_NETWORK}" 2>/dev/null | sed 's/^/  /' || warn "No explicit route shown for ${CIDR_NETWORK} (may still work if iface is up)"

  section "nftables rules (presence + counters)"
  have_cmd nft || die "nft not installed"

  if nft list chain ip "pve_${VM_BR_LAN}_nat" postrouting >/dev/null 2>&1; then
    ok "NAT postrouting chain exists"
    nft -a list chain ip "pve_${VM_BR_LAN}_nat" postrouting | sed 's/^/  /'
  else
    warn "Missing NAT postrouting chain"
  fi

  if nft list chain inet "pve_${VM_BR_LAN}_filter" forward >/dev/null 2>&1; then
    ok "Filter forward chain exists"
    nft -a list chain inet "pve_${VM_BR_LAN}_filter" forward | sed 's/^/  /'
  else
    warn "Missing filter forward chain"
  fi

  section "Next step (real proof)"
  info "To prove end-to-end NAT, run from a VM on ${VM_BR_LAN}:"
  info "  ping -c1 ${CIDR_GW}"
  info "  ping -c1 1.1.1.1"
  info "  getent hosts example.com"
}

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} apply  --lan-cidr <CIDR> [--lan-gw <IP>] [--wan-bridge vmbr0] [--lan-bridge vmbr1] [--reload]
  ${SCRIPT_NAME} remove [--wan-bridge vmbr0] [--lan-bridge vmbr1] [--reload]
  ${SCRIPT_NAME} status --lan-cidr <CIDR> [--lan-gw <IP>] [--wan-bridge vmbr0] [--lan-bridge vmbr1]
  ${SCRIPT_NAME} health --lan-cidr <CIDR> [--lan-gw <IP>] [--wan-bridge vmbr0] [--lan-bridge vmbr1]

Notes:
  - --lan-cidr must be a strict network CIDR (ipaddress strict=True), e.g. 10.42.0.0/16 (not 10.42.0.5/16)
  - If --lan-gw is omitted, gateway defaults to the first usable host (e.g. x.x.x.1)
  - /31 and /32 are rejected (no usable hosts for routed LAN)
  - Without --reload, no networking reload is performed (safer if remote)
EOF
}

apply() {
  need_root
  ensure_wan_bridge_exists
  calc_cidr

  log "Applying ${VM_BR_LAN} internal network (${CIDR_NETWORK}, gw ${CIDR_GW}) + NAT out via ${VM_BR_WAN}..."
  ensure_ifaces_d_sourced
  apply_bridge_dropin
  apply_ip_forwarding
  apply_nft_rules_now
  install_nat_persistence_service
  reload_networking_if_requested

  log
  ok "DONE."
  info "VMs on ${VM_BR_LAN}: subnet ${CIDR_NETWORK}, gateway ${CIDR_GW}"
}

remove_all() {
  need_root
  ensure_wan_bridge_exists

  log "Removing ${VM_BR_LAN} internal network + NAT..."
  remove_nat_persistence_service
  remove_nft_rules_now
  remove_ip_forwarding
  remove_bridge_dropin
  reload_networking_if_requested

  log
  ok "DONE."
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --wan-bridge) VM_BR_WAN="$2"; shift 2 ;;
      --lan-bridge) VM_BR_LAN="$2"; shift 2 ;;
      --lan-cidr) LAN_CIDR="$2"; shift 2 ;;
      --lan-gw) LAN_GW="$2"; shift 2 ;;
      --reload) RELOAD_NETWORKING="yes"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  # Set derived paths based on bridge name
  IFACES_D_FILE="${IFACES_D_DIR}/pve-${VM_BR_LAN}-internal.conf"
  SYSCTL_FILE="/etc/sysctl.d/99-pve-${VM_BR_LAN}-ipforward.conf"
  NAT_HELPER="/usr/local/sbin/pve-${VM_BR_LAN}-nat-nft.sh"
  NAT_SERVICE="/etc/systemd/system/pve-${VM_BR_LAN}-nat.service"
}

main() {
  if [[ "$#" -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"; shift
  parse_args "$@"

  # Validate required args per command
  case "${cmd}" in
    apply|status|health)
      [[ -n "${LAN_CIDR}" ]] || die "--lan-cidr is required for ${cmd}"
      ;;
    remove)
      # no cidr required
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  case "${cmd}" in
    apply) apply ;;
    remove) remove_all ;;
    status) status ;;
    health) health ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

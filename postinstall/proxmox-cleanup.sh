#!/bin/bash

#############################################
# Proxmox VE Post-Install Artefact Cleanup
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
#   Find and remove artefacts left behind by EARLIER versions of these scripts.
#
#   None of the other scripts clean up their predecessors: each writes its
#   current generation of files and leaves whatever the last one wrote in
#   place. Because those files live in drop-in directories that apply
#   everything they contain, superseded generations do not become inert -- they
#   stay active and fight the current one.
#
#   Observed on a live host, all three generations active simultaneously:
#     - two APT DPkg::Post-Invoke hooks, both patching the same PVE files
#       (99proxmoxui from Nov 2025 and 99proxmoxpolicy from Dec 2025)
#     - orphaned sysctl drop-ins from Aug 2025, including one that was a raw
#       1192-line `sysctl -a` dump being replayed at every boot
#     - a read-only kernel statistic being set on every boot, erroring each time
#
# Usage:
#   sudo ./proxmox-cleanup.sh [command]
#
# Commands:
#   status  - Report what would be removed, change nothing (default)
#   apply   - Remove superseded artefacts, backing each up first
#
#   Nothing is removed without `apply`. Everything removed is copied to the
#   backup directory first.
#
# Requirements:
#   - Root privileges
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No
# Backup Location: /root/backup/proxmox-config/removed-<timestamp>/
#
#############################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

BACKUP_ROOT="/root/backup/proxmox-config"

# Superseded APT hooks. The current generation is 99proxmoxpolicy /
# proxmox-policy-hook.sh, written by proxmox-update-policy.sh.
OLD_APT_HOOKS=(
    "/etc/apt/apt.conf.d/99proxmoxui"
    "/usr/local/bin/proxmox-ui-hook.sh"
)

# Superseded sysctl drop-ins. 98-proxmox-optimize.conf is the current one;
# anything below is from a generation that used a different name and now just
# overrides it by sorting later.
OLD_SYSCTL=(
    "/etc/sysctl.d/99-proxmox-optimize.conf"
    "/etc/sysctl.d/99-proxmox-tweaks.conf"
    "/etc/sysctl.d/99-proxmox-backup.conf"
)

FOUND=0
ACTIONS=()

#---------------------------------------------------------------
# Pure helpers -- unit-testable, see tests/test-cleanup.sh
#---------------------------------------------------------------

looks_like_sysctl_dump() {
    # Is this file content ($1) a `sysctl -a` dump rather than a config?
    #
    # A dump contains informational and read-only keys that no hand-written
    # config would ever set. One of these was sitting in /etc/sysctl.d being
    # replayed at every boot, overriding the deliberate settings and erroring
    # on every read-only key it touched.
    local content="$1"
    echo "$content" | grep -qE '^(dev\.cdrom\.info|debug\.exception-trace|kernel\.random\.(entropy_avail|boot_id|uuid))'
}

has_readonly_keys() {
    # Does this content ($1) set kernel keys that cannot be written?
    # These error on every boot: "sysctl: setting key ...: Operation not
    # permitted". They are statistics, not settings.
    local content="$1"
    echo "$content" | grep -qE '^[[:space:]]*(kernel\.random\.entropy_avail|kernel\.random\.(boot_id|uuid)|fs\.dentry-state|fs\.file-nr)[[:space:]]*='
}

network_tier_from_path() {
    # 99-proxmox-network-10gbe.conf -> 10gbe
    local path="$1" base
    base=$(basename "$path")
    echo "$base" | sed -n 's/^99-proxmox-network-\(.*\)\.conf$/\1/p'
}

#---------------------------------------------------------------
# Detection
#---------------------------------------------------------------

note() {
    # note <severity> <path> <reason>
    local severity="$1" path="$2" reason="$3"
    FOUND=$((FOUND + 1))
    ACTIONS+=("$path")
    case "$severity" in
        high) printf '  %b[HIGH]%b %s\n' "$RED" "$NC" "$path" ;;
        *)    printf '  %b[MED ]%b %s\n' "$YELLOW" "$NC" "$path" ;;
    esac
    printf '         %s\n' "$reason"
}

scan() {
    echo -e "${GREEN}=== Superseded Artefact Scan ===${NC}\n"

    #-- Old APT hooks ------------------------------------------------------
    echo -e "${CYAN}APT hooks${NC}"
    local hook found_hook=0
    for hook in "${OLD_APT_HOOKS[@]}"; do
        if [ -e "$hook" ]; then
            note high "$hook" \
                "superseded by 99proxmoxpolicy/proxmox-policy-hook.sh; both patch the same PVE files on every apt run"
            found_hook=1
        fi
    done
    [ "$found_hook" -eq 0 ] && echo "  none"

    #-- Old sysctl drop-ins ------------------------------------------------
    echo -e "\n${CYAN}sysctl drop-ins${NC}"
    local f content found_sysctl=0
    for f in "${OLD_SYSCTL[@]}"; do
        [ -e "$f" ] || continue
        content=$(cat "$f" 2>/dev/null || echo "")
        if looks_like_sysctl_dump "$content"; then
            note high "$f" \
                "raw 'sysctl -a' dump ($(wc -l < "$f") lines), not a config -- replayed at every boot and sorts after 98-proxmox-optimize.conf"
        elif has_readonly_keys "$content"; then
            note high "$f" \
                "sets read-only kernel statistics -- errors on every boot"
        else
            note med "$f" \
                "superseded by 98-proxmox-optimize.conf, which it currently overrides by sort order"
        fi
        found_sysctl=1
    done

    # Any sysctl.d file that sets a read-only key, wherever it came from.
    for f in /etc/sysctl.d/*.conf; do
        [ -e "$f" ] || continue
        case " ${OLD_SYSCTL[*]} " in *" $f "*) continue ;; esac
        content=$(cat "$f" 2>/dev/null || echo "")
        if has_readonly_keys "$content"; then
            note high "$f" \
                "sets a read-only kernel statistic (e.g. kernel.random.entropy_avail) -- errors on every boot"
            found_sysctl=1
        fi
    done
    [ "$found_sysctl" -eq 0 ] && echo "  none"

    #-- Stale network tier files -------------------------------------------
    # proxmox-network.sh writes 99-proxmox-network-<tier>.conf and never
    # removes the tier it replaced. Two tier files both apply, and which one
    # wins is decided by filename sort, not by which was chosen: run 10gbe then
    # 1gbe and "1gbe" sorts last, so the 1gbe values win.
    echo -e "\n${CYAN}network tier drop-ins${NC}"
    local tier_files=()
    for f in /etc/sysctl.d/99-proxmox-network-*.conf; do
        [ -e "$f" ] && tier_files+=("$f")
    done

    if [ ${#tier_files[@]} -le 1 ]; then
        echo "  none${tier_files[0]:+ (1 tier file, correct)}"
    else
        local winner
        winner=$(printf '%s\n' "${tier_files[@]}" | sort | tail -1)
        echo -e "  ${RED}${#tier_files[@]} tier files present -- all are being applied${NC}"
        for f in "${tier_files[@]}"; do
            if [ "$f" = "$winner" ]; then
                printf '    %s  <- wins by sort order (tier %s)\n' "$f" "$(network_tier_from_path "$f")"
            else
                note med "$f" "stale network tier '$(network_tier_from_path "$f")', superseded"
            fi
        done
    fi

    echo ""
    if [ "$FOUND" -eq 0 ]; then
        echo -e "${GREEN}Nothing superseded found. Host is clean.${NC}"
    else
        echo -e "${YELLOW}${FOUND} superseded artefact(s) found.${NC}"
    fi
}

#---------------------------------------------------------------
# Apply
#---------------------------------------------------------------

apply_cleanup() {
    scan

    if [ "$FOUND" -eq 0 ]; then
        return 0
    fi

    local backup_dir
    backup_dir="${BACKUP_ROOT}/removed-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    echo ""
    echo -e "${YELLOW}Removing...${NC}"

    local path
    for path in "${ACTIONS[@]}"; do
        [ -e "$path" ] || continue
        # Flatten the path into the backup name so /etc/... and /usr/... cannot
        # collide, and the original location stays readable.
        cp -a "$path" "${backup_dir}/$(echo "${path#/}" | tr '/' '_')" 2>/dev/null || true
        rm -f "$path"
        echo -e "  ${GREEN}removed${NC} $path"
    done

    echo ""
    echo -e "${GREEN}OK Backed up to $backup_dir${NC}"

    # Re-apply the surviving sysctl configuration so the running kernel matches
    # the files, rather than keeping values from the drop-ins just removed.
    if command -v sysctl >/dev/null 2>&1; then
        sysctl --system >/dev/null 2>&1 || \
            echo -e "${YELLOW}Note: some sysctl keys could not be applied${NC}"
        echo -e "${GREEN}OK Reloaded sysctl configuration${NC}"
    fi

    echo ""
    echo -e "${CYAN}Verify:${NC}"
    echo "  sysctl -a --pattern 'vm.swappiness|net.ipv4.tcp_keepalive_time'"
    echo "  ls /etc/apt/apt.conf.d/ | grep -i proxmox"
    echo "  apt-get install --reinstall -y proxmox-widget-toolkit   # hook exits 0?"
}

show_help() {
    echo "Proxmox VE Post-Install Artefact Cleanup"
    echo ""
    echo "Usage: $0 {status|apply}"
    echo ""
    echo "Commands:"
    echo "  status  - Report what would be removed, change nothing (default)"
    echo "  apply   - Remove superseded artefacts, backing each up first"
    echo ""
    echo "What it looks for:"
    echo "  - APT hooks from earlier generations still patching the same files"
    echo "  - sysctl drop-ins superseded by 98-proxmox-optimize.conf"
    echo "  - sysctl files that are 'sysctl -a' dumps rather than configs"
    echo "  - sysctl files setting read-only kernel statistics"
    echo "  - more than one network tier file, all applying at once"
    echo ""
    echo "Backups: ${BACKUP_ROOT}/removed-<timestamp>/"
}

#############################################
# Main
#############################################

# Sourcing defines the functions without running anything, so the detection
# helpers can be unit-tested. See tests/test-cleanup.sh.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

case "${1:-status}" in
    status)
        scan
        echo ""
        echo "Nothing was changed. Run '$0 apply' to remove these."
        ;;
    apply)
        apply_cleanup
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac

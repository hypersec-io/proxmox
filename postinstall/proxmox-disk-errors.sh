#!/bin/bash

#############################################
# Proxmox VE Drive Error-Recovery Configuration
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
#   Bound how long a drive may spend retrying a bad sector, so a sick disk
#   returns an ERROR instead of stalling.
#
#   ZFS can only act on an error, never on a stall. A drive that retries
#   without bound never triggers the repair-from-redundancy path, so the bad
#   block is never healed and every I/O queued behind it waits. Redundancy you
#   cannot reach is not redundancy.
#
#   Two mechanisms, in order of preference:
#
#     1. SCT ERC -- ask the drive itself to give up after N deciseconds.
#        Supported by most enterprise/NAS drives and many prosumer SSDs, but
#        commonly ships DISABLED. Does not survive a power cycle, so it has to
#        be reapplied at every boot (hence the systemd unit).
#
#     2. Kernel command timeout -- /sys/block/<dev>/device/timeout. The only
#        backstop for drives with no SCT support. Defaults to 30s, which is far
#        longer than any healthy SATA I/O should ever take.
#
#   Set together, the drive gives up before the kernel does, and the kernel
#   gives up before the pool wedges.
#
# Origin:
#   Written after a host-wide outage on 2026-07-26. A consumer SATA SSD with a
#   single pending ECC sector retried indefinitely -- "SCT Commands not
#   supported" -- and its raidz1 pool wedged; one txg took 769 seconds. The
#   host's shared zvol taskq threads blocked behind it and guests on a
#   completely unrelated, healthy pool lost their I/O. SMART reported PASSED
#   throughout.
#
#   Generalised from the hardening Derek wrote by hand during that incident.
#   Two details are his and were reverted to after the generated versions
#   proved worse: addressing drives by /dev/disk/by-id rather than sdX, and
#   matching the udev rule on ID_MODEL rather than per-drive serial. Both
#   matter for the same reason -- the protection has to survive a reboot or a
#   disk swap without anyone remembering to re-run this.
#
# SAFETY -- READ THIS:
#   SCT ERC is only correct BECAUSE there is redundancy. Telling a drive in a
#   NON-redundant pool to give up early tells it to abandon data it might
#   otherwise have recovered, and nothing else holds a copy. This script
#   therefore refuses to set SCT ERC on members of pools with no redundancy,
#   and only lowers the kernel timeout on redundant pools.
#
# Usage:
#   sudo ./proxmox-disk-errors.sh [command]
#
# Commands:
#   apply   - Detect pool members, configure SCT ERC and timeouts (default)
#   status  - Report current per-drive settings and pool redundancy
#   remove  - Remove the udev rule and systemd unit
#
# Requirements:
#   - ZFS pools configured
#   - smartmontools (installed by proxmox-optimize.sh)
#   - Root privileges
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No (settings applied immediately and on every boot)
#
#############################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

UDEV_RULE="/etc/udev/rules.d/60-zfs-disk-timeouts.rules"
ERC_SERVICE="/etc/systemd/system/zfs-disk-erc.service"
ERC_HELPER="/usr/local/bin/zfs-disk-erc"

# SCT ERC read/write limit, in DECIseconds. 70 = 7.0s.
#
# The conventional value for a redundant array: long enough for a legitimate
# retry to succeed, short enough that ZFS repairs from redundancy rather than
# waiting, and comfortably under the kernel timeout so the drive errors before
# the kernel escalates to a bus reset (which disrupts every device on the bus).
ERC_DECISECONDS=70

# Kernel command timeout for drives that cannot do SCT ERC, in seconds.
# Must exceed ERC_DECISECONDS/10 so SCT wins where it is available.
NO_SCT_TIMEOUT=10

#---------------------------------------------------------------
# Pure helpers -- no hardware access, unit-testable
#---------------------------------------------------------------
# See tests/test-disk-errors.sh.

pool_has_redundancy() {
    # Does `zpool status` output ($1) describe a redundant layout?
    # A plain stripe has no mirror/raidz/draid vdev line.
    #
    # The trailing [-:] is not optional: real vdevs are always "mirror-0",
    # "raidz1-0", "draid1:2d:4c:0s-0". Without it, a plain stripe in a pool
    # called "mirrorbackup" reads as redundant, and this function's whole job
    # is to stop retry-bounding being applied where there is no second copy.
    local status_output="$1"
    echo "$status_output" | grep -qE '^[[:space:]]+(mirror|raidz[123]?|draid[123]?)[-:]'
}

scterc_supported() {
    # Does `smartctl -l scterc` output ($1) indicate SCT ERC is available?
    # Drives without it say "SCT Commands not supported" or similar.
    local scterc_output="$1"
    echo "$scterc_output" | grep -qi 'SCT Error Recovery Control:'
}

scterc_is_disabled() {
    # Supported but switched off -- the common factory default, and the case
    # that matters most: the capability is present and doing nothing.
    local scterc_output="$1"
    echo "$scterc_output" | grep -qi 'Disabled'
}

strip_partition_suffix() {
    # sdc1 -> sdc, nvme0n1p1 -> nvme0n1, sdc -> sdc.
    # Split out from base_device so it can be tested without real block devices.
    local name="$1"

    if [[ "$name" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$name" =~ ^([a-z]+)[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$name"
    fi
}

#---------------------------------------------------------------
# Hardware-facing
#---------------------------------------------------------------

require_root() {
    [ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }
    return 0
}

require_tools() {
    if ! command -v zpool >/dev/null 2>&1; then
        echo -e "${RED}ZFS is not installed on this system${NC}"
        exit 1
    fi
    if ! command -v smartctl >/dev/null 2>&1; then
        echo -e "${RED}smartctl not found -- install smartmontools${NC}"
        echo "  apt-get install -y smartmontools"
        exit 1
    fi
    return 0
}

base_device() {
    # Map a pool member (by-id path, partition, bare name) to its base block
    # device name, e.g. /dev/disk/by-id/ata-FOO-part1 -> sdc.
    local member="$1" resolved

    resolved=$(readlink -f "$member" 2>/dev/null || echo "$member")
    resolved=$(strip_partition_suffix "${resolved#/dev/}")

    [ -b "/dev/$resolved" ] && echo "$resolved"
    return 0
}

stable_device_path() {
    # A /dev/disk/by-id path for $1, or /dev/$1 if none exists.
    #
    # Reverted to Derek's original approach from the incident scripts, which
    # addressed drives by /dev/disk/by-id. The generated version used bare sdX
    # names and was worse: kernel names are assigned in discovery order and are
    # NOT stable across reboots, so a boot-time unit that reasserts drive
    # settings by kernel name can target a different disk than the one it was
    # written for. On a host where some drives take the setting and others
    # cannot, that is exactly how the wrong drive ends up unprotected.
    #
    # ata-/nvme- links carry model and serial and are preferred; wwn- links are
    # stable too but opaque, so they are only a fallback.
    local dev="$1" link base fallback=""

    for link in /dev/disk/by-id/*; do
        [ -e "$link" ] || continue
        base=$(basename "$link")
        case "$base" in *-part[0-9]*) continue ;; esac
        [ "$(readlink -f "$link")" = "/dev/$dev" ] || continue
        case "$base" in
            wwn-*) [ -z "$fallback" ] && fallback="$link" ;;
            *)     echo "$link"; return 0 ;;
        esac
    done

    if [ -n "$fallback" ]; then
        echo "$fallback"
        return 0
    fi
    echo "/dev/$dev"
}

pool_members() {
    # Base device names backing pool $1, one per line, deduplicated.
    local pool="$1" member dev
    while read -r member; do
        [ -z "$member" ] && continue
        dev=$(base_device "$member")
        [ -n "$dev" ] && echo "$dev"
    done < <(zpool list -vHP "$pool" 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}')
}

#---------------------------------------------------------------
# Apply
#---------------------------------------------------------------

apply_config() {
    echo -e "${GREEN}=== Proxmox Drive Error-Recovery Configuration ===${NC}"
    echo -e "${CYAN}Bounding retry time so ZFS sees errors, not stalls${NC}\n"

    local erc_devices=() timeout_devices=() skipped_pools=()
    local pool status_output redundant dev scterc

    for pool in $(zpool list -H -o name); do
        status_output=$(zpool status "$pool" 2>/dev/null)

        if pool_has_redundancy "$status_output"; then
            redundant=yes
        else
            redundant=no
            skipped_pools+=("$pool")
        fi

        echo -e "Pool ${CYAN}${pool}${NC} (redundant: ${redundant})"

        if [ "$redundant" = no ]; then
            # Deliberate: see the SAFETY note in the header. Early give-up on a
            # pool with no second copy destroys data that a longer retry might
            # have recovered.
            echo -e "  ${YELLOW}No redundancy -- leaving error recovery at drive defaults${NC}"
            continue
        fi

        while read -r dev; do
            [ -z "$dev" ] && continue

            scterc=$(smartctl -l scterc "/dev/$dev" 2>/dev/null || true)

            if scterc_supported "$scterc"; then
                if scterc_is_disabled "$scterc"; then
                    echo -e "  /dev/$dev: SCT ERC supported but ${YELLOW}Disabled${NC} -> enabling ${ERC_DECISECONDS}ds"
                else
                    echo -e "  /dev/$dev: SCT ERC supported, reasserting ${ERC_DECISECONDS}ds"
                fi
                erc_devices+=("$dev")
            else
                echo -e "  /dev/$dev: ${YELLOW}no SCT ERC${NC} -> kernel timeout ${NO_SCT_TIMEOUT}s"
                timeout_devices+=("$dev")
            fi
        done < <(pool_members "$pool")
    done

    if [ ${#erc_devices[@]} -eq 0 ] && [ ${#timeout_devices[@]} -eq 0 ]; then
        echo -e "\n${YELLOW}No redundant pool members found -- nothing to configure${NC}"
        return 0
    fi

    write_erc_service "${erc_devices[@]}"
    write_udev_rule "${timeout_devices[@]}"

    echo ""
    if [ ${#skipped_pools[@]} -gt 0 ]; then
        echo -e "${YELLOW}Skipped (no redundancy):${NC} ${skipped_pools[*]}"
    fi
    echo -e "${GREEN}=== Configuration Complete ===${NC}"
    echo ""
    # Report only what was actually done. Printing "SCT ERC on 0 drives,
    # reapplied every boot" describes a systemd unit that was not installed,
    # and reads as protection that is not there.
    echo "Applied:"
    if [ ${#erc_devices[@]} -gt 0 ]; then
        echo "  - SCT ERC ${ERC_DECISECONDS}ds on ${#erc_devices[@]} drive(s), reapplied every boot"
    else
        echo "  - SCT ERC: no drive supports it, nothing to reapply"
    fi
    if [ ${#timeout_devices[@]} -gt 0 ]; then
        echo "  - Kernel timeout ${NO_SCT_TIMEOUT}s on ${#timeout_devices[@]} drive(s) with no SCT support"
    else
        echo "  - Kernel timeout: not needed, every drive bounds its own retries"
    fi
    echo ""
    echo "Verify with: $0 status"
}

write_erc_service() {
    local devices=("$@")

    if [ ${#devices[@]} -eq 0 ]; then
        # Nothing supports SCT ERC on this host; remove any stale unit rather
        # than leaving one that reapplies settings to drives that are gone.
        if [ -f "$ERC_SERVICE" ]; then
            systemctl disable --now zfs-disk-erc.service >/dev/null 2>&1 || true
            rm -f "$ERC_SERVICE" "$ERC_HELPER"
            systemctl daemon-reload
        fi
        return 0
    fi

    # Resolve to stable by-id paths at generation time. The helper must not
    # depend on kernel names surviving a reboot -- see stable_device_path.
    local dev paths=()
    for dev in "${devices[@]}"; do
        paths+=("$(stable_device_path "$dev")")
    done

    # SCT ERC is volatile: it is lost on a power cycle (though usually not on a
    # warm reboot), so it must be reasserted at every boot rather than set once.
    {
        cat << EOF
#!/bin/bash
# Reassert SCT ERC on redundant pool members.
# Installed by: proxmox-disk-errors.sh -- do not edit, changes are overwritten.
#
# SCT ERC does not persist across a power cycle. Without this, the setting
# silently reverts to the factory default (usually Disabled) and the drive goes
# back to retrying without bound.
#
# Drives are addressed by /dev/disk/by-id, not sdX: kernel names are assigned
# in discovery order and a drive that moves between boots would otherwise have
# the setting applied to whatever took its old name.

EOF
        for dev in "${paths[@]}"; do
            printf 'for_each_drive+=("%s")\n' "$dev"
        done
        cat << EOF

for drive in "\${for_each_drive[@]}"; do
    # A drive that has been pulled or replaced must not fail the unit.
    [ -e "\$drive" ] || { logger -t zfs-disk-erc "absent, skipped: \$drive"; continue; }
    if smartctl -l scterc,${ERC_DECISECONDS},${ERC_DECISECONDS} "\$drive" >/dev/null 2>&1; then
        logger -t zfs-disk-erc "SCT ERC ${ERC_DECISECONDS}ds set on \$drive"
    else
        logger -t zfs-disk-erc "failed to set SCT ERC on \$drive"
    fi
done

exit 0
EOF
    } > "$ERC_HELPER"
    chmod +x "$ERC_HELPER"

    cat > "$ERC_SERVICE" << EOF
[Unit]
Description=Set SCT ERC on ZFS pool members
Documentation=https://github.com/hyperi-io/proxmox
# Must run after the pool is up so the members exist, and before anything
# starts writing to them in anger.
After=zfs-import.target
Wants=zfs-import.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ERC_HELPER}

[Install]
WantedBy=zfs.target
EOF

    systemctl daemon-reload
    systemctl enable zfs-disk-erc.service >/dev/null 2>&1 || true
    systemctl start zfs-disk-erc.service >/dev/null 2>&1 || true

    echo -e "\n${GREEN}OK Installed $ERC_SERVICE${NC}"
}

write_udev_rule() {
    local devices=("$@")
    local dev serial

    if [ ${#devices[@]} -eq 0 ]; then
        [ -f "$UDEV_RULE" ] && { rm -f "$UDEV_RULE"; udevadm control --reload-rules 2>/dev/null || true; }
        return 0
    fi

    {
        echo "# Kernel command timeout for ZFS pool members with no SCT ERC support."
        echo "# Installed by: proxmox-disk-errors.sh -- do not edit, changes are overwritten."
        echo "#"
        echo "# These drives cannot be told to stop retrying, so the kernel has to give"
        echo "# up on their behalf. The 30s default is far longer than any healthy SATA"
        echo "# I/O; ${NO_SCT_TIMEOUT}s converts a stall into an error ZFS can actually repair from."
        echo "#"
        echo "# Matched on MODEL, not serial -- reverted to Derek's original incident"
        echo "# rule, which matched ENV{ID_MODEL} and worked better than the generated"
        echo "# per-serial version that briefly replaced it."
        echo "#"
        echo "# Whether a drive supports SCT ERC is a property of the MODEL, so a"
        echo "# replacement of the same model needs the same backstop -- and would not"
        echo "# get it from a serial-specific rule until somebody remembered to re-run"
        echo "# this script. Fitting a replacement disk is exactly the moment nobody is"
        echo "# thinking about kernel timeouts."
        echo "#"
        echo "# DEVTYPE==\"disk\" restricts this to whole disks. A partition carries the"
        echo "# same model but has no device/timeout attribute of its own -- without the"
        echo "# restriction udev retries the assignment against every partition and logs"
        echo "# a failure for each."
        echo ""

        # One rule per distinct model, rather than one per drive.
        local models=() model seen
        for dev in "${devices[@]}"; do
            model=$(udevadm info --query=property --name="/dev/$dev" 2>/dev/null | \
                    sed -n 's/^ID_MODEL=//p' | head -1)
            if [ -z "$model" ]; then
                serial=$(udevadm info --query=property --name="/dev/$dev" 2>/dev/null | \
                         sed -n 's/^ID_SERIAL_SHORT=//p' | head -1)
                if [ -n "$serial" ]; then
                    echo "# ${dev}: no ID_MODEL exposed, falling back to serial"
                    echo "ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", ENV{ID_SERIAL_SHORT}==\"${serial}\", ATTR{device/timeout}=\"${NO_SCT_TIMEOUT}\""
                else
                    echo "# WARNING: no ID_MODEL or ID_SERIAL_SHORT for ${dev}; kernel name is not stable across reboots"
                    echo "ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", KERNEL==\"${dev}\", ATTR{device/timeout}=\"${NO_SCT_TIMEOUT}\""
                fi
                continue
            fi

            seen=0
            for m in "${models[@]:-}"; do
                [ "$m" = "$model" ] && { seen=1; break; }
            done
            [ "$seen" -eq 1 ] && continue
            models+=("$model")

            echo "# ${model} -- no SCT ERC support"
            echo "ACTION==\"add|change\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", ENV{ID_MODEL}==\"${model}\", ATTR{device/timeout}=\"${NO_SCT_TIMEOUT}\""
        done
    } > "$UDEV_RULE"

    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true

    # udev only fires on add/change, so apply now to devices already present.
    for dev in "${devices[@]}"; do
        [ -w "/sys/block/$dev/device/timeout" ] && echo "$NO_SCT_TIMEOUT" > "/sys/block/$dev/device/timeout"
    done

    echo -e "${GREEN}OK Installed $UDEV_RULE${NC}"
}

#---------------------------------------------------------------
# Status
#---------------------------------------------------------------

show_status() {
    echo -e "${GREEN}=== Drive Error-Recovery Status ===${NC}\n"

    if [ -f "$ERC_SERVICE" ]; then
        echo -e "SCT ERC unit:  ${GREEN}INSTALLED${NC} ($(systemctl is-enabled zfs-disk-erc.service 2>/dev/null || echo unknown))"
    else
        echo -e "SCT ERC unit:  ${YELLOW}NOT INSTALLED${NC}"
    fi
    if [ -f "$UDEV_RULE" ]; then
        echo -e "udev rule:     ${GREEN}INSTALLED${NC}"
    else
        echo -e "udev rule:     ${YELLOW}NOT INSTALLED${NC}"
    fi

    local pool status_output dev scterc timeout erc_state
    for pool in $(zpool list -H -o name); do
        status_output=$(zpool status "$pool" 2>/dev/null)
        if pool_has_redundancy "$status_output"; then
            echo -e "\nPool ${CYAN}${pool}${NC} (redundant)"
        else
            echo -e "\nPool ${CYAN}${pool}${NC} ${YELLOW}(NO redundancy -- error recovery left at defaults)${NC}"
        fi

        printf '  %-12s %-28s %s\n' "DEVICE" "SCT ERC" "KERNEL TIMEOUT"
        while read -r dev; do
            [ -z "$dev" ] && continue
            scterc=$(smartctl -l scterc "/dev/$dev" 2>/dev/null || true)
            if scterc_supported "$scterc"; then
                if scterc_is_disabled "$scterc"; then
                    erc_state="supported, DISABLED"
                else
                    erc_state=$(echo "$scterc" | grep -i 'Read:' | head -1 | tr -s ' ' | sed 's/^ *//')
                    erc_state="${erc_state:-supported, enabled}"
                fi
            else
                erc_state="not supported"
            fi
            timeout=$(cat "/sys/block/$dev/device/timeout" 2>/dev/null || echo "?")
            printf '  %-12s %-28s %ss\n' "$dev" "$erc_state" "$timeout"
        done < <(pool_members "$pool")
    done

    echo ""
    echo "A drive showing 'not supported' with a 30s timeout is the failure mode"
    echo "that caused the 2026-07-26 outage -- it can stall for 30s per I/O and"
    echo "ZFS will never see an error it can repair from."
}

#---------------------------------------------------------------
# Remove
#---------------------------------------------------------------

remove_config() {
    echo -e "${GREEN}=== Removing Drive Error-Recovery Configuration ===${NC}\n"
    local removed=false

    if [ -f "$ERC_SERVICE" ]; then
        systemctl disable --now zfs-disk-erc.service >/dev/null 2>&1 || true
        rm -f "$ERC_SERVICE" "$ERC_HELPER"
        systemctl daemon-reload
        echo -e "${GREEN}OK Removed $ERC_SERVICE${NC}"
        removed=true
    fi

    if [ -f "$UDEV_RULE" ]; then
        rm -f "$UDEV_RULE"
        udevadm control --reload-rules 2>/dev/null || true
        echo -e "${GREEN}OK Removed $UDEV_RULE${NC}"
        removed=true
    fi

    if [ "$removed" = false ]; then
        echo -e "${CYAN}Nothing installed${NC}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Note: drives keep their current SCT ERC and timeout until reboot.${NC}"
    echo "After reboot they revert to factory defaults (usually unbounded retries)."
}

show_help() {
    echo "Proxmox VE Drive Error-Recovery Configuration"
    echo ""
    echo "Usage: $0 {apply|status|remove}"
    echo ""
    echo "Commands:"
    echo "  apply   - Configure SCT ERC and kernel timeouts (default)"
    echo "  status  - Show current per-drive settings"
    echo "  remove  - Remove the udev rule and systemd unit"
    echo ""
    echo "Why:"
    echo "  ZFS can only act on an error, never on a stall. A drive that retries"
    echo "  a bad sector without bound never triggers repair-from-redundancy, so"
    echo "  the block is never healed and the pool wedges behind it."
    echo ""
    echo "  SCT ERC is only applied to pools that HAVE redundancy. On a single"
    echo "  disk, giving up early would discard recoverable data."
}

#############################################
# Main
#############################################

# Sourcing defines the functions without running anything, so the pure helpers
# can be unit-tested without hardware. See tests/test-disk-errors.sh.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

case "${1:-apply}" in
    apply)
        require_root
        require_tools
        apply_config
        ;;
    status)
        require_root
        require_tools
        show_status
        ;;
    remove)
        require_root
        remove_config
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac

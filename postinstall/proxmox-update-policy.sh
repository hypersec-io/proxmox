#!/bin/bash

#############################################
# Proxmox VE Conservative Update Policy
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
#   Implement a conservative update policy for Proxmox VE that pins
#   packages to one minor version behind the latest available. This
#   allows the latest patch level within that minor version while
#   avoiding bleeding-edge minor releases.
#
# Policy:
#   - MAJOR: Same as latest available
#   - MINOR: max(installed_minor, n-1) - never downgrades
#   - PATCH: Latest available within the target minor
#
# Example:
#   If repo has 9.2.3, 9.1.5, 9.0.8 available:
#   - Policy pins to 9.1.* (allowing up to 9.1.5)
#   If repo only has 9.0.x available:
#   - Policy pins to 9.0.* (can't go below 0)
#   If installed is 9.1.x and repo has 9.1.0 as latest:
#   - Policy pins to 9.1.* (never downgrades to 9.0.*)
#
# Usage:
#   sudo ./proxmox-update-policy.sh [command]
#
# Commands:
#   enable      - Enable conservative update policy (default)
#   disable     - Disable policy and allow all updates
#   status      - Show current policy and pinned versions
#   update      - Refresh pinning based on current repo state
#   cron-enable - Install daily cron job to auto-update pinning
#   cron-disable- Remove the cron job
#
# Requirements:
#   - Proxmox VE
#   - Root privileges
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No
#
#############################################

set -e

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
PREFERENCES_FILE="/etc/apt/preferences.d/proxmox-conservative"
CRON_FILE="/etc/cron.daily/proxmox-update-policy"
SCRIPT_PATH="$(readlink -f "$0")"

# Core Proxmox packages to pin
PROXMOX_PACKAGES=(
    "proxmox-ve"
    "pve-manager"
    "pve-kernel-*"
    "pve-qemu-kvm"
    "pve-container"
    "pve-firewall"
    "pve-ha-manager"
    "pve-cluster"
    "proxmox-backup-client"
    "proxmox-widget-toolkit"
)

# Must be root
[ $EUID -ne 0 ] && { echo "Run as root"; exit 1; }

#############################################
# Helper Functions
#############################################

get_installed_version() {
    local pkg="$1"
    dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo ""
}

get_installed_minor() {
    # Get the major.minor of the currently installed proxmox-ve
    local installed
    installed=$(get_installed_version "proxmox-ve")
    if [ -n "$installed" ]; then
        echo "$installed" | grep -oE '^[0-9]+\.[0-9]+' || echo ""
    else
        echo ""
    fi
}

get_available_versions() {
    # Get all available versions of proxmox-ve from apt cache
    # Returns sorted list of versions (newest first)
    apt-cache madison proxmox-ve 2>/dev/null | \
        awk -F'|' '{print $2}' | \
        tr -d ' ' | \
        sort -V -r | \
        uniq
}

get_latest_minor() {
    # Extract the highest minor version from available versions
    # Input: list of versions (one per line)
    # Output: major.minor (e.g., "9.2")
    local versions="$1"
    echo "$versions" | head -1 | grep -oE '^[0-9]+\.[0-9]+' || echo ""
}

get_target_minor() {
    # Calculate target minor version (n-1 from latest, minimum 0)
    # Input: major.minor string (e.g., "9.2")
    # Output: major.minor string (e.g., "9.1")
    local latest_minor="$1"
    local major minor target_minor

    major=$(echo "$latest_minor" | cut -d. -f1)
    minor=$(echo "$latest_minor" | cut -d. -f2)

    if [ "$minor" -gt 0 ]; then
        target_minor=$((minor - 1))
    else
        target_minor=0
    fi

    echo "${major}.${target_minor}"
}

get_available_minors() {
    # Get list of unique minor versions available
    # Input: list of versions
    # Output: unique major.minor values, sorted descending
    local versions="$1"
    echo "$versions" | grep -oE '^[0-9]+\.[0-9]+' | sort -V -r | uniq
}

show_status() {
    echo -e "${GREEN}=== Proxmox Update Policy Status ===${NC}\n"

    if [ -f "$PREFERENCES_FILE" ]; then
        echo -e "${CYAN}Policy: ENABLED (conservative n-1)${NC}"
        echo -e "Preferences file: $PREFERENCES_FILE\n"

        # Extract pinned version from file
        local pinned_version
        pinned_version=$(grep -oP 'Pin: version \K[0-9]+\.[0-9]+' "$PREFERENCES_FILE" 2>/dev/null | head -1)
        if [ -n "$pinned_version" ]; then
            echo -e "Pinned to minor version: ${CYAN}${pinned_version}.*${NC}"
        fi
    else
        echo -e "${YELLOW}Policy: DISABLED (all updates allowed)${NC}"
    fi

    # Cron status
    echo ""
    if [ -f "$CRON_FILE" ]; then
        echo -e "Auto-update cron: ${GREEN}ENABLED${NC} (daily)"
    else
        echo -e "Auto-update cron: ${YELLOW}DISABLED${NC}"
    fi

    echo ""
    echo -e "${GREEN}Current installation:${NC}"
    local pve_version
    pve_version=$(get_installed_version "proxmox-ve")
    local manager_version
    manager_version=$(get_installed_version "pve-manager")
    echo "  proxmox-ve:  $pve_version"
    echo "  pve-manager: $manager_version"

    echo ""
    echo -e "${GREEN}Repository analysis:${NC}"
    local versions
    versions=$(get_available_versions)

    if [ -z "$versions" ]; then
        echo -e "  ${RED}Could not query available versions${NC}"
        return
    fi

    local latest_minor
    latest_minor=$(get_latest_minor "$versions")
    local target_minor
    target_minor=$(get_target_minor "$latest_minor")
    local available_minors
    available_minors=$(get_available_minors "$versions")

    echo "  Latest available: $(echo "$versions" | head -1)"
    echo "  Latest minor: $latest_minor"
    echo "  Target minor (n-1): $target_minor"
    echo ""
    echo "  Available minor versions:"
    echo "$available_minors" | while read -r m; do
        local latest_patch
        latest_patch=$(echo "$versions" | grep "^${m}\." | head -1)
        if [ "$m" = "$target_minor" ]; then
            echo -e "    ${GREEN}• $m (target) - latest patch: $latest_patch${NC}"
        else
            echo "    • $m - latest patch: $latest_patch"
        fi
    done

    echo ""
    echo -e "${GREEN}APT policy for proxmox-ve:${NC}"
    apt-cache policy proxmox-ve 2>/dev/null | grep -E "Installed|Candidate" | sed 's/^/  /'
}

enable_policy() {
    local quiet="${1:-}"

    [ -z "$quiet" ] && echo -e "${GREEN}=== Enabling Conservative Update Policy ===${NC}\n"

    # Refresh apt cache first
    [ -z "$quiet" ] && echo "Refreshing package lists..."
    apt-get update >/dev/null 2>&1

    # Get available versions
    local versions
    versions=$(get_available_versions)

    if [ -z "$versions" ]; then
        echo -e "${RED}Error: Could not query available Proxmox versions${NC}"
        echo "Ensure apt sources are configured correctly"
        exit 1
    fi

    # Calculate target minor version
    local latest_minor
    latest_minor=$(get_latest_minor "$versions")
    if [ -z "$latest_minor" ]; then
        echo -e "${RED}Error: Could not determine latest minor version${NC}"
        exit 1
    fi

    local target_minor
    target_minor=$(get_target_minor "$latest_minor")

    # Get currently installed minor version as floor (never downgrade)
    local installed_minor
    installed_minor=$(get_installed_minor)

    # Ensure target is at least the installed minor (never downgrade)
    if [ -n "$installed_minor" ]; then
        # Compare versions: if installed > target, use installed as floor
        local installed_major installed_min target_major target_min
        installed_major=$(echo "$installed_minor" | cut -d. -f1)
        installed_min=$(echo "$installed_minor" | cut -d. -f2)
        target_major=$(echo "$target_minor" | cut -d. -f1)
        target_min=$(echo "$target_minor" | cut -d. -f2)

        # If installed minor is greater than computed target, use installed as floor
        if [ "$installed_major" -eq "$target_major" ] && [ "$installed_min" -gt "$target_min" ]; then
            [ -z "$quiet" ] && echo -e "${YELLOW}Note: Installed version ($installed_minor) > n-1 target ($target_minor)${NC}"
            [ -z "$quiet" ] && echo -e "${YELLOW}Using installed minor as floor: $installed_minor${NC}"
            target_minor="$installed_minor"
        fi
    fi

    # Verify target minor exists in repo
    local available_minors
    available_minors=$(get_available_minors "$versions")
    if ! echo "$available_minors" | grep -qE "^${target_minor}$"; then
        # Target minor not available, use latest minor instead
        [ -z "$quiet" ] && echo -e "${YELLOW}Note: Minor version $target_minor not available in repo${NC}"
        [ -z "$quiet" ] && echo -e "${YELLOW}Falling back to latest minor: $latest_minor${NC}"
        target_minor="$latest_minor"
    fi

    local latest_in_target
    latest_in_target=$(echo "$versions" | grep "^${target_minor}\." | head -1)

    [ -z "$quiet" ] && echo "Repository latest: $(echo "$versions" | head -1)"
    [ -z "$quiet" ] && echo "Latest minor: $latest_minor"
    [ -z "$quiet" ] && echo "Target minor (n-1): $target_minor"
    [ -z "$quiet" ] && echo "Latest patch in target: $latest_in_target"
    [ -z "$quiet" ] && echo ""

    # Build preferences file content
    local prefs_content
    local repo_latest
    repo_latest=$(echo "$versions" | head -1)
    prefs_content="# Proxmox VE Conservative Update Policy (n-1 minor)
# Generated: $(date -Iseconds)
#
# Policy: Stay one minor version behind latest
# Repository latest: ${repo_latest}
# Target minor: ${target_minor}.*
#
# This allows patch updates within ${target_minor}.x while avoiding
# bleeding-edge minor releases.
#
# To disable: sudo proxmox-update-policy.sh disable
# To refresh: sudo proxmox-update-policy.sh update

"

    for pkg in "${PROXMOX_PACKAGES[@]}"; do
        prefs_content+="Package: $pkg
Pin: version ${target_minor}.*
Pin-Priority: 1000

"
    done

    # Write preferences file
    echo "$prefs_content" > "$PREFERENCES_FILE"
    [ -z "$quiet" ] && echo -e "${GREEN}OK Created $PREFERENCES_FILE${NC}"

    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo -e "${GREEN}Conservative update policy enabled.${NC}"
    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo "Policy:"
    [ -z "$quiet" ] && echo "  • Pinned to minor version: $target_minor.*"
    [ -z "$quiet" ] && echo "  • Patch updates within $target_minor.x will install"
    [ -z "$quiet" ] && echo "  • Minor version $latest_minor.x will NOT auto-install"
    [ -z "$quiet" ] && echo ""
    [ -z "$quiet" ] && echo "The pinning updates automatically when:"
    [ -z "$quiet" ] && echo "  • You run: sudo $0 update"
    [ -z "$quiet" ] && echo "  • Cron job runs (if enabled with: sudo $0 cron-enable)"
}

disable_policy() {
    echo -e "${GREEN}=== Disabling Conservative Update Policy ===${NC}\n"

    if [ -f "$PREFERENCES_FILE" ]; then
        rm -f "$PREFERENCES_FILE"
        echo -e "${GREEN}OK Removed $PREFERENCES_FILE${NC}"

        echo "Updating package lists..."
        apt-get update >/dev/null 2>&1
        echo -e "${GREEN}OK Package lists updated${NC}"

        echo ""
        echo -e "${YELLOW}All Proxmox updates are now allowed.${NC}"
        echo "Run 'apt update && apt dist-upgrade' to upgrade to latest version."
    else
        echo -e "${CYAN}Policy already disabled (no preferences file found)${NC}"
    fi
}

update_policy() {
    echo -e "${GREEN}=== Updating Conservative Update Policy ===${NC}\n"

    if [ ! -f "$PREFERENCES_FILE" ]; then
        echo -e "${YELLOW}Policy not enabled. Run 'enable' first.${NC}"
        exit 1
    fi

    # Re-run enable to refresh pinning
    enable_policy
}

enable_cron() {
    echo -e "${GREEN}=== Enabling Daily Cron Job ===${NC}\n"

    cat > "$CRON_FILE" << EOF
#!/bin/bash
# Proxmox Conservative Update Policy - Daily refresh
# Installed by: proxmox-update-policy.sh cron-enable
#
# This job refreshes the APT pinning daily to track n-1 minor version

# Run quietly, only output on error
"$SCRIPT_PATH" update --quiet 2>&1 | logger -t proxmox-update-policy
EOF

    chmod +x "$CRON_FILE"
    echo -e "${GREEN}OK Installed $CRON_FILE${NC}"
    echo ""
    echo "The pinning will now update daily to track the n-1 minor version."
    echo "Check logs with: journalctl -t proxmox-update-policy"
}

disable_cron() {
    echo -e "${GREEN}=== Disabling Daily Cron Job ===${NC}\n"

    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        echo -e "${GREEN}OK Removed $CRON_FILE${NC}"
    else
        echo -e "${CYAN}Cron job already disabled${NC}"
    fi
}

show_help() {
    echo "Proxmox VE Conservative Update Policy"
    echo ""
    echo "Usage: $0 {enable|disable|status|update|cron-enable|cron-disable}"
    echo ""
    echo "Commands:"
    echo "  enable       - Enable policy (pin to n-1 minor version)"
    echo "  disable      - Disable policy (allow all updates)"
    echo "  status       - Show current policy and available versions"
    echo "  update       - Refresh pinning based on current repo state"
    echo "  cron-enable  - Install daily cron job to auto-update pinning"
    echo "  cron-disable - Remove the daily cron job"
    echo ""
    echo "Policy behaviour:"
    echo "  MAJOR: Same as latest available"
    echo "  MINOR: max(installed, n-1) - never downgrades below installed"
    echo "  PATCH: Latest available within target minor"
    echo ""
    echo "Example:"
    echo "  If repo has 9.2.3 as latest, policy pins to 9.1.*"
    echo "  If repo has 9.0.5 as latest, policy pins to 9.0.* (can't go below 0)"
}

#############################################
# Main
#############################################

case "${1:-help}" in
    enable)
        enable_policy
        ;;
    disable)
        disable_policy
        ;;
    status)
        show_status
        ;;
    update)
        if [ "${2:-}" = "--quiet" ]; then
            enable_policy "quiet"
        else
            update_policy
        fi
        ;;
    cron-enable)
        enable_cron
        ;;
    cron-disable)
        disable_cron
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac

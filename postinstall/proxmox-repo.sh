#!/bin/bash

#############################################
# Proxmox VE Repository Configuration
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
#   Configure Proxmox VE repositories for community (no-subscription)
#   use. Disables enterprise repositories and enables the free
#   community repository.
#
# Usage:
#   sudo ./proxmox-repo.sh
#
# Requirements:
#   - Proxmox VE (auto-detects version)
#   - Debian-based system (auto-detects codename)
#   - Root privileges
#   - Internet connection
#
# Features:
#   - Creates no-subscription repository configuration
#   - Disables enterprise repositories
#   - Updates package lists
#
# Note:
#   UI customizations (warning suppression) are handled separately by
#   proxmox-update-policy.sh when the conservative update policy is enabled.
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No
#
#############################################

set -e
trap 'error_handler $? $LINENO' ERR

# Error handler
error_handler() {
    echo -e "${RED}Error occurred at line $2 (exit code: $1)${NC}"
    echo "Attempting to continue..."
    set +e
}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Must be root
[ $EUID -ne 0 ] && { echo "Run as root"; exit 1; }

#############################################
# Auto-detect Debian Codename
#############################################

# Detect Debian codename from os-release
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DEBIAN_CODENAME="${VERSION_CODENAME:-}"
fi

# Fallback: try lsb_release
if [ -z "$DEBIAN_CODENAME" ] && command -v lsb_release &>/dev/null; then
    DEBIAN_CODENAME=$(lsb_release -cs 2>/dev/null || true)
fi

# Validate codename
if [ -z "$DEBIAN_CODENAME" ]; then
    echo -e "${RED}Error: Could not detect Debian codename${NC}"
    echo "Please ensure /etc/os-release exists or lsb_release is installed"
    exit 1
fi

echo -e "${GREEN}=== Proxmox Repository Configuration ===${NC}"
echo -e "Detected Debian codename: ${CYAN}${DEBIAN_CODENAME}${NC}\n"

#############################################
# Configure Repositories
#############################################
echo -e "${YELLOW}[1/2] Configuring repositories...${NC}"

# Configure Debian official repositories (using detected codename)
DEBIAN_SOURCES="/etc/apt/sources.list.d/debian-official.sources"
DEBIAN_SOURCES_CONTENT="Types: deb
URIs: http://deb.debian.org/debian
Suites: ${DEBIAN_CODENAME}
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${DEBIAN_CODENAME}-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: ${DEBIAN_CODENAME}-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"

if [ -f "$DEBIAN_SOURCES" ]; then
    EXISTING_CONTENT=$(cat "$DEBIAN_SOURCES")
    if [ "$EXISTING_CONTENT" = "$DEBIAN_SOURCES_CONTENT" ]; then
        echo -e "${CYAN}Debian official repositories already configured${NC}"
    else
        echo "$DEBIAN_SOURCES_CONTENT" > "$DEBIAN_SOURCES"
        echo -e "${GREEN}OK Debian official repositories updated${NC}"
    fi
else
    echo "$DEBIAN_SOURCES_CONTENT" > "$DEBIAN_SOURCES"
    echo -e "${GREEN}OK Debian official repositories configured${NC}"
fi

# Configure Proxmox no-subscription repository (using detected codename)
cat > /etc/apt/sources.list.d/proxmox.sources << EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${DEBIAN_CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

echo -e "${GREEN}OK Proxmox no-subscription repository configured${NC}"

# Clean up old/misnamed repository files
OLD_DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
if [ -f "$OLD_DEBIAN_SOURCES" ] && grep -q "download.proxmox.com" "$OLD_DEBIAN_SOURCES" 2>/dev/null; then
    rm -f "$OLD_DEBIAN_SOURCES"
    echo -e "${CYAN}Removed old misnamed file: $OLD_DEBIAN_SOURCES${NC}"
fi

# Disable enterprise repositories
if [ -f "/etc/apt/sources.list.d/pve-enterprise.sources" ]; then
    mv -n "/etc/apt/sources.list.d/pve-enterprise.sources" "/etc/apt/sources.list.d/pve-enterprise.sources.disabled" 2>/dev/null || true
    echo -e "${GREEN}OK Enterprise repository disabled${NC}"
else
    echo -e "${CYAN}Enterprise repository already disabled${NC}"
fi

if [ -f "/etc/apt/sources.list.d/ceph.sources" ]; then
    mv -n "/etc/apt/sources.list.d/ceph.sources" "/etc/apt/sources.list.d/ceph.sources.disabled" 2>/dev/null || true
    echo -e "${GREEN}OK Ceph repository disabled${NC}"
else
    echo -e "${CYAN}Ceph repository already disabled${NC}"
fi

#############################################
# Update Package Lists
#############################################
echo -e "\n${YELLOW}[2/2] Updating package lists...${NC}"
apt-get update >/dev/null 2>&1
echo -e "${GREEN}OK Package lists updated${NC}"

#############################################
# Summary
#############################################
echo -e "\n${GREEN}=== Configuration Complete ===${NC}"
echo ""
echo "Applied:"
echo "  • Debian ${DEBIAN_CODENAME} official repositories configured"
echo "  • Proxmox no-subscription repository enabled"
echo "  • Enterprise repositories disabled"
echo ""
echo "Next steps:"
echo "  • Run proxmox-update-policy.sh to enable conservative updates"
echo "    and suppress 'not recommended for production' warnings"
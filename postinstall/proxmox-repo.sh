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
#   community repository. Also applies UI customizations for community
#   edition branding and subscription nag removal.
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
#   - Removes subscription nag dialog
#   - Adds community edition branding to UI
#   - Installs APT hook to maintain customizations
#   - Updates package lists
#
# IMPORTANT NOTICE:
#   This script modifies Proxmox VE UI files which are licensed under AGPLv3.
#   The script itself is Apache 2.0, but modified Proxmox files remain AGPLv3.
#   This is provided for personal/internal use with pve-no-subscription repository.
#   Users must comply with Proxmox VE's AGPLv3 license terms and subscription policy.
#   See: https://www.proxmox.com/en/proxmox-ve/pricing
#
# Idempotent: Yes (safe to run multiple times)
# Requires Reboot: No
# Backup Location: /root/backup
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

# Create backup directory
BACKUP_DIR="/root/backup"
mkdir -p "$BACKUP_DIR"

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

echo -e "${GREEN}=== Proxmox Repository & UI Configuration ===${NC}"
echo -e "Detected Debian codename: ${CYAN}${DEBIAN_CODENAME}${NC}\n"

#############################################
# Configure Repositories
#############################################
echo -e "${YELLOW}[1/3] Configuring repositories...${NC}"

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

# Update package list
echo "Updating package lists..."
apt-get update >/dev/null 2>&1
echo -e "${GREEN}OK Package lists updated${NC}"

#############################################
# UI Customizations (Nag Removal + Branding)
#############################################
echo -e "\n${YELLOW}[2/3] Configuring UI customizations...${NC}"

WIDGET_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
HTML_FILE="/usr/share/pve-manager/index.html.tpl"
NEEDS_RESTART=false

# === Subscription Nag Removal ===
if [ -f "$WIDGET_FILE" ]; then
    if grep -qF "checked_command: function (orig_cmd) { orig_cmd(); }," "$WIDGET_FILE" 2>/dev/null; then
        echo -e "${CYAN}Subscription nag already removed${NC}"
    else
        START_COUNT=$(grep -c "^        checked_command: function (orig_cmd) {$" "$WIDGET_FILE" 2>/dev/null || echo "0")

        if [ "$START_COUNT" -eq 1 ]; then
            cp "$WIDGET_FILE" "$BACKUP_DIR/proxmoxlib.js.backup.$(date +%Y%m%d_%H%M%S)"
            sed -i "/checked_command: function (orig_cmd) {\$/,/^        },\$/c\\        checked_command: function (orig_cmd) { orig_cmd(); }," "$WIDGET_FILE"

            if grep -qF "checked_command: function (orig_cmd) { orig_cmd(); }," "$WIDGET_FILE"; then
                echo -e "${GREEN}OK Subscription nag removed${NC}"
                NEEDS_RESTART=true
            else
                echo -e "${YELLOW}Warning: Patch verification failed${NC}"
            fi
        elif [ "$START_COUNT" -eq 0 ]; then
            echo -e "${CYAN}Pattern not found (already patched or file changed)${NC}"
        else
            echo -e "${YELLOW}Warning: Pattern matches $START_COUNT times (expected 1)${NC}"
            echo "  Skipping to avoid breaking the file"
        fi
    fi
fi

# === Community Branding (Login Window) ===
if [ -f "$JS_FILE" ]; then
    if grep -qF "Proxmox VE Login (Community Repositories)" "$JS_FILE" 2>/dev/null; then
        echo -e "${CYAN}Login window already branded${NC}"
    else
        COUNT=$(grep -cF "title: gettext('Proxmox VE Login')," "$JS_FILE" 2>/dev/null || true)
        COUNT=${COUNT:-0}

        if [ "$COUNT" -eq 1 ]; then
            cp "$JS_FILE" "$BACKUP_DIR/pvemanagerlib.js.backup.$(date +%Y%m%d_%H%M%S)"
            sed -i "s/title: gettext('Proxmox VE Login'),/title: gettext('Proxmox VE Login (Community Repositories)'),/" "$JS_FILE"
            echo -e "${GREEN}OK Login window branded${NC}"
            NEEDS_RESTART=true
        elif [ "$COUNT" -eq 0 ]; then
            echo -e "${CYAN}Pattern not found (already patched)${NC}"
        else
            echo -e "${YELLOW}Warning: Pattern matches $COUNT times (expected 1), skipping${NC}"
        fi
    fi
fi

# === Community Branding (Browser Tab) ===
if [ -f "$HTML_FILE" ]; then
    if grep -qF "Proxmox Virtual Environment (Community Repositories)" "$HTML_FILE" 2>/dev/null; then
        echo -e "${CYAN}Browser tab already branded${NC}"
    else
        COUNT=$(grep -cF "<title>[% nodename %] - Proxmox Virtual Environment</title>" "$HTML_FILE" 2>/dev/null || true)
        COUNT=${COUNT:-0}

        if [ "$COUNT" -eq 1 ]; then
            cp "$HTML_FILE" "$BACKUP_DIR/index.html.tpl.backup.$(date +%Y%m%d_%H%M%S)"
            sed -i "s|<title>\[% nodename %\] - Proxmox Virtual Environment</title>|<title>[% nodename %] - Proxmox Virtual Environment (Community Repositories)</title>|" "$HTML_FILE"
            echo -e "${GREEN}OK Browser tab branded${NC}"
            NEEDS_RESTART=true
        elif [ "$COUNT" -eq 0 ]; then
            echo -e "${CYAN}Pattern not found (already patched)${NC}"
        else
            echo -e "${YELLOW}Warning: Pattern matches $COUNT times (expected 1), skipping${NC}"
        fi
    fi
fi

# === Restart Service Once ===
if [ "$NEEDS_RESTART" == "true" ]; then
    systemctl restart pveproxy.service >/dev/null 2>&1 && \
        echo -e "${GREEN}OK pveproxy service restarted${NC}" || \
        echo -e "${YELLOW}Warning: Could not restart pveproxy${NC}"
fi

#############################################
# Install APT Hook for Persistence
#############################################
echo -e "\n${YELLOW}[3/3] Installing APT hook for persistence...${NC}"

APT_HOOK_UI="/etc/apt/apt.conf.d/99proxmoxui"
HOOK_SCRIPT_UI="/usr/local/bin/proxmox-ui-hook.sh"

# Clean up old naming convention (backward compatibility)
OLD_APT_HOOK="/etc/apt/apt.conf.d/99-proxmox-ui.conf"
if [ -f "$OLD_APT_HOOK" ]; then
    rm -f "$OLD_APT_HOOK"
    echo -e "${CYAN}Removed old naming: $OLD_APT_HOOK${NC}"
fi

if [ ! -f "$APT_HOOK_UI" ]; then
    # Create unified hook script
    cat > "$HOOK_SCRIPT_UI" << 'HOOK_UI_EOF'
#!/bin/bash
# Proxmox UI Customization Hook (Nag Removal + Branding)

WIDGET_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
HTML_FILE="/usr/share/pve-manager/index.html.tpl"
NEEDS_RESTART=false

# === Subscription Nag Removal ===
if [ -f "$WIDGET_FILE" ]; then
    if ! grep -qF "checked_command: function (orig_cmd) { orig_cmd(); }," "$WIDGET_FILE" 2>/dev/null; then
        START_COUNT=$(grep -c "^        checked_command: function (orig_cmd) {$" "$WIDGET_FILE" 2>/dev/null || echo "0")
        if [ "$START_COUNT" -eq 1 ]; then
            sed -i "/checked_command: function (orig_cmd) {\$/,/^        },\$/c\\        checked_command: function (orig_cmd) { orig_cmd(); }," "$WIDGET_FILE"
            NEEDS_RESTART=true
        fi
    fi
fi

# === Community Branding (Login Window) ===
if [ -f "$JS_FILE" ]; then
    if ! grep -qF "Proxmox VE Login (Community Repositories)" "$JS_FILE" 2>/dev/null; then
        if grep -qF "title: gettext('Proxmox VE Login')," "$JS_FILE" 2>/dev/null; then
            sed -i "s/title: gettext('Proxmox VE Login'),/title: gettext('Proxmox VE Login (Community Repositories)'),/" "$JS_FILE"
            NEEDS_RESTART=true
        fi
    fi
fi

# === Community Branding (Browser Tab) ===
if [ -f "$HTML_FILE" ]; then
    if ! grep -qF "Proxmox Virtual Environment (Community Repositories)" "$HTML_FILE" 2>/dev/null; then
        if grep -qF "<title>[% nodename %] - Proxmox Virtual Environment</title>" "$HTML_FILE" 2>/dev/null; then
            sed -i "s|<title>\[% nodename %\] - Proxmox Virtual Environment</title>|<title>[% nodename %] - Proxmox Virtual Environment (Community Repositories)</title>|" "$HTML_FILE"
            NEEDS_RESTART=true
        fi
    fi
fi

# === Restart Service Once ===
[ "$NEEDS_RESTART" = "true" ] && systemctl restart pveproxy.service >/dev/null 2>&1
HOOK_UI_EOF

    chmod +x "$HOOK_SCRIPT_UI"

    # Create unified APT hook
    cat > "$APT_HOOK_UI" << 'APT_UI_EOF'
DPkg::Post-Invoke {
    "/usr/local/bin/proxmox-ui-hook.sh";
};
APT_UI_EOF

    echo -e "${GREEN}OK APT hook installed${NC}"
else
    echo -e "${CYAN}APT hook already installed${NC}"
fi

#############################################
# Summary
#############################################
echo -e "\n${GREEN}=== Configuration Complete ===${NC}"
echo ""
echo "Applied:"
echo "  • Debian ${DEBIAN_CODENAME} official repositories configured"
echo "  • Proxmox no-subscription repository enabled"
echo "  • Enterprise repositories disabled"
echo "  • Subscription nag removed"
echo "  • Community edition branding added"
echo "  • APT hook installed (maintains customizations)"
echo ""
echo "Notes:"
echo "  • UI modifications survive package updates via APT hooks"
echo "  • Modified Proxmox files remain under AGPLv3 license"
echo "  • Refresh browser to see UI changes (Ctrl+F5)"
echo ""
echo "Backups stored in: $BACKUP_DIR"